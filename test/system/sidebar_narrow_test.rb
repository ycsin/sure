require "application_system_test_case"

# At the sidebar's narrowest width a group's name must give way to its total:
# a longer name ("Investments", "Other Liabilities") used to push the amount
# out of line with the other groups' amounts or onto a second line.
class SidebarNarrowTest < ApplicationSystemTestCase
  setup { sign_in users(:family_admin) }

  test "at the narrowest sidebar every group's total stays on one line and lines up" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit root_path
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "240")))
    visit root_path
    assert_left_sidebar_width 240

    totals = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary p.privacy-sensitive"))
        .filter((p) => p.offsetParent)
        .map((p) => { const r = p.getBoundingClientRect(); return { right: Math.round(r.right), lines: Math.round(r.height / parseFloat(getComputedStyle(p).lineHeight)) } })
    JS

    assert_operator totals.size, :>=, 3
    assert_equal [ 1 ], totals.map { |total| total["lines"] }.uniq, "a group total wrapped"
    assert_equal 1, totals.map { |total| total["right"] }.uniq.size, "the group totals don't line up: #{totals.inspect}"

    names = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#sidebar-scroll [data-group-key] summary span.font-medium"))
        .filter((span) => span.offsetParent)
        .map((span) => ({ name: span.textContent.trim(), title: span.title, ellipsis: getComputedStyle(span).textOverflow === "ellipsis", cut: span.scrollWidth > span.clientWidth }))
    JS

    assert_equal totals.size, names.size, "every visible group's name should be checked"
    assert names.all? { |name| name["ellipsis"] && name["title"] == name["name"] }, "group names must truncate with their full name as the title: #{names.inspect}"
    assert names.any? { |name| name["cut"] }, "expected a long group name (e.g. Investments) to be cut at this width: #{names.inspect}"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left")))
  end

  private
    # The stored width is applied once the sidebar-resize controller connects,
    # and the sidebar then animates to it, so wait until it has settled there.
    def assert_left_sidebar_width(expected)
      page.document.synchronize do
        width = page.evaluate_script(%(Math.round(document.querySelector('[data-sidebar-resize-target="leftSidebar"]').getBoundingClientRect().width)))
        raise Capybara::ExpectationNotMet, "the left sidebar is #{width}px wide, not #{expected}px" unless width == expected
      end
    end
end
