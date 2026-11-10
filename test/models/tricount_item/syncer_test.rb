# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class TricountItem::SyncerTest < ActiveSupport::TestCase
  include TricountTestHelper

  setup do
    @family = families(:empty)
    @item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    @provider = mock
    @provider.stubs(:synchronize!)
    @item.stubs(:tricount_provider).returns(@provider)
    @item.stubs(:schedule_account_syncs)
  end

  def sync_item
    sync = Sync.create!(syncable: @item)
    TricountItem::Syncer.new(@item).perform_sync(sync)
    sync.reload
  end

  def link_account
    tricount_account = @item.tricount_accounts.new
    tricount_account.upsert_from_tricount!(tricount_registry)
    tricount_account.assign_member!(ME)
    account = @family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    tricount_account.ensure_account_provider!(account)
  end

  test "a clean sync is healthy" do
    @provider.stubs(:registry).returns(tricount_registry)

    assert_equal 0, sync_item.sync_stats["total_errors"]
  end

  test "a tricount that can't be read leaves the sync unhealthy and logs it for support" do
    @provider.stubs(:registry).raises(Provider::Tricount::Error.new("Tricount server error (502). Please try again later.", :server_error))

    sync = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "tricount").count }, 1 do
      sync = sync_item
    end

    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "import_error", sync.sync_stats["errors"].sole["category"]
  end

  test "an account that can't be processed leaves the sync unhealthy" do
    link_account
    @provider.stubs(:registry).returns(tricount_registry)
    TricountAccount::Processor.any_instance.stubs(:process).raises(ActiveRecord::RecordInvalid)

    sync = sync_item

    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "account_processing_error", sync.sync_stats["errors"].sole["category"]
  end
end
