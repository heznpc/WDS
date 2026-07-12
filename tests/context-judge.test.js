import test from "node:test";
import assert from "node:assert/strict";

import {
  buildJudgePayload,
  createContextOccurrence,
  createExplicitRemovalPlan,
  normalizeJudgeResponse,
} from "../src/context-judge.js";

const CHECK_KEYS = [
  "contextSufficient",
  "exactOccurrenceUnderstood",
  "semanticallyEmpty",
  "taskIntentPreserved",
  "speechActPreserved",
  "polarityModalityPreserved",
  "discourseRelationPreserved",
  "toneSocialForcePreserved",
  "grammarPreserved",
  "formattingPreserved",
];

function makeFixture({ text = "음, 버튼을 작게 해주세요.", revision = 3 } = {}) {
  const visibleTo = text.indexOf(",") + 1;
  const occurrence = createContextOccurrence({
    text,
    revision,
    suggestion: {
      key: "local-candidate",
      from: 0,
      to: visibleTo > 0 ? visibleTo : text.length,
      consumedTo: text[visibleTo] === " " ? visibleTo + 1 : (visibleTo > 0 ? visibleTo : text.length),
      sourceText: text,
    },
  });
  const payload = buildJudgePayload({
    occurrence,
    requestId: "request-1",
    turns: [
      { role: "user", text: "버튼을 손보고 있습니다." },
      { role: "assistant", text: "어느 부분을 바꿀까요?" },
    ],
  });
  return { occurrence, payload };
}

function checks(overrides = {}) {
  return Object.fromEntries(CHECK_KEYS.map((key) => [key, overrides[key] ?? true]));
}

