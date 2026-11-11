require "application_system_test_case"

# Each frame of a sidebar's width animation lays out everything beside it
# again, and a long activity list took most of a frame to lay out, so the
# animation stuttered on account pages. While a sidebar animates (or is
# dragged) the page is marked, and rows off screen skip layout. The mark comes
# off afterwards: left on, the containment would clip the rows' menus.
class SidebarAnimationRowsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "activity rows skip layout only while a sidebar animates" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    row = "#main [data-controller~='clickable-row']"
    assert_selector row, minimum: 1

    # The toggle saves the preference first; the test layout has no csrf meta tag.
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))
    assert_equal "visible", page.evaluate_script(%(getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility))

    page.execute_script(<<~JS)
      window.__frames = [];
      const sample = () => {
        window.__frames.push([document.documentElement.hasAttribute("data-layout-animating"), getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility]);
        if (window.__frames.length < 90) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    JS
    find("[data-action='app-layout#toggleLeftSidebar']").click
    sleep 1.5

    frames = page.evaluate_script("window.__frames")
    marked = frames.select(&:first)
    assert marked.any?, "the page was never marked while the sidebar animated"
    assert marked.all? { |_, visibility| visibility == "auto" }, "rows did not skip layout while the page was marked: #{marked.uniq.inspect}"
    assert_not page.evaluate_script(%(document.documentElement.hasAttribute("data-layout-animating"))), "the mark was left on after the animation"
    assert_equal "visible", page.evaluate_script(%(getComputedStyle(document.querySelector(#{row.to_json})).contentVisibility)), "rows still skip layout after the animation"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # A drag holds the mark until the pointer is released. A pointer the browser
  # cancels (taking a touch over to scroll), or a second pointerdown during the
  # drag, must not leave it on: rows would keep skipping layout and clip menus.
  test "a cancelled or doubled sidebar drag does not leave the page marked" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    handle = "[data-action~='pointerdown->sidebar-resize#startLeft']"
    assert_selector handle, visible: :all

    marks = page.evaluate_script(<<~JS)
      (() => {
        const handle = document.querySelector(#{handle.to_json});
        const marked = () => document.documentElement.hasAttribute("data-layout-animating");
        const down = () => handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 300 }));
        down();
        const duringDrag = marked();
        down();
        window.dispatchEvent(new PointerEvent("pointercancel", { bubbles: true }));
        const afterCancel = marked();
        down();
        window.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
        return { duringDrag, afterCancel, afterUp: marked() };
      })()
    JS

    assert marks["duringDrag"], "a drag did not mark the page"
    assert_not marks["afterCancel"], "a cancelled drag (after a second pointerdown) left the page marked"
    assert_not marks["afterUp"], "a released drag left the page marked"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  # Toggling the same sidebar again while it moves reverses its transition: the
  # old one is cancelled and a new one runs, which must keep the mark until it
  # ends.
  test "a sidebar toggled again mid-animation keeps the page marked until it stops" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit account_path(accounts(:depository))
    page.execute_script(%(if (!document.querySelector("[name='csrf-token']")) { const m = document.createElement("meta"); m.name = "csrf-token"; m.content = "test"; document.head.append(m) }))

    marks = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const toggle = document.querySelector("[data-action='app-layout#toggleLeftSidebar']");
      const marked = () => document.documentElement.hasAttribute("data-layout-animating");
      toggle.click();
      setTimeout(() => {
        toggle.click();
        setTimeout(() => {
          const duringReversal = marked();
          setTimeout(() => done({ duringReversal, after: marked() }), 1200);
        // Well inside the reversed transition, which runs only as long as the
        // first had already run (about 100ms of its 300ms).
        }, 40);
      }, 100);
    JS

    assert marks["duringReversal"], "the reversed animation ran without the mark"
    assert_not marks["after"], "the mark was left on after the reversed animation"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end
end
