#!/usr/bin/env node

import { constants as fsConstants } from "node:fs";
import { access } from "node:fs/promises";
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");

const nativeTools = {
  bridge: {
    packageDirectory: path.join(repositoryRoot, "native", "WDSAxBridge"),
    executableName: "wds-ax-bridge",
  },
  overlay: {
    packageDirectory: path.join(repositoryRoot, "native", "WDSWhack"),
    executableName: "wds-whack",
  },
  sensor: {
    packageDirectory: path.join(repositoryRoot, "native", "WDSSensor"),
    executableName: "wds-sensor",
  },
};

const overlayDurationMilliseconds = 760;
const deletionDelayMilliseconds = 180;
const sensorExitGraceMilliseconds = 2_000;
const sensorForceKillGraceMilliseconds = 500;
const maximumSensorLineBytes = 256 * 1024;
const validMotionDirections = new Set([
  "stationary",
  "north",
  "northeast",
  "east",
  "southeast",
  "south",
  "southwest",
  "west",
  "northwest",
]);

const usage = `Usage:
  npm run native:whack -- --target <exact-text> --bundle-id <id> --delete [--capture-mouse-ms <100..5000>]
  npm run native:whack -- --target <exact-text> --bundle-id <id> --preview [--capture-mouse-ms <100..5000>]

Safety:
  Exactly one of --delete or --preview is required. The target must occur exactly
  once in the focused editable element. Mouse capture consumes derived summaries
  only, then stops before a fresh text inspection. This command never sends or
  submits text.`;

export class OrchestrationError extends Error {
  constructor(step, code, message, { deleted } = {}) {
    super(message);
    this.name = "OrchestrationError";
    this.step = step;
    this.code = code;
    this.deleted = deleted;
  }
}

function stationaryMouseMotion() {
  return { direction: "stationary", speed: 0, distance: 0 };
}

export function parseCaptureMouseMilliseconds(value) {
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    throw new OrchestrationError(
      "arguments",
      "invalid_capture_mouse_ms",
      "--capture-mouse-ms must be an integer between 100 and 5000.",
    );
  }
  const milliseconds = Number(value);
  if (!Number.isSafeInteger(milliseconds) || milliseconds < 100 || milliseconds > 5_000) {
    throw new OrchestrationError(
      "arguments",
      "invalid_capture_mouse_ms",
      "--capture-mouse-ms must be an integer between 100 and 5000.",
    );
  }
  return milliseconds;
}

