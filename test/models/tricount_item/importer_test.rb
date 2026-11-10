# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class TricountItem::ImporterTest < ActiveSupport::TestCase
  include TricountTestHelper

  setup do
    @item = families(:empty).tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    @provider = mock
  end

  def import!
    TricountItem::Importer.new(@item, tricount_provider: @provider).import
  end

  test "each followed tricount becomes a provider account with its members and entries" do
    @provider.expects(:synchronize!).with([ SHARING_TOKEN ])
    @provider.expects(:registry).with(SHARING_TOKEN).returns(tricount_registry)

    import!
    tricount_account = @item.tricount_accounts.sole

    assert_equal [ REGISTRY_UUID, "Weekend trip", "EUR" ], [ tricount_account.tricount_account_id, tricount_account.name, tricount_account.currency ]
    assert_equal [ "Alex", "Sam", "Kim" ], tricount_account.members.map(&:name)
    assert_equal 5, tricount_account.raw_transactions_payload.size
    assert_equal 4, tricount_account.active_entry_count, "the deleted entry is left out"
    assert_not tricount_account.raw_payload.key?("all_registry_entry")
    assert_not_includes [ tricount_account.raw_payload, tricount_account.raw_transactions_payload ].to_json, SHARING_TOKEN,
      "the sharing token grants write access and stays only in the encrypted item"
    assert_nil tricount_account.current_balance, "no member chosen yet"
  end

  test "the tricount's currency is normalised, and an unknown one keeps the last good one" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry.merge("currency" => "chf"))
    import!
    assert_equal "CHF", @item.tricount_accounts.sole.currency

    @provider.stubs(:registry).returns(tricount_registry.merge("currency" => "XXX"))
    import!
    assert_equal "CHF", @item.tricount_accounts.sole.currency
  end

  test "a later import keeps the chosen member and updates the balance" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry)
    import!
    @item.tricount_accounts.sole.assign_member!(ME)

    @provider.stubs(:registry).returns(tricount_registry(entries: tricount_entries.first(2)))
    import!

    assert_equal [ ME, BigDecimal("65") ], @item.tricount_accounts.sole.values_at(:member_uuid, :current_balance)
  end

  test "an unlinked tricount whose link was removed is dropped" do
    @provider.stubs(:synchronize!)
    @provider.stubs(:registry).returns(tricount_registry)
    import!
    @item.update!(sharing_tokens: "tOtherToken9")

    @provider.stubs(:registry).with("tOtherToken9").returns(tricount_registry.merge("uuid" => "other-uuid"))
    import!

    assert_equal [ "other-uuid" ], @item.tricount_accounts.pluck(:tricount_account_id)
  end

  test "a refused session marks the connection for attention" do
    @provider.stubs(:synchronize!).raises(Provider::Tricount::AuthenticationError.new("refused"))

    assert_raises(Provider::Tricount::AuthenticationError) { import! }
    assert @item.reload.requires_update?
  end
end
