# frozen_string_literal: true

require "test_helper"
require_relative "../support/tricount_test_helper"

class TricountItemsControllerTest < ActionDispatch::IntegrationTest
  include TricountTestHelper

  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
  end

  def followed_item
    item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    tricount_account = item.tricount_accounts.new
    tricount_account.upsert_from_tricount!(tricount_registry)
    [ item, tricount_account ]
  end

  test "following a tricount link stores its token and syncs" do
    assert_difference -> { @family.tricount_items.count }, 1 do
      post tricount_items_url, params: { tricount_item: { sharing_links: "https://tricount.com/#{SHARING_TOKEN}" } }
    end

    item = @family.tricount_items.order(:created_at).last
    assert_equal [ SHARING_TOKEN ], item.sharing_token_list
    assert_equal [ "Tricount", "tricount.com", "https://tricount.com" ], [ item.institution_name, item.institution_domain, item.institution_url ]
    assert item.syncing?
  end

  test "a link that is not a tricount link is refused" do
    assert_no_difference -> { @family.tricount_items.count } do
      post tricount_items_url, params: { tricount_item: { sharing_links: "https://example.com/" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "border-destructive-subtle", "shown with DS::Alert"
    assert_includes response.body, I18n.t("tricount_items.create.invalid_links")
  end

  test "adding a link keeps the tricounts already followed" do
    item, = followed_item

    patch tricount_item_url(item), params: { tricount_item: { sharing_links: "tSecondOne42" } }

    assert_equal [ SHARING_TOKEN, "tSecondOne42" ], item.reload.sharing_token_list
  end

  test "setting up a tricount creates a cash account following the chosen member" do
    item, tricount_account = followed_item

    post complete_account_setup_tricount_item_url(item), params: { accounts: { tricount_account.id => { import: "1", member_uuid: ME } } }

    account = tricount_account.reload.current_account
    assert_redirected_to accounts_url
    assert_equal [ "Weekend trip", "Depository", BigDecimal("-20"), "EUR" ], [ account.name, account.accountable_type, account.balance, account.currency ]
    assert_equal ME, tricount_account.member_uuid
    assert_equal [ "Tricount", "tricount.com" ], [ account.read_attribute(:institution_name), account.read_attribute(:institution_domain) ]
  end

  test "accounts can be named with a Tricount prefix, and the choice is remembered" do
    item, tricount_account = followed_item

    post complete_account_setup_tricount_item_url(item),
      params: { prefix_account_names: "1", accounts: { tricount_account.id => { import: "1", member_uuid: ME } } }

    assert_equal "tricount: Weekend trip", tricount_account.reload.current_account.name
    assert item.reload.prefix_account_names?
  end

  test "a tricount can't be set up without choosing a member" do
    item, tricount_account = followed_item

    assert_no_difference -> { Account.count } do
      post complete_account_setup_tricount_item_url(item), params: { accounts: { tricount_account.id => { import: "1", member_uuid: "" } } }
    end
    assert_redirected_to setup_accounts_tricount_item_url(item)
    assert_equal I18n.t("tricount_items.complete_account_setup.member_required"), flash[:alert]
  end

  test "the setup page lists each tricount with its members to choose from" do
    item, = followed_item

    get setup_accounts_tricount_item_url(item)

    assert_response :success
    assert_select "option", text: "Alex"
    assert_select "option", text: "Kim"
  end

  test "linking an existing cash account follows the chosen member" do
    item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }

    assert_redirected_to account_url(account)
    assert_equal [ account, SAM ], [ tricount_account.reload.current_account, tricount_account.member_uuid ]
    assert_equal "tricount.com", account.reload.read_attribute(:institution_domain)
  end

  test "linking submits outside the dialog's frame, so the account page reloads" do
    followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new)

    get select_existing_account_tricount_items_url(account_id: account.id)

    assert_response :success
    assert_select "form[action='#{link_existing_account_tricount_items_path}'][data-turbo-frame='_top']"
  end

  # Family scoping alone lets an admin reach a co-member's account; with the
  # shares cleared the admin holds no permission on it at all.
  test "an account the admin can't manage can't be linked" do
    _item, tricount_account = followed_item
    account = @family.accounts.create!(name: "Trip", balance: 0, currency: "EUR", accountable: Depository.new, owner: users(:family_member))
    account.account_shares.destroy_all

    get select_existing_account_tricount_items_url(account_id: account.id)
    assert_redirected_to accounts_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]

    post link_existing_account_tricount_items_url, params: { account_id: account.id, tricount_account_id: tricount_account.id, member_uuid: SAM }
    assert_redirected_to accounts_url
    assert_nil tricount_account.reload.current_account
  end

  test "only an admin can follow a tricount" do
    sign_in users(:family_member)

    assert_no_difference -> { @family.tricount_items.count } do
      post tricount_items_url, params: { tricount_item: { sharing_links: "https://tricount.com/#{SHARING_TOKEN}" } }
    end
    assert_redirected_to accounts_url
  end
end
