const REQUEST_SCHEMA_VERSION = "wds.context-judge.request.v1";
const RESULT_SCHEMA_VERSION = "wds.context-judge.result.v1";
const LOCALE = "ko-KR";

const VERDICTS = new Set(["keep", "suggest_remove", "safe_remove"]);
const TURN_ROLES = new Set(["user", "assistant"]);
const SEMANTIC_FUNCTIONS = new Set([
  "none",
  "discourse_marker",
  "contrast_or_correction",
  "polarity_or_negation",
  "stance_or_hedge",
  "emphasis",
  "address_or_social",
  "task_content",
  "formatting_or_structure",
  "unclear",
]);
const REASON_CODES = new Set([
  "semantically_empty",
  "optional_style",
  "meaning_bearing",
  "context_insufficient",
  "unsafe_edit",
  "malformed_candidate",
]);
const RISK_FLAGS = new Set([
  "context_incomplete",
  "meaning_change",
  "intent_change",
  "speech_act_change",
  "polarity_modality_change",
  "discourse_relation_change",
  "tone_social_force_change",
  "grammar_change",
  "formatting_change",
  "ambiguous_occurrence",
]);
const HARD_RISK_FLAGS = new Set([
  "context_incomplete",
  "meaning_change",
  "intent_change",
  "speech_act_change",
  "polarity_modality_change",
  "discourse_relation_change",
  "grammar_change",
  "formatting_change",
  "ambiguous_occurrence",
]);
const CHECK_KEYS = Object.freeze([
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
]);

const RESPONSE_KEYS = Object.freeze([
  "schemaVersion",
  "requestId",
  "revision",
  "draftDigest",
  "results",
]);
const RESULT_KEYS = Object.freeze([
  "candidateId",
  "candidateDigest",
  "verdict",
  "confidence",
  "semanticFunction",
  "reasonCode",
  "riskFlags",
  "checks",
]);
const REQUEST_KEYS = Object.freeze([
  "schemaVersion",
  "requestId",
  "revision",
  "draftDigest",
  "locale",
  "context",
  "draft",
  "occurrences",
]);
const OCCURRENCE_KEYS = Object.freeze([
  "candidateId",
  "candidateDigest",
  "candidateKey",
  "visibleRange",
  "deleteRange",
  "exactText",
  "deleteText",
  "editedDraft",
]);
const SAFE_TOKEN = /^[A-Za-z0-9._:-]{1,160}$/u;

const textEncoder = new TextEncoder();
const graphemeSegmenter = typeof Intl?.Segmenter === "function"
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
  : null;

class ContextContractError extends TypeError {
  constructor(message) {
    super(message);
    this.name = "ContextContractError";
  }
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function hasExactKeys(value, expectedKeys) {
  if (!isPlainObject(value)) return false;
  const actualKeys = Object.keys(value).sort();
  const sortedExpected = [...expectedKeys].sort();
  return actualKeys.length === sortedExpected.length &&
    actualKeys.every((key, index) => key === sortedExpected[index]);
}

function isRevision(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function isSafeIdentifier(value, maximumLength = 160) {
  return typeof value === "string" &&
    value.length > 0 &&
    value.length <= maximumLength &&
    !/[\u0000-\u001f\u007f]/u.test(value);
}

function isSafeToken(value) {
  return typeof value === "string" && SAFE_TOKEN.test(value);
}

/** FNV-1a over UTF-8 bytes. It stays synchronous in browsers and Node. */
function digestText(value) {
  let hash = 2166136261;
  for (const byte of textEncoder.encode(value)) {
    hash ^= byte;
    hash = Math.imul(hash, 16777619);
  }
  return `fnv1a32:${(hash >>> 0).toString(16).padStart(8, "0")}`;
}

function graphemeBoundaries(text) {
  const boundaries = new Set([0, text.length]);
  if (graphemeSegmenter) {
    for (const segment of graphemeSegmenter.segment(text)) boundaries.add(segment.index);
    return boundaries;
  }

  // Older runtimes get code-point safety. Modern supported browsers and Node
  // use Intl.Segmenter above, which also protects combining and ZWJ clusters.
  let index = 0;
  for (const codePoint of text) {
    boundaries.add(index);
    index += codePoint.length;
  }
  boundaries.add(text.length);
  return boundaries;
}

function isValidRange(text, range, { allowEmpty = false } = {}) {
  if (!isPlainObject(range)) return false;
  const { from, to } = range;
  if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to)) return false;
  if (from < 0 || to > text.length || from > to || (!allowEmpty && from === to)) return false;
  const boundaries = graphemeBoundaries(text);
  return boundaries.has(from) && boundaries.has(to);
}

