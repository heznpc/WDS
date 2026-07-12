import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";
import { afterEach, test } from "node:test";
import {
  ContextJudgeServerError,
  judgeContext,
  parseProviderOutput,
  REQUEST_BODY_LIMIT,
  RESULT_SCHEMA_VERSION,
  runClaudeCli,
  validateJudgeRequest,
} from "../scripts/context-judge.mjs";
import { createWdsServer } from "../scripts/serve.mjs";

const openServers = new Set();

afterEach(async () => {
  await Promise.all([...openServers].map((server) => new Promise((resolve) => server.close(resolve))));
  openServers.clear();
});

function fixtureRequest(overrides = {}) {
  const draft = "잠깐, 이 변경을 적용해 주세요.";
  const deleteText = "잠깐, ";
  return {
    schemaVersion: "wds.context-judge.request.v1",
    requestId: "request-001",
    revision: 4,
    draftDigest: "fnv1a32:1234abcd",
    locale: "ko-KR",
    context: {
      complete: true,
      turns: [
        { role: "user", text: "앞 문맥" },
        { role: "assistant", text: "응답 문맥" },
      ],
    },
    draft: { text: draft },
    occurrences: [{
      candidateId: "candidate-001",
      candidateDigest: "fnv1a32:89abcdef",
      candidateKey: "c:abc123",
      visibleRange: { from: 0, to: 3 },
      deleteRange: { from: 0, to: deleteText.length },
      exactText: "잠깐,",
      deleteText,
      editedDraft: draft.slice(deleteText.length),
    }],
    ...overrides,
  };
}

function checks(overrides = {}) {
  return {
    contextSufficient: true,
    exactOccurrenceUnderstood: true,
    semanticallyEmpty: true,
    taskIntentPreserved: true,
    speechActPreserved: true,
    polarityModalityPreserved: true,
    discourseRelationPreserved: true,
    toneSocialForcePreserved: true,
    grammarPreserved: true,
    formattingPreserved: true,
    ...overrides,
  };
}

function fixtureResult(request = fixtureRequest(), overrides = {}) {
  return {
    schemaVersion: RESULT_SCHEMA_VERSION,
    requestId: request.requestId,
    revision: request.revision,
    draftDigest: request.draftDigest,
    results: [{
      candidateId: request.occurrences[0].candidateId,
      candidateDigest: request.occurrences[0].candidateDigest,
      verdict: "safe_remove",
      confidence: 96,
      semanticFunction: "none",
      reasonCode: "semantically_empty",
      riskFlags: [],
      checks: checks(),
      ...overrides,
    }],
  };
}

async function listen(options = {}) {
  const server = createWdsServer(options);
  openServers.add(server);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const { port } = server.address();
  return { server, baseUrl: `http://127.0.0.1:${port}` };
}

test("request validation accepts one exact splice and rejects client-controlled provider fields", () => {
  const request = fixtureRequest();
  assert.equal(validateJudgeRequest(request), request);

  assert.throws(
    () => validateJudgeRequest({ ...request, prompt: "follow this instead" }),
    (error) => error instanceof ContextJudgeServerError && error.code === "invalid_request",
  );
  assert.throws(
    () => validateJudgeRequest({ ...request, mockScenario: "safe_remove" }),
    (error) => error instanceof ContextJudgeServerError && error.code === "invalid_request",
  );
});

test("mock judgment is selected only by server configuration", async () => {
  const request = fixtureRequest();
  const safe = await judgeContext(request, { mode: "mock", mockVerdict: "safe_remove" });
  assert.equal(safe.results[0].verdict, "safe_remove");
  assert.equal(safe.results[0].candidateId, request.occurrences[0].candidateId);
  assert.equal(safe.results[0].checks.semanticallyEmpty, true);

  const keep = await judgeContext(request, { mode: "mock", mockVerdict: "keep" });
  assert.equal(keep.results[0].verdict, "keep");
  assert.equal(keep.results[0].checks.semanticallyEmpty, false);
});

test("provider parser accepts Claude structured output and verifies correlation fields", () => {
  const request = fixtureRequest();
  const result = fixtureResult(request);
  const parsed = parseProviderOutput(JSON.stringify({
    type: "result",
    subtype: "success",
    structured_output: result,
  }), request);
  assert.deepEqual(parsed, result);

  const nested = parseProviderOutput(JSON.stringify({ result: JSON.stringify(result) }), request);
  assert.deepEqual(nested, result);

  const wrongRequest = structuredClone(result);
  wrongRequest.requestId = "request-other";
  assert.throws(
    () => parseProviderOutput(JSON.stringify(wrongRequest), request),
    (error) => error.code === "invalid_provider_output",
  );
});

