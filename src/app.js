import { measureTextareaRange, previewElementEffect, spawnTextEffect } from "./effects.js";
import {
  buildJudgePayload,
  createContextOccurrence,
  createExplicitRemovalPlan,
  normalizeJudgeResponse,
} from "./context-judge.js";
import { requestContextJudgment } from "./judge-client.js";
import {
  createHabitModel,
  effectForCandidate,
  observePrompt,
  rankHabitCandidates,
  setCandidateDecision,
  setCandidateEffect,
  setCandidateEnabled,
  suggestForInput,
} from "./learner.js";
import { EFFECT_LABELS } from "./rules.js";

const EFFECT_IDS = Object.keys(EFFECT_LABELS);

const elements = {
  composer: document.querySelector(".composer"),
  composerForm: document.querySelector("#composerForm"),
  conversation: document.querySelector("#conversation"),
  effectPalette: document.querySelector("#effectPalette"),
  eventToast: document.querySelector("#eventToast"),
  fxLayer: document.querySelector("#fxLayer"),
  habitList: document.querySelector("#habitList"),
  learningState: document.querySelector("#learningState"),
  modelStatus: document.querySelector("#modelStatus"),
  observedCount: document.querySelector("#observedCount"),
  predictionAction: document.querySelector("#predictionAction"),
  predictionBar: document.querySelector("#predictionBar"),
  predictionCopy: document.querySelector("#predictionCopy"),
  predictionLabel: document.querySelector("#predictionLabel"),
  predictionPhrase: document.querySelector("#predictionPhrase"),
  promptInput: document.querySelector("#promptInput"),
  rawSendButton: document.querySelector("#rawSendButton"),
  releasedCount: document.querySelector("#releasedCount"),
  reviewLive: document.querySelector("#reviewLive"),
};

const state = {
  composing: false,
  appliedEdits: [],
  appliedSourceText: null,
  lastCompositionEnd: 0,
  model: createHabitModel(),
  released: 0,
  revision: 0,
  review: {
    controller: null,
    occurrence: null,
    payload: null,
    result: null,
    sourceText: null,
    status: "idle",
  },
  reviewSequence: 0,
  reviewTimer: null,
  suggestion: null,
  suppressedText: null,
  toastTimer: null,
  turns: [],
};

function showToast(message, tone = "default") {
  window.clearTimeout(state.toastTimer);
  elements.eventToast.textContent = message;
  elements.eventToast.dataset.tone = tone;
  elements.eventToast.classList.add("event-toast--visible");
  state.toastTimer = window.setTimeout(() => {
    elements.eventToast.classList.remove("event-toast--visible");
  }, 2600);
}

function appendMessage(text, edits, bypassed) {
  const message = document.createElement("div");
  message.className = "message message--user";

  const author = document.createElement("span");
  author.className = "message-author";
  author.textContent = "YOU / SENT";

  const body = document.createElement("p");
  body.textContent = text;
  message.append(author, body);

  if (edits.length > 0 || bypassed) {
    const localNote = document.createElement("div");
    localNote.className = "message-local-note";
    localNote.textContent = bypassed
      ? "문맥 검사를 건너뛰고 현재 입력 그대로 보냈습니다."
      : `사용자가 날린 표현: ${edits.map((edit) => `“${edit.raw}”`).join(", ")}`;
    message.append(localNote);
  }

  elements.conversation.append(message);
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  elements.conversation.scrollTo({
    top: elements.conversation.scrollHeight,
    behavior: reducedMotion ? "auto" : "smooth",
  });
}

function pulseComposer() {
  elements.composer.classList.remove("composer--invalid");
  requestAnimationFrame(() => elements.composer.classList.add("composer--invalid"));
}

function visualEditsFor(edits) {
  if (edits.length <= 3) return edits;
  const sourceValue = elements.promptInput.value;
  return [
    ...edits.slice(0, 3),
    {
      ...edits[3],
      to: edits.at(-1).to,
      raw: sourceValue.slice(edits[3].from, edits.at(-1).to),
      effect: "unwrite",
    },
  ];
}

