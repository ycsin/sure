require "test_helper"

class EtoroItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @item = etoro_items(:configured_item)
    @etoro_account = etoro_accounts(:main_account)
  end

  test "create saves both keys and starts a sync" do
    assert_difference "EtoroItem.count", 1 do
      post etoro_items_url, params: { etoro_item: { api_key: "new_public_key", user_key: "new_user_key" } }
    end

    item = EtoroItem.order(:created_at).last
    assert_redirected_to accounts_path
    assert_equal "new_user_key", item.user_key
    assert_equal I18n.t("settings.providers.etoro_panel.default_account_name"), item.name
    assert_enqueued_with(job: SyncJob, args: [ item.syncs.sole ])
  end

  test "create without a user key is rejected" do
    assert_no_difference "EtoroItem.count" do
      post etoro_items_url, params: { etoro_item: { api_key: "new_public_key", user_key: "" } }
    end
  end

  test "update keeps keys left blank" do
    patch etoro_item_url(@item), params: { etoro_item: { api_key: "rotated_public_key", user_key: "" } }

    @item.reload
    assert_equal "rotated_public_key", @item.api_key
    assert_equal "test_user_key", @item.user_key
  end

  test "new keys put a connection that needs attention back in good standing and sync it" do
    @item.update!(status: :requires_update)

    assert_enqueued_with(job: SyncJob) do
      patch etoro_item_url(@item), params: { etoro_item: { api_key: "rotated_public_key", user_key: "" } }
    end

    assert @item.reload.good?
  end

  test "complete account setup creates a linked investment account" do
    EtoroAccount::Processor.any_instance.stubs(:process)

    assert_difference "Account.count", 1 do
      post complete_account_setup_etoro_item_url(@item), params: { account_ids: [ @etoro_account.id ] }
    end

    assert_redirected_to accounts_path
    account = @etoro_account.reload.current_account
    assert_equal "Investment", account.accountable_type
    assert_equal "USD", account.currency
  end

  test "complete account setup in a zone ahead of UTC dates trades by eToro's UTC day" do
    with_closed_position_in(timezone: "Asia/Singapore")

    post complete_account_setup_etoro_item_url(@item), params: { account_ids: [ @etoro_account.id ] }

    assert_trades_on_utc_days(@etoro_account.reload.current_account)
  end

  test "accounts page shows the connection card" do
    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)}"
  end

  test "setup accounts lists the discovered account" do
    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]'][value=?]", @etoro_account.id
  end

  test "setup accounts offers only the manual accounts the user may write to" do
    private_account = member_investment_account
    shared_account = member_investment_account(shared_with_admin: "read_write")

    get setup_accounts_etoro_item_url(@item)

    assert_response :success
    assert_select "select[name=account_id] option[value=?]", accounts(:investment).id
    assert_select "select[name=account_id] option[value=?]", private_account.id, count: 0
    assert_select "select[name=account_id] option[value=?]", shared_account.id, count: 0
  end

  test "select existing account lists the unlinked eToro account" do
    get select_existing_account_etoro_items_url(account_id: accounts(:investment).id)

    assert_response :success
    assert_select "input[type=radio][name=etoro_account_id][value=?]", @etoro_account.id
  end

  test "select existing account rejects an account the user cannot see" do
    get select_existing_account_etoro_items_url(account_id: member_investment_account.id)

    assert_response :not_found
  end

  test "select existing account rejects an account shared without full control" do
    get select_existing_account_etoro_items_url(account_id: member_investment_account(shared_with_admin: "read_write").id)

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "link existing account links a manual investment account and syncs it" do
    account = accounts(:investment)

    assert_no_difference "DebugLogEntry.count" do
      assert_difference "AccountProvider.count", 1 do
        assert_enqueued_with(job: SyncJob) do
          post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
        end
      end
    end

    assert_redirected_to account_path(account)
    assert_equal account, @etoro_account.reload.current_account
    assert_equal BigDecimal("12000"), account.reload.balance
    assert account.has_current_anchor?
  end

  test "link existing account in a zone ahead of UTC dates trades by eToro's UTC day" do
    with_closed_position_in(timezone: "Asia/Singapore")

    post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: @etoro_account.id }

    assert_trades_on_utc_days(accounts(:investment))
  end

  test "link existing account rejects an account that is not a manual investment account" do
    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:depository).id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to account_path(accounts(:depository))
    assert_equal I18n.t("etoro_items.link_existing_account.only_manual_investment"), flash[:alert]
  end

  test "link existing account rejects an eToro account linked elsewhere" do
    other = families(:dylan_family).accounts.create!(name: "Other brokerage", balance: 0, currency: "USD", owner: users(:family_admin), accountable: Investment.new)
    @etoro_account.ensure_account_provider!(other)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to account_path(accounts(:investment))
    assert_equal I18n.t("etoro_items.link_existing_account.already_linked"), flash[:alert]
  end

  test "link existing account does not reach another family's eToro account" do
    other_item = families(:empty).etoro_items.create!(name: "Elsewhere", api_key: "key", user_key: "user")
    other_account = other_item.etoro_accounts.create!(name: "eToro", etoro_account_id: "other", currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: accounts(:investment).id, etoro_account_id: other_account.id }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("etoro_items.link_existing_account.not_found"), flash[:alert]
  end

  test "link existing account rejects an account the user cannot see" do
    account = member_investment_account

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to settings_providers_path
    assert_unchanged account
  end

  test "link existing account rejects an account shared without full control" do
    account = member_investment_account(shared_with_admin: "read_write")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_unchanged account
  end

  test "link existing account accepts an account shared with full control" do
    account = member_investment_account(shared_with_admin: "full_control")

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_etoro_items_url, params: { account_id: account.id, etoro_account_id: @etoro_account.id }
    end

    assert_redirected_to account_path(account)
  end

  test "sync starts a sync" do
    assert_enqueued_with(job: SyncJob) do
      post sync_etoro_item_url(@item)
    end

    assert_response :redirect
  end

  test "sync from the panel re-renders the panel in place" do
    post sync_etoro_item_url(@item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "etoro-providers-panel"
    assert @item.reload.syncing?
  end

  test "destroy unlinks the account and schedules the connection for deletion" do
    @etoro_account.ensure_account_provider!(accounts(:investment))

    assert_enqueued_with(job: DestroyJob) do
      delete etoro_item_url(@item)
    end

    assert_redirected_to settings_providers_path
    assert @item.reload.scheduled_for_deletion?
    assert_not AccountProvider.exists?(provider_type: "EtoroAccount")
  end

  private

    # A manual investment account another member owns, optionally shared with
    # the signed-in admin.
    def member_investment_account(shared_with_admin: nil)
      account = families(:dylan_family).accounts.create!(
        name: "Pension",
        balance: 123_456,
        currency: "EUR",
        owner: users(:family_member),
        accountable: Investment.new
      )
      account.share_with!(users(:family_admin), permission: shared_with_admin) if shared_with_admin
      account
    end

    # A position opened and closed late in the UTC day, which is already the
    # next day in the family's zone.
    def with_closed_position_in(timezone:)
      families(:dylan_family).update!(timezone: timezone)
      travel_to Time.utc(2026, 10, 24, 10)
      @item.update!(raw_instruments_payload: { "1001" => { "symbol" => "AAPL", "name" => "Apple", "type_id" => 5 } })
      @etoro_account.update!(raw_trades_payload: [ {
        "positionId" => 21, "instrumentId" => 1001, "isBuy" => true, "leverage" => 1, "units" => 4,
        "investment" => 400, "netProfit" => 40, "openTimestamp" => "2026-01-10T17:00:00Z", "closeTimestamp" => "2026-02-10T20:00:00Z"
      } ])
      Security::Resolver.stubs(:new).with("AAPL").returns(stub(resolve: securities(:aapl)))
    end

    def assert_trades_on_utc_days(account)
      trades = account.entries.where(source: "etoro", entryable_type: "Trade")
      assert_equal Date.new(2026, 1, 10), trades.find_by!(external_id: "etoro_position_21_open").date
      assert_equal Date.new(2026, 2, 10), trades.find_by!(external_id: "etoro_position_21_close_#{Time.utc(2026, 2, 10, 20).to_i}").date
    end

    def assert_unchanged(account)
      account.reload
      assert_empty account.account_providers
      assert_equal BigDecimal("123456"), account.balance
      assert_equal "EUR", account.currency
    end
end
