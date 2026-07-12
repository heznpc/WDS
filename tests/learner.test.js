import test from "node:test";
import assert from "node:assert/strict";

import {
  contextEnabledCandidates,
  createHabitModel,
  extractPrefixCandidates,
  observePrompt,
  rankHabitCandidates,
  setCandidateDecision,
  suggestForInput,
} from "../src/learner.js";

function observeAll(prompts) {
  return prompts.reduce((model, text) => observePrompt(model, { text }), createHabitModel());
}

test("쉼표로 끝난 문두 전체와 정확한 범위를 추출한다", () => {
  const [candidate] = extractPrefixCandidates("  그러니까, 이 부분을 고쳐줘.");

  assert.equal(candidate.phrase, "그러니까,");
  assert.equal(candidate.from, 2);
  assert.equal(candidate.to, 7);
  assert.equal(candidate.consumedTo, 8);
});

test("문장 중간 표현과 코드·인용 시작은 후보로 추출하지 않는다", () => {
  assert.equal(extractPrefixCandidates("그 답은 그러니까, 다릅니다.")[0]?.phrase, "그 답은 그러니까,");
  assert.deepEqual(extractPrefixCandidates("> 그러니까, 인용입니다."), []);
  assert.deepEqual(extractPrefixCandidates("```js"), []);
  assert.deepEqual(extractPrefixCandidates("https://example.com 설명"), []);
});

test("서로 다른 뒤 문맥에서 두 번 반복되면 예측을 시작한다", () => {
  const model = observeAll([
    "그러니까, 버튼을 더 작게 해줘.",
    "그러니까, 여백을 조금 줄여줘.",
  ]);
  const [candidate] = rankHabitCandidates(model);

  assert.equal(candidate.phrase, "그러니까,");
  assert.equal(candidate.previewReady, true);
  assert.equal(candidate.ready, false);

  const prediction = suggestForInput(model, { text: "그러", cursor: 2 });
  assert.equal(prediction.kind, "prediction");
  assert.equal(prediction.phrase, "그러니까,");
});

test("세 번째의 다양한 문맥에서 문맥 검사 후보가 된다", () => {
  const model = observeAll([
    "그러니까, 버튼을 더 작게 해줘.",
    "그러니까, 여백을 조금 줄여줘.",
    "그러니까, 제목을 위로 옮겨줘.",
  ]);
  const [candidate] = rankHabitCandidates(model);

  assert.equal(candidate.ready, true);
  assert.ok(candidate.confidence >= 0.68);
});

test("같은 뒤 문맥을 복제한 경우 후보로 올리지 않는다", () => {
  const model = observeAll([
    "그러니까, 버튼을 더 작게 해줘.",
    "그러니까, 버튼을 더 작게 해줘.",
    "그러니까, 버튼을 더 작게 해줘.",
  ]);
  assert.deepEqual(rankHabitCandidates(model), []);
});

test("승인은 삭제 규칙이 아니라 문맥 검사 대상을 만든다", () => {
  let model = observeAll([
    "그러니까, 버튼을 더 작게 해줘.",
    "그러니까, 여백을 조금 줄여줘.",
    "그러니까, 제목을 위로 옮겨줘.",
  ]);
  const [candidate] = rankHabitCandidates(model);

  assert.deepEqual(contextEnabledCandidates(model), []);
  model = setCandidateDecision(model, { key: candidate.key, decision: "accepted", effect: "poof" });
  assert.equal(contextEnabledCandidates(model)[0].phrase, "그러니까,");
  assert.equal(contextEnabledCandidates(model)[0].effect, "poof");
});

test("거절한 후보는 추가 관찰 뒤에도 보이지 않는다", () => {
  let model = observeAll([
    "그러니까, 버튼을 더 작게 해줘.",
    "그러니까, 여백을 조금 줄여줘.",
    "그러니까, 제목을 위로 옮겨줘.",
  ]);
  const [candidate] = rankHabitCandidates(model);
  model = setCandidateDecision(model, { key: candidate.key, decision: "rejected" });
  model = observePrompt(model, { text: "그러니까, 문구를 다시 써줘." });

  assert.deepEqual(rankHabitCandidates(model), []);
});

test("IME 조합 중에는 입력 제안을 만들지 않는다", () => {
  const model = observeAll([
    "그러니까, 버튼을 더 작게 해줘.",
    "그러니까, 여백을 조금 줄여줘.",
  ]);
  assert.equal(suggestForInput(model, { text: "그러", cursor: 2, composing: true }), null);
});

test("모델은 원문 전체가 아니라 횟수와 해시만 보관한다", () => {
  const secretRemainder = "고유한원문나머지";
  const model = observePrompt(createHabitModel(), {
    text: `그러니까, ${secretRemainder}를 처리해줘.`,
  });
  const serialized = JSON.stringify(model);

  assert.equal(serialized.includes(secretRemainder), false);
  assert.deepEqual(JSON.parse(serialized), model);
});

test("쉼표 없는 반복도 충분한 빈도와 문맥 다양성이 있으면 후보가 된다", () => {
  const model = observeAll([
    "일단 버튼을 고쳐줘.",
    "일단 여백을 줄여줘.",
    "일단 색상을 바꿔줘.",
    "일단 문구를 정리해줘.",
  ]);
  const candidate = rankHabitCandidates(model).find((item) => item.phrase === "일단");

  assert.equal(candidate?.ready, true);
});
