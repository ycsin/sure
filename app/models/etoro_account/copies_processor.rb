# Shows an eToro account split into copies (EtoroAccount#split_into_copies?):
# each copy-trading mirror is an account of its own, holding the mirror's
# positions and its uninvested cash, and the main account keeps the positions
# the user opened and the rest of the cash. Together they are eToro's total.
#
# eToro reports no past figures of a mirror, so a copy's history is what Sure
# recorded of it (EtoroPortfolioSnapshot): it starts on the first day a sync
# saw the mirror, and each day is the day's last sync, carried over a day no
# sync ran. Before that day the main account holds the whole account, valued
# as the totals mode does: eToro's daily total and cash, with what is not cash
# one "eToro investments" holding. On that day the copy's positions move to
# the copy account as its holdings, and the rest of its value, its cash, as a
# transfer, and so do the money added to or taken out of a copy since the day
# before (eToro's depositSummary and withdrawalSummary) and, when the copy is
# closed, its last value back. From then on the main account's daily total
# is eToro's less its copies', and its holdings are those recorded of the
# positions the user opened. A copy not set up as an account stays in the
# main account, as part of the investments holding.
#
# Sure works out the days before today from the trades, so the holdings of
# every past day are reported as eToro's (see EtoroAccount::TotalsProcessor),
# and no trades of eToro's positions are kept.
class EtoroAccount::CopiesProcessor
  include EtoroAccount::DataHelpers

  HOLDING_PREFIX = "etoro_copies_".freeze
  TRANSFER_PREFIX = "etoro_copy_".freeze

  # One part's snapshots, read for any day: the day's or the latest before
  # it. A closed snapshot is worth nothing.
  class Part
    attr_reader :mirror_id, :snapshots

    def initialize(mirror_id, snapshots)
      @mirror_id = mirror_id
      @snapshots = snapshots.sort_by(&:date)
      @dates = @snapshots.map(&:date)
    end

    def first_date
      @dates.first
    end

    def on(date)
      index = @dates.bsearch_index { |day| day > date } || @dates.size
      index.zero? ? nil : @snapshots[index - 1]
    end

    def total_on(date)
      snapshot = on(date)
      snapshot.nil? || snapshot.closed? ? BigDecimal("0") : snapshot.total
    end

    def holdings_on(date)
      snapshot = on(date)
      snapshot.nil? || snapshot.closed? ? {} : snapshot.holdings
    end

    # The day after which the copy is worth nothing, if it was closed.
    def closed_on
      @snapshots.last&.closed? ? @dates.last : nil
    end

    # The money that moved between the main account and the copy, by day:
    # the copy's cash on the first day it is seen, or seen again, money
    # added to or taken out of it since the day before, and its last value
    # when it is closed, which eToro returns as cash. Each is [kind, date,
    # amount], to the copy when the kind is :opened or :deposit.
    #
    # The copy's cash on its first day is its total less what the block
    # gives as the value of its holdings that day. The holdings arrive as
    # holdings: Sure takes a day's cash as the total less the holdings, so a
    # transfer of the whole value would leave the copy's cash below zero the
    # day before, by what the holdings are worth.
    #
    # Money added or taken out is counted against the latest earlier day
    # eToro sent the figure for, so a day it sent none loses nothing.
    def movements
      previous = nil
      deposits = withdrawals = nil
      @snapshots.each_with_object([]) do |snapshot, moves|
        if snapshot.closed?
          moves << [ :closed, snapshot.date, previous.total ] if previous && !previous.closed?
        elsif previous.nil? || previous.closed?
          moves << [ :opened, snapshot.date, snapshot.total - yield(snapshot) ]
          deposits, withdrawals = snapshot.deposits, snapshot.withdrawals
        else
          if snapshot.deposits
            moves << [ :deposit, snapshot.date, snapshot.deposits - deposits ] if deposits
            deposits = snapshot.deposits
          end
          if snapshot.withdrawals
            moves << [ :withdrawal, snapshot.date, snapshot.withdrawals - withdrawals ] if withdrawals
            withdrawals = snapshot.withdrawals
          end
        end
        previous = snapshot
      end.select { |_kind, _date, amount| amount.positive? }
    end
  end

  class << self
    # Takes off a main account no longer split what the split wrote: the past
    # holdings and the transfers to and from its copies, both sides.
    def clear(etoro_account)
      account = etoro_account.current_account
      return unless account

      account.holdings.where("external_id LIKE ?", "#{HOLDING_PREFIX}%").delete_all
      transfer_entries(account).each { |entry| destroy_transfer(entry) }
    end

    def transfer_entries(account)
      account.entries.where(source: "etoro", entryable_type: "Transaction").where("external_id LIKE ?", "#{TRANSFER_PREFIX}%")
    end

    def destroy_transfer(entry)
      transfer = entry.entryable&.transfer
      legs = [ entry, transfer&.inflow_transaction&.entry, transfer&.outflow_transaction&.entry ].compact.uniq
      Entry.transaction { legs.each(&:destroy!) }
    end
  end

  def initialize(etoro_account, securities: nil)
    @etoro_account = etoro_account
    @securities = securities
  end

  # Today's total: the mirror's for a copy; eToro's less the copies' shown
  # for the main account.
  def current_total
    return own_part.total_on(Date.current) if copy?

    (@etoro_account.current_balance || 0) - shown_copies.sum(BigDecimal("0")) { |_copy, part| part.total_on(Date.current) }
  end

  # The trades of eToro's positions, which the history is not worked out
  # from, and the holdings of past days, which #write_past_holdings! writes
  # again. A trade the user added stays.
  def remove_position_records!
    account.entries.where(source: "etoro", entryable_type: "Trade").destroy_all
    account.holdings.where(date: ...Date.current).delete_all
  end

  # The value of the copies not set up as accounts, held by the main account
  # today as its investments holding. Returns it.
  def write_current_investments!
    return BigDecimal("0") if copy?

    value = unshown_value_on(Date.current)
    if value.positive?
      write_rows([ holding_row(investments_security, Date.current, 1, value) ])
    else
      account.holdings.where(security_id: investments_security.id, date: Date.current).delete_all
    end
    value
  end

  # [date, total] of each past day to reconcile the account to: from the
  # first snapshot to the day it was closed for a copy, and each day of
  # eToro's daily balances, less the copies' totals, for the main account.
  def daily_totals
    if copy?
      first = own_part.first_date
      return [] if first.nil?

      last = [ own_part.closed_on, Date.current.prev_day ].compact.min
      (first..last).map { |date| [ date, own_part.total_on(date) ] }
    else
      etoro_days.map do |date, (total, _cash)|
        [ date, total - shown_copies.sum(BigDecimal("0")) { |_copy, part| part.total_on(date) } ]
      end
    end
  end

  # The holdings of every day from the account's start to yesterday, as
  # reported: those recorded of the part's positions, and for the main
  # account the investments holding. Each security has a zero on each day
  # it was not held, and today when it is no longer held, which keeps Sure
  # from carrying a holding back or forward over those days. The holdings
  # import closes nothing here, as the rows of the days before are rewritten
  # after it.
  def write_past_holdings!
    dates = (account.start_date..Date.current.prev_day).to_a
    return if dates.empty?

    held_today = account.holdings.where(date: Date.current, account_provider_id: provider_id).where.not(qty: 0).pluck(:security_id).to_set
    values = dates.index_with { |date| values_on(date) }
    security_ids = values.values.flat_map(&:keys).to_set | held_today
    prices = known_prices(values)

    rows = dates.flat_map do |date|
      security_ids.map do |security_id|
        qty, amount = values[date][security_id]
        qty&.positive? ? holding_row(security_id, date, qty, amount) : holding_row(security_id, date, 0, 0, price: prices[security_id])
      end
    end
    rows += (security_ids - held_today).map { |security_id| holding_row(security_id, Date.current, 0, 0, price: prices[security_id]) }
    write_rows(rows)
  end

  # Brings the transfers between the main account and each copy set up as
  # an account in line with the copies' movements. One that still matches
  # stays, with whatever the user set on it, and takes the movement's amount,
  # which changes with each sync on a copy's first day. Those of a disabled
  # copy stay as they are: Sure no longer writes to its account.
  def sync_transfers!
    return if copy?

    active, disabled = shown_copies.partition { |copy, _part| !copy.shown_account.disabled? }
    frozen = disabled.map { |copy, _part| "#{TRANSFER_PREFIX}#{copy.mirror_id}_" }

    wanted = active.flat_map do |copy, part|
      part.movements { |snapshot| holdings_value(copy, snapshot) }.map do |kind, date, amount|
        [ "#{TRANSFER_PREFIX}#{copy.mirror_id}_#{kind}_#{date.iso8601}", { copy_account: copy.shown_account, kind: kind, date: date, amount: amount.round(4) } ]
      end
    end.to_h

    self.class.transfer_entries(account).includes(:entryable).find_each do |entry|
      next if frozen.any? { |prefix| entry.external_id.start_with?(prefix) }

      movement = wanted[entry.external_id]
      next wanted.delete(entry.external_id) if movement && update_transfer(entry, movement)

      self.class.destroy_transfer(entry)
    end

    wanted.each { |external_id, movement| create_transfer(external_id, movement) }
  end

  private

    def copy?
      @etoro_account.copy?
    end

    def account
      @etoro_account.current_account
    end

    def provider_id
      @etoro_account.account_provider&.id
    end

    def currency
      @etoro_account.currency
    end

    def instruments_map
      @etoro_account.instruments_map
    end

    def owner
      @etoro_account.positions_owner
    end

    def parts
      @parts ||= owner.portfolio_snapshots.to_a.group_by(&:mirror_id).to_h { |mirror_id, snapshots| [ mirror_id, Part.new(mirror_id, snapshots) ] }
    end

    def own_part
      parts[copy? ? @etoro_account.mirror_id : EtoroPortfolioSnapshot::OWN_POSITIONS] || Part.new(nil, [])
    end

    # The copies set up as accounts and shown, with their parts.
    def shown_copies
      @shown_copies ||= owner.copy_accounts.includes(account_provider: :account).filter_map do |copy|
        part = parts[copy.mirror_id]
        [ copy, part ] if part && copy.shown_account
      end
    end

    def unshown_parts
      shown = shown_copies.map { |copy, _part| copy.mirror_id }
      parts.except(EtoroPortfolioSnapshot::OWN_POSITIONS, *shown).values
    end

    def unshown_value_on(date)
      unshown_parts.sum(BigDecimal("0")) { |part| part.total_on(date) }
    end

    # The first day the account's parts were recorded: the main account
    # holds the whole account, valued as totals, before it.
    def split_from
      @split_from ||= parts.values.filter_map(&:first_date).min || Date.current
    end

    # eToro's [total, cash] of each past day, as in the totals mode.
    def etoro_days
      @etoro_days ||= Array(owner.raw_balance_history_payload).each_with_object({}) do |snapshot, days|
        next if snapshot["currency"].present? && snapshot["currency"] != currency

        date = parse_date(snapshot["date"])
        total = parse_decimal(snapshot["total"])
        days[date] = [ total, parse_decimal(snapshot["cash"]) ] if date && total && date < Date.current
      end.sort.to_h
    end

    # What the copy account shows the holdings of the snapshot's day at.
    # Today's are those the holdings import takes from the mirror's open
    # positions, which can leave out a position the snapshot recorded.
    # Those of a past day are the snapshot's (see #values_on), less an
    # instrument eToro has not described yet, whose value counts as cash.
    def holdings_value(copy, snapshot)
      return EtoroAccount::HoldingsProcessor.new(copy, securities: @securities).value if snapshot.date == Date.current

      snapshot.holdings.sum(BigDecimal("0")) do |instrument_id, held|
        instruments_map[instrument_id.to_s] ? snapshot_held(instrument_id, held).last : 0
      end
    end

    # [units, value] of a snapshot's holding of an instrument, less the part
    # it counted only because eToro had not described the instrument yet,
    # once eToro describes it as a CFD.
    def snapshot_held(instrument_id, held)
      units = parse_decimal(held["units"]) || BigDecimal("0")
      value = parse_decimal(held["value"]) || BigDecimal("0")
      type_id = instruments_map.dig(instrument_id.to_s, "type_id")
      return [ units, value ] if held["assumed_units"].nil? || type_id.nil? || REAL_ASSET_TYPE_IDS.include?(type_id.to_i)

      [ units - (parse_decimal(held["assumed_units"]) || 0), value - (parse_decimal(held["assumed_value"]) || 0) ]
    end

    # { security_id => [qty, amount] } of the account on a past day.
    def values_on(date)
      values = {}

      if copy? || date >= split_from
        own_part.holdings_on(date).each do |instrument_id, held|
          units, value = snapshot_held(instrument_id, held)
          next unless units.positive?

          security = trade_security_for(instrument_id)
          next unless security

          qty, amount = values[security.id] || [ BigDecimal("0"), BigDecimal("0") ]
          values[security.id] = [ qty + units, amount + value ]
        end
      end

      unless copy?
        invested = date >= split_from ? unshown_value_on(date) : totals_investments_on(date)
        values[investments_security.id] = [ BigDecimal("1"), invested ] if invested&.positive?
      end

      values
    end

    # The totals mode's investments value of a day before the split: eToro's
    # total less its cash, carried from the day before over a day eToro sent
    # no figures for.
    def totals_investments_on(date)
      @totals_investments ||= begin
        last = nil
        etoro_days.transform_values do |total, cash|
          last = cash ? [ total - cash, BigDecimal("0") ].max : last
        end
      end

      day = @totals_investments.keys.select { |known| known <= date }.max
      day && @totals_investments[day]
    end

    def known_prices(values)
      values.values.each_with_object({}) do |day, prices|
        day.each { |security_id, (qty, amount)| prices[security_id] ||= (amount / qty).round(4) if qty.positive? }
      end.tap do |prices|
        account.holdings.where(date: Date.current).where.not(qty: 0).pluck(:security_id, :price).each { |id, price| prices[id] ||= price }
      end
    end

    def investments_security
      @investments_security ||= EtoroAccount::TotalsProcessor.security_for(account)
    end

    def holding_row(security, date, qty, amount, price: nil)
      security_id = security.respond_to?(:id) ? security.id : security
      {
        account_id: account.id,
        security_id: security_id,
        date: date,
        currency: currency,
        qty: qty,
        price: price || (qty.positive? ? (amount / qty).round(4) : 0),
        amount: amount.round(4),
        account_provider_id: provider_id,
        external_id: "#{HOLDING_PREFIX}#{@etoro_account.etoro_account_id}_#{security_id}_#{date.iso8601}"
      }
    end

    def write_rows(rows)
      rows.each_slice(500) { |batch| Holding.upsert_all(batch, unique_by: %i[account_id security_id date currency]) }
    end

    # Gives a transfer between the same accounts on the movement's day the
    # movement's amount. Returns whether it is that transfer.
    def update_transfer(entry, movement)
      transfer = entry.entryable.transfer
      counterpart = transfer&.then { |found| [ found.inflow_transaction, found.outflow_transaction ] }&.map(&:entry)&.find { |leg| leg != entry }
      return false unless entry.date == movement[:date] && counterpart&.account_id == movement[:copy_account].id

      amount = %i[opened deposit].include?(movement[:kind]) ? movement[:amount] : -movement[:amount]
      return true if entry.amount == amount

      Entry.transaction do
        entry.update!(amount: amount)
        counterpart.update!(amount: -amount)
        transfer.reload.update!(amount: movement[:amount])
      end
      true
    end

    def create_transfer(external_id, movement)
      copy_account = movement[:copy_account]
      from, to = %i[opened deposit].include?(movement[:kind]) ? [ account, copy_account ] : [ copy_account, account ]

      Entry.transaction do
        self.class.transfer_entries(copy_account).where(external_id: external_id).find_each { |stale| self.class.destroy_transfer(stale) }

        outflow = transfer_leg(from, external_id, movement, movement[:amount], I18n.t("etoro_items.copies.transfer_to", account: to.name))
        inflow = transfer_leg(to, external_id, movement, -movement[:amount], I18n.t("etoro_items.copies.transfer_from", account: from.name))
        Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: outflow.entryable, status: "confirmed", amount: movement[:amount])
      end
    end

    def transfer_leg(account, external_id, movement, amount, name)
      account.entries.create!(
        date: movement[:date], name: name, amount: amount, currency: account.currency,
        source: "etoro", external_id: external_id,
        entryable: Transaction.new(kind: "funds_movement")
      )
    end
end
