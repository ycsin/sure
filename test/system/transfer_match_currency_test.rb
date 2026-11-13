require "application_system_test_case"

# Matching a transaction to an account in another currency: the dialog offers
# to create the counterpart in that account's currency, with the amount
# prefilled from the exchange rate on the transaction's date.
class TransferMatchCurrencyTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 0, currency: "EUR", accountable: Depository.new)
    @entry = create_transaction(amount: 100, account: accounts(:depository), name: "Card top-up", date: Date.current)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.92)
    sign_in @user
  end

  test "creates the counterpart in the target account's currency, prefilled from the exchange rate" do
    open_matcher

    section = "[data-transfer-match-target='currencySection']"
    select_new_transaction
    select_ds("Target account", accounts(:investment))
    assert_selector "#{section}.hidden", visible: :all

    select_ds("Target account", @eur_account)
    assert_selector section, visible: true
    assert_text "Record it in EUR, the account's currency"
    # Waits for the rate request to fill it in.
    assert_field "transfer_match[target_amount]", with: "92.00"
    amount = find("input[name='transfer_match[target_amount]']")
    assert_text "1 USD = 0.92 EUR"

    amount.fill_in(with: "91.40")
    click_button "Create transfer match"
    assert_text "Transfer created"

    new_entry = @entry.reload.transaction.transfer.inflow_transaction.entry
    assert_equal @eur_account, new_entry.account
    assert_equal "EUR", new_entry.currency
    assert_equal(-91.40, new_entry.amount)
  end

  test "the counterpart can still be created in the transaction's currency" do
    open_matcher
    select_new_transaction
    select_ds("Target account", @eur_account)

    find("input[type='checkbox'][name='transfer_match[use_target_currency]']").uncheck
    assert_no_selector "input[name='transfer_match[target_amount]']", visible: true
    click_button "Create transfer match"
    assert_text "Transfer created"

    new_entry = @entry.reload.transaction.transfer.inflow_transaction.entry
    assert_equal "USD", new_entry.currency
    assert_equal(-100, new_entry.amount)
  end

  test "the prefilled amount uses the target currency's precision" do
    kwd_account = @user.family.accounts.create!(name: "KWD Savings", balance: 0, currency: "KWD", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "USD", to_currency: "KWD", date: Date.current, rate: 0.30712)

    open_matcher
    select_new_transaction
    select_ds("Target account", kwd_account)

    # Kuwaiti dinars have three decimals.
    assert_field "transfer_match[target_amount]", with: "30.712"
  end

  # A rate that arrives after the account was changed back to one in the
  # transaction's currency is dropped; choosing the other account again must
  # ask for the rate anew rather than leave the amount empty.
  test "choosing the other currency again after leaving it mid-request still prefills" do
    open_matcher
    select_new_transaction
    page.execute_script(<<~JS)
      const fetchNow = window.fetch.bind(window);
      let delayed = false;
      window.fetch = (input, init) => {
        const url = String(input);
        if (!delayed && url.includes("exchange_rate")) {
          delayed = true;
          return new Promise((resolve) => setTimeout(() => resolve(fetchNow(input, init)), 800));
        }
        return fetchNow(input, init);
      };
    JS

    select_ds("Target account", @eur_account)
    select_ds("Target account", accounts(:investment))
    sleep 1.2
    select_ds("Target account", @eur_account)

    assert_field "transfer_match[target_amount]", with: "92.00"
  end

  private
    def open_matcher
      visit transactions_path
      within("##{dom_id(@entry)}") { click_on "Card top-up" }
      # The matcher sits in the drawer's collapsed settings section.
      find("summary", text: /#{I18n.t("transactions.show.settings")}/i).click
      click_on I18n.t("transactions.show.open_matcher")
      assert_text "Match transfer or payment"
    end

    # With candidates to match the dialog starts on "match existing"; without,
    # it only creates.
    def select_new_transaction
      return unless has_select?("transfer_match[method]", wait: 0)

      select "Create new transaction", from: "transfer_match[method]"
    end
end