function findExactRanges(text, needle) {
  if (typeof needle !== "string" || needle.length === 0) return [];
  const boundaries = graphemeBoundaries(text);
  const matches = [];
  let cursor = 0;

  while (cursor <= text.length - needle.length) {
    const from = text.indexOf(needle, cursor);
    if (from < 0) break;
    const to = from + needle.length;
    if (boundaries.has(from) && boundaries.has(to)) matches.push({ from, to });
    cursor = from + 1;
  }

  return matches;
}

function resolveSuggestionRange(text, suggestion) {
  if (typeof suggestion === "string") {
    const ranges = findExactRanges(text, suggestion);
    if (ranges.length === 0) throw new ContextContractError("제안 표현이 현재 입력에 없습니다.");
    if (ranges.length > 1) throw new ContextContractError("제안 표현이 여러 번 있어 정확한 범위가 필요합니다.");
    return { visibleRange: ranges[0], deleteRange: ranges[0], candidateKey: digestText(suggestion) };
  }

  if (!isPlainObject(suggestion)) {
    throw new ContextContractError("제안은 문자열 또는 로컬 범위 객체여야 합니다.");
  }

  if (typeof suggestion.sourceText === "string" && suggestion.sourceText !== text) {
    throw new ContextContractError("제안이 만들어진 뒤 입력이 바뀌었습니다.");
  }

  const hasFrom = Number.isSafeInteger(suggestion.from);
  const hasTo = Number.isSafeInteger(suggestion.to);
  if (hasFrom !== hasTo) throw new ContextContractError("제안 범위가 완전하지 않습니다.");

  let visibleRange;
  if (hasFrom && hasTo) {
    visibleRange = { from: suggestion.from, to: suggestion.to };
  } else {
    const exactText = typeof suggestion.exactText === "string"
      ? suggestion.exactText
      : typeof suggestion.phrase === "string"
        ? suggestion.phrase
        : null;
    const ranges = findExactRanges(text, exactText);
    if (ranges.length === 0) throw new ContextContractError("제안 표현이 현재 입력에 없습니다.");
    if (ranges.length > 1) throw new ContextContractError("제안 표현이 여러 번 있어 정확한 범위가 필요합니다.");
    [visibleRange] = ranges;
  }

  const deleteTo = Number.isSafeInteger(suggestion.consumedTo)
    ? suggestion.consumedTo
    : visibleRange.to;
  const deleteRange = { from: visibleRange.from, to: deleteTo };
  const candidateKey = isSafeToken(suggestion.key)
    ? suggestion.key
    : digestText(text.slice(visibleRange.from, visibleRange.to));

  return { visibleRange, deleteRange, candidateKey };
}

function occurrenceDigestSource(occurrence) {
  return JSON.stringify({
    revision: occurrence.revision,
    draftDigest: occurrence.draftDigest,
    candidateKey: occurrence.candidateKey,
    visibleRange: occurrence.visibleRange,
    deleteRange: occurrence.deleteRange,
    exactText: occurrence.exactText,
    deleteText: occurrence.deleteText,
    editedDraft: occurrence.editedDraft,
  });
}

