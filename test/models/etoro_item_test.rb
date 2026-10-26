require "test_helper"

class EtoroItemTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  setup do
    @item = @syncable = etoro_items(:configured_item)
  end

  test "needs both keys to be configured" do
    assert @item.credentials_configured?

    @item.user_key = ""
    assert_not @item.credentials_configured?
  end

  test "process_accounts skips accounts that are disabled or being deleted" do
    account = accounts(:investment)
    etoro_accounts(:main_account).ensure_account_provider!(account)
    account.disable!
    EtoroAccount::Processor.any_instance.expects(:process).never

    assert_empty @item.process_accounts
  end

  test "unlink_all! detaches the account and keeps its holdings" do
    account = accounts(:investment)
    link = etoro_accounts(:main_account).ensure_account_provider!(account)
    holding = Holding.create!(
      account: account,
      security: securities(:msft),
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: link.id
    )

    @item.unlink_all!(dry_run: false)

    assert_not AccountProvider.exists?(provider_type: "EtoroAccount")
    assert_nil holding.reload.account_provider_id
    assert Account.exists?(account.id)
  end

  test "unlink_all! changes nothing on a dry run" do
    link = etoro_accounts(:main_account).ensure_account_provider!(accounts(:investment))

    results = @item.unlink_all!(dry_run: true)

    assert_equal [ link.id ], results.flat_map { |result| result[:provider_link_ids] }
    assert AccountProvider.exists?(link.id)
  end

  test "deleting the connection hands the securities eToro priced back to Sure without eToro's prices" do
    priced = Security.create!(ticker: "ACME", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.current, price: 10, currency: "USD")
    @item.update!(raw_instruments_payload: { "3001" => { "symbol" => "ACME", "price_history" => { "security_id" => priced.id, "currency" => "USD", "written_from" => Date.current.iso8601 } } })

    @item.destroy!

    assert_equal [ true, nil ], [ priced.reload.offline?, priced.offline_reason ]
    assert_empty priced.prices
  end

  test "deleting the connection syncs again the accounts valued at eToro's prices" do
    priced = Security.create!(ticker: "ACME", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.current, price: 10, currency: "USD")
    @item.update!(raw_instruments_payload: { "3001" => { "symbol" => "ACME", "price_history" => { "security_id" => priced.id, "currency" => "USD", "written_from" => Date.current.iso8601 } } })
    holder = accounts(:investment)
    holder.holdings.create!(security: priced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    assert_difference -> { holder.syncs.count }, 1 do
      @item.destroy!
    end
  end

  test "deleting the connection leaves the prices another connection linked to an account gives a security" do
    priced = Security.create!(ticker: "ACME", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.current, price: 10, currency: "USD")
    instruments = { "3001" => { "symbol" => "ACME", "price_history" => { "security_id" => priced.id, "currency" => "USD", "written_from" => Date.current.iso8601 } } }
    @item.update!(raw_instruments_payload: instruments)
    newer = etoro_items(:pending_setup_item)
    newer.update!(raw_instruments_payload: instruments)
    newer.etoro_accounts.create!(name: "eToro", etoro_account_id: "etoro_trading_2", currency: "USD").ensure_account_provider!(accounts(:investment))

    @item.destroy!

    assert_equal EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON, priced.reload.offline_reason
    assert_equal 1, priced.prices.count
  end

  test "encrypts the instrument metadata when active record encryption is configured" do
    skip "Encryption not configured" unless EtoroItem.encryption_ready?

    @item.update!(raw_instruments_payload: { "1001" => { "symbol" => "AAPL" } })

    quoted_id = EtoroItem.connection.quote(@item.id)
    raw = EtoroItem.connection.select_one("SELECT raw_instruments_payload FROM etoro_items WHERE id = #{quoted_id}")
    assert_not_includes raw["raw_instruments_payload"].to_s, "AAPL"
    assert_equal "AAPL", @item.reload.instruments_map.dig("1001", "symbol")
  end
end