function finiteRectangle(rectangle) {
  if (!rectangle || typeof rectangle !== "object") return null;
  const candidate = {
    x: Number(rectangle.x),
    y: Number(rectangle.y),
    width: Number(rectangle.width),
    height: Number(rectangle.height),
  };
  if (!Object.values(candidate).every(Number.isFinite)) return null;
  if (candidate.width <= 0 || candidate.height <= 0) return null;
  return candidate;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function graphemeCount(value) {
  const text = String(value);
  if (typeof Intl.Segmenter !== "function") return Array.from(text).length;
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  return Array.from(segmenter.segment(text)).length;
}

/**
 * Estimates a small overlay rectangle from the focused element when Electron does
 * not expose AXBoundsForRange. JavaScript indices and the bridge's NSRange are both
 * UTF-16 based, while the width estimate deliberately uses grapheme counts.
 */
export function fallbackRectFromFocusedFrame({
  focusedElementFrame,
  currentValue,
  target,
  utf16Range,
}) {
  const frame = finiteRectangle(focusedElementFrame);
  if (!frame) throw new TypeError("focusedElementFrame must be a finite, positive rectangle");
  if (typeof currentValue !== "string" || typeof target !== "string" || target.length === 0) {
    throw new TypeError("currentValue and a non-empty target are required");
  }
  if (
    !utf16Range ||
    !Number.isInteger(utf16Range.location) ||
    !Number.isInteger(utf16Range.length) ||
    utf16Range.location < 0 ||
    utf16Range.length < 1 ||
    currentValue.slice(
      utf16Range.location,
      utf16Range.location + utf16Range.length,
    ) !== target
  ) {
    throw new TypeError("utf16Range must identify the exact target");
  }

  const horizontalInset = Math.min(frame.width / 4, clamp(frame.width * 0.025, 5, 12));
  const verticalInset = Math.min(frame.height / 4, clamp(frame.height * 0.14, 3, 10));
  const usableWidth = Math.max(1, frame.width - horizontalInset * 2);
  const usableHeight = Math.max(1, frame.height - verticalInset * 2);
  const prefix = currentValue.slice(0, utf16Range.location);
  const prefixGraphemes = graphemeCount(prefix);
  const targetGraphemes = Math.max(1, graphemeCount(target));
  const allGraphemes = Math.max(1, graphemeCount(currentValue));

  // A capped per-grapheme estimate keeps the effect local for a short prefix and
  // prevents a long value from claiming the entire editable element.
  const glyphWidth = clamp(usableWidth / allGraphemes, 6, 12);
  const minimumTargetWidth = Math.min(18, usableWidth);
  const estimatedX = horizontalInset + prefixGraphemes * glyphWidth;
  const localX = clamp(
    estimatedX,
    horizontalInset,
    Math.max(horizontalInset, frame.width - horizontalInset - minimumTargetWidth),
  );
  const availableWidth = Math.max(1, frame.width - horizontalInset - localX);
  const width = Math.min(
    availableWidth,
    Math.max(minimumTargetWidth, targetGraphemes * glyphWidth),
  );
  const height = Math.min(32, usableHeight);

  return {
    x: frame.x + localX,
    y: frame.y + verticalInset,
    width,
    height,
  };
}

function rectanglesOverlap(a, b) {
  return (
    a.x < b.x + b.width &&
    a.x + a.width > b.x &&
    a.y < b.y + b.height &&
    a.y + a.height > b.y
  );
}

export function chooseOverlayRectangle(inspection) {
  const frame = finiteRectangle(inspection.focusedElementFrame);
  const exactBounds = finiteRectangle(inspection.targetBounds);
  const exactBoundsLookSane =
    exactBounds &&
    exactBounds.width <= 6_000 &&
    exactBounds.height <= 2_000 &&
    (!frame || rectanglesOverlap(exactBounds, frame));

  if (exactBoundsLookSane) {
    return { rectangle: exactBounds, source: "targetBounds" };
  }
  if (!frame) {
    throw new OrchestrationError(
      "inspect",
      "target_geometry_unavailable",
      "Neither valid target bounds nor a focused-element frame is available.",
    );
  }

  return {
    rectangle: fallbackRectFromFocusedFrame({
      focusedElementFrame: frame,
      currentValue: inspection.currentValue,
      target: inspection.target,
      utf16Range: inspection.utf16Range,
    }),
    source: "focusedElementFrameEstimate",
  };
}

export function parseArguments(arguments_) {
  if (arguments_.includes("--help") || arguments_.includes("-h")) {
    return { help: true };
  }

  const options = {
    target: null,
    bundleIdentifier: null,
    captureMouseMilliseconds: null,
    delete: false,
    preview: false,
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (
      argument === "--target" ||
      argument === "--bundle-id" ||
      argument === "--capture-mouse-ms"
    ) {
      const value = arguments_[index + 1];
      if (value === undefined || value.startsWith("--")) {
        throw new OrchestrationError("arguments", "missing_value", `${argument} requires a value.`);
      }
      const key = argument === "--target"
        ? "target"
        : argument === "--bundle-id"
          ? "bundleIdentifier"
          : "captureMouseMilliseconds";
      if (options[key] !== null) {
        throw new OrchestrationError("arguments", "duplicate_argument", `${argument} may be specified only once.`);
      }
      options[key] = argument === "--capture-mouse-ms"
        ? parseCaptureMouseMilliseconds(value)
        : value;
      index += 1;
    } else if (argument === "--delete" || argument === "--preview") {
      const key = argument.slice(2);
      if (options[key]) {
        throw new OrchestrationError("arguments", "duplicate_argument", `${argument} may be specified only once.`);
      }
      options[key] = true;
    } else {
      throw new OrchestrationError("arguments", "unexpected_argument", `Unexpected argument: ${argument}`);
    }
  }

  if (!options.target) {
    throw new OrchestrationError("arguments", "missing_target", "A non-empty --target value is required.");
  }
  if (!options.bundleIdentifier) {
    throw new OrchestrationError("arguments", "missing_bundle_id", "A non-empty --bundle-id value is required.");
  }
  if (options.delete === options.preview) {
    throw new OrchestrationError(
      "arguments",
      "explicit_mode_required",
      "Specify exactly one of --delete or --preview.",
    );
  }
  return options;
}

function nonnegativeFiniteNumber(
  value,
  field,
  { step = "sensor", code = "invalid_mouse_summary" } = {},
) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new OrchestrationError(
      step,
      code,
      `The ${step} input contains an invalid ${field}.`,
    );
  }
  return value;
}