function responseFor(payload, overrides = {}) {
  const [target] = payload.occurrences;
  return {
    schemaVersion: "wds.context-judge.result.v1",
    requestId: payload.requestId,
    revision: payload.revision,
    draftDigest: payload.draftDigest,
    results: [{
      candidateId: target.candidateId,
      candidateDigest: target.candidateDigest,
      verdict: "keep",
      confidence: 88,
      semanticFunction: "discourse_marker",
      reasonCode: "meaning_bearing",
      riskFlags: [],
      checks: checks(),
      ...overrides,
    }],
  };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

test("로컬 suggestion에서 표시 범위와 한 개의 정확한 삭제 범위를 만든다", () => {
  const text = "음, 버튼을 작게 해주세요.";
  const { occurrence, payload } = makeFixture({ text });

  assert.equal(occurrence.exactText, "음,");
  assert.equal(occurrence.deleteText, "음, ");
  assert.equal(occurrence.editedDraft, "버튼을 작게 해주세요.");
  assert.deepEqual(occurrence.visibleRange, { from: 0, to: 2 });
  assert.deepEqual(occurrence.deleteRange, { from: 0, to: 3 });
  assert.match(occurrence.draftDigest, /^fnv1a32:[0-9a-f]{8}$/u);
  assert.match(occurrence.candidateDigest, /^fnv1a32:[0-9a-f]{8}$/u);

  assert.deepEqual(payload.occurrences[0].deleteRange, { from: 0, to: 3 });
  assert.equal(payload.draft.text, text);
  assert.equal(payload.context.complete, true);
  assert.deepEqual(payload.context.turns[0], { role: "user", text: "버튼을 손보고 있습니다." });
});

test("문자열 suggestion은 정확히 한 번 등장할 때만 occurrence가 된다", () => {
  const occurrence = createContextOccurrence({
    text: "잠깐, 이 부분을 봐주세요.",
    suggestion: "잠깐,",
    revision: 1,
  });
  assert.equal(occurrence.exactText, "잠깐,");

  assert.throws(
    () => createContextOccurrence({ text: "찾을 수 없습니다.", suggestion: "없음", revision: 1 }),
    /현재 입력에 없습니다/u,
  );
  assert.throws(
    () => createContextOccurrence({ text: "음 음", suggestion: "음", revision: 1 }),
    /여러 번/u,
  );
});

test("중복 문자열도 로컬 UTF-16 범위가 있으면 한 occurrence로 특정된다", () => {
  const occurrence = createContextOccurrence({
    text: "음 음",
    revision: 2,
    suggestion: { key: "second", from: 2, to: 3 },
  });

  assert.deepEqual(occurrence.visibleRange, { from: 2, to: 3 });
  assert.equal(occurrence.exactText, "음");
});

test("UTF-16 offset은 이모지 grapheme 전체 경계만 허용한다", () => {
  const emoji = "👩🏽‍💻";
  const text = `${emoji} 확인해 주세요.`;
  const occurrence = createContextOccurrence({
    text,
    revision: 4,
    suggestion: { key: "emoji", from: 0, to: emoji.length, consumedTo: emoji.length + 1 },
  });

  assert.equal(occurrence.exactText, emoji);
  assert.equal(occurrence.visibleRange.to, emoji.length);
  assert.throws(
    () => createContextOccurrence({
      text,
      revision: 4,
      suggestion: { key: "split-emoji", from: 0, to: 2 },
    }),
    /grapheme/u,
  );
});

test("malformed raw response는 예외 대신 fail-keep으로 정규화한다", () => {
  const { payload } = makeFixture();
  const expected = {
    status: "keep",
    confidence: 0,
    reasonCode: "MALFORMED_RESPONSE",
    semanticFunction: "unknown",
  };

  assert.deepEqual(normalizeJudgeResponse({ payload, response: "not-json" }), expected);
  assert.deepEqual(normalizeJudgeResponse({ payload, response: null }), expected);
});

test("결과 누락·중복·추가는 모두 fail-keep한다", () => {
  const { payload } = makeFixture();
  const missing = responseFor(payload);
  missing.results = [];
  assert.equal(normalizeJudgeResponse({ payload, response: missing }).reasonCode, "MISSING_RESULT");

  const duplicate = responseFor(payload);
  duplicate.results.push(clone(duplicate.results[0]));
  assert.equal(normalizeJudgeResponse({ payload, response: duplicate }).reasonCode, "DUPLICATE_RESULT");

  const extra = responseFor(payload);
  extra.results.push({
    ...clone(extra.results[0]),
    candidateId: "candidate:other",
    candidateDigest: "fnv1a32:00000000",
  });
  assert.equal(normalizeJudgeResponse({ payload, response: extra }).reasonCode, "UNEXPECTED_RESULT");
});

test("schema·revision·draft digest가 다르면 stale 응답을 적용하지 않는다", () => {
  const { payload } = makeFixture();
  const wrongSchema = responseFor(payload);
  wrongSchema.schemaVersion = "wds.context-judge.result.v0";
  assert.equal(normalizeJudgeResponse({ payload, response: wrongSchema }).reasonCode, "SCHEMA_MISMATCH");

  const stale = responseFor(payload);
  stale.revision += 1;
  assert.equal(normalizeJudgeResponse({ payload, response: stale }).reasonCode, "STALE_RESPONSE");

  const wrongDigest = responseFor(payload);
  wrongDigest.draftDigest = "fnv1a32:00000000";
  assert.equal(normalizeJudgeResponse({ payload, response: wrongDigest }).reasonCode, "DIGEST_MISMATCH");
});

test("keep verdict는 LLM의 이유와 의미 기능을 보존한다", () => {
  const { payload } = makeFixture();
  const result = normalizeJudgeResponse({ payload, response: responseFor(payload) });

  assert.deepEqual(result, {
    status: "keep",
    confidence: 88,
    reasonCode: "meaning_bearing",
    semanticFunction: "discourse_marker",
  });
});

test("suggest_remove는 편집이 아니라 suggest 상태만 만든다", () => {
  const { payload } = makeFixture();
  const response = responseFor(payload, {
    verdict: "suggest_remove",
    confidence: 84,
    semanticFunction: "discourse_marker",
    reasonCode: "optional_style",
    checks: checks({ toneSocialForcePreserved: false }),
  });

  assert.deepEqual(normalizeJudgeResponse({ payload, response }), {
    status: "suggest",
    confidence: 84,
    reasonCode: "optional_style",
    semanticFunction: "discourse_marker",
  });
});

test("safe_remove는 95점 이상·모든 check true·risk 없음일 때만 remove 권고가 된다", () => {
  const { payload } = makeFixture();
  const safe = responseFor(payload, {
    verdict: "safe_remove",
    confidence: 97,
    semanticFunction: "none",
    reasonCode: "semantically_empty",
  });
  assert.equal(normalizeJudgeResponse({ payload, response: safe }).status, "remove");

  const lowConfidence = responseFor(payload, {
    verdict: "safe_remove",
    confidence: 94,
  });
  assert.equal(normalizeJudgeResponse({ payload, response: lowConfidence }).status, "suggest");

  const failedCheck = responseFor(payload, {
    verdict: "safe_remove",
    confidence: 99,
    checks: checks({ toneSocialForcePreserved: false }),
  });
  assert.equal(normalizeJudgeResponse({ payload, response: failedCheck }).status, "suggest");

  const risk = responseFor(payload, {
    verdict: "safe_remove",
    confidence: 99,
    riskFlags: ["tone_social_force_change"],
  });
  assert.equal(normalizeJudgeResponse({ payload, response: risk }).status, "suggest");
});

test("낮은 suggest confidence와 hard risk는 local gate에서 keep한다", () => {
  const { payload } = makeFixture();
  const lowConfidence = responseFor(payload, {
    verdict: "suggest_remove",
    confidence: 69,
    reasonCode: "optional_style",
  });
  assert.equal(normalizeJudgeResponse({ payload, response: lowConfidence }).status, "keep");

  const hardRisk = responseFor(payload, {
    verdict: "safe_remove",
    confidence: 99,
    semanticFunction: "none",
    reasonCode: "unsafe_edit",
    riskFlags: ["meaning_change"],
  });
  assert.equal(normalizeJudgeResponse({ payload, response: hardRisk }).status, "keep");
});

test("LLM 결과에 offset이나 편집 문자열이 추가되면 fail-keep한다", () => {
  const { payload } = makeFixture();
  const response = responseFor(payload);
  response.results[0].editedDraft = "모델이 만든 문장";

  assert.deepEqual(normalizeJudgeResponse({ payload, response }), {
    status: "keep",
    confidence: 0,
    reasonCode: "MALFORMED_RESULT",
    semanticFunction: "unknown",
  });
});

test("명시 수락 함수만 로컬 exact range의 단일 removal plan을 만든다", () => {
  const { occurrence } = makeFixture();
  const plan = createExplicitRemovalPlan({
    text: occurrence.sourceText,
    occurrence,
    effect: "poof",
  });

  assert.equal(plan.output, "버튼을 작게 해주세요.");
  assert.equal(plan.edits.length, 1);
  assert.deepEqual(
    { from: plan.edits[0].from, to: plan.edits[0].to, consumedTo: plan.edits[0].consumedTo },
    { from: 0, to: 2, consumedTo: 3 },
  );
  assert.equal(plan.requiresExplicitAcceptance, true);
  assert.equal(plan.autoApply, false);
  assert.throws(
    () => createExplicitRemovalPlan({ text: `${occurrence.sourceText}!`, occurrence, effect: "poof" }),
    /현재 입력과 일치하지 않습니다/u,
  );
});

test("exact range 제거 결과가 빈 문자열이어도 plan 자체는 유효하다", () => {
  const occurrence = createContextOccurrence({ text: "음", suggestion: "음", revision: 1 });
  const plan = createExplicitRemovalPlan({ text: "음", occurrence, effect: "ascend" });

  assert.equal(plan.output, "");
  assert.equal(plan.edits.length, 1);
});
