require "application_system_test_case"

# Opening or closing a sidebar animates its width, which resizes the charts
# beside it on every frame. Charts that redrew on each of those frames made the
# animation stutter; they now stretch their drawing during the animation and
# draw once, at the size the animation ends on (utils/settled_resize).
class ChartSidebarResizeTest < ApplicationSystemTestCase
  NET_WORTH = "#main [data-controller~='time-series-chart']".freeze

  setup do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(1100, 900)
    visit root_path
    assert_selector "#{NET_WORTH} svg"
    wait_until_settled
  end

  teardown do
    page.execute_script("localStorage.clear()") rescue nil
  end

  test "a sidebar animation redraws each dashboard chart at most once, at its final size" do
    assert_selector "#main [data-controller~='sankey-chart'] svg"
    page.execute_script(<<~JS)
      // The charts that redraw through SettledResize (the donut sizes itself).
      window.__charts = Array.from(document.querySelectorAll("#main [data-controller]"))
        .filter((el) => el.dataset.controller.split(" ").some((name) => ["time-series-chart", "sankey-chart", "bar-chart", "spending-chart"].includes(name)));
      window.__draws = window.__charts.map(() => 0);
      window.__widths = window.__charts.map((chart) => chart.querySelector("svg")?.parentElement.clientWidth);
      new MutationObserver((mutations) => mutations.forEach((m) => m.addedNodes.forEach((node) => {
        if (node.nodeName !== "svg") return;
        const i = window.__charts.findIndex((chart) => chart.contains(node));
        if (i >= 0) window.__draws[i]++;
      }))).observe(document.getElementById("main"), { childList: true, subtree: true });
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)

    charts = nil
    page.document.synchronize(10) do
      charts = page.evaluate_script(<<~JS)
        window.__charts.map((chart, i) => {
          const svg = chart.querySelector("svg");
          const width = svg?.parentElement.clientWidth;
          return { name: `${i}:${chart.dataset.controller}`, draws: window.__draws[i], resized: width !== window.__widths[i],
                   // Drawn at its container's width, in its drawing coordinates too,
                   // and not stretched (a stretched drawing carries preserveAspectRatio).
                   fits: !!svg && Number(svg.getAttribute("width")) === width &&
                     (!svg.hasAttribute("viewBox") || Number(svg.getAttribute("viewBox").split(/[ ,]+/)[2]) === width) &&
                     !svg.hasAttribute("preserveAspectRatio") };
        })
      JS
      # Only charts whose width changed.
      raise Capybara::ExpectationNotMet, "a resized chart is still stretched: #{charts.inspect}" unless charts.all? { |chart| !chart["resized"] || chart["fits"] }
    end
    assert_operator charts.size, :>=, 4, "expected the dashboard's time-series, Sankey, bar and spending charts: #{charts.inspect}"
    draws = charts.to_h { |chart| [ chart["name"], chart["draws"] ] }
    puts "chart sidebar resize draws: #{draws.inspect}"
    charts.select { |chart| chart["resized"] }.each do |chart|
      assert_operator chart["draws"], :>=, 1, "#{chart["name"]} changed width but was never redrawn"
    end
    # One draw as the animation ends; a loaded machine can stall long enough
    # mid-animation to settle once early, so allow a second. Redrawing on every
    # frame was 6-7 draws per chart.
    draws.each do |chart, count|
      assert_operator count, :<=, 2, "#{chart} was drawn #{count} times during one sidebar animation"
    end
  end

  test "the chart's dates keep their shape and their place at the edges while a sidebar animates" do
    assert_selector "#{NET_WORTH} svg .tick text", count: 2
    page.execute_script(<<~JS)
      window.__labels = []; window.__sampling = true;
      // Measured after each frame is painted (resize observers run before the
      // paint, after requestAnimationFrame callbacks), so it sees what was shown.
      const afterPaint = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
      const sample = () => {
        const element = document.querySelector("#{NET_WORTH}");
        const container = element.getBoundingClientRect();
        const svg = element.querySelector("svg");
        const [first, last] = Array.from(element.querySelectorAll("svg .tick text")).map((t) => t.getBoundingClientRect());
        // On a slow machine this can run after the next animation step has
        // begun, measuring a layout the chart has not followed yet and that was
        // never painted: only count frames where the drawing fills its container.
        const painted = svg && Math.round(Number(svg.getAttribute("width"))) === Math.round(container.width);
        if (first && last && painted) window.__labels.push([Math.round(container.width), first.left - container.left, container.right - last.right, first.width, last.width]);
        if (window.__sampling) afterPaint(sample);
      };
      // The settled baseline, before the toggle; then after each paint.
      sample();
    JS
    before = net_worth_width
    toggle_left_sidebar
    wait_until_settled(changed_from: before)
    page.execute_script("window.__sampling = false")

    samples = page.evaluate_script("window.__labels")
    widths = samples.map(&:first)
    assert_equal before, widths.first, "sampling began after the animation had started"
    assert_equal net_worth_width, widths.last, "sampling ended before the animation finished"
    assert widths.any? { |width| width != widths.first && width != widths.last }, "no sample fell inside the animation: #{widths.uniq.inspect}"

    spread = samples.transpose.drop(1).map { |values| (values.max - values.min).round(1) }
    puts "date labels (left gap, right gap, widths) spread: #{spread.inspect}"
    assert spread.all? { |value| value <= 2 }, "the dates moved or changed shape during the animation: #{spread.inspect}"
  end

  # A quick drag back and forth can bring a chart back to the size it was drawn
  # at before it settles; its drawing must not stay stretched to the last size.
  test "a chart resized and back before it settles fits its container again" do
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const element = document.querySelector("#{NET_WORTH}");
      const original = element.clientWidth;
      element.style.width = Math.round(original * 0.6) + "px";
      requestAnimationFrame(() => requestAnimationFrame(() => {
        element.style.width = "";
        requestAnimationFrame(() => requestAnimationFrame(() => {
          done({ container: element.clientWidth, svg: Number(element.querySelector("svg").getAttribute("width")), original });
        }));
      }));
    JS

    assert_equal result["original"], result["container"]
    assert_equal result["container"], result["svg"], "the chart's drawing stayed stretched to the intermediate size: #{result.inspect}"
  end

  private
    def toggle_left_sidebar
      # The toggle saves the preference first; the test layout has no csrf meta tag.
      page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))
      find("[data-action='app-layout#toggleLeftSidebar']").click
    end

    def net_worth_width
      page.evaluate_script(%(document.querySelector(#{NET_WORTH.to_json}).clientWidth))
    end

    # Waits (bounded) until the net worth chart is drawn at its container's
    # size, unstretched, and that size has held for two checks in a row (and,
    # with changed_from, differs from that width).
    def wait_until_settled(changed_from: nil)
      last = nil
      page.document.synchronize(10) do
        state = page.evaluate_script(<<~JS)
          (() => {
            const element = document.querySelector(#{NET_WORTH.to_json});
            const svg = element.querySelector("svg");
            const viewBox = svg && Number(svg.getAttribute("viewBox").split(/[ ,]+/)[2]);
            return { width: element.clientWidth, drawn: !!svg && Number(svg.getAttribute("width")) === element.clientWidth && viewBox === element.clientWidth && !svg.hasAttribute("preserveAspectRatio") };
          })()
        JS
        stable = last && last["width"] == state["width"]
        last = state
        settled = state["drawn"] && stable && (changed_from.nil? || state["width"] != changed_from)
        raise Capybara::ExpectationNotMet, "the chart has not settled: #{state.inspect}" unless settled
      end
    end
end