function playEdits(edits) {
  const inputRect = elements.promptInput.getBoundingClientRect();
  const inputStyle = window.getComputedStyle(elements.promptInput);
  const paddingLeft = Number.parseFloat(inputStyle.paddingLeft) || 0;
  const paddingTop = Number.parseFloat(inputStyle.paddingTop) || 0;

  visualEditsFor(edits).forEach((edit) => {
    const measuredRect = measureTextareaRange(elements.promptInput, edit.from, edit.to);
    const isVisible =
      measuredRect.top + measuredRect.height >= inputRect.top &&
      measuredRect.top <= inputRect.bottom &&
      measuredRect.left + measuredRect.width >= inputRect.left &&
      measuredRect.left <= inputRect.right;
    const rect = isVisible
      ? measuredRect
      : {
          ...measuredRect,
          left: inputRect.left + paddingLeft,
          top: inputRect.top + paddingTop,
          width: Math.min(measuredRect.width, inputRect.width - paddingLeft),
        };

    spawnTextEffect({
      layer: elements.fxLayer,
      source: elements.promptInput,
      text: edit.raw,
      rect,
      effect: edit.effect,
    });
  });
}

function makeEffectSelect(candidate, selectedEffect) {
  const label = document.createElement("label");
  label.className = "habit-effect-select";
  const hidden = document.createElement("span");
  hidden.className = "sr-only";
  hidden.textContent = `${candidate.phrase} 퇴장 효과`;
  const select = document.createElement("select");
  select.dataset.action = "effect";

  EFFECT_IDS.forEach((effectId) => {
    const option = document.createElement("option");
    option.value = effectId;
    option.textContent = EFFECT_LABELS[effectId];
    option.selected = effectId === selectedEffect;
    select.append(option);
  });

  label.append(hidden, select);
  return label;
}

function makeHabitCard(candidate) {
  const card = document.createElement("article");
  card.className = "habit-card";
  card.dataset.candidateKey = candidate.key;

  const top = document.createElement("div");
  top.className = "habit-card-top";
  const phrase = document.createElement("strong");
  phrase.className = "habit-phrase";
  phrase.textContent = candidate.phrase;
  const badge = document.createElement("span");
  badge.className = "habit-badge";
  badge.textContent = candidate.decision === "accepted"
    ? candidate.enabled ? "CONTEXT ON" : "PAUSED"
    : candidate.ready ? "READY" : "LEARNING";
  top.append(phrase, badge);

  const metrics = document.createElement("p");
  metrics.className = "habit-metrics";
  metrics.textContent = `문두 ${candidate.starts}회 · 뒤 문맥 ${candidate.diversity}종 · 패턴 ${Math.round(candidate.confidence * 100)}%`;

  const progress = document.createElement("div");
  progress.className = "habit-progress";
  const progressBar = document.createElement("i");
  progressBar.style.width = `${Math.min(100, (candidate.starts / candidate.targetStarts) * 100)}%`;
  progress.append(progressBar);

  const actions = document.createElement("div");
  actions.className = "habit-actions";
  const effect = candidate.effect ?? effectForCandidate(candidate.key);

  if (candidate.decision === "accepted") {
    const toggle = document.createElement("label");
    toggle.className = "habit-auto-toggle";
    const toggleInput = document.createElement("input");
    toggleInput.type = "checkbox";
    toggleInput.checked = candidate.enabled;
    toggleInput.dataset.action = "enabled";
    const toggleText = document.createElement("span");
    toggleText.textContent = "문맥 검사";
    toggle.append(toggleInput, toggleText);
    actions.append(toggle, makeEffectSelect(candidate, effect));
  } else if (candidate.ready) {
    const accept = document.createElement("button");
    accept.type = "button";
    accept.dataset.action = "accept";
    accept.className = "habit-accept";
    accept.textContent = "문맥 검사";
    actions.append(makeEffectSelect(candidate, effect), accept);
  } else {
    const learning = document.createElement("span");
    learning.className = "habit-learning-copy";
    learning.textContent = `서로 다른 문장에서 ${candidate.targetStarts - candidate.starts}회 더 확인합니다.`;
    actions.append(learning);
  }

  const preview = document.createElement("button");
  preview.type = "button";
  preview.dataset.action = "preview";
  preview.className = "habit-preview";
  preview.setAttribute("aria-label", `${candidate.phrase} 효과 미리보기`);
  preview.textContent = "▶";
  actions.append(preview);

  const reject = document.createElement("button");
  reject.type = "button";
  reject.dataset.action = "reject";
  reject.className = "habit-reject";
  reject.textContent = candidate.decision === "accepted" ? "해제" : "아님";
  actions.append(reject);

  card.append(top, metrics, progress, actions);
  return card;
}