function assertOccurrence(occurrence, currentText = occurrence?.sourceText) {
  if (!isPlainObject(occurrence) || typeof currentText !== "string") {
    throw new ContextContractError("정확한 발생 정보가 필요합니다.");
  }
  if (!isRevision(occurrence.revision) || !isSafeToken(occurrence.candidateKey)) {
    throw new ContextContractError("발생 정보의 revision 또는 candidateKey가 올바르지 않습니다.");
  }
  if (occurrence.sourceText !== currentText || occurrence.draftDigest !== digestText(currentText)) {
    throw new ContextContractError("발생 정보가 현재 입력과 일치하지 않습니다.");
  }
  if (!isValidRange(currentText, occurrence.visibleRange) || !isValidRange(currentText, occurrence.deleteRange)) {
    throw new ContextContractError("발생 범위가 grapheme 경계와 맞지 않습니다.");
  }
  if (
    occurrence.deleteRange.from !== occurrence.visibleRange.from ||
    occurrence.deleteRange.to < occurrence.visibleRange.to
  ) {
    throw new ContextContractError("삭제 범위가 표시 범위를 정확히 포함하지 않습니다.");
  }

  const exactText = currentText.slice(occurrence.visibleRange.from, occurrence.visibleRange.to);
  const deleteText = currentText.slice(occurrence.deleteRange.from, occurrence.deleteRange.to);
  const editedDraft = `${currentText.slice(0, occurrence.deleteRange.from)}${currentText.slice(occurrence.deleteRange.to)}`;
  if (
    occurrence.exactText !== exactText ||
    occurrence.deleteText !== deleteText ||
    occurrence.editedDraft !== editedDraft
  ) {
    throw new ContextContractError("발생 정보에 로컬 원문과 다른 편집 내용이 있습니다.");
  }

  const expectedDigest = digestText(occurrenceDigestSource(occurrence));
  const expectedId = `candidate:${expectedDigest.slice("fnv1a32:".length)}`;
  if (occurrence.candidateDigest !== expectedDigest || occurrence.candidateId !== expectedId) {
    throw new ContextContractError("발생 식별자가 로컬 내용과 일치하지 않습니다.");
  }
}

export function createContextOccurrence({ text, suggestion, revision }) {
  if (typeof text !== "string" || !isRevision(revision)) {
    throw new ContextContractError("현재 입력과 0 이상의 정수 revision이 필요합니다.");
  }

  const { visibleRange, deleteRange, candidateKey } = resolveSuggestionRange(text, suggestion);
  if (!isValidRange(text, visibleRange) || !isValidRange(text, deleteRange)) {
    throw new ContextContractError("제안 범위가 UTF-16 grapheme 경계와 맞지 않습니다.");
  }
  if (deleteRange.from !== visibleRange.from || deleteRange.to < visibleRange.to) {
    throw new ContextContractError("삭제 범위는 표시 범위를 정확히 포함해야 합니다.");
  }

  const draftDigest = digestText(text);
  const occurrence = {
    sourceText: text,
    revision,
    draftDigest,
    candidateId: "",
    candidateDigest: "",
    candidateKey,
    visibleRange: { ...visibleRange },
    deleteRange: { ...deleteRange },
    exactText: text.slice(visibleRange.from, visibleRange.to),
    deleteText: text.slice(deleteRange.from, deleteRange.to),
    editedDraft: `${text.slice(0, deleteRange.from)}${text.slice(deleteRange.to)}`,
  };
  occurrence.candidateDigest = digestText(occurrenceDigestSource(occurrence));
  occurrence.candidateId = `candidate:${occurrence.candidateDigest.slice("fnv1a32:".length)}`;
  assertOccurrence(occurrence);
  return occurrence;
}

function normalizeTurns(turns) {
  if (!Array.isArray(turns)) throw new ContextContractError("turns는 배열이어야 합니다.");
  return turns.map((turn) => {
    if (
      !isPlainObject(turn) ||
      !TURN_ROLES.has(turn.role) ||
      typeof turn.text !== "string" ||
      turn.text.length === 0
    ) {
      throw new ContextContractError("각 turn에는 user 또는 assistant role과 text가 필요합니다.");
    }
    return { role: turn.role, text: turn.text };
  });
}

