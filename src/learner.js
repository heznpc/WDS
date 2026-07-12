const EFFECT_IDS = ["ascend", "deflate", "poof", "melt", "vortex", "unwrite"];

const WORD_PATTERN = /[\p{L}\p{N}]+(?:['’’-][\p{L}\p{N}]+)*/gu;
const EXCLUDED_OPENING = /^(?:```|>|[-*+]\s|\d+[.)]\s|https?:\/\/|\/\w|[\[{])/u;

function clamp(value, minimum = 0, maximum = 1) {
  return Math.min(maximum, Math.max(minimum, value));
}

function normalizeToken(value) {
  return value.normalize("NFKC").toLocaleLowerCase().replace(/\s+/gu, " ").trim();
}

function hashText(value) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(36);
}

function tokenize(text) {
  return Array.from(text.matchAll(WORD_PATTERN), (match) => ({
    value: normalizeToken(match[0]),
    start: match.index,
    end: match.index + match[0].length,
  }));
}

function openingContext(text) {
  const firstLine = text.split(/\r?\n/u, 1)[0] ?? "";
  const leading = firstLine.match(/^\s*/u)?.[0].length ?? 0;
  const body = firstLine.slice(leading);

  if (!body || EXCLUDED_OPENING.test(body)) return null;
  return { body, firstLine, leading };
}

function continuationHash(tokens) {
  const value = tokens.slice(0, 3).map((token) => token.value).join(" ");
  return hashText(value || "∅");
}

function ngramHash(tokens) {
  return hashText(tokens.map((token) => token.value).join(" "));
}

function candidateKey(kind, canonicalPhrase) {
  return `${kind === "comma" ? "c" : "n"}:${hashText(canonicalPhrase)}`;
}

export function extractPrefixCandidates(text) {
  const context = openingContext(text);
  if (!context) return [];

  const { body, leading } = context;
  const commaIndexes = [body.indexOf(","), body.indexOf("，")].filter((index) => index > 0);
  const commaIndex = commaIndexes.length > 0 ? Math.min(...commaIndexes) : -1;

  if (commaIndex > 0 && commaIndex <= 24) {
    const prefixText = body.slice(0, commaIndex);
    const prefixTokens = tokenize(prefixText);
    const remainderTokens = tokenize(body.slice(commaIndex + 1));
    const canonicalPhrase = prefixTokens.map((token) => token.value).join(" ");

    if (
      prefixTokens.length >= 1 &&
      prefixTokens.length <= 3 &&
      canonicalPhrase.length >= 2 &&
      remainderTokens.length >= 1
    ) {
      let consumedTo = leading + commaIndex + 1;
      while (text[consumedTo] === " " || text[consumedTo] === "\t") consumedTo += 1;

      return [{
        key: candidateKey("comma", canonicalPhrase),
        phrase: `${canonicalPhrase},`,
        canonicalPhrase,
        kind: "comma",
        requireComma: true,
        tokenCount: prefixTokens.length,
        ngramHash: ngramHash(prefixTokens),
        continuationHash: continuationHash(remainderTokens),
        from: leading,
        to: leading + commaIndex + 1,
        consumedTo,
      }];
    }
  }

  const tokens = tokenize(body);
  if (tokens.length < 2 || tokens[0].start !== 0) return [];

  const observations = [];
  const maximumSize = Math.min(3, tokens.length - 1);
  for (let size = 1; size <= maximumSize; size += 1) {
    const prefixTokens = tokens.slice(0, size);
    const canonicalPhrase = prefixTokens.map((token) => token.value).join(" ");
    if (canonicalPhrase.length < 2 || canonicalPhrase.length > 24) continue;

    const rawEnd = leading + prefixTokens.at(-1).end;
    let consumedTo = rawEnd;
    while (text[consumedTo] === " " || text[consumedTo] === "\t") consumedTo += 1;

    observations.push({
      key: candidateKey("ngram", canonicalPhrase),
      phrase: canonicalPhrase,
      canonicalPhrase,
      kind: "ngram",
      requireComma: false,
      tokenCount: prefixTokens.length,
      ngramHash: ngramHash(prefixTokens),
      continuationHash: continuationHash(tokens.slice(size)),
      from: leading,
      to: rawEnd,
      consumedTo,
    });
  }

  return observations;
}

function collectDocumentNgrams(text) {
  const tokens = tokenize(text).slice(0, 160);
  const hashes = new Set();

  for (let start = 0; start < tokens.length; start += 1) {
    for (let size = 1; size <= 3 && start + size <= tokens.length; size += 1) {
      hashes.add(ngramHash(tokens.slice(start, start + size)));
    }
  }

  return hashes;
}

export function createHabitModel() {
  return {
    version: 1,
    totalPrompts: 0,
    eligiblePrompts: 0,
    documentFrequency: {},
    candidates: {},
  };
}

function cloneModel(model) {
  const candidates = {};
  for (const [key, candidate] of Object.entries(model.candidates)) {
    candidates[key] = {
      ...candidate,
      continuations: { ...candidate.continuations },
    };
  }

  return {
    ...model,
    documentFrequency: { ...model.documentFrequency },
    candidates,
  };
}

export function observePrompt(model, { text }) {
  const next = cloneModel(model);
  const trimmed = text.trim();
  if (!trimmed) return next;

  next.totalPrompts += 1;
  const context = openingContext(text);
  if (!context || tokenize(context.body).length < 2) return next;

  next.eligiblePrompts += 1;
  for (const hash of collectDocumentNgrams(text)) {
    next.documentFrequency[hash] = (next.documentFrequency[hash] ?? 0) + 1;
  }

  for (const observation of extractPrefixCandidates(text)) {
    const previous = next.candidates[observation.key];
    const candidate = previous ?? {
      key: observation.key,
      phrase: observation.phrase,
      canonicalPhrase: observation.canonicalPhrase,
      kind: observation.kind,
      requireComma: observation.requireComma,
      tokenCount: observation.tokenCount,
      ngramHash: observation.ngramHash,
      starts: 0,
      continuations: {},
      decision: "pending",
      effect: null,
      enabled: true,
    };

    candidate.starts += 1;
    candidate.continuations[observation.continuationHash] = true;
    next.candidates[observation.key] = candidate;
  }

  return next;
}

function scoreCandidate(model, candidate) {
  const starts = candidate.starts;
  const diversity = Object.keys(candidate.continuations).length;
  const eligible = Math.max(model.eligiblePrompts, 1);
  const documentFrequency = Math.max(model.documentFrequency[candidate.ngramHash] ?? starts, 1);
  const rate = starts / eligible;
  const precision = Math.min(1, starts / documentFrequency);
  const supportScore = 1 - Math.exp(-starts / 3);
  const rateScore = Math.min(1, rate / 0.3);
  const precisionScore = clamp((precision - 0.5) / 0.5);
  const diversityScore = Math.min(1, Math.max(0, diversity - 1) / 3);
  const boundaryScore = candidate.requireComma ? 1 : 0.45;
  const confidence =
    0.3 * supportScore +
    0.2 * rateScore +
    0.2 * precisionScore +
    0.2 * diversityScore +
    0.1 * boundaryScore;
  const previewReady = candidate.requireComma
    ? starts >= 2 && diversity >= 2 && precision >= 0.55
    : starts >= 3 && diversity >= 2 && precision >= 0.6;
  const ready = candidate.requireComma
    ? starts >= 3 && diversity >= 2 && precision >= 0.6 && confidence >= 0.68
    : starts >= 4 && diversity >= 3 && precision >= 0.65 && confidence >= 0.72;

  return {
    ...candidate,
    confidence,
    diversity,
    precision,
    rate,
    previewReady,
    ready,
    targetStarts: candidate.requireComma ? 3 : 4,
  };
}

export function effectForCandidate(key) {
  const numericHash = Number.parseInt(hashText(key), 36);
  return EFFECT_IDS[numericHash % EFFECT_IDS.length];
}

export function rankHabitCandidates(model) {
  const ranked = Object.values(model.candidates)
    .map((candidate) => scoreCandidate(model, candidate))
    .filter((candidate) => candidate.decision !== "rejected")
    .filter((candidate) => candidate.previewReady || candidate.decision === "accepted")
    .sort((left, right) => {
      const acceptedDifference = Number(right.decision === "accepted") - Number(left.decision === "accepted");
      if (acceptedDifference !== 0) return acceptedDifference;
      const readyDifference = Number(right.ready) - Number(left.ready);
      if (readyDifference !== 0) return readyDifference;
      if (right.starts !== left.starts) return right.starts - left.starts;
      return right.confidence - left.confidence;
    });

  const kept = [];
  for (const candidate of ranked) {
    const shadowed = kept.some(
      (existing) =>
        candidate.kind === "ngram" &&
        existing.kind === "ngram" &&
        candidate.canonicalPhrase.startsWith(`${existing.canonicalPhrase} `) &&
        existing.previewReady,
    );
    if (!shadowed) kept.push(candidate);
  }

  return kept;
}

export function setCandidateDecision(model, { key, decision, effect }) {
  if (!model.candidates[key]) return model;
  const next = cloneModel(model);
  next.candidates[key] = {
    ...next.candidates[key],
    decision,
    effect: effect ?? next.candidates[key].effect ?? effectForCandidate(key),
    enabled: decision === "accepted",
  };
  return next;
}

export function setCandidateEnabled(model, { key, enabled }) {
  if (!model.candidates[key]) return model;
  const next = cloneModel(model);
  next.candidates[key] = { ...next.candidates[key], enabled };
  return next;
}

export function setCandidateEffect(model, { key, effect }) {
  if (!model.candidates[key]) return model;
  const next = cloneModel(model);
  next.candidates[key] = { ...next.candidates[key], effect };
  return next;
}

export function contextEnabledCandidates(model) {
  return Object.values(model.candidates)
    .filter((candidate) => candidate.decision === "accepted" && candidate.enabled)
    .map((candidate) => ({
      key: candidate.key,
      phrase: candidate.phrase,
      effect: candidate.effect ?? effectForCandidate(candidate.key),
    }));
}

function countGraphemes(value) {
  if (typeof Intl.Segmenter === "function") {
    return Array.from(new Intl.Segmenter("ko", { granularity: "grapheme" }).segment(value)).length;
  }
  return Array.from(value).length;
}

export function suggestForInput(model, { text, cursor = text.length, composing = false }) {
  if (composing || !text || cursor !== text.length) return null;

  const leading = text.match(/^\s*/u)?.[0].length ?? 0;
  const fullBody = text.slice(leading).replace("，", ",");
  const lineBreak = fullBody.search(/\r?\n/u);
  const body = lineBreak >= 0 ? fullBody.slice(0, lineBreak) : fullBody;
  if (!body) return null;

  for (const candidate of rankHabitCandidates(model)) {
    const expected = candidate.phrase;
    const exactPrefix = candidate.requireComma ? expected : candidate.canonicalPhrase;
    const hasFullPrefix = body.startsWith(exactPrefix) && (
      candidate.requireComma ||
      !body[exactPrefix.length] ||
      /[,\s]/u.test(body[exactPrefix.length])
    );

    if (hasFullPrefix) {
      let consumedLength = exactPrefix.length;
      if (!candidate.requireComma && body[consumedLength] === ",") consumedLength += 1;
      while (body[consumedLength] === " " || body[consumedLength] === "\t") consumedLength += 1;
      if (!body.slice(consumedLength).trim()) continue;

      return {
        key: candidate.key,
        kind: candidate.decision === "accepted" && candidate.enabled
          ? "context-check"
          : candidate.ready
            ? "candidate-ready"
            : "repeat-learning",
        phrase: candidate.phrase,
        completion: "",
        from: leading,
        to: leading + exactPrefix.length,
        consumedTo: leading + consumedLength,
        confidence: candidate.confidence,
        effect: candidate.effect ?? effectForCandidate(candidate.key),
        sourceText: text,
      };
    }

    if (
      body.length < expected.length &&
      countGraphemes(body) >= 2 &&
      expected.startsWith(body)
    ) {
      return {
        key: candidate.key,
        kind: "prediction",
        phrase: candidate.phrase,
        completion: expected.slice(body.length),
        from: leading,
        to: leading + body.length,
        consumedTo: leading + body.length,
        confidence: candidate.confidence,
        effect: candidate.effect ?? effectForCandidate(candidate.key),
        sourceText: text,
      };
    }
  }

  return null;
}
