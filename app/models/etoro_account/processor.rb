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

    def account
      @account ||= etoro_account.current_account
    end

    def total_balance
      etoro_account.current_balance || 0
    end

    def update_account_balance!
      account.assign_attributes(
        balance: total_balance,
        cash_balance: etoro_account.cash_balance || 0,
        currency: etoro_account.currency
      )
      account.save!

      result = account.set_current_balance(total_balance, schedule_sync: false)
      raise Provider::Etoro::Error, "Failed to set the current balance: #{result.error}" unless result.success?
    end
end
