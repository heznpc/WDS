import { createReadStream, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { pathToFileURL } from "node:url";
import {
  ContextJudgeServerError,
  judgeContext,
  REQUEST_BODY_LIMIT,
} from "./context-judge.mjs";

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 4173;
const allowedFiles = new Set(["/index.html", "/styles.css"]);
const allowedPrefixes = ["/src/"];

const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
};

class HttpError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

function writeJson(response, status, body, extraHeaders = {}) {
  if (response.headersSent || response.destroyed) return;
  response.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "X-Content-Type-Options": "nosniff",
    ...extraHeaders,
  });
  response.end(JSON.stringify(body));
}

function sameOriginRequest(request) {
  const host = request.headers.host;
  if (typeof host !== "string" || !/^127\.0\.0\.1(?::\d{1,5})?$/u.test(host)) return false;
  const origin = request.headers.origin;
  if (origin === undefined) return true;
  return origin === `http://${host}`;
}

async function readJsonBody(request) {
  const contentType = request.headers["content-type"];
  if (
    typeof contentType !== "string" ||
    contentType.split(";", 1)[0].trim().toLowerCase() !== "application/json"
  ) {
    throw new HttpError(415, "json_required");
  }

  const declaredLength = request.headers["content-length"];
  if (declaredLength !== undefined) {
    const parsedLength = Number(declaredLength);
    if (!Number.isSafeInteger(parsedLength) || parsedLength < 0) {
      throw new HttpError(400, "invalid_request");
    }
    if (parsedLength > REQUEST_BODY_LIMIT) throw new HttpError(413, "payload_too_large");
  }

  const chunks = [];
  let byteLength = 0;
  for await (const chunk of request) {
    byteLength += chunk.length;
    if (byteLength > REQUEST_BODY_LIMIT) {
      request.resume();
      throw new HttpError(413, "payload_too_large");
    }
    chunks.push(chunk);
  }
  if (byteLength === 0) throw new HttpError(400, "invalid_json");

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}

async function handleContextJudge(request, response, { judge, judgeOptions }) {
  if (!sameOriginRequest(request)) {
    writeJson(response, 403, { error: "forbidden_origin" });
    request.resume();
    return;
  }
  if (request.method !== "POST") {
    writeJson(response, 405, { error: "method_not_allowed" }, { Allow: "POST" });
    request.resume();
    return;
  }

  const controller = new AbortController();
  const onAborted = () => controller.abort();
  const onResponseClose = () => {
    if (!response.writableEnded) controller.abort();
  };
  request.once("aborted", onAborted);
  response.once("close", onResponseClose);

  try {
    const payload = await readJsonBody(request);
    const result = await judge(payload, { ...judgeOptions, signal: controller.signal });
    writeJson(response, 200, result);
  } catch (error) {
    if (controller.signal.aborted || response.destroyed) return;
    if (error instanceof HttpError || error instanceof ContextJudgeServerError) {
      writeJson(response, error.status, { error: error.code });
      return;
    }
    writeJson(response, 503, { error: "provider_failed" });
  } finally {
    request.removeListener("aborted", onAborted);
    response.removeListener("close", onResponseClose);
  }
}

function handleStatic(request, response, root) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, {
      Allow: "GET, HEAD",
      "Content-Type": "text/plain; charset=utf-8",
    });
    response.end("Method not allowed");
    return;
  }

  const rawPath = new URL(request.url || "/", "http://127.0.0.1").pathname;
  const requestedPath = rawPath === "/" ? "/index.html" : rawPath;
  if (
    !allowedFiles.has(requestedPath) &&
    !allowedPrefixes.some((prefix) => requestedPath.startsWith(prefix))
  ) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  const safePath = normalize(requestedPath).replace(/^(\.\.[/\\])+/u, "");
  const filePath = join(root, safePath);
  if (!filePath.startsWith(root)) {
    response.writeHead(403);
    response.end("Forbidden");
    return;
  }

  try {
    if (!statSync(filePath).isFile()) throw new Error("Not a file");
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Type": mimeTypes[extname(filePath)] || "application/octet-stream",
      "X-Content-Type-Options": "nosniff",
    });
    if (request.method === "HEAD") {
      response.end();
      return;
    }
    createReadStream(filePath).pipe(response);
  } catch {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
  }
}

export function createWdsServer({
  root = process.cwd(),
  judge = judgeContext,
  judgeOptions = {},
} = {}) {
  return createServer((request, response) => {
    let pathname;
    try {
      pathname = new URL(request.url || "/", "http://127.0.0.1").pathname;
    } catch {
      response.writeHead(400);
      response.end("Bad request");
      return;
    }

    if (pathname === "/api/context-judge") {
      void handleContextJudge(request, response, { judge, judgeOptions });
      return;
    }
    handleStatic(request, response, root);
  });
}

export function startWdsServer({
  host = DEFAULT_HOST,
  port = Number.parseInt(process.env.PORT || String(DEFAULT_PORT), 10),
  ...options
} = {}) {
  const server = createWdsServer(options);
  server.listen(port, host, () => {
    const address = server.address();
    const listeningPort = typeof address === "object" && address ? address.port : port;
    console.log(`WDS is running at http://${host}:${listeningPort}`);
  });
  return server;
}

const isMain = process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;
if (isMain) startWdsServer();
