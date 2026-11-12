require "application_system_test_case"

# On a touchscreen a chart has no hover and no mouse drag: a finger sliding
# along it moves the tooltip (scrubbing), and a long press followed by a slide
# selects a date range. Vertical swipes must still scroll the page. The
# gestures are real touch input (Chrome DevTools Input.dispatchTouchEvent), so
# the browser applies touch-action and fires pointer and emulated mouse events
# as it does on a phone.
class ChartTouchTest < ApplicationSystemTestCase
  CHART = "#netWorthChart".freeze

  setup do
    sign_in users(:family_admin)
    assert_selector "#{CHART} .drag-select-brush .overlay", visible: :all
    # Touch input lands on whatever is at the point, so the chart must be on screen.
    page.execute_script(%(document.querySelector("#{CHART}").scrollIntoView({ block: "center" })))
  end

  test "a finger sliding along the chart moves the tooltip with it, and it stays until a touch elsewhere" do
    from = chart_point(0.2)
    nudged = [ from[0] + 30, from[1] ]
    to = chart_point(0.8)

    # Moving off the first point straight away: a finger resting longer
    # than the long press starts a selection instead (the next test).
    touch("touchStart", from)
    touch("touchMove", nudged)
    first_date = tooltip_date
    assert tooltip_visible?, "a touch shows the tooltip"

    slide(nudged, to)
    # The browser may deliver the last move with the next frame.
    page.document.synchronize(5) do
      off_by = (to[0] - chart_box["left"] - guideline_x).abs
      raise Capybara::ExpectationNotMet, "the guideline is #{off_by.round}px from the finger" if off_by > point_spacing
    end
    assert_not_equal first_date, tooltip_date, "the tooltip did not follow the finger"

    touch("touchEnd")
    assert tooltip_visible?, "lifting the finger keeps the tooltip on the last point"
    assert_equal "/", URI.parse(page.current_url).path

    header = page.evaluate_script(%(document.querySelector("#{CHART}").getBoundingClientRect().top)) - 40
    touch("touchStart", [ 20, header ])
    touch("touchEnd")
    assert_not tooltip_visible?, "a touch elsewhere hides the tooltip"
  end

  test "a long press then a slide selects a date range" do
    from = chart_point(0.3)
    to = chart_point(0.7)

    touch("touchStart", from)
    sleep 0.7
    assert_selector "#{CHART} .touch-selection", visible: :all
    slide(from, to)
    selection_width = page.evaluate_script(%(Number(document.querySelector("#{CHART} .touch-selection").getAttribute("width"))))
    assert_in_delta to[0] - from[0], selection_width, 2
    touch("touchEnd")

    assert_current_path(%r{/\?.*start_date=.*end_date=})
    params = Rack::Utils.parse_query(URI.parse(page.current_url).query)
    assert_operator Date.parse(params["start_date"]), :<, Date.parse(params["end_date"])
  end

  test "a long press lifted without sliding selects nothing and keeps the tooltip" do
    point = chart_point(0.4)

    touch("touchStart", point)
    sleep 0.7
    touch("touchEnd")

    assert tooltip_visible?, "the tooltip went away"
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    assert_nil URI.parse(page.current_url).query
  end

  # Dashboard cards are reordered by holding them (800 ms); a hold on the
  # chart selects a range and must not lift its card.
  test "holding a finger on the chart does not pick up its dashboard card" do
    point = chart_point(0.4)

    touch("touchStart", point)
    sleep 1.2
    assert_selector "#{CHART} .touch-selection", visible: :all
    grabbed = page.evaluate_script(%(document.querySelector("#{CHART}").closest("[data-sortable-list-target='item']").getAttribute("aria-grabbed")))
    touch("touchEnd")

    assert_equal "false", grabbed, "the hold picked up the dashboard card"
  end

  # During a selection a one-finger drift up or down must not scroll the page,
  # but a second finger makes it a pinch, which zooms as anywhere else.
  test "a selection keeps one finger from scrolling but leaves a pinch to the browser" do
    page.execute_script(<<~JS)
      window.__moves = []
      document.addEventListener("touchmove", (event) => window.__moves.push([event.touches.length, event.defaultPrevented]))
    JS
    point = chart_point(0.4)

    touch("touchStart", point)
    sleep 0.7
    touch("touchMove", [ point[0] + 15, point[1] + 5 ])
    # A second finger lands (touchStart with both), then both move.
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart",
      touchPoints: [ { x: point[0] + 15, y: point[1] + 5 }, { x: point[0] + 60, y: point[1] + 30 } ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove",
      touchPoints: [ { x: point[0] + 10, y: point[1] }, { x: point[0] + 80, y: point[1] + 50 } ])
    touch("touchEnd")

    moves = page.evaluate_script("window.__moves")
    assert_includes moves, [ 1, true ], "a one-finger move during a selection was not kept from scrolling: #{moves.inspect}"
    assert_includes moves, [ 2, false ], "a two-finger move during a selection was cancelled: #{moves.inspect}"
  end

  test "a slide without the long press only moves the tooltip and selects nothing" do
    from = chart_point(0.3)
    middle = chart_point(0.5)
    to = chart_point(0.7)

    # Resting past the long press in the middle of a slide: a finger that
    # already moved is scrubbing, so going on must not select.
    touch("touchStart", from)
    slide(from, middle)
    sleep 0.7
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    slide(middle, to)
    touch("touchEnd")

    assert_no_selector "#{CHART} .touch-selection", visible: :all
    assert_equal "/", URI.parse(page.current_url).path
    assert_nil URI.parse(page.current_url).query
  end

  test "a vertical swipe on the chart scrolls the page and hides the tooltip" do
    page.driver.browser.manage.window.resize_to(1400, 700)
    page.execute_script(%(document.querySelector("#{CHART}").scrollIntoView({ block: "center" })))
    before = scroll_offsets
    start = chart_point(0.5)

    touch("touchStart", start)
    slide(start, [ start[0], start[1] - 250 ], steps: 12)
    touch("touchEnd")

    assert_equal "pan-y pinch-zoom", page.evaluate_script(%(getComputedStyle(document.querySelector("#{CHART} svg")).touchAction)),
      "the chart takes horizontal slides and leaves vertical scrolling and pinch zoom to the browser"
    assert_not_equal before, scroll_offsets, "the page did not scroll"
    assert_not tooltip_visible?, "the tooltip stayed after the page scrolled"
    assert_no_selector "#{CHART} .touch-selection", visible: :all
    assert_equal "/", URI.parse(page.current_url).path
  end

  # Emulated mouse events are ignored for a moment after a touch, timed with
  # performance.now(), which counts from the page load. Held at 500 ms, the
  # page stays in its first second: with no touch yet, the mouse must work.
  test "the mouse works before any touch, even in the page's first second" do
    clock = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: "performance.now = () => 500")
    visit root_path
    assert_selector "#{CHART} .drag-select-brush .overlay", visible: :all
    page.execute_script(%(document.querySelector("#{CHART}").scrollIntoView({ block: "center" })))

    find("#{CHART} .drag-select-brush .overlay", visible: :all).hover

    assert tooltip_visible?, "hovering showed no tooltip"
  ensure
    # Registered for every later page in this browser, not only this visit.
    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: clock["identifier"]) if clock
  end

  private
    def touch(type, point = nil)
      points = point ? [ { x: point[0], y: point[1] } ] : []
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: type, touchPoints: points)
    end

    def slide(from, to, steps: 10)
      (1..steps).each do |step|
        x = from[0] + (to[0] - from[0]) * step / steps.to_f
        y = from[1] + (to[1] - from[1]) * step / steps.to_f
        touch("touchMove", [ x, y ])
      end
    end

    def chart_box
      page.evaluate_script(<<~JS)
        (() => {
          const r = document.querySelector("#{CHART} .drag-select-brush .overlay").getBoundingClientRect()
          return { left: r.left, top: r.top, width: r.width, height: r.height }
        })()
      JS
    end

    # A point at a fraction of the chart's width, halfway down, in viewport pixels.
    def chart_point(fraction)
      box = chart_box
      [ box["left"] + box["width"] * fraction, box["top"] + box["height"] / 2 ]
    end

    def point_spacing
      count = page.evaluate_script(%(JSON.parse(document.querySelector("#{CHART}").dataset.timeSeriesChartDataValue).values.length))
      chart_box["width"] / [ count - 1, 1 ].max
    end

    def guideline_x
      page.evaluate_script(%(Number(document.querySelector("#{CHART} .guideline").getAttribute("x1"))))
    end

    def tooltip_date
      page.evaluate_script(%(document.querySelector("#{CHART} > .chart-tooltip .text-secondary")?.textContent.trim()))
    end

    def tooltip_visible?
      # Shown and hidden through its inline opacity (the class starts it hidden).
      page.evaluate_script(%(document.querySelector("#{CHART} > .chart-tooltip").style.opacity)) == "1"
    end

    # Every scrollable box's offset, since the page scrolls inside the layout.
    def scroll_offsets
      page.evaluate_script(<<~JS)
        [document.scrollingElement.scrollTop, ...Array.from(document.querySelectorAll("*")).filter((el) => el.scrollHeight > el.clientHeight && /auto|scroll/.test(getComputedStyle(el).overflowY)).map((el) => el.scrollTop)]
      JS
    end
end
