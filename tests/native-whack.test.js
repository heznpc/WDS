import test from "node:test";
import assert from "node:assert/strict";

import {
  bridgeArguments,
  chooseOverlayRectangle,
  fallbackRectFromFocusedFrame,
  motionFromMouseSummary,
  overlayArguments,
  parseArguments,
  parseCaptureMouseMilliseconds,
  parseMouseSensorJSONLines,
  sha256UTF8,
  validateDeletion,
  validateInspection,
} from "../scripts/native-whack.mjs";

const frame = { x: 249, y: 869, width: 724, height: 44 };

test("uses a valid exact AX range rectangle", () => {
  const result = chooseOverlayRectangle({
    focusedElementFrame: frame,
    targetBounds: { x: 260, y: 876, width: 74, height: 22 },
  });

  assert.equal(result.source, "targetBounds");
  assert.deepEqual(result.rectangle, { x: 260, y: 876, width: 74, height: 22 });
});

test("falls back to a small rectangle inside the focused input", () => {
  const result = fallbackRectFromFocusedFrame({
    focusedElementFrame: frame,
    currentValue: "이 문장만 남겨 주세요.",
    target: "이 문장만 ",
    utf16Range: { location: 0, length: 6 },
  });

  assert.ok(result.x >= frame.x && result.x < frame.x + frame.width);
  assert.ok(result.y >= frame.y && result.y < frame.y + frame.height);
  assert.ok(result.width > 0 && result.width < frame.width / 2);
  assert.ok(result.height > 0 && result.height <= frame.height);
});

test("rejects Electron's zero-sized range and estimates from the input frame", () => {
  const result = chooseOverlayRectangle({
    focusedElementFrame: frame,
    targetBounds: { x: 0, y: 956, width: 0, height: 0 },
    currentValue: "앞부분 뒤부분",
    target: "뒤부분",
    utf16Range: { location: 4, length: 3 },
  });

  assert.equal(result.source, "focusedElementFrameEstimate");
  assert.ok(result.rectangle.x > frame.x);
});

test("fails closed when the supplied UTF-16 range does not match the target", () => {
  assert.throws(
    () => fallbackRectFromFocusedFrame({
      focusedElementFrame: frame,
      currentValue: "문장",
      target: "문장",
      utf16Range: { location: 1, length: 2 },
    }),
    /exact target/,
  );
});

test("accepts only an integer mouse-capture duration from 100 through 5000 ms", () => {
  assert.equal(parseCaptureMouseMilliseconds("100"), 100);
  assert.equal(parseCaptureMouseMilliseconds("5000"), 5_000);

  for (const invalid of ["99", "5001", "100.5", "1e3", "", "-100"]) {
    assert.throws(
      () => parseCaptureMouseMilliseconds(invalid),
      (error) => error.code === "invalid_capture_mouse_ms",
    );
  }
});

test("parses the optional capture duration without weakening explicit mode", () => {
  const options = parseArguments([
    "--target",
    "정확한 구간",
    "--bundle-id",
    "example.desktop",
    "--capture-mouse-ms",
    "750",
    "--preview",
  ]);

  assert.equal(options.captureMouseMilliseconds, 750);
  assert.equal(options.preview, true);
  assert.equal(options.delete, false);
  assert.throws(
    () => parseArguments([
      "--target",
      "정확한 구간",
      "--bundle-id",
      "example.desktop",
      "--capture-mouse-ms",
      "750",
    ]),
    (error) => error.code === "explicit_mode_required",
  );
});

test("uses only the latest mouse summary and ignores redacted text snapshots", () => {
  const bundleIdentifier = "example.desktop";
  const output = [
    { type: "sensor_started", bundle_id: bundleIdentifier },
    {
      type: "mouse_summary",
      bundle_id: bundleIdentifier,
      summary: {
        event_count: 3,
        direction: "west",
        average_speed_points_per_second: 120,
        distance_points: 48,
      },
    },
    {
      type: "text_snapshot",
      bundle_id: bundleIdentifier,
      text_redacted: true,
      utf16_length: 27,
    },
    {
      type: "mouse_summary",
      bundle_id: bundleIdentifier,
      summary: {
        event_count: 7,
        direction: "northeast",
        average_speed_points_per_second: 432.5,
        distance_points: 219.25,
      },
    },
    { type: "sensor_stopped", bundle_id: bundleIdentifier },
  ].map((record) => JSON.stringify(record)).join("\n");

  assert.deepEqual(parseMouseSensorJSONLines(output, bundleIdentifier), {
    direction: "northeast",
    speed: 432.5,
    distance: 219.25,
  });
});

test("uses stationary zero motion when a clean capture has no mouse events", () => {
  assert.deepEqual(motionFromMouseSummary({ event_count: 0 }), {
    direction: "stationary",
    speed: 0,
    distance: 0,
  });

  const bundleIdentifier = "example.desktop";
  const output = [
    { type: "sensor_started", bundle_id: bundleIdentifier },
    { type: "sensor_stopped", bundle_id: bundleIdentifier },
  ].map((record) => JSON.stringify(record)).join("\n");
  assert.deepEqual(parseMouseSensorJSONLines(output, bundleIdentifier), {
    direction: "stationary",
    speed: 0,
    distance: 0,
  });
});

