import { Controller } from "@hotwired/stimulus"

// Sizes the app to the window (--app-height) and keeps the end of the page
// clear of the mobile bottom nav.
//
// The page scrolls inside #main, which reserves room for the fixed nav with
// a bottom padding of 5rem plus the safe area. That holds while the page ends
// where the screen does. In an installed web app on iOS the last rows (an
// account's page numbers and rows-per-page menu) were reported to stay under
// the nav at the end of the scroll, as when the page runs below the visible
// screen (sized to a window height taller than the screen it's shown on).
// #main's padding therefore also covers how far it actually runs under the
// nav, measured here as --bottom-nav-overlap.
export default class extends Controller {
  static targets = ["content", "bottomNav"]

  // Before connect(): Stimulus reports the targets already on the page first.
  initialize() {
    this.resizeObserver = new ResizeObserver(() => this.updateBottomNavOverlap())
  }

  connect() {
    this.updateViewport()

    this.boundResize = this.handleResize.bind(this)

    window.addEventListener("resize", this.boundResize)
    window.addEventListener("orientationchange", this.boundResize)
    window.visualViewport?.addEventListener("resize", this.boundResize)
  }

  disconnect() {
    window.removeEventListener("resize", this.boundResize)
    window.removeEventListener("orientationchange", this.boundResize)
    window.visualViewport?.removeEventListener("resize", this.boundResize)
  }

  // Turbo swaps <body> (and with it both targets) on each visit; this
  // controller sits on <html> and stays.
  // #main fills its parent; the parent's size changes with the app's height.
  contentTargetConnected(element) {
    this.resizeObserver.observe(element.parentElement)
    this.updateBottomNavOverlap()
  }

  contentTargetDisconnected(element) {
    if (element.parentElement) this.resizeObserver.unobserve(element.parentElement)
  }

  bottomNavTargetConnected(element) {
    this.resizeObserver.observe(element)
    this.updateBottomNavOverlap()
  }

  bottomNavTargetDisconnected(element) {
    this.resizeObserver.unobserve(element)
  }

  handleResize() {
    this.updateViewport()
    this.updateBottomNavOverlap()
  }

  updateViewport() {
    const height = window.innerHeight
    document.documentElement.style.setProperty("--app-height", `${height}px`)
  }

  // How far #main runs under the nav. Measured at the bottom of #main's
  // parent, which #main fills: #main's own box grows with a padding taller
  // than it, which would feed back into the measurement.
  updateBottomNavOverlap() {
    if (!this.hasContentTarget) return

    const nav = this.hasBottomNavTarget ? this.bottomNavTarget.getBoundingClientRect() : null
    const area = this.contentTarget.parentElement?.getBoundingClientRect()
    // A hidden nav (wide screens) measures 0 tall and covers nothing.
    const overlap = nav && area && nav.height > 0 ? area.bottom - nav.top : 0
    // Set on <html>, as --app-height is: a morph refresh reconciles <body>'s
    // elements with the server's markup and would drop it from #main.
    document.documentElement.style.setProperty("--bottom-nav-overlap", `${Math.max(0, Math.ceil(overlap))}px`)
  }
}
