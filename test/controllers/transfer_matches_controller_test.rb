require "test_helper"

class TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "new only offers candidates from accounts the user can write to" do
    loan = accounts(:loan)
    loan.update!(owner: users(:family_member))
    # Accessible but not writable: candidates must be filtered by write access
    loan.account_shares.create!(user: @user, permission: "read_only")

    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    hidden_inflow = create_transaction(amount: -100, account: loan, name: "Hidden member inflow")
    visible_inflow = create_transaction(amount: -100, account: accounts(:investment), name: "Visible own inflow")

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_select "[role=option][data-value=?]", visible_inflow.id
    assert_select "[role=option][data-value=?]", hidden_inflow.id, count: 0
  end

  test "new shows account logos and preselects the closest candidate and first account" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client")
    accounts(:investment).update!(institution_domain: "example-broker.com")

    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    inflow = create_transaction(amount: -100, account: accounts(:investment), name: "Broker inflow")

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_select "[role=option][data-value=?] img[src*='example-broker.com']", inflow.id
    assert_select "input[type=hidden][name='transfer_match[matched_entry_id]'][value=?]", inflow.id
    assert_select "input[type=hidden][name='transfer_match[target_account_id]']:not([value=''])"
  end

  test "new preselects an unrejected candidate over a closer rejected one" do
    outflow_entry = create_transaction(amount: 123.45, account: accounts(:depository), date: Date.current)
    rejected_inflow = create_transaction(amount: -123.45, account: accounts(:investment), date: Date.current, name: "Rejected inflow")
    open_inflow = create_transaction(amount: -123.45, account: accounts(:credit_card), date: 1.day.ago.to_date, name: "Open inflow")
    RejectedTransfer.create!(inflow_transaction_id: rejected_inflow.entryable_id, outflow_transaction_id: outflow_entry.entryable_id)

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_select "[role=option][data-value=?]", rejected_inflow.id
    assert_select "input[type=hidden][name='transfer_match[matched_entry_id]'][value=?]", open_inflow.id
  end

  test "new preloads account logo dependencies for every select option" do
    outflow_entry = create_transaction(amount: 123.45, account: accounts(:depository))
    3.times do |i|
      account = @user.family.accounts.create!(name: "Logo account #{i}", currency: "USD", balance: 0, accountable: Depository.new, owner: @user)
      create_transaction(amount: -123.45, account: account)
    end
    option_account_ids = @user.family.accounts.where.not(id: outflow_entry.account_id).pluck(:id)

    # Batched IN (...) preloads are fine; a per-account lookup is the N+1.
    single_lookup_ids = []
    callback = lambda do |*, payload|
      next unless payload[:sql].match?(/FROM "(account_providers|active_storage_attachments)" WHERE .*"(account_id|record_id)" = \$1/)

      single_lookup_ids << payload[:binds].first.value
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get new_transaction_transfer_match_path(outflow_entry)
    end

    assert_response :success
    assert_empty single_lookup_ids & option_account_ids
  end

  test "matches existing transaction and creates transfer" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))
    outflow_transaction = create_transaction(amount: -100, account: accounts(:investment))

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "existing",
          matched_entry_id: outflow_transaction.id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "creates transfer for target account" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))

    assert_difference [ "Transfer.count", "Entry.count", "Transaction.count" ], 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "new",
          target_account_id: accounts(:investment).id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "creates the new transaction in the target account's currency at the amount given" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    eur_account = eur_depository

    assert_difference [ "Transfer.count", "Entry.count" ], 1 do
      post transaction_transfer_match_path(outflow_entry), params: {
        transfer_match: { method: "new", target_account_id: eur_account.id, use_target_currency: "1", target_amount: "91.50" }
      }
    end

    new_entry = Transfer.order(created_at: :desc).first.inflow_transaction.entry
    assert_equal eur_account, new_entry.account
    assert_equal "EUR", new_entry.currency
    assert_equal(-91.50, new_entry.amount)
  end

  test "creates the new transaction in the matched transaction's currency when the option is off" do
    inflow_entry = create_transaction(amount: -100, account: accounts(:depository))
    eur_account = eur_depository

    post transaction_transfer_match_path(inflow_entry), params: {
      transfer_match: { method: "new", target_account_id: eur_account.id, use_target_currency: "0", target_amount: "91.50" }
    }

    new_entry = Transfer.order(created_at: :desc).first.outflow_transaction.entry
    assert_equal eur_account, new_entry.account
    assert_equal "USD", new_entry.currency
    assert_equal 100, new_entry.amount
  end

  test "refuses a new transaction in the target account's currency without a positive amount" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    eur_account = eur_depository

    # "0.001" is 0 at EUR's two decimals.
    [ "", "0", "-5", "abc", "0.001" ].each do |amount|
      assert_no_difference [ "Transfer.count", "Entry.count" ] do
        post transaction_transfer_match_path(outflow_entry), params: {
          transfer_match: { method: "new", target_account_id: eur_account.id, use_target_currency: "1", target_amount: amount }
        }
      end
      assert_redirected_to transactions_url
      assert_equal "Enter the amount in EUR for the new transaction.", flash[:alert]
    end
  end

  test "an account in the same currency ignores the target currency option" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: { method: "new", target_account_id: accounts(:investment).id, use_target_currency: "1", target_amount: "5" }
    }

    new_entry = Transfer.order(created_at: :desc).first.inflow_transaction.entry
    assert_equal "USD", new_entry.currency
    assert_equal(-100, new_entry.amount)
  end

  test "new gives the dialog each account's currency and the transaction's amount and date" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    eur_account = eur_depository

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_select "[data-controller='transfer-match']" do |elements|
      currencies = JSON.parse(elements.first["data-transfer-match-account-currencies-value"])
      assert_equal "EUR", currencies[eur_account.id]
      assert_equal "USD", elements.first["data-transfer-match-entry-currency-value"]
      assert_equal outflow_entry.date.iso8601, elements.first["data-transfer-match-date-value"]
    end
    assert_select "[data-transfer-match-target='currencySection'] input[name='transfer_match[target_amount]']"
  end

  test "new transfer entry is protected from provider sync" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    transfer = Transfer.order(created_at: :desc).first
    new_entry = transfer.inflow_transaction.entry

    assert new_entry.user_modified?, "New transfer entry should be marked as user_modified to protect from provider sync"
  end

  test "assigns investment_contribution kind and category for investment destination" do
    # Outflow from depository (positive amount), target is investment
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    outflow_entry.reload
    outflow_txn = outflow_entry.entryable

    assert_equal "investment_contribution", outflow_txn.kind

    category = @user.family.investment_contributions_category
    assert_equal category, outflow_txn.category
  end

  test "new shows the transaction being matched with its account logo" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client")
    accounts(:credit_card).update!(institution_domain: "example-card.com")
    inflow = create_transaction(amount: -100, account: accounts(:credit_card))

    get new_transaction_transfer_match_path(inflow)

    assert_response :success
    assert_select "button[disabled][data-select-target=button] img[src*='example-card.com']"
    assert_select "select[name='transfer_match[entry_id]']", count: 0
  end

  test "destroy dismisses the transfer hint by rejecting its pairs" do
    outflow = create_transaction(amount: 500, account: accounts(:depository))
    inflow = create_transaction(amount: -500, account: accounts(:credit_card))

    assert_difference -> { RejectedTransfer.count } => 1 do
      delete transaction_transfer_match_path(outflow), as: :turbo_stream
    end

    assert_response :success
    assert_match %(<turbo-stream action="remove" target="#{ActionView::RecordIdentifier.dom_id(outflow.transaction, :transfer_hint)}">), response.body
    assert RejectedTransfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "destroy is refused on an account the user may only read" do
    loan = accounts(:loan)
    loan.update!(owner: users(:family_member))
    loan.account_shares.create!(user: @user, permission: "read_only")
    outflow = create_transaction(amount: 500, account: loan)
    create_transaction(amount: -500, account: accounts(:credit_card))

    assert_no_difference -> { RejectedTransfer.count } do
      delete transaction_transfer_match_path(outflow)
    end
  end

  private
    def eur_depository
      @user.family.accounts.create!(name: "EUR Savings", balance: 0, currency: "EUR", accountable: Depository.new)
    end
end
