require "test_helper"

class TruelayerAccountTest < ActiveSupport::TestCase
  setup do
    @item = TruelayerItem.create!(family: families(:empty), name: "Globex", client_id: "sure-test", client_secret: "secret")
  end

  test "names repeated multi-currency balances after the bank and currency" do
    names = TruelayerAccount.display_names([
      snapshot("a1", "Jane Doe", "GBP", "Globex"),
      snapshot("a2", "Jane Doe", "USD", "Globex"),
      snapshot("a3", "Savings", "EUR", "Globex")
    ])

    assert_equal({ "a1" => "Globex (GBP)", "a2" => "Globex (USD)", "a3" => "Globex (EUR)" }, names)
  end

  test "prefers the connection's bank name over the per-account provider name" do
    names = TruelayerAccount.display_names([
      snapshot("a1", "Jane Doe", "GBP", "GLOBEX PAYMENTS LTD"),
      snapshot("a2", "Jane Doe", "USD", "GLOBEX PAYMENTS LTD")
    ], institution: "Globex")
    card = @item.truelayer_accounts.new
    card.upsert_truelayer_snapshot!(snapshot("c1", "Gold", "GBP", "ACME CARDS LTD", kind: "card"), institution: "Acme Cards")

    assert_equal({ "a1" => "Globex (GBP)", "a2" => "Globex (USD)" }, names)
    assert_equal "Acme Cards - Gold", card.name
    assert_equal "Acme Cards", card.institution_metadata["name"]
  end

  test "keeps bank names when a connection repeats none, and adds card digits" do
    names = TruelayerAccount.display_names([
      snapshot("a1", "EVERYDAY ACCOUNT", "GBP", "Acme Bank"),
      snapshot("c1", "REWARDS CARD", "GBP", "Acme Bank", kind: "card", partial_card_number: "4242")
    ])

    assert_equal({ "a1" => "EVERYDAY ACCOUNT", "c1" => "REWARDS CARD ••4242" }, names)
  end

  test "prefixes the institution unless the name already starts with it" do
    acme = @item.truelayer_accounts.new
    acme.upsert_truelayer_snapshot!(snapshot("a1", "EVERYDAY ACCOUNT", "GBP", "Acme Bank"))
    globex = @item.truelayer_accounts.new
    globex.upsert_truelayer_snapshot!(snapshot("a2", "x", "USD", "Globex"), display_name: "Globex (USD)")

    assert_equal "Acme Bank - EVERYDAY ACCOUNT", acme.name
    assert_equal "Globex (USD)", globex.name
    assert_equal "USD", globex.currency
  end

  test "merging keeps stored history, replaces updated transactions and skips pending ones" do
    account = @item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
    account.merge_truelayer_transactions!([ txn("old", -1, "2020-01-01"), txn("same", -2, "2026-01-01") ])

    account.merge_truelayer_transactions!([ txn("same", -3, "2026-01-01"), txn("pend", -4, "2026-01-02", status: "pending") ])

    stored = account.reload.raw_transactions_payload.to_h { |t| [ t["transaction_id"], t["amount"] ] }
    assert_equal({ "old" => -1, "same" => -3 }, stored)
  end

  test "drops a stored transaction the bank stopped returning inside the covered range, with its entry" do
    account, sure_account = linked_account
    account.merge_truelayer_transactions!([ txn("provisional", 34, days_ago(3)), txn("old", -1, days_ago(30)) ])
    TruelayerAccount::Processor.new(account).process

    assert_difference -> { DebugLogEntry.with_provider_key("truelayer").count }, 1 do
      account.merge_truelayer_transactions!([ txn("cleared", 34, days_ago(3)) ], covered: 7.days.ago..Time.current)
    end
    TruelayerAccount::Processor.new(account).process

    assert_equal %w[cleared old], account.reload.raw_transactions_payload.map { |t| t["transaction_id"] }.sort
    assert_equal %w[truelayer_cleared truelayer_old], sure_account.entries.where(source: "truelayer").order(:external_id).pluck(:external_id)
    assert_equal({ "transaction_ids" => [ "provisional" ], "entries_removed" => 1, "entries_kept" => 0 },
      DebugLogEntry.with_provider_key("truelayer").last.metadata.slice("transaction_ids", "entries_removed", "entries_kept"))
  end

  test "keeps the entry of a withdrawn transaction the user has taken over" do
    account, sure_account = linked_account
    account.merge_truelayer_transactions!([ txn("edited", -5, days_ago(3)) ])
    TruelayerAccount::Processor.new(account).process
    sure_account.entries.find_by!(external_id: "truelayer_edited").mark_user_modified!

    account.merge_truelayer_transactions!([ txn("other", -1, days_ago(2)) ], covered: 7.days.ago..Time.current)

    assert_equal %w[other], account.reload.raw_transactions_payload.map { |t| t["transaction_id"] }
    assert sure_account.entries.exists?(external_id: "truelayer_edited")
    assert_equal 1, DebugLogEntry.with_provider_key("truelayer").last.metadata["entries_kept"]
  end

  test "keeps stored transactions dated near the edges of the covered range or when the bank returns nothing booked" do
    account = @item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
    covered = Time.zone.parse("2026-03-01 12:00")..Time.zone.parse("2026-03-08 12:00")
    account.merge_truelayer_transactions!([ txn("first-day", -1, "2026-03-02"), txn("last-day", -2, "2026-03-08"), txn("middle", -3, "2026-03-05") ])

    account.merge_truelayer_transactions!([ txn("pend", -4, "2026-03-05", status: "pending") ], covered: covered)
    assert_equal %w[first-day last-day middle], stored_ids(account)

    account.merge_truelayer_transactions!([ txn("new", -5, "2026-03-06") ], covered: covered)
    assert_equal %w[first-day last-day new], stored_ids(account)
  end

  test "suggests a depository subtype from the account's name" do
    assert_equal "checking", @item.truelayer_accounts.new(name: "Acme Bank - Current Account").suggested_depository_subtype
    assert_equal "savings", @item.truelayer_accounts.new(name: "Instant Savings").suggested_depository_subtype
    assert_nil @item.truelayer_accounts.new(name: "Rewards Card").suggested_depository_subtype
  end

  private

    def snapshot(id, name, currency, institution, kind: "account", **extra)
      { account_id: id, display_name: name, currency: currency, kind: kind, account_type: "TRANSACTION", provider: { display_name: institution, provider_id: "ob-#{institution.parameterize}" } }.merge(extra)
    end

    def txn(id, amount, date, **extra)
      { transaction_id: id, amount: amount, timestamp: "#{date}T00:00:00Z", currency: "GBP", description: "x" }.merge(extra)
    end

    def days_ago(days)
      days.days.ago.to_date.iso8601
    end

    def stored_ids(account)
      account.reload.raw_transactions_payload.map { |t| t["transaction_id"] }.sort
    end

    def linked_account
      account = @item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
      sure_account = Account.create!(family: @item.family, name: "Acc", balance: 0, currency: "GBP", accountable: Depository.new)
      AccountProvider.create!(account: sure_account, provider: account)
      [ account.reload, sure_account ]
    end
end