export function buildJudgePayload({ occurrence, turns = [], requestId }) {
  assertOccurrence(occurrence);
  if (!isSafeToken(requestId)) throw new ContextContractError("requestId가 필요합니다.");
  if (!occurrence.editedDraft.trim()) {
    throw new ContextContractError("빈 입력을 만드는 후보는 문맥 판정으로 보내지 않습니다.");
  }

  return {
    schemaVersion: REQUEST_SCHEMA_VERSION,
    requestId,
    revision: occurrence.revision,
    draftDigest: occurrence.draftDigest,
    locale: LOCALE,
    context: {
      complete: true,
      turns: normalizeTurns(turns),
    },
    draft: { text: occurrence.sourceText },
    occurrences: [{
      candidateId: occurrence.candidateId,
      candidateDigest: occurrence.candidateDigest,
      candidateKey: occurrence.candidateKey,
      visibleRange: { ...occurrence.visibleRange },
      deleteRange: { ...occurrence.deleteRange },
      exactText: occurrence.exactText,
      deleteText: occurrence.deleteText,
      editedDraft: occurrence.editedDraft,
    }],
  };
}

function failKeep(reasonCode) {
  return {
    status: "keep",
    confidence: 0,
    reasonCode,
    semanticFunction: "unknown",
  };
}