function renderHabits() {
  const candidates = rankHabitCandidates(state.model);
  const acceptedCount = candidates.filter((candidate) => candidate.decision === "accepted" && candidate.enabled).length;

  elements.observedCount.textContent = String(state.model.totalPrompts);
  elements.modelStatus.textContent = acceptedCount > 0
    ? `${acceptedCount} CONTEXT`
    : candidates.length > 0
      ? `${candidates.length} FOUND`
      : "LISTENING";

  if (state.model.totalPrompts === 0) {
    elements.learningState.textContent = "아직 판단하지 않습니다.";
  } else if (candidates.length === 0) {
    elements.learningState.textContent = "문장 시작과 뒤 문맥을 비교 중입니다.";
  } else if (candidates.some((candidate) => candidate.ready && candidate.decision !== "accepted")) {
    elements.learningState.textContent = "문맥 검사를 켤 수 있는 반복 후보가 있습니다.";
  } else {
    elements.learningState.textContent = "반복 패턴을 계속 확인하고 있습니다.";
  }

  if (candidates.length === 0) {
    const empty = document.createElement("div");
    empty.className = "habit-empty";
    const strong = document.createElement("strong");
    strong.textContent = "아직 들은 습관이 없습니다.";
    const copy = document.createElement("p");
    copy.textContent = "반복은 검사 후보만 만듭니다. 실제 제거 여부는 매 문장의 문맥을 따로 봅니다.";
    empty.append(strong, copy);
    elements.habitList.replaceChildren(empty);
    return;
  }

  const fragment = document.createDocumentFragment();
  candidates.forEach((candidate) => fragment.append(makeHabitCard(candidate)));
  elements.habitList.replaceChildren(fragment);
}

function renderEffectPalette() {
  const fragment = document.createDocumentFragment();
  EFFECT_IDS.forEach((effectId) => {
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.effect = effectId;
    button.className = "effect-chip";
    button.textContent = EFFECT_LABELS[effectId];
    button.setAttribute("aria-label", `${EFFECT_LABELS[effectId]} 효과 미리보기`);
    fragment.append(button);
  });
  elements.effectPalette.replaceChildren(fragment);
}

const REVIEW_COPY = Object.freeze({
  AMBIGUOUS: "빼도 될 가능성은 있지만 말투가 달라질 수 있습니다.",
  CONTEXT_INSUFFICIENT: "판단할 문맥이 충분하지 않아 원문을 유지합니다.",
  FORMAT_OR_LITERAL: "인용·코드·형식의 일부라서 그대로 둡니다.",
  MEANING_BEARING: "이번 문장에서는 의미나 연결 역할이 있습니다.",
  REDUNDANT_NO_EFFECT: "이번 문장에서는 빼도 의미와 의도가 유지됩니다.",
  TONE_BEARING: "의미는 비슷하지만 말투나 강조가 달라질 수 있습니다.",
  context_insufficient: "판단할 문맥이 충분하지 않아 원문을 유지합니다.",
  malformed_candidate: "정확한 구간을 확인하지 못해 원문을 유지합니다.",
  meaning_bearing: "이번 문장에서는 의미나 연결 역할이 있습니다.",
  optional_style: "빼도 될 수 있지만 말투나 강조가 달라질 수 있습니다.",
  semantically_empty: "이번 문장에서는 빼도 의미와 의도가 유지됩니다.",
  unsafe_edit: "안전하게 편집할 수 없어 원문을 유지합니다.",
});