/** Converts the aggregate sensor schema into the overlay's deliberately small input. */
export function motionFromMouseSummary(summary) {
  if (summary === null || summary === undefined) return stationaryMouseMotion();
  if (!summary || typeof summary !== "object" || Array.isArray(summary)) {
    throw new OrchestrationError(
      "sensor",
      "invalid_mouse_summary",
      "The mouse summary must be a JSON object.",
    );
  }

  const eventCount = summary.event_count;
  if (!Number.isSafeInteger(eventCount) || eventCount < 0) {
    throw new OrchestrationError(
      "sensor",
      "invalid_mouse_summary",
      "The mouse summary contains an invalid event_count.",
    );
  }
  if (eventCount === 0) return stationaryMouseMotion();

  const direction = summary.direction;
  if (typeof direction !== "string" || !validMotionDirections.has(direction)) {
    throw new OrchestrationError(
      "sensor",
      "invalid_mouse_summary",
      "The mouse summary contains an invalid direction.",
    );
  }

  return {
    direction,
    speed: nonnegativeFiniteNumber(
      summary.average_speed_points_per_second,
      "average_speed_points_per_second",
    ),
    distance: nonnegativeFiniteNumber(summary.distance_points, "distance_points"),
  };
}

function createMouseSensorJSONLParser(expectedBundleIdentifier) {
  let pending = "";
  let latestSummary = null;
  let failure = null;
  let sawStart = false;
  let sawStop = false;

  function fail(code, message) {
    if (!failure) failure = new OrchestrationError("sensor", code, message);
  }

  function consumeLine(rawLine) {
    const line = rawLine.trim();
    if (!line || failure) return;
    if (Buffer.byteLength(line, "utf8") > maximumSensorLineBytes) {
      fail("sensor_line_too_large", "The mouse sensor emitted an oversized JSON line.");
      return;
    }

    let record;
    try {
      record = JSON.parse(line);
    } catch {
      fail("invalid_sensor_jsonl", "The mouse sensor emitted invalid JSON Lines output.");
      return;
    }
    if (!record || typeof record !== "object" || Array.isArray(record)) {
      fail("invalid_sensor_jsonl", "The mouse sensor emitted a non-object JSON record.");
      return;
    }
    if (record.type === "error") {
      const code = typeof record.error?.code === "string" ? record.error.code : "sensor_reported_error";
      const message = typeof record.error?.message === "string"
        ? record.error.message
        : "The mouse sensor reported an error.";
      fail(code, message);
      return;
    }

    if (
      (record.type === "sensor_started" ||
        record.type === "mouse_summary" ||
        record.type === "sensor_stopped") &&
      record.bundle_id !== expectedBundleIdentifier
    ) {
      fail("sensor_scope_mismatch", "The mouse sensor output does not match the requested app.");
      return;
    }

    if (record.type === "sensor_started") {
      sawStart = true;
    } else if (record.type === "sensor_stopped") {
      sawStop = true;
    } else if (record.type === "mouse_summary") {
      try {
        // Deliberately retain only the latest derived aggregate, never snapshots or
        // raw mouse samples. The sensor is not launched with --emit-text.
        motionFromMouseSummary(record.summary);
        latestSummary = record.summary;
      } catch (error) {
        failure = error;
      }
    }
  }

  return {
    push(chunk) {
      if (failure) return;
      pending += chunk;
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() ?? "";
      for (const line of lines) consumeLine(line);
      if (Buffer.byteLength(pending, "utf8") > maximumSensorLineBytes) {
        fail("sensor_line_too_large", "The mouse sensor emitted an oversized JSON line.");
        pending = "";
      }
    },
    finish() {
      if (pending.trim()) consumeLine(pending);
      pending = "";
      if (failure) throw failure;
      if (!sawStart || !sawStop) {
        throw new OrchestrationError(
          "sensor",
          "incomplete_sensor_session",
          "The mouse sensor did not report a complete capture session.",
        );
      }
      return motionFromMouseSummary(latestSummary);
    },
    get failure() {
      return failure;
    },
  };
}