function parseRawResponse(response) {
  if (typeof response !== "string") return response;
  const trimmed = response.trim();
  if (!trimmed) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

function validatePayloadForResponse(payload) {
  if (!hasExactKeys(payload, REQUEST_KEYS) || payload.schemaVersion !== REQUEST_SCHEMA_VERSION) return false;
  if (!isSafeToken(payload.requestId) || !isRevision(payload.revision) || payload.locale !== LOCALE) return false;
  if (!hasExactKeys(payload.context, ["complete", "turns"]) || typeof payload.context.complete !== "boolean") return false;
  if (!Array.isArray(payload.context.turns) || payload.context.turns.some(
    (turn) => !hasExactKeys(turn, ["role", "text"]) || !TURN_ROLES.has(turn.role) || typeof turn.text !== "string",
  )) return false;
  if (!hasExactKeys(payload.draft, ["text"]) || typeof payload.draft.text !== "string") return false;
  if (payload.draftDigest !== digestText(payload.draft.text)) return false;
  if (!Array.isArray(payload.occurrences) || payload.occurrences.length !== 1) return false;

  const [target] = payload.occurrences;
  if (!hasExactKeys(target, OCCURRENCE_KEYS)) return false;
  if (!isSafeToken(target.candidateId) || !isSafeToken(target.candidateDigest) || !isSafeToken(target.candidateKey)) return false;
  if (!isValidRange(payload.draft.text, target.visibleRange) || !isValidRange(payload.draft.text, target.deleteRange)) {
    return false;
  }
  if (target.deleteRange.from !== target.visibleRange.from || target.deleteRange.to < target.visibleRange.to) return false;
  const locallyBound = target.exactText === payload.draft.text.slice(target.visibleRange.from, target.visibleRange.to) &&
    target.deleteText === payload.draft.text.slice(target.deleteRange.from, target.deleteRange.to) &&
    target.editedDraft === `${payload.draft.text.slice(0, target.deleteRange.from)}${payload.draft.text.slice(target.deleteRange.to)}`;
  if (!locallyBound) return false;
  const expectedDigest = digestText(occurrenceDigestSource({
    ...target,
    revision: payload.revision,
    draftDigest: payload.draftDigest,
  }));
  return target.candidateDigest === expectedDigest &&
    target.candidateId === `candidate:${expectedDigest.slice("fnv1a32:".length)}`;
}

function isValidRiskFlags(riskFlags) {
  if (!Array.isArray(riskFlags)) return false;
  if (!riskFlags.every((flag) => RISK_FLAGS.has(flag))) return false;
  return new Set(riskFlags).size === riskFlags.length;
}

function isValidChecks(checks) {
  return hasExactKeys(checks, CHECK_KEYS) && CHECK_KEYS.every((key) => typeof checks[key] === "boolean");
}

function isValidResult(result) {
  return hasExactKeys(result, RESULT_KEYS) &&
    isSafeToken(result.candidateId) &&
    isSafeToken(result.candidateDigest) &&
    VERDICTS.has(result.verdict) &&
    typeof result.confidence === "number" &&
    Number.isInteger(result.confidence) &&
    result.confidence >= 0 &&
    result.confidence <= 100 &&
    SEMANTIC_FUNCTIONS.has(result.semanticFunction) &&
    REASON_CODES.has(result.reasonCode) &&
    isValidRiskFlags(result.riskFlags) &&
    isValidChecks(result.checks);
}

export function normalizeJudgeResponse({ payload, response }) {
  if (!validatePayloadForResponse(payload)) return failKeep("INVALID_REQUEST_BINDING");

  const parsed = parseRawResponse(response);
  if (!hasExactKeys(parsed, RESPONSE_KEYS)) return failKeep("MALFORMED_RESPONSE");
  if (parsed.schemaVersion !== RESULT_SCHEMA_VERSION) return failKeep("SCHEMA_MISMATCH");
  if (
    parsed.requestId !== payload.requestId ||
    parsed.revision !== payload.revision
  ) {
    return failKeep("STALE_RESPONSE");
  }
  if (parsed.draftDigest !== payload.draftDigest) return failKeep("DIGEST_MISMATCH");
  if (!Array.isArray(parsed.results)) return failKeep("MALFORMED_RESPONSE");

  const [target] = payload.occurrences;
  const matches = parsed.results.filter(
    (result) => result?.candidateId === target.candidateId &&
      result?.candidateDigest === target.candidateDigest,
  );
  if (matches.length === 0) return failKeep("MISSING_RESULT");
  if (matches.length > 1) return failKeep("DUPLICATE_RESULT");
  if (parsed.results.length !== 1) return failKeep("UNEXPECTED_RESULT");

  const [result] = matches;
  if (!isValidResult(result)) return failKeep("MALFORMED_RESULT");

  const normalized = {
    status: "keep",
    confidence: result.confidence,
    reasonCode: result.reasonCode,
    semanticFunction: result.semanticFunction,
  };
  if (result.verdict === "keep") return normalized;

  const understood = result.checks.contextSufficient && result.checks.exactOccurrenceUnderstood;
  if (!understood) return normalized;
  const hasHardRisk = result.riskFlags.some((flag) => HARD_RISK_FLAGS.has(flag));
  if (hasHardRisk) return normalized;

  if (result.verdict === "suggest_remove") {
    normalized.status = result.confidence >= 70 ? "suggest" : "keep";
    return normalized;
  }

  const allChecksPass = CHECK_KEYS.every((key) => result.checks[key]);
  normalized.status = result.confidence >= 95 && allChecksPass && result.riskFlags.length === 0
    ? "remove"
    : "suggest";
  return normalized;
}

export function createExplicitRemovalPlan({ text, occurrence, effect = null }) {
  if (typeof text !== "string") throw new ContextContractError("현재 입력이 필요합니다.");
  if (effect !== null && !isSafeIdentifier(effect, 80)) {
    throw new ContextContractError("효과 식별자가 올바르지 않습니다.");
  }
  assertOccurrence(occurrence, text);

  const output = `${text.slice(0, occurrence.deleteRange.from)}${text.slice(occurrence.deleteRange.to)}`;
  const edit = {
    from: occurrence.visibleRange.from,
    to: occurrence.visibleRange.to,
    consumedTo: occurrence.deleteRange.to,
    raw: occurrence.exactText,
    effect,
    candidateKey: occurrence.candidateKey,
    candidateId: occurrence.candidateId,
    candidateDigest: occurrence.candidateDigest,
  };

  return {
    type: "remove_exact_occurrence",
    draftDigest: occurrence.draftDigest,
    outputDigest: digestText(output),
    candidateId: occurrence.candidateId,
    candidateDigest: occurrence.candidateDigest,
    deleteRange: { ...occurrence.deleteRange },
    deleteText: occurrence.deleteText,
    output,
    edits: [edit],
    requiresExplicitAcceptance: true,
    autoApply: false,
  };
}
