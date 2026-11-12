require "application_system_test_case"

# The spending chart's axis labels sit in a column on the right. It was a
# fixed 48px: a currency shown by its code ("SGD 10.0K") was cut off at the
# card's edge, and even "$100.0" ended a pixel from it. The column now fits
# the widest label with 4px to spare.
class SpendingChartAxisTest < ApplicationSystemTestCase
  include EntriesTestHelper

  CHART = "#main [data-controller~='spending-chart']".freeze

  setup do
    @user = users(:family_admin)
  end

  test "axis labels of a currency shown by its code fit inside the chart" do
    family = @user.family
    family.update!(currency: "SGD")
    account = family.accounts.create!(name: "SGD Checking", balance: 0, currency: "SGD", accountable: Depository.new)
    travel_to Date.current.beginning_of_month + 14.days
    create_transaction(account: account, currency: "SGD", amount: 12_000, date: Date.current.beginning_of_month - 1.month + 3.days)
    create_transaction(account: account, currency: "SGD", amount: 9_000, date: Date.current.beginning_of_month + 2.days)

    labels = visit_dashboard_and_measure_axis
    # Wider than the old column had room for (48px less the 8px padding),
    # whatever the browser's locale makes of the currency.
    assert_operator labels["widest"], :>, 40, "expected labels too wide for the old column: #{labels.inspect}"
    assert_operator labels["overflow"], :<=, -3.5, "an axis label runs into or past the chart's edge: #{labels.inspect}"
  end

  test "short axis labels keep their distance from the chart's edge" do
    labels = visit_dashboard_and_measure_axis
    assert_operator labels["texts"].size, :>=, 2, "expected axis labels: #{labels.inspect}"
    assert_operator labels["overflow"], :<=, -3.5, "an axis label runs into or past the chart's edge: #{labels.inspect}"
    assert_operator labels["column"], :>=, 48, "the axis column narrowed: #{labels.inspect}"
  end

  private
    def visit_dashboard_and_measure_axis
      sign_in @user
      page.driver.browser.manage.window.resize_to(1100, 900)
      visit root_path
      assert_selector "#{CHART} svg circle"
      page.evaluate_script(<<~JS)
        (() => {
          const svg = document.querySelector("#{CHART} svg circle").ownerSVGElement;
          const box = svg.getBoundingClientRect();
          // The y axis labels (axisRight places them at x = its padding).
          const ticks = Array.from(svg.querySelectorAll("g.tick text")).filter((t) => t.getAttribute("x") > 0);
          const dashed = svg.querySelector("line[stroke-dasharray]").getBoundingClientRect();
          return {
            texts: ticks.map((t) => t.textContent),
            widest: Math.max(...ticks.map((t) => t.getBoundingClientRect().width)),
            overflow: Math.max(...ticks.map((t) => t.getBoundingClientRect().right - box.right)),
            column: Math.round(box.right - dashed.right),
          };
        })()
      JS
    end
end