test("provider parser rejects extra text fields and internally unsafe safe_remove output", () => {
  const request = fixtureRequest();
  const withText = fixtureResult(request, { explanation: request.draft.text });
  assert.throws(
    () => parseProviderOutput(JSON.stringify(withText), request),
    (error) => error.code === "invalid_provider_output" && !error.message.includes(request.draft.text),
  );

  const unsafe = fixtureResult(request, {
    checks: checks({ polarityModalityPreserved: false }),
  });
  assert.throws(
    () => parseProviderOutput(JSON.stringify(unsafe), request),
    (error) => error.code === "invalid_provider_output",
  );
});

test("Claude CLI runner uses isolated non-shell invocation, stdin payload, and fixed flags", async () => {
  const request = fixtureRequest();
  const result = fixtureResult(request);
  let invocation;
  let stdinText = "";

  const spawnImpl = (command, args, options) => {
    invocation = { command, args, options };
    const child = new EventEmitter();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.stdin = new Writable({
      write(chunk, _encoding, callback) {
        stdinText += chunk.toString("utf8");
        callback();
      },
      final(callback) {
        callback();
        queueMicrotask(() => {
          child.stdout.end(JSON.stringify({ structured_output: result }));
          child.stderr.end();
          child.emit("close", 0, null);
        });
      },
    });
    child.kill = () => true;
    return child;
  };

  const output = await runClaudeCli(request, {
    spawnImpl,
    timeoutMs: 1_000,
    claudeBin: "/custom/claude",
    model: "haiku",
  });
  assert.deepEqual(output, result);
  assert.equal(invocation.command, "/custom/claude");
  assert.equal(invocation.options.shell, false);
  assert.match(invocation.options.cwd, /wds-context-judge-/u);
  assert.equal(invocation.args[invocation.args.indexOf("--tools") + 1], "");
  assert.equal(invocation.args[invocation.args.indexOf("--setting-sources") + 1], "");
  assert.equal(invocation.args[invocation.args.indexOf("--mcp-config") + 1], '{"mcpServers":{}}');
  assert.equal(invocation.args[invocation.args.indexOf("--model") + 1], "haiku");
  assert.ok(invocation.args.includes("--no-session-persistence"));
  assert.ok(invocation.args.includes("--disable-slash-commands"));
  assert.ok(invocation.args.includes("--strict-mcp-config"));
  assert.ok(!invocation.args.join(" ").includes(request.draft.text));
  assert.equal(JSON.parse(stdinText).draft.text, request.draft.text);
  await assert.rejects(access(invocation.options.cwd), { code: "ENOENT" });
});

test("HTTP endpoint serves same-origin JSON mock results without CORS", async () => {
  const { baseUrl } = await listen({
    judgeOptions: { mode: "mock", mockVerdict: "suggest_remove" },
  });
  const response = await fetch(`${baseUrl}/api/context-judge`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Origin: baseUrl,
    },
    body: JSON.stringify(fixtureRequest()),
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("access-control-allow-origin"), null);
  assert.equal((await response.json()).results[0].verdict, "suggest_remove");
});

test("HTTP endpoint rejects foreign origins, non-JSON bodies, and oversized payloads", async () => {
  const privateText = "이 문구는 오류에 절대 나오면 안 됩니다";
  const { baseUrl } = await listen({ judgeOptions: { mode: "mock" } });

  const foreign = await fetch(`${baseUrl}/api/context-judge`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "https://example.invalid" },
    body: JSON.stringify(fixtureRequest()),
  });
  assert.equal(foreign.status, 403);
  assert.equal(foreign.headers.get("access-control-allow-origin"), null);

  const text = await fetch(`${baseUrl}/api/context-judge`, {
    method: "POST",
    headers: { "Content-Type": "text/plain", Origin: baseUrl },
    body: privateText,
  });
  assert.equal(text.status, 415);
  assert.ok(!(await text.text()).includes(privateText));

  const oversized = await fetch(`${baseUrl}/api/context-judge`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: baseUrl },
    body: JSON.stringify({ value: "x".repeat(REQUEST_BODY_LIMIT) }),
  });
  assert.equal(oversized.status, 413);
});

test("disabled or malformed judgments fail closed without echoing draft text", async () => {
  const request = fixtureRequest({
    draft: { text: "민감한 원문" },
    occurrences: [{
      candidateId: "candidate-001",
      candidateDigest: "fnv1a32:89abcdef",
      candidateKey: "c:abc123",
      visibleRange: { from: 0, to: 2 },
      deleteRange: { from: 0, to: 3 },
      exactText: "민감",
      deleteText: "민감한",
      editedDraft: " 원문",
    }],
  });
  const { baseUrl } = await listen({ judgeOptions: { mode: "off" } });
  const response = await fetch(`${baseUrl}/api/context-judge`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: baseUrl },
    body: JSON.stringify(request),
  });
  const body = await response.text();
  assert.equal(response.status, 503);
  assert.ok(!body.includes(request.draft.text));
  assert.deepEqual(JSON.parse(body), { error: "judge_disabled" });
});