export function parseMouseSensorJSONLines(output, expectedBundleIdentifier) {
  if (typeof output !== "string" || typeof expectedBundleIdentifier !== "string") {
    throw new TypeError("String output and expectedBundleIdentifier are required");
  }
  const parser = createMouseSensorJSONLParser(expectedBundleIdentifier);
  parser.push(output);
  return parser.finish();
}

function exactOccurrenceCount(value, target) {
  let count = 0;
  let searchFrom = 0;
  while (searchFrom <= value.length) {
    const location = value.indexOf(target, searchFrom);
    if (location === -1) break;
    count += 1;
    searchFrom = location + 1;
  }
  return count;
}

export function sha256UTF8(value) {
  if (typeof value !== "string") throw new TypeError("A string value is required");
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export function validateInspection(payload, options) {
  if (!payload || payload.ok !== true) {
    throw new OrchestrationError("inspect", "invalid_bridge_response", "The bridge did not return a successful inspection.");
  }
  if (payload.target !== options.target || payload.bundleIdentifier !== options.bundleIdentifier) {
    throw new OrchestrationError("inspect", "inspection_scope_mismatch", "The bridge response does not match the requested target scope.");
  }
  if (typeof payload.currentValue !== "string") {
    throw new OrchestrationError("inspect", "invalid_current_value", "The bridge inspection omitted the focused text value.");
  }
  if (
    typeof payload.valueSHA256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(payload.valueSHA256) ||
    payload.valueSHA256 !== sha256UTF8(payload.currentValue)
  ) {
    throw new OrchestrationError(
      "inspect",
      "inspection_digest_mismatch",
      "The bridge digest does not match the exact inspected UTF-8 value.",
    );
  }
  if (
    !Number.isSafeInteger(payload.targetProcessIdentifier) ||
    payload.targetProcessIdentifier <= 0
  ) {
    throw new OrchestrationError(
      "inspect",
      "invalid_target_process",
      "The bridge inspection omitted a valid target process ID.",
    );
  }
  if (payload.occurrenceCount !== 1 || exactOccurrenceCount(payload.currentValue, options.target) !== 1) {
    throw new OrchestrationError("inspect", "target_not_unique", "The exact target must occur exactly once.");
  }

  const range = payload.utf16Range;
  if (
    !range ||
    !Number.isInteger(range.location) ||
    !Number.isInteger(range.length) ||
    range.location < 0 ||
    range.length !== options.target.length ||
    payload.currentValue.slice(range.location, range.location + range.length) !== options.target
  ) {
    throw new OrchestrationError("inspect", "target_range_mismatch", "The bridge range does not identify the exact target.");
  }

  return {
    ...payload,
    expectedRemainder:
      payload.currentValue.slice(0, range.location) +
      payload.currentValue.slice(range.location + range.length),
  };
}

export function bridgeArguments(command, options, inspection = null) {
  if (command !== "inspect" && command !== "delete") {
    throw new TypeError("Bridge command must be inspect or delete");
  }
  const arguments_ = [
    command,
    "--target",
    options.target,
    "--bundle-id",
    options.bundleIdentifier,
  ];
  if (command === "inspect") return arguments_;

  const range = inspection?.utf16Range;
  if (
    typeof inspection?.valueSHA256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(inspection.valueSHA256) ||
    !Number.isSafeInteger(inspection?.targetProcessIdentifier) ||
    inspection.targetProcessIdentifier <= 0 ||
    !range ||
    !Number.isSafeInteger(range.location) ||
    range.location < 0 ||
    !Number.isSafeInteger(range.length) ||
    range.length <= 0
  ) {
    throw new OrchestrationError(
      "delete",
      "invalid_delete_precondition",
      "Delete requires the digest, process ID, and exact UTF-16 range returned by inspect.",
      { deleted: false },
    );
  }

  return arguments_.concat([
    "--expected-value-sha256",
    inspection.valueSHA256,
    "--expected-pid",
    String(inspection.targetProcessIdentifier),
    "--expected-range-location",
    String(range.location),
    "--expected-range-length",
    String(range.length),
  ]);
}

export function validateDeletion(payload, inspection) {
  const deleted = payload?.deleted === true;
  const precondition = payload?.valuePrecondition;
  const preconditionKeys = precondition && typeof precondition === "object"
    ? Object.keys(precondition).sort()
    : [];
  if (
    !deleted ||
    typeof payload.resultValue !== "string" ||
    payload.resultValue !== inspection.expectedRemainder ||
    payload.valueSHA256 !== inspection.valueSHA256 ||
    Object.hasOwn(payload, "currentValue") ||
    preconditionKeys.length !== 2 ||
    preconditionKeys[0] !== "actualSHA256" ||
    preconditionKeys[1] !== "expectedSHA256" ||
    precondition.expectedSHA256 !== inspection.valueSHA256 ||
    precondition.actualSHA256 !== inspection.valueSHA256
  ) {
    throw new OrchestrationError(
      "delete",
      "delete_result_mismatch",
      "The bridge did not verify the exact expected remainder and full-draft digest.",
      { deleted },
    );
  }
  return payload;
}

function runExecutable(file, arguments_, { cwd } = {}) {
  return new Promise((resolve) => {
    execFile(
      file,
      arguments_,
      { cwd, encoding: "utf8", maxBuffer: 4 * 1024 * 1024 },
      (error, stdout, stderr) => {
        resolve({
          exitCode: error ? (typeof error.code === "number" ? error.code : null) : 0,
          launchCode: error && typeof error.code === "string" ? error.code : null,
          signal: error?.signal ?? null,
          stdout: stdout ?? "",
          stderr: stderr ?? "",
        });
      },
    );
  });
}

async function isExecutable(file) {
  try {
    await access(file, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function ensureNativeTool(specification) {
  const executable = path.join(
    specification.packageDirectory,
    ".build",
    "release",
    specification.executableName,
  );
  if (await isExecutable(executable)) return { executable, built: false };

  const build = await runExecutable("swift", ["build", "-c", "release"], {
    cwd: specification.packageDirectory,
  });
  if (build.exitCode !== 0 || build.launchCode) {
    throw new OrchestrationError(
      "build",
      build.launchCode ?? "swift_build_failed",
      `Could not build ${specification.executableName}.`,
    );
  }
  if (!(await isExecutable(executable))) {
    throw new OrchestrationError(
      "build",
      "built_executable_missing",
      `The build completed without producing ${specification.executableName}.`,
    );
  }
  return { executable, built: true };
}

async function captureMouseMotion(executable, options) {
  const milliseconds = options.captureMouseMilliseconds;
  const parser = createMouseSensorJSONLParser(options.bundleIdentifier);
  const child = spawn(
    executable,
    [
      "--bundle-id",
      options.bundleIdentifier,
      "--duration-ms",
      String(milliseconds),
      "--mouse-window-ms",
      String(milliseconds),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  let stderr = "";
  let timedOut = false;
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    parser.push(chunk);
    if (parser.failure) child.kill("SIGTERM");
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    if (stderr.length < 4_096) stderr += chunk;
  });

  let settled = false;
  const completion = new Promise((resolve) => {
    child.once("error", (error) => {
      if (!settled) {
        settled = true;
        resolve({ exitCode: null, signal: null, launchCode: error.code ?? "sensor_launch_failed" });
      }
    });
    child.once("close", (exitCode, signal) => {
      if (!settled) {
        settled = true;
        resolve({ exitCode, signal, launchCode: null });
      }
    });
  });

  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill("SIGTERM");
  }, milliseconds + sensorExitGraceMilliseconds);
  timeout.unref();
  const forceKill = setTimeout(() => {
    if (timedOut && !settled) child.kill("SIGKILL");
  }, milliseconds + sensorExitGraceMilliseconds + sensorForceKillGraceMilliseconds);
  forceKill.unref();

  const result = await completion;
  clearTimeout(timeout);
  clearTimeout(forceKill);

  if (timedOut) {
    throw new OrchestrationError(
      "sensor",
      "sensor_timeout",
      "The mouse sensor did not stop within the capture timeout.",
    );
  }
  if (parser.failure) throw parser.failure;
  if (result.launchCode) {
    throw new OrchestrationError(
      "sensor",
      result.launchCode,
      "The mouse sensor could not be launched.",
    );
  }
  if (result.exitCode !== 0 || result.signal) {
    throw new OrchestrationError(
      "sensor",
      "sensor_failed",
      stderr.trim() || "The mouse sensor did not exit cleanly.",
    );
  }
  return parser.finish();
}

function parseBridgeJSON(result, step) {
  if (result.launchCode) {
    throw new OrchestrationError(
      step,
      result.launchCode,
      "The accessibility bridge could not be launched.",
    );
  }
  if (!result.stdout.trim() && result.exitCode !== 0) {
    throw new OrchestrationError(
      step,
      "bridge_failed_without_json",
      `The accessibility bridge ${step} command failed without a JSON result.`,
    );
  }

  let payload;
  try {
    payload = JSON.parse(result.stdout.trim());
  } catch {
    throw new OrchestrationError(step, "invalid_bridge_json", "The accessibility bridge returned invalid JSON.");
  }

  if (result.exitCode !== 0 || result.launchCode || payload?.ok !== true) {
    const bridgeError = payload?.error;
    throw new OrchestrationError(
      step,
      bridgeError?.code ?? result.launchCode ?? "bridge_failed",
      bridgeError?.message ?? `The accessibility bridge ${step} command failed.`,
    );
  }
  return payload;
}

async function runBridge(executable, command, options, inspection = null) {
  const result = await runExecutable(
    executable,
    bridgeArguments(command, options, inspection),
  );
  return parseBridgeJSON(result, command);
}

function validateOverlayMotion(motion) {
  if (!motion || typeof motion !== "object" || !validMotionDirections.has(motion.direction)) {
    throw new OrchestrationError("overlay", "invalid_motion", "The overlay motion direction is invalid.");
  }
  const numericOptions = { step: "overlay", code: "invalid_motion" };
  const speed = nonnegativeFiniteNumber(motion.speed, "motion speed", numericOptions);
  const distance = nonnegativeFiniteNumber(motion.distance, "motion distance", numericOptions);
  return { direction: motion.direction, speed, distance };
}

export function overlayArguments(rectangle, motion) {
  const normalizedMotion = validateOverlayMotion(motion);
  return [
    "--x",
    String(rectangle.x),
    "--y",
    String(rectangle.y),
    "--width",
    String(rectangle.width),
    "--height",
    String(rectangle.height),
    "--duration-ms",
    String(overlayDurationMilliseconds),
    "--motion-direction",
    normalizedMotion.direction,
    "--motion-speed",
    String(normalizedMotion.speed),
    "--motion-distance",
    String(normalizedMotion.distance),
  ];
}

function launchOverlay(executable, rectangle, motion) {
  const arguments_ = overlayArguments(rectangle, motion);
  const child = spawn(executable, arguments_, {
    stdio: ["ignore", "ignore", "pipe"],
  });

  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    if (stderr.length < 4_096) stderr += chunk;
  });

  let settleStarted;
  const started = new Promise((resolve, reject) => {
    settleStarted = { resolve, reject };
  });
  let settled = false;
  const completion = new Promise((resolve) => {
    child.once("spawn", () => settleStarted.resolve());
    child.once("error", (error) => {
      settleStarted.reject(error);
      if (!settled) {
        settled = true;
        resolve({ exitCode: null, signal: null, launchCode: error.code ?? "overlay_launch_failed", stderr });
      }
    });
    child.once("close", (exitCode, signal) => {
      if (!settled) {
        settled = true;
        resolve({ exitCode, signal, launchCode: null, stderr });
      }
    });
  });

  const timeout = setTimeout(() => child.kill("SIGTERM"), overlayDurationMilliseconds + 4_000);
  timeout.unref();
  completion.finally(() => clearTimeout(timeout));
  return { started, completion };
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function assertOverlaySuccess(result, { deleted = false } = {}) {
  if (result.exitCode !== 0 || result.launchCode || result.signal) {
    throw new OrchestrationError(
      "overlay",
      result.launchCode ?? "overlay_failed",
      "The native overlay did not complete successfully.",
      { deleted },
    );
  }
}

async function orchestrate(options) {
  const toolPromises = [
    ensureNativeTool(nativeTools.bridge),
    ensureNativeTool(nativeTools.overlay),
  ];
  if (options.captureMouseMilliseconds !== null) {
    toolPromises.push(ensureNativeTool(nativeTools.sensor));
  }
  const [bridgeTool, overlayTool, sensorTool = null] = await Promise.all(toolPromises);

  const motion = sensorTool
    ? await captureMouseMotion(sensorTool.executable, options)
    : stationaryMouseMotion();

  // Capture has fully stopped before this point. Inspect again now so geometry and
  // the exact UTF-16 range cannot be reused from a stale pre-capture snapshot.
  const inspection = validateInspection(
    await runBridge(bridgeTool.executable, "inspect", options),
    options,
  );
  const geometry = chooseOverlayRectangle(inspection);
  const overlay = launchOverlay(overlayTool.executable, geometry.rectangle, motion);
  try {
    await overlay.started;
  } catch {
    const failed = await overlay.completion;
    assertOverlaySuccess(failed);
  }

  if (options.preview) {
    assertOverlaySuccess(await overlay.completion);
    return {
      ok: true,
      mode: "preview",
      deleted: false,
      boundsSource: geometry.source,
      mouseMotion: motion,
      built: {
        bridge: bridgeTool.built,
        overlay: overlayTool.built,
        ...(sensorTool ? { sensor: sensorTool.built } : {}),
      },
    };
  }

  const readiness = await Promise.race([
    sleep(deletionDelayMilliseconds).then(() => ({ ready: true })),
    overlay.completion.then((result) => ({ ready: false, result })),
  ]);
  if (!readiness.ready) {
    assertOverlaySuccess(readiness.result);
    throw new OrchestrationError(
      "overlay",
      "overlay_ended_early",
      "The overlay ended before the deletion cue; nothing was deleted.",
      { deleted: false },
    );
  }

  let deletion;
  try {
    deletion = await runBridge(bridgeTool.executable, "delete", options, inspection);
  } catch (error) {
    // Do not re-inspect or infer success after a non-zero delete subprocess. The
    // bridge's structured failure is the only reported mutation state.
    await overlay.completion;
    throw error;
  }

  try {
    deletion = validateDeletion(deletion, inspection);
  } catch (error) {
    await overlay.completion;
    throw error;
  }

  const overlayResult = await overlay.completion;
  assertOverlaySuccess(overlayResult, { deleted: true });
  return {
    ok: true,
    mode: "delete",
    deleted: true,
    deletionMethod: deletion.deletionMethod,
    boundsSource: geometry.source,
    mouseMotion: motion,
    built: {
      bridge: bridgeTool.built,
      overlay: overlayTool.built,
      ...(sensorTool ? { sensor: sensorTool.built } : {}),
    },
  };
}

async function main() {
  try {
    const options = parseArguments(process.argv.slice(2));
    if (options.help) {
      process.stdout.write(`${usage}\n`);
      return;
    }
    process.stdout.write(`${JSON.stringify(await orchestrate(options))}\n`);
  } catch (error) {
    const failure =
      error instanceof OrchestrationError
        ? error
        : new OrchestrationError("orchestrate", "unexpected_error", error?.message ?? String(error));
    const response = {
      ok: false,
      step: failure.step,
      error: { code: failure.code, message: failure.message },
    };
    if (typeof failure.deleted === "boolean") {
      response.deleted = failure.deleted;
    } else if (failure.step === "delete") {
      response.deletionState = "unverified";
    }
    process.stdout.write(`${JSON.stringify(response)}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await main();
}
