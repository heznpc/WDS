const EFFECT_COLORS = Object.freeze({
  ascend: "#d8ff66",
  deflate: "#ffcb70",
  melt: "#ff7e7e",
  poof: "#c5b8ff",
  unwrite: "#71d7ff",
  vortex: "#f0a8ff",
});

const EFFECT_DURATIONS = Object.freeze({
  ascend: 560,
  deflate: 460,
  melt: 600,
  poof: 500,
  unwrite: 560,
  vortex: 600,
});

const mirrorProperties = [
  "borderBottomWidth",
  "borderLeftWidth",
  "borderRightWidth",
  "borderTopWidth",
  "boxSizing",
  "direction",
  "fontFamily",
  "fontFeatureSettings",
  "fontKerning",
  "fontSize",
  "fontStretch",
  "fontStyle",
  "fontVariant",
  "fontVariationSettings",
  "fontWeight",
  "letterSpacing",
  "lineHeight",
  "overflowX",
  "overflowY",
  "scrollbarGutter",
  "paddingBottom",
  "paddingLeft",
  "paddingRight",
  "paddingTop",
  "tabSize",
  "textAlign",
  "textIndent",
  "textTransform",
  "wordSpacing",
  "writingMode",
];

const ghostTextProperties = [
  "direction",
  "fontFamily",
  "fontFeatureSettings",
  "fontKerning",
  "fontSize",
  "fontStretch",
  "fontStyle",
  "fontVariant",
  "fontVariationSettings",
  "fontWeight",
  "letterSpacing",
  "lineHeight",
  "tabSize",
  "textAlign",
  "textTransform",
  "wordSpacing",
  "writingMode",
];

function copyTextStyle(source, target) {
  const style = window.getComputedStyle(source);
  for (const property of ghostTextProperties) {
    target.style[property] = style[property];
  }
}

export function measureTextareaRange(textarea, from, to) {
  const textareaRect = textarea.getBoundingClientRect();
  const computed = window.getComputedStyle(textarea);
  const mirror = document.createElement("div");

  mirror.className = "textarea-mirror";
  mirror.style.position = "fixed";
  mirror.style.left = `${textareaRect.left}px`;
  mirror.style.top = `${textareaRect.top}px`;
  mirror.style.width = `${textareaRect.width}px`;
  mirror.style.height = `${textareaRect.height}px`;
  mirror.style.visibility = "hidden";
  mirror.style.overflow = "hidden";
  mirror.style.whiteSpace = "pre-wrap";
  mirror.style.overflowWrap = "break-word";
  mirror.style.wordBreak = "break-word";
  mirror.style.pointerEvents = "none";

  for (const property of mirrorProperties) {
    mirror.style[property] = computed[property];
  }

  mirror.append(document.createTextNode(textarea.value.slice(0, from)));
  const marker = document.createElement("span");
  marker.textContent = textarea.value.slice(from, to) || "\u200b";
  mirror.append(marker, document.createTextNode(textarea.value.slice(to) || "\u200b"));
  document.body.append(mirror);
  mirror.scrollTop = textarea.scrollTop;
  mirror.scrollLeft = textarea.scrollLeft;

  const markerRects = marker.getClientRects();
  const markerRect = marker.getBoundingClientRect();
  mirror.remove();

  return {
    left: markerRect.left,
    top: markerRect.top,
    width: markerRect.width,
    height: markerRect.height,
    multiline: markerRects.length > 1,
  };
}

function segmentGraphemes(text) {
  if (typeof Intl.Segmenter === "function") {
    const segmenter = new Intl.Segmenter("ko", { granularity: "grapheme" });
    return Array.from(segmenter.segment(text), ({ segment }) => segment);
  }

  return Array.from(text);
}

function appendCharacterSpans(copy, text, effect) {
  const graphemes = segmentGraphemes(text);

  graphemes.forEach((character, index) => {
    const span = document.createElement("span");
    span.className = "fx-char";
    span.textContent = character;

    if (effect === "melt") {
      span.style.setProperty("--char-delay", `${Math.min(index * 18, 120)}ms`);
    } else {
      const reverseIndex = graphemes.length - index - 1;
      span.style.setProperty("--char-delay", `${Math.min(reverseIndex * 42, 240)}ms`);
    }

    copy.append(span);
  });
}

function appendParticles(root, count, radius, className = "fx-particle") {
  for (let index = 0; index < count; index += 1) {
    const angle = (Math.PI * 2 * index) / count - Math.PI / 2;
    const particle = document.createElement("i");
    particle.className = className;
    particle.style.setProperty("--particle-x", `${Math.cos(angle) * radius}px`);
    particle.style.setProperty("--particle-y", `${Math.sin(angle) * radius}px`);
    particle.style.setProperty("--particle-delay", `${index * 16}ms`);
    root.append(particle);
  }
}

export function spawnTextEffect({ layer, source, text, rect, effect }) {
  const root = document.createElement("span");
  const copy = document.createElement("span");
  const safeEffect = Object.hasOwn(EFFECT_COLORS, effect) ? effect : "ascend";

  root.className = `fx-ghost fx-ghost--${safeEffect}`;
  root.classList.toggle("fx-ghost--multiline", Boolean(rect.multiline));
  root.style.left = `${rect.left}px`;
  root.style.top = `${rect.top}px`;
  root.style.width = `${Math.max(rect.width, 1)}px`;
  root.style.height = `${Math.max(rect.height, 1)}px`;
  root.style.setProperty("--effect-color", EFFECT_COLORS[safeEffect]);
  root.setAttribute("aria-hidden", "true");

  copy.className = "fx-copy";
  copyTextStyle(source, copy);

  if (safeEffect === "melt" || safeEffect === "unwrite") {
    appendCharacterSpans(copy, text, safeEffect);
  } else {
    copy.textContent = text;
  }

  root.append(copy);

  if (safeEffect === "ascend") {
    const halo = document.createElement("i");
    halo.className = "fx-halo";
    root.append(halo);
    appendParticles(root, 3, 23, "fx-star");
  }

  if (safeEffect === "poof") {
    appendParticles(root, 6, 32);
  }

  if (safeEffect === "vortex") {
    const vortex = document.createElement("i");
    vortex.className = "fx-vortex";
    root.append(vortex);
  }

  layer.append(root);

  const fallbackTimer = window.setTimeout(
    () => root.remove(),
    EFFECT_DURATIONS[safeEffect] + 220,
  );
  requestAnimationFrame(() => {
    const animations = root.getAnimations({ subtree: true });
    if (animations.length === 0) return;

    Promise.allSettled(animations.map((animation) => animation.finished)).then(() => {
      window.clearTimeout(fallbackTimer);
      root.remove();
    });
  });
  return root;
}

export function previewElementEffect({ layer, element, text, effect }) {
  const range = document.createRange();
  range.selectNodeContents(element);
  const rangeRect = range.getBoundingClientRect();
  const rect = rangeRect.width > 0 ? rangeRect : element.getBoundingClientRect();
  return spawnTextEffect({ layer, source: element, text, rect, effect });
}
