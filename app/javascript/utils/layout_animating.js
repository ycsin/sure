// Marks the page while a sidebar is animating or being dragged, as
// `<html data-layout-animating>`. Each frame of a sidebar's width change lays
// out everything beside it again, and a long list (an account's activity) takes
// most of a frame to lay out; while the mark is set, CSS lets rows that are off
// screen skip that (content-visibility: auto, on the activity row partials). It is not left
// on: that containment would clip the rows' fixed-position menus.
let holds = 0;

function apply() {
  if (holds > 0) {
    document.documentElement.dataset.layoutAnimating = "";
  } else {
    delete document.documentElement.dataset.layoutAnimating;
  }
}

// Marks the page until the caller releases it (a drag).
export function holdLayoutAnimating() {
  holds += 1;
  apply();
  let released = false;
  return () => {
    if (released) return;
    released = true;
    holds -= 1;
    apply();
  };
}

// Marks the page until `element`'s width transition ends (or `fallbackMs`
// passes, for a transition that never runs or ends). A toggle while the
// sidebar is still moving reverses its transition: the old one is cancelled
// and a new one runs. The element keeps one mark, renewed by each toggle and
// released by the end of the running transition, never by a cancellation.
const marks = new WeakMap();

export function markLayoutAnimating(element, { fallbackMs = 600 } = {}) {
  let mark = marks.get(element);
  if (!mark) {
    const release = holdLayoutAnimating();
    mark = {
      timer: null,
      finish: () => {
        element.removeEventListener("transitionend", mark.onEnd);
        clearTimeout(mark.timer);
        marks.delete(element);
        release();
      },
      onEnd: (event) => {
        if (event.target === element && event.propertyName === "width") mark.finish();
      },
    };
    element.addEventListener("transitionend", mark.onEnd);
    marks.set(element, mark);
  }
  clearTimeout(mark.timer);
  mark.timer = setTimeout(() => mark.finish(), fallbackMs);
}
