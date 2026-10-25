class EtoroAccount::Processor
  attr_reader :etoro_account

  def initialize(etoro_account)
    @etoro_account = etoro_account
  end

  # Returns the number of holdings imported and of records (holdings, trades,
  # daily balances) that failed to import.
  def process
    return unless account.present?

    # Setup and linking run this inside a request, in the family's zone,
    # while sync jobs run it in UTC. eToro's daily balances are UTC days, so
    # the anchor, the holdings snapshot and the trades are dated in UTC
    # either way.
    result = Time.use_zone("UTC") { import_records }
    account.broadcast_sync_complete
    result
  end

  private

    def import_records
      return import_copy if etoro_account.copy?
      return import_split if etoro_account.shown_as_copies?

      EtoroAccount::CopiesProcessor.clear(etoro_account)
      update_account_balance!
      return import_totals if etoro_account.shown_as_totals?

      EtoroAccount::TotalsProcessor.clear(account)
      securities = {}
      holdings = EtoroAccount::HoldingsProcessor.new(etoro_account, securities: securities)
      holdings_value = holdings.process
      # Cash is whatever the holdings don't account for, so CFD equity and
      # money parked in copy-trading mirrors count as cash.
      account.update!(cash_balance: total_balance - holdings_value)

      activities = EtoroAccount::ActivitiesProcessor.new(etoro_account, securities: securities)
      activities.process
      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account)
      balance_history.process
      account.ensure_opening_anchor_precedes_entries

      {
        holdings: holdings.imported_count,
        failed_records: holdings.failed_count + activities.failed_count + balance_history.failed_count
      }
    end

    def import_totals
      totals = EtoroAccount::TotalsProcessor.new(etoro_account)
      account.update!(cash_balance: total_balance - totals.process)

      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account)
      balance_history.process
      totals.fit_opening_anchor!

      { holdings: 1, failed_records: balance_history.failed_count }
    end

    # The main account of an account split into copies: the positions the
    # user opened, and the investments of copies not set up as accounts.
    def import_split
      securities = {}
      copies = EtoroAccount::CopiesProcessor.new(etoro_account, securities: securities)
      total = copies.current_total
      update_account_balance!(total)
      copies.remove_position_records!

      holdings = EtoroAccount::HoldingsProcessor.new(etoro_account, securities: securities)
      account.update!(cash_balance: total - holdings.process - copies.write_current_investments!)

      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account, totals: copies.daily_totals)
      balance_history.process
      copies.sync_transfers!
      EtoroAccount::TotalsProcessor.fit_opening_anchor!(account)
      copies.write_past_holdings!

      { holdings: holdings.imported_count, failed_records: holdings.failed_count + balance_history.failed_count }
    end

    # A copy's account, which counts nothing while its main account is not
    # split: the main account shows the copy's positions then. It keeps its
    # link, for a return to copies, which rebuilds it from the snapshots.
    def import_copy
      copies = EtoroAccount::CopiesProcessor.new(etoro_account, securities: {})

      unless etoro_account.split_into_copies?
        emptied = account.entries.where(source: "etoro").destroy_all.any?
        emptied = account.holdings.delete_all.positive? || emptied
        update_account_balance!(BigDecimal("0"), cash: BigDecimal("0"))
        EtoroAccount::TotalsProcessor.fit_opening_anchor!(account)
        # The connection's sync leaves a disabled account out of the account
        # syncs that work out its balances again.
        account.sync_later if emptied && account.disabled?
        return { holdings: 0, failed_records: 0 }
      end

      total = copies.current_total
      update_account_balance!(total)
      copies.remove_position_records!

      holdings = EtoroAccount::HoldingsProcessor.new(etoro_account, securities: {})
      account.update!(cash_balance: total - holdings.process)

      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account, totals: copies.daily_totals)
      balance_history.process
      EtoroAccount::TotalsProcessor.fit_opening_anchor!(account)
      copies.write_past_holdings!

      { holdings: holdings.imported_count, failed_records: holdings.failed_count + balance_history.failed_count }
    end

    def account
      @account ||= etoro_account.current_account
    end

    def total_balance
      etoro_account.current_balance || 0
    end

    def update_account_balance!(total = total_balance, cash: etoro_account.cash_balance || 0)
      account.assign_attributes(balance: total, cash_balance: cash, currency: etoro_account.currency)
      account.save!

      result = account.set_current_balance(total, schedule_sync: false)
      raise Provider::Etoro::Error, "Failed to set the current balance: #{result.error}" unless result.success?
    end
end