function setPredictionAction(label) {
  const shortcut = document.createElement("kbd");
  shortcut.textContent = "Tab";
  elements.predictionAction.replaceChildren(document.createTextNode(`${label} `), shortcut);
}

function announceReview(message = "") {
  elements.reviewLive.textContent = message;
}

function clearReview({ abort = true } = {}) {
  window.clearTimeout(state.reviewTimer);
  state.reviewTimer = null;
  if (abort) state.review.controller?.abort();
  state.review = {
    controller: null,
    occurrence: null,
    payload: null,
    result: null,
    sourceText: null,
    status: "idle",
  };
  elements.composer.removeAttribute("aria-busy");
}

function reviewMatchesCurrentInput() {
  return Boolean(
    state.review.sourceText === elements.promptInput.value &&
    state.review.occurrence?.candidateKey === state.suggestion?.key,
  );
}

function renderPrediction() {
  const suggestion = state.suggestion;
  const suppressed = state.suppressedText === elements.promptInput.value;
  elements.predictionBar.dataset.state = "idle";

  if (!suggestion || suppressed) {
    elements.predictionBar.hidden = true;
    announceReview();
    return;
  }

  elements.predictionPhrase.textContent = suggestion.phrase;
  elements.predictionAction.hidden = true;

  if (suggestion.kind === "prediction") {
    elements.predictionLabel.textContent = "LOCAL PATTERN";
    elements.predictionCopy.textContent = "까지 이어질 수 있습니다. 반복은 검사 후보를 고를 뿐 삭제 근거가 아닙니다.";
    announceReview();
  } else if (suggestion.kind === "candidate-ready") {
    elements.predictionLabel.textContent = "CONTEXT AVAILABLE";
    elements.predictionCopy.textContent = "가 반복됐습니다. 우측에서 문맥 검사를 켜면 매 문장에서 따로 판단합니다.";
    announceReview("반복 후보가 발견됐습니다. 아직 텍스트는 바뀌지 않았습니다.");
  } else if (suggestion.kind === "repeat-learning") {
    elements.predictionLabel.textContent = "PATTERN OBSERVED";
    elements.predictionCopy.textContent = "를 관찰 중입니다. 지금은 어떤 편집도 제안하지 않습니다.";
    announceReview();
  } else if (!reviewMatchesCurrentInput() || state.review.status === "idle") {
    elements.predictionLabel.textContent = "CONTEXT QUEUED";
    elements.predictionCopy.textContent = "가 이번 문장에서 맡는 역할을 확인할 예정입니다.";
    elements.predictionBar.dataset.state = "loading";
    announceReview("문맥 검사를 준비하고 있습니다.");
  } else if (state.review.status === "queued" || state.review.status === "loading") {
    elements.predictionLabel.textContent = "READING CONTEXT";
    elements.predictionCopy.textContent = "의 반복 횟수는 무시하고, 현재 문장과 최근 세션만 비교하고 있습니다.";
    elements.predictionBar.dataset.state = "loading";
    announceReview("현재 문맥에서 표현의 역할을 확인하고 있습니다.");
  } else if (state.review.status === "keep") {
    elements.predictionLabel.textContent = "CONTEXT · KEEP";
    elements.predictionCopy.textContent = REVIEW_COPY[state.review.result?.reasonCode]
      ?? "이번 문장에서는 그대로 두는 편이 안전합니다.";
    elements.predictionBar.dataset.state = "keep";
    announceReview("문맥 판정 결과, 이번 표현은 유지합니다.");
  } else if (state.review.status === "suggest" || state.review.status === "remove") {
    const strongRecommendation = state.review.status === "remove";
    elements.predictionLabel.textContent = strongRecommendation
      ? "CONTEXT · RELEASE"
      : "CONTEXT · YOUR CALL";
    elements.predictionCopy.textContent = REVIEW_COPY[state.review.result?.reasonCode]
      ?? "명시적으로 수락할 때만 이 구간을 뺍니다.";
    elements.predictionAction.hidden = false;
    elements.predictionBar.dataset.state = strongRecommendation ? "remove" : "suggest";
    setPredictionAction("이번만 날리기");
    announceReview("제거 제안이 있습니다. Tab 또는 화면 버튼으로만 적용됩니다.");
  } else if (state.review.status === "error") {
    elements.predictionLabel.textContent = "CONTEXT · UNAVAILABLE";
    elements.predictionCopy.textContent = "를 판단하지 못했습니다. 실패 시에는 항상 원문을 유지합니다.";
    elements.predictionBar.dataset.state = "error";
    announceReview("문맥 판정을 사용할 수 없어 원문을 유지합니다.");
  }

  elements.predictionBar.hidden = false;
}

