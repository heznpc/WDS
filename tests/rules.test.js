import test from "node:test";
import assert from "node:assert/strict";

import { createRule, transformPrompt } from "../src/rules.js";

test("승인된 규칙이 없으면 입력을 그대로 둔다", () => {
  const result = transformPrompt("흠, 이 부분을 고쳐줘.");
  assert.equal(result.output, "흠, 이 부분을 고쳐줘.");
  assert.equal(result.edits.length, 0);
});

test("사용자가 승인한 문두 규칙만 제거한다", () => {
  const rule = createRule({ id: "accepted", phrase: "흠,", effect: "ascend" });
  const result = transformPrompt("흠, 이 부분을 고쳐줘.", [rule]);

  assert.equal(result.output, "이 부분을 고쳐줘.");
  assert.equal(result.edits[0].raw, "흠,");
});

test("문장 중간과 비슷한 단어는 건드리지 않는다", () => {
  const rule = createRule({ id: "accepted", phrase: "흠,", effect: "ascend" });
  assert.equal(transformPrompt("그건 흠, 조금 다릅니다.", [rule]).edits.length, 0);
  assert.equal(transformPrompt("흠집을 고쳐줘.", [rule]).edits.length, 0);
});

test("겹치는 규칙은 더 긴 표현을 우선한다", () => {
  const shortRule = createRule({ id: "short", phrase: "일단", effect: "deflate" });
  const longRule = createRule({ id: "long", phrase: "일단 먼저", effect: "poof", custom: true });
  const result = transformPrompt("일단 먼저, 버튼을 고쳐줘.", [shortRule, longRule]);

  assert.equal(result.output, "버튼을 고쳐줘.");
  assert.equal(result.edits[0].ruleId, "long");
});

test("전각 쉼표도 승인된 쉼표 규칙의 경계로 처리한다", () => {
  const rule = createRule({ id: "comma", phrase: "그러니까,", effect: "melt" });
  const result = transformPrompt("그러니까， 여백을 줄여줘.", [rule]);
  assert.equal(result.output, "여백을 줄여줘.");
});

test("규칙은 JSON 저장 경계를 지나도 동작한다", () => {
  const rule = createRule({ id: "stored", phrase: "일단", effect: "unwrite" });
  const restored = JSON.parse(JSON.stringify(rule));
  assert.equal(transformPrompt("일단, 확인해줘.", [restored]).output, "확인해줘.");
});

test("한글과 이모지의 UTF-16 offset을 보존한다", () => {
  const rule = createRule({ id: "emoji", phrase: "🤔", effect: "melt" });
  const result = transformPrompt("🤔 한글로 답해줘.", [rule]);

  assert.equal(result.output, "한글로 답해줘.");
  assert.equal(result.edits[0].from, 0);
  assert.equal(result.edits[0].to, 2);
});
