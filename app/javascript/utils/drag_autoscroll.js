// Scrolls the box a dragged item is in while the pointer rests near its top
// or bottom edge, so an item can be moved past what is on screen. Without it
// a held item could only reach the rows already in view: a mouse wheel does
// nothing during a native drag in most browsers, and a touch drag holds the
// page still.
//
// update() is called with the pointer on every move (dragover, touchmove);
// the scrolling runs once per frame, so it carries on while the pointer is
// still, faster the closer it is to the edge. onScroll(x, y) lets the caller
// place the drop position again as the rows move under a still pointer.
export default class DragAutoscroll {
  constructor({ edge = 80, maxStep = 20, onScroll = () => {} } = {}) {
    this.edge = edge;
    this.maxStep = maxStep;
    this.onScroll = onScroll;
    this.scroller = null;
    this.point = null;
    this.frame = null;
  }

  update(element, clientX, clientY) {
    this.scroller ??= scrollParent(element);
    this.point = { x: clientX, y: clientY };
    this.frame ??= requestAnimationFrame(this.#step);
  }

  stop() {
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = null;
    this.scroller = null;
    this.point = null;
  }

  #step = () => {
    this.frame = null;
    if (!this.scroller || !this.point) return;

    const step = this.#stepFor(this.point.y);
    if (step === 0) return;

    const before = this.scroller.scrollTop;
    this.scroller.scrollTop = before + step;
    if (this.scroller.scrollTop === before) return; // at the end already

    this.onScroll(this.point.x, this.point.y);
    this.frame = requestAnimationFrame(this.#step);
  };

  // Pixels to scroll this frame: 0 away from the edges, up to maxStep at
  // (or past) an edge of the box's visible part.
  #stepFor(y) {
    const { top, bottom } = visibleBounds(this.scroller);
    const edge = Math.min(this.edge, (bottom - top) / 4);
    if (y < top + edge)
      return -Math.ceil(this.maxStep * strength(top + edge - y, edge));
    if (y > bottom - edge)
      return Math.ceil(this.maxStep * strength(y - (bottom - edge), edge));
    return 0;
  }
}

// 0 at the inner end of the edge zone, 1 at the edge and beyond, eased so
// the speed is easy to control near the start.
function strength(depth, edge) {
  const t = Math.min(depth / edge, 1);
  return t * t;
}

function visibleBounds(scroller) {
  if (scroller === document.scrollingElement)
    return { top: 0, bottom: window.innerHeight };
  const rect = scroller.getBoundingClientRect();
  return {
    top: Math.max(rect.top, 0),
    bottom: Math.min(rect.bottom, window.innerHeight),
  };
}

function scrollParent(element) {
  for (let node = element?.parentElement; node; node = node.parentElement) {
    const { overflowY } = getComputedStyle(node);
    if (/auto|scroll/.test(overflowY) && node.scrollHeight > node.clientHeight)
      return node;
  }
  return document.scrollingElement;
}