function scheduleContextReview(suggestion) {
  if (state.composing || suggestion.kind !== "context-check") return;

  let occurrence;
  try {
    occurrence = createContextOccurrence({
      text: elements.promptInput.value,
      suggestion,
      revision: state.revision,
    });
  } catch {
    clearReview();
    return;
  }

  if (
    state.review.sourceText === elements.promptInput.value &&
    state.review.occurrence?.candidateDigest === occurrence.candidateDigest &&
    state.review.status !== "error"
  ) {
    return;
  }

  clearReview();
  const requestId = `wds-${Date.now().toString(36)}-${++state.reviewSequence}`;
  const payload = buildJudgePayload({
    occurrence,
    turns: state.turns.slice(-8),
    requestId,
  });
  state.review = {
    controller: null,
    occurrence,
    payload,
    result: null,
    sourceText: elements.promptInput.value,
    status: "queued",
  };
  renderPrediction();

  state.reviewTimer = window.setTimeout(async () => {
    if (!reviewMatchesCurrentInput() || state.composing) return;
    const controller = new AbortController();
    state.review.controller = controller;
    state.review.status = "loading";
    elements.composer.setAttribute("aria-busy", "true");
    renderPrediction();

    try {
      const response = await requestContextJudgment(payload, { signal: controller.signal });
      if (
        controller.signal.aborted ||
        state.review.payload !== payload ||
        !reviewMatchesCurrentInput() ||
        elements.promptInput.value !== occurrence.sourceText
      ) return;

      const result = normalizeJudgeResponse({ payload, response });
      state.review.result = result;
      state.review.status = result.status;
    } catch (error) {
      if (controller.signal.aborted || state.review.payload !== payload) return;
      state.review.status = error?.code === "aborted" ? "idle" : "error";
    } finally {
      if (state.review.payload === payload) {
        state.review.controller = null;
        elements.composer.removeAttribute("aria-busy");
        renderPrediction();
      }
    }
  }, 480);
}

function updatePrediction({ schedule = true } = {}) {
  if (state.suppressedText !== elements.promptInput.value) state.suppressedText = null;

  const previousSuggestion = state.suggestion;
  state.suggestion = suggestForInput(state.model, {
    text: elements.promptInput.value,
    cursor: elements.promptInput.selectionStart,
    composing: state.composing,
  });

  const reviewBecameStale =
    state.review.sourceText !== elements.promptInput.value ||
    state.review.occurrence?.candidateKey !== state.suggestion?.key;
  if (state.review.status !== "idle" && reviewBecameStale) clearReview();

  renderPrediction();
  if (schedule && state.suggestion?.kind === "context-check") {
    scheduleContextReview(state.suggestion);
  } else if (
    previousSuggestion?.kind === "context-check" &&
    state.suggestion?.kind !== "context-check"
  ) {
    clearReview();
  }
}

