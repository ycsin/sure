class EtoroAccount::BalanceHistoryProcessor
  include EtoroAccount::DataHelpers

  attr_reader :failed_count

  # `totals`, [date, total] pairs, stand in for eToro's daily balances, as
  # for an account split into copies (see EtoroAccount::CopiesProcessor).
  def initialize(etoro_account, totals: nil)
    @etoro_account = etoro_account
    @snapshots = totals
    @failed_count = 0
  end

  # Records eToro's end-of-day equity as reconciliations, which the reverse
  # balance calculator treats as waypoints. eToro reports no deposits,
  # withdrawals or dividends, so these are what keep the balance history true
  # between trades. Days on or after the current anchor are left to it. The
  # reconciliations carry the "etoro" source, which tells the account charts
  # that the history they cover is the provider's. A valuation eToro did not
  # write is the user's figure and stays as it is.
  def process
    return 0 unless account.present?

    anchor_date = account.current_anchor_date
    kept = users_valuation_dates
    past = snapshots.select { |date, _total| date < anchor_date && !kept.include?(date) }
    recorded = account.entries.valuations.where(date: past.map(&:first)).pluck(:date, :amount).to_h

    count = past.count do |date, total|
      next false if recorded[date]&.to_d == total

      result = account.set_current_balance(total, date: date, schedule_sync: false)
      capture_failure(date, result.error) unless result.success?
      result.success?
    end

    tag_reconciliations(past.map(&:first))
    count
  end

  private

    def account
      @etoro_account.current_account
    end

    # [date, total] pairs in the account's currency.
    def snapshots
      @snapshots ||= Array(@etoro_account.raw_balance_history_payload).filter_map do |snapshot|
        next if snapshot["currency"].present? && snapshot["currency"] != @etoro_account.currency

        date = parse_date(snapshot["date"])
        total = parse_decimal(snapshot["total"])
        [ date, total ] if date && total
      end
    end

    def tag_reconciliations(dates)
      return if dates.empty?

      valuations(dates)
        .where(source: nil, valuations: { kind: "reconciliation" })
        .update_all(source: "etoro", updated_at: Time.current)
    end

    # The opening anchor, and the valuations a manual account held before it
    # was linked to eToro. The anchors a sync rotates into reconciliations
    # come after the link.
    def users_valuation_dates
      linked_at = @etoro_account.account_provider&.created_at
      users = valuations.where(valuations: { kind: "opening_anchor" })
      users = users.or(valuations.where("entries.source IS DISTINCT FROM ?", "etoro").where(entries: { created_at: ...linked_at })) if linked_at
      users.pluck(:date).to_set
    end

    def valuations(dates = nil)
      scope = account.entries.joins("INNER JOIN valuations ON valuations.id = entries.entryable_id AND entries.entryable_type = 'Valuation'")
      dates ? scope.where(date: dates) : scope
    end

    def capture_failure(date, error)
      @failed_count += 1
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "EtoroAccount::BalanceHistoryProcessor - Failed to record the #{date} balance: #{error}",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { date: date.to_s, etoro_account_id: @etoro_account.id }
      )
    end
end
