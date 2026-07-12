export const EFFECT_LABELS = Object.freeze({
  ascend: "승천",
  deflate: "바람 빠짐",
  melt: "녹아내림",
  poof: "먼지로 펑",
  unwrite: "되감기",
  vortex: "블랙홀",
});

export function createRule({ id, phrase, effect, active = true, custom = false, candidateKey = null }) {
  const normalizedPhrase = phrase.trim();
  const requireComma = /[,，]$/u.test(normalizedPhrase);
  const canonicalPhrase = normalizedPhrase.replace(/[,，]\s*$/u, "");

  if (!canonicalPhrase) {
    throw new Error("규칙에는 한 글자 이상의 표현이 필요합니다.");
  }

  if (!Object.hasOwn(EFFECT_LABELS, effect)) {
    throw new Error(`알 수 없는 효과입니다: ${effect}`);
  }

  return {
    id,
    phrase: requireComma ? `${canonicalPhrase},` : canonicalPhrase,
    canonicalPhrase,
    effect,
    active,
    custom,
    candidateKey,
    requireComma,
  };
}

function matchRulePrefix(input, rule) {
  if (!input.startsWith(rule.canonicalPhrase)) return null;

  let cursor = rule.canonicalPhrase.length;
  const nextCharacter = input.slice(cursor, cursor + 1);

  if (nextCharacter === "," || nextCharacter === "，") {
    cursor += 1;
  } else if (rule.requireComma) {
    return null;
  } else if (nextCharacter && !/\s/u.test(nextCharacter)) {
    return null;
  }

  const visibleLength = cursor;
  while (input[cursor] === " " || input[cursor] === "\t") {
    cursor += 1;
  }

  return {
    consumedLength: cursor,
    raw: input.slice(0, visibleLength),
    visibleLength,
  };
}

/**
 * Low-level explicit rule utility kept for isolated/manual integrations.
 * The context-aware app never feeds learned repetition candidates into this
 * function; user-visible edits use an exact, per-occurrence review instead.
 */
export function transformPrompt(input, rules = []) {
  const leadingWhitespace = input.match(/^\s*/u)?.[0] ?? "";
  let cursor = leadingWhitespace.length;
  const edits = [];

  while (cursor < input.length) {
    const remainder = input.slice(cursor);
    let nextEdit = null;

    for (const rule of rules) {
      if (!rule.active) continue;

      const match = matchRulePrefix(remainder, rule);
      if (!match) continue;

      const candidate = {
        from: cursor,
        to: cursor + match.visibleLength,
        consumedTo: cursor + match.consumedLength,
        raw: match.raw,
        ruleId: rule.id,
        candidateKey: rule.candidateKey,
        effect: rule.effect,
        custom: rule.custom,
      };

      const candidateLength = candidate.consumedTo - candidate.from;
      const currentLength = nextEdit ? nextEdit.consumedTo - nextEdit.from : -1;
      if (
        candidateLength > currentLength ||
        (candidateLength === currentLength && candidate.custom && !nextEdit?.custom)
      ) {
        nextEdit = candidate;
      }
    }

    if (!nextEdit) break;

    const { custom: _custom, ...publicEdit } = nextEdit;
    edits.push(publicEdit);
    cursor = nextEdit.consumedTo;
  }

  if (edits.length === 0) {
    return { original: input, output: input, edits };
  }

  return {
    original: input,
    output: `${leadingWhitespace}${input.slice(cursor)}`,
    edits,
  };
}