test("fails closed on malformed, errored, scoped, or incomplete sensor output", () => {
  const bundleIdentifier = "example.desktop";
  const started = JSON.stringify({ type: "sensor_started", bundle_id: bundleIdentifier });
  const stopped = JSON.stringify({ type: "sensor_stopped", bundle_id: bundleIdentifier });

  assert.throws(
    () => parseMouseSensorJSONLines(`${started}\nnot-json\n${stopped}`, bundleIdentifier),
    (error) => error.code === "invalid_sensor_jsonl",
  );
  assert.throws(
    () => parseMouseSensorJSONLines([
      started,
      JSON.stringify({
        type: "error",
        ok: false,
        error: { code: "permission_required", message: "Permission missing." },
      }),
    ].join("\n"), bundleIdentifier),
    (error) => error.code === "permission_required",
  );
  assert.throws(
    () => parseMouseSensorJSONLines([
      started,
      JSON.stringify({
        type: "mouse_summary",
        bundle_id: "different.desktop",
        summary: { event_count: 0 },
      }),
      stopped,
    ].join("\n"), bundleIdentifier),
    (error) => error.code === "sensor_scope_mismatch",
  );
  assert.throws(
    () => parseMouseSensorJSONLines(started, bundleIdentifier),
    (error) => error.code === "incomplete_sensor_session",
  );
});

test("passes derived motion to the overlay using the native CLI contract", () => {
  const arguments_ = overlayArguments(
    { x: 10, y: 20, width: 100, height: 30 },
    { direction: "southwest", speed: 321.5, distance: 88 },
  );

  assert.deepEqual(arguments_.slice(-6), [
    "--motion-direction",
    "southwest",
    "--motion-speed",
    "321.5",
    "--motion-distance",
    "88",
  ]);
  assert.throws(
    () => overlayArguments(
      { x: 10, y: 20, width: 100, height: 30 },
      { direction: "sideways", speed: 1, distance: 2 },
    ),
    (error) => error.code === "invalid_motion",
  );
});

test("retains the exact draft digest, PID, and UTF-16 range for delete", () => {
  const target = "지울 부분";
  const currentValue = `앞 ${target} 뒤`;
  const location = currentValue.indexOf(target);
  const options = { target, bundleIdentifier: "example.desktop" };
  const inspection = validateInspection({
    ok: true,
    target,
    bundleIdentifier: options.bundleIdentifier,
    currentValue,
    valueSHA256: sha256UTF8(currentValue),
    targetProcessIdentifier: 4123,
    occurrenceCount: 1,
    utf16Range: { location, length: target.length },
  }, options);

  assert.deepEqual(
    bridgeArguments("delete", options, inspection).slice(-8),
    [
      "--expected-value-sha256",
      sha256UTF8(currentValue),
      "--expected-pid",
      "4123",
      "--expected-range-location",
      String(location),
      "--expected-range-length",
      String(target.length),
    ],
  );
});

test("rejects an inspection whose full-draft digest does not match", () => {
  const target = "지울 부분";
  const original = `앞 ${target} 뒤`;
  const otherwiseModified = `바뀐 앞 ${target} 뒤`;
  const options = { target, bundleIdentifier: "example.desktop" };

  assert.throws(
    () => validateInspection({
      ok: true,
      target,
      bundleIdentifier: options.bundleIdentifier,
      currentValue: otherwiseModified,
      valueSHA256: sha256UTF8(original),
      targetProcessIdentifier: 4123,
      occurrenceCount: 1,
      utf16Range: {
        location: otherwiseModified.indexOf(target),
        length: target.length,
      },
    }, options),
    (error) => error.code === "inspection_digest_mismatch",
  );
});

test("delete bridge arguments fail closed without the retained precondition", () => {
  assert.throws(
    () => bridgeArguments(
      "delete",
      { target: "지울 부분", bundleIdentifier: "example.desktop" },
      { valueSHA256: sha256UTF8("지울 부분") },
    ),
    (error) => error.code === "invalid_delete_precondition" && error.deleted === false,
  );
});

test("accepts a delete precondition result containing only matching digests", () => {
  const valueSHA256 = sha256UTF8("앞 지울 부분 뒤");
  const inspection = { valueSHA256, expectedRemainder: "앞  뒤" };
  const payload = {
    deleted: true,
    valueSHA256,
    resultValue: inspection.expectedRemainder,
    valuePrecondition: {
      expectedSHA256: valueSHA256,
      actualSHA256: valueSHA256,
    },
  };

  assert.equal(validateDeletion(payload, inspection), payload);
  assert.throws(
    () => validateDeletion({
      ...payload,
      currentValue: "앞 지울 부분 뒤",
    }, inspection),
    (error) => error.code === "delete_result_mismatch" && error.deleted === true,
  );
  assert.throws(
    () => validateDeletion({
      ...payload,
      valuePrecondition: {
        ...payload.valuePrecondition,
        actualValue: "앞 지울 부분 뒤",
      },
    }, inspection),
    (error) => error.code === "delete_result_mismatch" && error.deleted === true,
  );
});