function applyReviewEdit() {
  if (
    !["suggest", "remove"].includes(state.review.status) ||
    !reviewMatchesCurrentInput() ||
    state.composing
  ) return;

  let plan;
  try {
    plan = createExplicitRemovalPlan({
      text: elements.promptInput.value,
      occurrence: state.review.occurrence,
      effect: state.suggestion?.effect ?? effectForCandidate(state.suggestion?.key ?? "context"),
    });
  } catch {
    showToast("입력이 바뀌어 오래된 제안을 적용하지 않았습니다.", "warning");
    clearReview();
    updatePrediction();
    return;
  }

  if (!plan?.output?.trim() || !Array.isArray(plan.edits) || plan.edits.length !== 1) return;
  const previousValue = elements.promptInput.value;
  const previousCursor = elements.promptInput.selectionStart;
  const [edit] = plan.edits;
  playEdits(plan.edits);
  state.appliedSourceText ??= previousValue;
  state.appliedEdits.push(edit);
  state.released += 1;
  state.revision += 1;
  elements.releasedCount.textContent = String(state.released);
  elements.promptInput.value = plan.output;
  const removedLength = edit.consumedTo - edit.from;
  const nextCursor = Math.max(0, previousCursor - removedLength);
  elements.promptInput.setSelectionRange(nextCursor, nextCursor);
  elements.promptInput.focus();
  clearReview();
  state.suppressedText = null;
  showToast("문맥 제안을 수락해 이 입력에서만 날렸습니다.", "success");
  announceReview("제안한 표현을 제거했습니다.");
  updatePrediction();
}

function sendPrompt({ bypass = false } = {}) {
  if (state.composing) {
    showToast("한글 조합이 끝난 뒤 보내주세요.", "warning");
    return;
  }

  const original = elements.promptInput.value;
  if (!original.trim()) {
    pulseComposer();
    showToast("보낼 말이 없습니다.", "warning");
    return;
  }

  const beforeCandidates = rankHabitCandidates(state.model);
  const beforePreviewKeys = new Set(beforeCandidates.map((candidate) => candidate.key));
  const beforeReadyKeys = new Set(
    beforeCandidates.filter((candidate) => candidate.ready).map((candidate) => candidate.key),
  );
  const observedText = state.appliedSourceText ?? original;
  const appliedEdits = [...state.appliedEdits];
  appendMessage(original, appliedEdits, bypass);
  state.model = observePrompt(state.model, { text: observedText });
  state.turns.push({ role: "user", text: original });
  state.turns = state.turns.slice(-8);
  clearReview();
  elements.promptInput.value = "";
  elements.promptInput.focus();
  state.revision += 1;
  state.appliedEdits = [];
  state.appliedSourceText = null;
  state.suppressedText = null;
  renderHabits();
  updatePrediction();

  const afterCandidates = rankHabitCandidates(state.model);
  const newlyReady = afterCandidates.find(
    (candidate) => candidate.ready && !beforeReadyKeys.has(candidate.key),
  );
  const newlyVisible = afterCandidates.find((candidate) => !beforePreviewKeys.has(candidate.key));

  if (appliedEdits.length > 0) {
    showToast(`직접 수락한 표현 ${appliedEdits.length}개를 뺀 상태로 전송했습니다.`, "success");
  } else if (newlyReady) {
    showToast(`새 반복 후보가 문맥 검사를 기다리고 있습니다.`, "success");
  } else if (newlyVisible) {
    showToast("새로운 반복 패턴을 관찰하기 시작했습니다.");
  } else if (bypass) {
    showToast("문맥 검사를 건너뛰고 현재 입력 그대로 전송했습니다.");
  } else {
    showToast(`${state.model.totalPrompts}번째 문장의 시작을 비교했습니다.`);
  }
}

