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
end
