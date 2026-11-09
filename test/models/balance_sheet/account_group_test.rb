require "test_helper"

class BalanceSheet::AccountGroupTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  def create_account(name, balance:, currency: @family.currency, institution: nil, domain: nil, accountable: Depository.new)
    @family.accounts.create!(name: name, balance: balance, currency: currency, institution_name: institution, institution_domain: domain, accountable: accountable)
  end

  def cash_group
    BalanceSheet.new(@family).assets.account_groups.find { |group| group.key == "depository" }
  end

  test "accounts sharing an institution become one entry with their combined total in the family's currency" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 2)
    create_account("Wise EUR", balance: 100, currency: "EUR", institution: "Wise", domain: "wise.com")
    create_account("Wise main", balance: 50, institution: "Wise", domain: "wise.com")
    create_account("Savings", balance: 10)

    entries = cash_group.sidebar_entries
    bundle = entries.find { |entry| entry.is_a?(BalanceSheet::AccountGroup::InstitutionBundle) }

    assert_equal 2, entries.size
    assert_equal [ "Wise", %w[Wise\ EUR Wise\ main] ], [ bundle.name, bundle.accounts.map(&:name).sort ]
    assert_equal Money.new(250, @family.currency), bundle.total_money
  end

  test "accounts at one institution sharing a currency show their total in that currency" do
    ExchangeRate.create!(from_currency: "SGD", to_currency: @family.currency, date: Date.current, rate: 3)
    create_account("DBS savings", balance: 100, currency: "SGD", institution: "DBS")
    create_account("DBS salary", balance: 20, currency: "SGD", institution: "DBS")

    bundle = cash_group.sidebar_entries.grep(BalanceSheet::AccountGroup::InstitutionBundle).sole

    assert_equal Money.new(120, "SGD"), bundle.total_money
  end

  test "with a name order a bundle sorts by its institution's name, its accounts keeping theirs" do
    create_account("Apple", balance: 1)
    create_account("Zeta EUR", balance: 1, institution: "Monzo")
    create_account("Alpha GBP", balance: 1, institution: "Monzo")
    create_account("Pear", balance: 1)

    entries = cash_group.sidebar_entries(order: AccountOrder.new("name_asc"))

    assert_equal %w[Apple Monzo Pear], entries.map(&:name)
    assert_equal [ "Alpha GBP", "Zeta EUR" ], entries[1].accounts.map(&:name)
    assert_equal %w[Pear Monzo Apple], cash_group.sidebar_entries(order: AccountOrder.new("name_desc")).map(&:name)
  end

  test "with a balance order a bundle sorts by its total in the family's currency" do
    create_account("Big", balance: 50)
    create_account("Wise A", balance: 30, institution: "Wise")
    create_account("Wise B", balance: 40, institution: "Wise")
    create_account("Small", balance: 10)

    assert_equal %w[Wise Big Small], cash_group.sidebar_entries(order: AccountOrder.new("balance_desc")).map(&:name)
    assert_equal %w[Small Big Wise], cash_group.sidebar_entries(order: AccountOrder.new("balance_asc")).map(&:name)
  end

  test "an institution with a single account stays a plain row" do
    create_account("Schwab", balance: 10, institution: "Schwab")
    create_account("Savings", balance: 10)

    assert cash_group.sidebar_entries.none? { |entry| entry.is_a?(BalanceSheet::AccountGroup::InstitutionBundle) }
  end

  test "institutions match ignoring case and spacing, and by domain when there is no name" do
    create_account("A", balance: 1, institution: " wise ")
    create_account("B", balance: 1, institution: "WISE")
    create_account("C", balance: 1, domain: "dbs.com.sg")
    create_account("D", balance: 1, domain: "dbs.com.sg")

    bundles = cash_group.sidebar_entries.grep(BalanceSheet::AccountGroup::InstitutionBundle)

    assert_equal [ %w[A B], %w[C D] ], bundles.map { |bundle| bundle.accounts.map(&:name).sort }.sort
  end

  test "saved settings rename a bundle and show its total in their currency, converted at today's rates" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "CHF", date: Date.current, rate: 0.8)
    ExchangeRate.create!(from_currency: @family.currency, to_currency: "CHF", date: Date.current, rate: 0.5)
    create_account("Wise EUR", balance: 100, currency: "EUR", institution: "Wise")
    create_account("Wise main", balance: 50, institution: "Wise")
    settings = @family.institution_groups.create!(key: "wise", name: "Wise multi-currency", currency: "CHF")

    bundle = cash_group.sidebar_entries(institution_groups: { "wise" => settings }).grep(BalanceSheet::AccountGroup::InstitutionBundle).sole

    assert_equal "Wise multi-currency", bundle.name
    assert_equal Money.new(105, "CHF"), bundle.total_money
  end

  test "a saved currency in the family's converts accounts sharing another currency" do
    ExchangeRate.create!(from_currency: "SGD", to_currency: @family.currency, date: Date.current, rate: 3)
    create_account("DBS savings", balance: 100, currency: "SGD", institution: "DBS")
    create_account("DBS salary", balance: 20, currency: "SGD", institution: "DBS")
    settings = @family.institution_groups.create!(key: "dbs", currency: @family.currency)

    bundle = cash_group.institution_bundles(institution_groups: { "dbs" => settings }).sole

    assert_equal Money.new(360, @family.currency), bundle.total_money
    assert_equal "DBS", bundle.name
  end

  test "the icon is the picked member's, else the default; an account outside the bundle is ignored" do
    first = create_account("Wise A", balance: 1, institution: "Wise")
    second = create_account("Wise B", balance: 1, institution: "Wise")
    outsider = create_account("Savings", balance: 1)
    picked = @family.institution_groups.create!(key: "wise", logo_account: second)

    bundle = cash_group.institution_bundles(institution_groups: { "wise" => picked }).sole
    assert_equal second, bundle.logo_account.account

    picked.logo_account_id = outsider.id
    bundle = cash_group.institution_bundles(institution_groups: { "wise" => picked }).sole
    assert_equal first, bundle.logo_account.account
  end

  test "with a domain and no picked account the icon is the domain's" do
    Setting.stubs(:brand_fetch_client_id).returns("client-id")
    create_account("Wise A", balance: 1, institution: "Wise")
    at_domain = create_account("Wise B", balance: 1, institution: "Wise", domain: "wise.com")
    settings = @family.institution_groups.create!(key: "wise", institution_domain: "https://www.revolut.com/")

    bundle = cash_group.institution_bundles(institution_groups: { "wise" => settings }).sole
    assert_equal Account.brandfetch_logo_url_for("revolut.com"), bundle.logo_url

    at_domain.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "wise.png")
    settings.update!(institution_domain: "wise.com")
    bundle = cash_group.institution_bundles(institution_groups: { "wise" => settings }).sole
    assert_equal at_domain.reload.stored_logo_url, bundle.logo_url
  end

  test "an institution's slug names its bundle within one group" do
    create_account("Wise A", balance: 1, institution: "Wise")
    create_account("Wise B", balance: 1, institution: "Wise")
    create_account("Wise card", balance: 1, institution: "Wise", accountable: CreditCard.new)
    create_account("Wise card 2", balance: 1, institution: "Wise", accountable: CreditCard.new)

    balance_sheet = BalanceSheet.new(@family)
    cash, card = balance_sheet.account_groups.flat_map(&:institution_bundles)

    assert_not_equal cash.slug, card.slug
    assert_equal %w[Wise\ card Wise\ card\ 2], balance_sheet.institution_bundle(card.slug).accounts.map(&:name).sort
    assert_nil balance_sheet.institution_bundle("depository-000000000000")
  end
end