elements.composerForm.addEventListener("submit", (event) => {
  event.preventDefault();
  sendPrompt();
});

elements.rawSendButton.addEventListener("click", () => sendPrompt({ bypass: true }));
elements.predictionAction.addEventListener("click", applyReviewEdit);

elements.promptInput.addEventListener("compositionstart", () => {
  state.composing = true;
  clearReview();
  state.suggestion = null;
  elements.predictionBar.hidden = true;
});

elements.promptInput.addEventListener("compositionend", () => {
  state.composing = false;
  state.lastCompositionEnd = performance.now();
  requestAnimationFrame(updatePrediction);
});

elements.promptInput.addEventListener("input", () => {
  state.revision += 1;
  updatePrediction();
});
elements.promptInput.addEventListener("click", updatePrediction);
elements.promptInput.addEventListener("keyup", (event) => {
  if (!["Enter", "Tab", "Escape"].includes(event.key)) updatePrediction();
});

elements.promptInput.addEventListener("keydown", (event) => {
  if (
    event.key === "Tab" &&
    !event.shiftKey &&
    !event.altKey &&
    !event.ctrlKey &&
    !event.metaKey &&
    !state.composing &&
    ["suggest", "remove"].includes(state.review.status) &&
    reviewMatchesCurrentInput()
  ) {
    event.preventDefault();
    applyReviewEdit();
    return;
  }

  if (event.key === "Escape" && state.suggestion) {
    clearReview();
    state.suppressedText = elements.promptInput.value;
    renderPrediction();
    return;
  }

  if (event.key !== "Enter" || event.shiftKey) return;
  const inCompositionGrace = performance.now() - state.lastCompositionEnd < 32;
  if (event.isComposing || event.keyCode === 229 || state.composing) return;
  if (inCompositionGrace) {
    event.preventDefault();
    event.stopPropagation();
    return;
  }

  event.preventDefault();
  sendPrompt({ bypass: event.altKey });
});

elements.habitList.addEventListener("change", (event) => {
  const card = event.target.closest(".habit-card");
  if (!card) return;
  const key = card.dataset.candidateKey;

  if (event.target.matches('[data-action="enabled"]')) {
    state.model = setCandidateEnabled(state.model, { key, enabled: event.target.checked });
    if (!event.target.checked && state.suggestion?.key === key) clearReview();
  }

  if (event.target.matches('[data-action="effect"]')) {
    state.model = setCandidateEffect(state.model, { key, effect: event.target.value });
  }

  renderHabits();
  updatePrediction();
});

elements.habitList.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  const card = button.closest(".habit-card");
  const key = card.dataset.candidateKey;
  const candidate = rankHabitCandidates(state.model).find((item) => item.key === key);
  if (!candidate) return;

  if (button.dataset.action === "accept") {
    const effect = card.querySelector('select[data-action="effect"]')?.value ?? effectForCandidate(key);
    state.model = setCandidateDecision(state.model, { key, decision: "accepted", effect });
    showToast("이 반복 표현은 앞으로 매번 문맥을 따로 확인합니다.", "success");
  }

  if (button.dataset.action === "reject") {
    state.model = setCandidateDecision(state.model, { key, decision: "rejected" });
    if (state.suggestion?.key === key) clearReview();
    showToast("이 표현은 반복 후보에서 제외했습니다.");
  }

  if (button.dataset.action === "preview") {
    const phrase = card.querySelector(".habit-phrase");
    const effect = card.querySelector('select[data-action="effect"]')?.value
      ?? candidate.effect
      ?? effectForCandidate(key);
    previewElementEffect({ layer: elements.fxLayer, element: phrase, text: candidate.phrase, effect });
  }

  renderHabits();
  updatePrediction();
});

elements.effectPalette.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-effect]");
  if (!button) return;
  previewElementEffect({
    layer: elements.fxLayer,
    element: button,
    text: button.textContent,
    effect: button.dataset.effect,
  });
});

renderEffectPalette();
renderHabits();
updatePrediction();
