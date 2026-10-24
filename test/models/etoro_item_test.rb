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

  test "encrypts the instrument metadata when active record encryption is configured" do
    skip "Encryption not configured" unless EtoroItem.encryption_ready?

    @item.update!(raw_instruments_payload: { "1001" => { "symbol" => "AAPL" } })

    quoted_id = EtoroItem.connection.quote(@item.id)
    raw = EtoroItem.connection.select_one("SELECT raw_instruments_payload FROM etoro_items WHERE id = #{quoted_id}")
    assert_not_includes raw["raw_instruments_payload"].to_s, "AAPL"
    assert_equal "AAPL", @item.reload.instruments_map.dig("1001", "symbol")
  end
end
