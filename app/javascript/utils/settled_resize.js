// Redraws a chart once its container has settled on a new size, stretching
// the drawing it already has in the meantime.
//
// A container resized by an animation (a sidebar opening or closing) or by a
// drag changes size on every frame, and a full d3 redraw on each of them makes
// the animation stutter. Instead the existing SVG is stretched to the new size
// at once, and `redraw` runs when a width transition around the chart ends or
// the size has not changed for `settleMs`. A size that did not change (the
// observer's first callback right after the chart drew) redraws nothing.
//
// Text is not stretched with the drawing: each label is scaled back to its
// normal shape around its anchor, and a label marked
// `data-settled-resize-edge="left"` or `"right"` also keeps its distance from
// that edge, so the redraw at the end finds it where it already is.
export default class SettledResize {
  constructor(element, redraw, { settleMs = 150 } = {}) {
    this.element = element;
    this.redraw = redraw;
    this.settleMs = settleMs;
    this.timer = null;
    this.drawnSize = null;
    // Width transitions running around the chart (a sidebar animating): while
    // any is, only its end settles the chart, not a pause in resizes.
    this.transitions = new Set();
  }

  start() {
    this.drawnSize = this.#size();
    this.observer = new ResizeObserver(() => this.#onResize());
    this.observer.observe(this.element);
    document.addEventListener("transitionrun", this.#onTransitionRun);
    document.addEventListener("transitionend", this.#onTransitionEnd);
    document.addEventListener("transitioncancel", this.#onTransitionEnd);
  }

  stop() {
    this.observer?.disconnect();
    document.removeEventListener("transitionrun", this.#onTransitionRun);
    document.removeEventListener("transitionend", this.#onTransitionEnd);
    document.removeEventListener("transitioncancel", this.#onTransitionEnd);
    clearTimeout(this.timer);
    this.timer = null;
  }

  // The chart drew (for any reason): this is now the size it is drawn at.
  drew() {
    this.drawnSize = this.#size();
    this.textGeometry = null;
    // A pending settle would only draw the same size again.
    clearTimeout(this.timer);
    this.timer = null;
  }

  #size() {
    return { width: this.element.clientWidth, height: this.element.clientHeight };
  }

  #onResize() {
    const size = this.#size();
    const drawn = this.drawnSize;
    if (drawn && size.width === drawn.width && size.height === drawn.height) {
      // Back at the drawn size before settling (a quick drag back and forth):
      // the drawing may still be stretched to the last size, so undo that.
      const stretched = this.element.querySelector("svg");
      if (this.timer && stretched) this.#stretch(stretched, size);
      clearTimeout(this.timer);
      this.timer = null;
      return;
    }

    const svg = this.element.querySelector("svg");
    // Nothing to stretch (a chart that was hidden or too small to draw): draw now.
    if (!svg || !drawn || drawn.width <= 0 || drawn.height <= 0) {
      this.#settle();
      return;
    }

    this.#stretch(svg, size);
    clearTimeout(this.timer);
    // During a width transition, wait for its end (with a long fallback in case
    // it never comes); otherwise for a pause in resizes (a drag, a window).
    const wait = this.transitions.size > 0 ? 1000 : this.settleMs;
    this.timer = setTimeout(() => this.#settle(), wait);
  }

  #stretch(svg, size) {
    // Measure the labels once, as drawn, before anything is stretched; again
    // if the SVG was replaced since (a chart's delayed, animated draw).
    if (!this.textGeometry || this.textGeometrySvg !== svg) {
      this.textGeometry = this.#measureTexts(svg);
      this.textGeometrySvg = svg;
    }
    if (!svg.hasAttribute("viewBox")) {
      const width = svg.getAttribute("width") || this.drawnSize.width;
      const height = svg.getAttribute("height") || this.drawnSize.height;
      svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    }
    svg.setAttribute("width", size.width);
    svg.setAttribute("height", size.height);
    svg.setAttribute("preserveAspectRatio", "none");

    const drawn = this.drawnSize;
    const sx = size.width / drawn.width;
    const sy = size.height / drawn.height;
    this.textGeometry.forEach((geometry) => this.#keepTextShape(geometry, sx, sy, size));
  }

  // Where each label's anchor sits, in the chart's own coordinates (its
  // groups' offsets included), and which share of its box that anchor is at.
  #measureTexts(svg) {
    const toSvg = svg.getScreenCTM()?.inverse();
    return Array.from(svg.querySelectorAll("text")).flatMap((text) => {
      const box = text.getBBox();
      const ctm = text.getScreenCTM();
      if (!toSvg || !ctm || box.width === 0) return [];
      const anchor = getComputedStyle(text).textAnchor;
      const share = anchor === "start" ? 0 : anchor === "end" ? 1 : 0.5;
      const offsetX = toSvg.multiply(ctm).e;
      return [ { text, share, x: offsetX + box.x + box.width * share, edge: text.dataset.settledResizeEdge } ];
    });
  }

  // Scales a label back by the stretch, around the point its text-anchor puts
  // it at, so its glyphs keep their shape; an edge label is moved to keep its
  // distance from that edge.
  #keepTextShape({ text, share, x, edge }, sx, sy, size) {
    let dx = 0;
    if (edge === "left") dx = x / sx - x;
    if (edge === "right") dx = (size.width - (this.drawnSize.width - x)) / sx - x;
    text.style.transformBox = "fill-box";
    text.style.transformOrigin = `${share * 100}% 50%`;
    text.style.transform = `translate(${dx}px, 0) scale(${1 / sx}, ${1 / sy})`;
  }

  #settle() {
    clearTimeout(this.timer);
    this.timer = null;
    this.redraw();
    this.drawnSize = this.#size();
    this.textGeometry = null;
  }

  #isLayoutTransition(event) {
    return event.propertyName === "width" && !this.element.contains(event.target);
  }

  #onTransitionRun = (event) => {
    if (this.#isLayoutTransition(event)) this.transitions.add(event.target);
  };

  // A layout transition (a sidebar's width) has ended: redraw at once rather
  // than wait out the settle delay, once no other one is still running.
  #onTransitionEnd = (event) => {
    if (!this.#isLayoutTransition(event)) return;
    this.transitions.delete(event.target);
    if (this.timer && this.transitions.size === 0) this.#settle();
  };
}
