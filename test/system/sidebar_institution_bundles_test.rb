require "application_system_test_case"

# An institution entry is a <details> inside its group's wrapper, which carries
# the group's data-group-key. The script that restores the sidebar's open
# groups after a Turbo visit must keep the two apart: a closed entry must not
# close its group, and an open one must stay open.
class SidebarInstitutionBundlesTest < ApplicationSystemTestCase
  include EntriesTestHelper

  GROUP = "#asset_depository details:not([data-institution-bundle])".freeze
  BUNDLE = "#asset_depository details[data-institution-bundle='wise']".freeze

  setup do
    @user = users(:family_admin)
    family = @user.family
    %w[EUR GBP].each do |currency|
      family.accounts.create!(name: "Wise #{currency}", balance: 10, currency: family.currency, institution_name: "Wise", accountable: Depository.new)
    end
    @brokerage = family.accounts.create!(name: "Bundle test brokerage", balance: 5, currency: family.currency, accountable: Investment.new)
    sign_in @user
  end

  test "a group and the institution entry inside it keep their own open state across a visit" do
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }
    assert_selector "#{GROUP}[open]"
    assert_no_selector "#{BUNDLE}[open]"

    within("#asset_investment") do
      find("summary", match: :first).click
      click_link "Bundle test brokerage"
    end
    assert_selector "#asset_investment a[data-active-account][href='#{account_path(@brokerage)}']"
    assert_equal [ true, false ], open_states, "the closed entry closed its group"

    find("#{BUNDLE} > summary [data-institution-bundle-toggle]").click
    first(:link, "Home").click
    assert_no_selector "#sidebar-scroll [data-active-account]", visible: :all
    assert_equal [ true, true ], open_states, "the open entry was closed"
  end

  test "an institution's name leads to its page, and its chevron opens it in place" do
    create_transaction(account: Account.find_by!(name: "Wise EUR"), name: "Wise coffee", currency: @user.family.currency)
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }

    find("#{BUNDLE} > summary [data-institution-bundle-toggle]").click
    assert_selector "#{BUNDLE}[open]"
    assert_current_path root_path

    find("#{BUNDLE} > summary a").click
    assert_selector "main h2", text: "Wise"
    assert_current_path(%r{\A/institution_groups/depository-})
    within("#institution-group-activity") { assert_text "Wise coffee" }
    assert_selector "#{BUNDLE} > summary a[data-active-account]"
  end

  test "settings saved on an institution's page rename it and change its currency in the sidebar" do
    family = @user.family
    ExchangeRate.create!(from_currency: family.currency, to_currency: "CHF", date: Date.current, rate: 2)
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }
    find("#{BUNDLE} > summary a").click
    assert_selector "main h2", text: "Wise"

    click_on I18n.t("institution_groups.header.settings")
    within("dialog") do
      fill_in I18n.t("institution_groups.form.name"), with: "Wise Business"
      select "Swiss Franc (CHF)", from: I18n.t("institution_groups.form.currency")
      click_on I18n.t("institution_groups.form.save")
    end

    assert_selector "main h2", text: "Wise Business"
    within("#{BUNDLE} > summary") do
      assert_text "Wise Business"
      assert_text Money.new(40, "CHF").format
    end
  end

  test "an institution entry's total lines up with the account rows' balances" do
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }
    find("#{BUNDLE} > summary [data-institution-bundle-toggle]").click

    edges = page.evaluate_script(<<~JS)
      (() => {
        const group = document.querySelector("#asset_depository")
        const right = (el) => Math.round(el.getBoundingClientRect().right)
        const total = group.querySelector("details[data-institution-bundle='wise'] > summary .privacy-sensitive")
        const row = Array.from(group.querySelectorAll("a[href^='/accounts/'] .privacy-sensitive")).find((el) => !el.closest("[data-institution-bundle]"))
        return [right(total), right(row)]
      })()
    JS

    assert_equal edges.second, edges.first, "the entry's total is not aligned with the rows' balances"
  end

  test "clicking an institution entry's row opens it in place" do
    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }

    find("#{BUNDLE} > summary .privacy-sensitive").click

    assert_selector "#{BUNDLE}[open]"
    assert_current_path root_path
  end

  test "an institution entry draws its accounts' combined sparkline" do
    @user.family.accounts.where(institution_name: "Wise").each do |account|
      [ 20, 0 ].each { |days| account.balances.create!(date: days.days.ago.to_date, balance: 10 + days, start_cash_balance: 10 + days, currency: account.currency) }
    end

    visit root_path
    within("#asset_depository") { find("summary", match: :first).click }

    assert_selector "#{BUNDLE} > summary turbo-frame[complete] [data-controller='time-series-chart'] svg path", wait: 10
  end

  private
    def open_states
      evaluate_script(%([#{GROUP.to_json}, #{BUNDLE.to_json}].map(function (selector) { return document.querySelector(selector).open; })))
    end
end
