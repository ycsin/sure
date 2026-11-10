require "test_helper"

class InstitutionGroupsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @eur = create_account("Wise EUR", @family)
    @gbp = create_account("Wise GBP", @family)
  end

  test "show lists the accounts and merges their activity, newest first" do
    create_transaction(account: @eur, name: "Older EUR coffee", date: 3.days.ago.to_date, currency: @family.currency)
    create_transaction(account: @gbp, name: "Newer GBP lunch", date: 1.day.ago.to_date, currency: @family.currency)
    create_transaction(account: accounts(:depository), name: "Not at Wise", date: Date.current)

    get institution_group_url(bundle_slug)

    assert_response :success
    assert_select "h2", text: "Wise"
    assert_select "#institution-group-accounts a[href='#{account_path(@eur)}']"
    assert_select "#institution-group-accounts a[href='#{account_path(@gbp)}']"
    assert_select "#institution-group-chart[data-time-series-chart-selectable-value='true']"
    names = css_select("#institution-group-activity a").map { |link| link.text.strip }
    assert_operator names.index("Newer GBP lunch"), :<, names.index("Older EUR coffee")
    assert_not_includes names, "Not at Wise"
  end

  test "the sparkline is the accounts' combined balance over the last 30 days" do
    [ @eur, @gbp ].each_with_index do |account, index|
      [ 30, 0 ].each { |days| account.balances.create!(date: days.days.ago.to_date, balance: 10 * (index + 1) + days, start_cash_balance: 10 * (index + 1) + days, currency: @family.currency) }
    end

    get sparkline_institution_group_url(bundle_slug)

    assert_response :success
    assert_select "turbo-frame##{bundle_slug}_sparkline"
    series = JSON.parse(css_select("[data-controller='time-series-chart']").first["data-time-series-chart-data-value"])
    assert_equal [ 90, 30 ], [ series["values"].first, series["values"].last ].map { |point| point.dig("value", "amount").to_d.to_i }
  end

  test "a sparkline URL carrying the current version may be reused by the browser" do
    bundle = @family.balance_sheet.institution_bundle(bundle_slug)

    get sparkline_institution_group_url(bundle_slug, v: bundle.sparkline_version)
    assert_includes response.headers["Cache-Control"], "max-age=86400"

    get sparkline_institution_group_url(bundle_slug, v: "stale")
    assert_not_includes response.headers["Cache-Control"].to_s, "max-age=86400"
  end

  test "an unknown bundle has no sparkline" do
    get sparkline_institution_group_url("depository-000000000000")

    assert_response :not_found
  end

  test "a range picked on the chart narrows the activity, and a preset period does not" do
    create_transaction(account: @eur, name: "Inside the range", date: 5.days.ago.to_date, currency: @family.currency)
    create_transaction(account: @gbp, name: "Before the range", date: 20.days.ago.to_date, currency: @family.currency)

    get institution_group_url(bundle_slug, start_date: 10.days.ago.to_date, end_date: Date.current)

    assert_select "#institution-group-activity-filters a[href='#{institution_group_path(bundle_slug)}']"
    assert_select "#institution-group-activity", text: /Inside the range/
    assert_select "#institution-group-activity", text: /Before the range/, count: 0

    get institution_group_url(bundle_slug, period: "last_30_days")

    assert_select "#institution-group-activity-filters", count: 0
    assert_select "#institution-group-activity", text: /Before the range/
  end

  test "show is not found for an unknown slug or another family's institution" do
    get institution_group_url("depository-000000000000")
    assert_response :not_found

    # Another family bundles its Wise accounts under the same slug; this
    # family no longer has two.
    2.times { |index| create_account("Other Wise #{index}", families(:empty)) }
    @eur.update!(institution_name: "Revolut")
    get institution_group_url(bundle_slug)
    assert_response :not_found
  end

  test "a member sees the institution's accounts shared with them only" do
    third = create_account("Wise USD", @family)
    create_transaction(account: third, name: "Unshared spend", currency: @family.currency)
    create_transaction(account: @eur, name: "Shared spend", currency: @family.currency)
    [ @eur, @gbp ].each { |account| account.account_shares.create!(user: users(:family_member), permission: "read_only") }
    sign_in users(:family_member)

    get institution_group_url(bundle_slug)

    assert_response :success
    assert_select "#institution-group-accounts a[href='#{account_path(third)}']", count: 0
    assert_select "#institution-group-activity", text: /Shared spend/
    assert_select "#institution-group-activity", text: /Unshared spend/, count: 0

    AccountShare.where(account: @gbp, user: users(:family_member)).destroy_all
    get institution_group_url(bundle_slug)
    assert_response :not_found
  end

  test "edit offers the URL's icon and each member account's" do
    get edit_institution_group_url(bundle_slug)

    assert_response :success
    assert_select "select[name='institution_group[logo_account_id]'] option", count: 3
    assert_select "select[name='institution_group[logo_account_id]'] option[value='#{@gbp.id}']", text: "Wise GBP"
  end

  test "update saves the institution's settings, blank fields keeping the defaults" do
    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Wise Business", institution_domain: "https://wise.com/", currency: "EUR", logo_account_id: @gbp.id } }

    assert_redirected_to institution_group_url(bundle_slug)
    settings = @family.institution_groups.find_by!(key: "wise")
    assert_equal [ "Wise Business", "wise.com", "EUR", @gbp.id ], [ settings.name, settings.institution_domain, settings.currency, settings.logo_account_id ]

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "", institution_domain: "", currency: "", logo_account_id: "" } }

    assert_equal 1, @family.institution_groups.count
    assert_equal [ nil, nil, nil, nil ], settings.reload.slice(:name, :institution_domain, :currency, :logo_account_id).values
  end

  test "update refuses an unsupported currency or an icon from outside the institution" do
    patch institution_group_url(bundle_slug), params: { institution_group: { currency: "XYZ" } }
    assert_response :unprocessable_entity

    patch institution_group_url(bundle_slug), params: { institution_group: { logo_account_id: accounts(:depository).id } }
    assert_response :unprocessable_entity
    assert_empty @family.institution_groups
  end

  test "settings are not editable by a guest or for another family's institution" do
    guest = users(:family_member)
    guest.update!(role: "guest")
    [ @eur, @gbp ].each { |account| account.account_shares.create!(user: guest, permission: "read_only") }
    sign_in guest
    get institution_group_url(bundle_slug)
    assert_response :success
    assert_select "a[href='#{edit_institution_group_path(bundle_slug)}']", count: 0

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Taken over" } }
    assert_redirected_to accounts_url
    assert_empty @family.institution_groups

    sign_in @user
    2.times { |index| create_account("Other Wise #{index}", families(:empty)) }
    @eur.update!(institution_name: "Revolut")

    patch institution_group_url(bundle_slug), params: { institution_group: { name: "Taken over" } }

    assert_response :not_found
    assert_not InstitutionGroup.exists?(name: "Taken over")
  end

  private
    def create_account(name, family)
      family.accounts.create!(name: name, balance: 10, currency: family.currency, institution_name: "Wise", accountable: Depository.new)
    end

    def bundle_slug
      "depository-#{Digest::MD5.hexdigest("wise")[0, 12]}"
    end
end
