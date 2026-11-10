require "application_system_test_case"

# The head script applies the stored sidebar widths before the first paint,
# and sidebar_resize_controller applies them again once it connects; wherever
# the two disagree, the sidebars visibly jump after the page appears.
class SidebarWidthsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "without the assistant the left sidebar keeps the room of the right one the layout leaves out" do
    users(:family_admin).family.update!(assistant_type: "mcp_only")
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit root_path
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "480"); localStorage.setItem("sure.sidebarWidth.right", "560")))

    visit root_path

    assert_nil page.evaluate_script(%(document.querySelector("[data-app-layout-target='rightSidebar']"))), "the layout leaves the right sidebar out"
    assert_equal kept_widths.first, before_paint_widths.first
    assert_equal "480px", before_paint_widths.first, "the stored width fits once no room is kept for the right sidebar"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"); localStorage.removeItem("sure.sidebarWidth.right")))
  end

  test "the widths applied before the first paint are the ones the resize controller keeps" do
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit root_path
    # Wider together than the viewport allows with both sidebars open.
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "480"); localStorage.setItem("sure.sidebarWidth.right", "560")))

    visit root_path

    assert page.evaluate_script(%(["leftSidebar", "rightSidebar"].every((target) => document.querySelector("[data-app-layout-target='" + target + "']").offsetWidth > 0))), "both sidebars open"
    before_paint = before_paint_widths
    kept = kept_widths

    assert_equal kept, before_paint
    assert_operator before_paint.sum(&:to_i), :<, 560 + 480, "the pair was not clamped together"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"); localStorage.removeItem("sure.sidebarWidth.right")))
  end

  test "a visit after a resize keeps the sidebar at its new width instead of sliding back to it" do
    page.driver.browser.manage.window.resize_to(1500, 1000)
    visit root_path
    find("[data-action*='sidebar-resize#keyLeft']").send_keys(:arrow_left, :arrow_left, :arrow_left)
    resized = page.evaluate_script(%(Math.round(document.querySelector("[data-app-layout-target='leftSidebar']").getBoundingClientRect().width)))
    assert_equal 320 - 3 * 16, resized
    assert_equal "#{resized}px", page.evaluate_script(%(getComputedStyle(document.documentElement).getPropertyValue("--left-sidebar-width").trim())),
      "a page swapped in by a visit reads the width from <html> until the resize controller connects"
    assert_equal "width", page.evaluate_script(%(getComputedStyle(document.querySelector("[data-app-layout-target='leftSidebar']")).transitionProperty)),
      "only opening and closing animate; a width set by a resize or a visit applies at once"
    find("#sidebar-scroll details", match: :first).find("summary").click

    page.execute_script(<<~JS)
      window.sidebarWidths = []
      const start = performance.now()
      const sample = () => {
        window.sidebarWidths.push(Math.round(document.querySelector("[data-app-layout-target='leftSidebar']").getBoundingClientRect().width))
        if (performance.now() - start < 800) requestAnimationFrame(sample)
      }
      requestAnimationFrame(sample)
    JS
    find("#sidebar-scroll details[open] a[href^='/accounts/']", match: :first).click
    assert_selector "#sidebar-scroll a[data-active-account]"
    sleep 1

    assert_equal [ resized ], page.evaluate_script("window.sidebarWidths").uniq, "the sidebar changed width across the visit"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"); localStorage.removeItem("sure.sidebarWidth.right")))
  end

  private
    def before_paint_widths
      page.evaluate_script(%(["left", "right"].map((side) => getComputedStyle(document.documentElement).getPropertyValue("--" + side + "-sidebar-width").trim())))
    end

    # What sidebar_resize_controller applied once it connected; it writes both
    # widths on connect, so wait for them rather than reading too early.
    def kept_widths
      assert_selector "[data-controller~='sidebar-resize'][style*='--left-sidebar-width'][style*='--right-sidebar-width']", visible: :all
      page.evaluate_script(%(["left", "right"].map((side) => document.querySelector("[data-controller~='sidebar-resize']").style.getPropertyValue("--" + side + "-sidebar-width"))))
    end
end
