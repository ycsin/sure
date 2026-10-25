require "test_helper"

class EtoroAccountCopiesProcessorTest < ActiveSupport::TestCase
  SPLIT_ON = Date.new(2026, 10, 22)

  setup do
    travel_to Date.new(2026, 10, 24)

    @main = etoro_accounts(:main_account)
    @item = @main.etoro_item
    @item.update!(raw_instruments_payload: {
      "1001" => { "symbol" => "AAPL", "name" => "Apple", "type_id" => 5 },
      "1002" => { "symbol" => "MSFT", "name" => "Microsoft", "type_id" => 5 }
    })
    Security::Resolver.stubs(:new).with("AAPL").returns(stub(resolve: securities(:aapl)))
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))

    @main.update!(
      display_mode: :copies,
      current_balance: 1040,
      cash_balance: 410,
      raw_positions_payload: [
        position(11, 1001, mirror: 0, units: 1, amount: 90, pnl: 10),
        position(12, 1002, mirror: 7, units: 2, amount: 400, pnl: 70)
      ],
      raw_balance_history_payload: [
        { "date" => "2026-10-20", "total" => "1000", "cash" => "400", "currency" => "USD" },
        { "date" => "2026-10-21", "total" => "1010", "cash" => "400", "currency" => "USD" },
        { "date" => "2026-10-22", "total" => "1020", "cash" => "410", "currency" => "USD" },
        { "date" => "2026-10-23", "total" => "1030", "cash" => "410", "currency" => "USD" }
      ]
    )
    @main_account = Account.create_from_etoro_account(@main)
    @main.ensure_account_provider!(@main_account)

    # Sure first recorded the account on 22 October.
    (SPLIT_ON..Date.current).each { |date| snapshot(0, date, total: 400, cash: 300, holdings: { "1001" => [ 1, 100 ] }) }
    snapshot(7, SPLIT_ON, total: 500, cash: 50, holdings: { "1002" => [ 2, 450 ] })
    snapshot(7, Date.new(2026, 10, 23), total: 510, cash: 50, holdings: { "1002" => [ 2, 460 ] })
    snapshot(7, Date.current, total: 520, cash: 50, holdings: { "1002" => [ 2, 470 ] })
  end

  test "the first split moves each copy's value to its account, and the accounts add up to eToro's total" do
    copy_account = set_up_copy(7)

    process_all

    assert_equal(
      { Date.new(2026, 10, 20) => 1000, Date.new(2026, 10, 21) => 1010, SPLIT_ON => 520, Date.new(2026, 10, 23) => 520, Date.current => 520 },
      totals(@main_account).except(Date.new(2026, 10, 19))
    )
    assert_equal({ Date.new(2026, 10, 21) => 0, SPLIT_ON => 500, Date.new(2026, 10, 23) => 510, Date.current => 520 }, totals(copy_account).except(Date.new(2026, 10, 20)))
    [ Date.new(2026, 10, 22), Date.new(2026, 10, 23), Date.current ].each do |date|
      assert_equal etoro_total(date), totals(@main_account)[date] + totals(copy_account)[date], "the accounts add up to eToro's total on #{date}"
    end

    # The copy's positions arrive as its holdings and only its cash moves.
    assert_equal [ [ :to_copy, SPLIT_ON, BigDecimal("50") ] ], transfers(copy_account)
    assert_copy_opens copy_account, SPLIT_ON, total: 500, cash: 50
    assert_accounts_add_up copy_account

    investments = EtoroAccount::TotalsProcessor.security_for(@main_account)
    assert_equal BigDecimal("610"), holding(@main_account, investments, Date.new(2026, 10, 21)).amount, "before the split, as totals"
    assert_equal BigDecimal("100"), holding(@main_account, securities(:aapl), SPLIT_ON).amount
    assert_nil holding(@main_account, securities(:msft), Date.current)
    assert_equal BigDecimal("0"), @main_account.holdings.where(security: investments, date: SPLIT_ON..).sum(:amount)
    assert_equal BigDecimal("460"), holding(copy_account, securities(:msft), Date.new(2026, 10, 23)).amount
    assert_equal BigDecimal("470"), holding(copy_account, securities(:msft), Date.current).amount
    assert_equal BigDecimal("0"), holding(copy_account, securities(:msft), Date.new(2026, 10, 21)).qty

    assert_equal [ BigDecimal("400"), BigDecimal("420") ], cash_on(@main_account, [ Date.new(2026, 10, 21), SPLIT_ON ])
    assert_equal [ BigDecimal("0"), BigDecimal("50") ], cash_on(copy_account, [ Date.new(2026, 10, 21), Date.current ])
    assert_empty @main_account.trades
  end

  test "a copy first recorded today holds nothing the day before and its recorded value today" do
    @main.update!(current_balance: 1240, raw_positions_payload: @main.raw_positions_payload + [ position(13, 1001, mirror: 9, units: 1, amount: 140, pnl: 10) ])
    snapshot(9, Date.current, total: 200, cash: 50, holdings: { "1001" => [ 1, 150 ] })
    copy_account = set_up_copy(9)

    process_all

    assert_equal [ [ :to_copy, Date.current, BigDecimal("50") ] ], transfers(copy_account)
    assert_copy_opens copy_account, Date.current, total: 200, cash: 50
    assert_equal BigDecimal("150"), holding(copy_account, securities(:aapl), Date.current).amount
    assert_equal BigDecimal("1040"), totals(@main_account)[Date.current]
    assert_accounts_add_up copy_account

    # A second sync the same day moves the day's figures to the copy.
    transfer = copy_transfers.sole
    @main.portfolio_snapshots.find_by!(mirror_id: 9, date: Date.current).update!(total: 230, cash: 60, holdings: { "1001" => { "units" => "1", "value" => "170" } })
    @main.update!(current_balance: 1270, raw_positions_payload: @main.raw_positions_payload.map { |row| row["positionID"] == 13 ? row.merge("unrealizedPnL" => { "pnL" => 30 }) : row })

    process_all

    assert_equal [ transfer.id ], copy_transfers.pluck(:id)
    assert_equal [ [ :to_copy, Date.current, BigDecimal("60") ] ], transfers(copy_account)
    assert_copy_opens copy_account, Date.current, total: 230, cash: 60
    assert_equal BigDecimal("1040"), totals(@main_account)[Date.current]
    assert_accounts_add_up copy_account

    # The days before hold nothing whatever day the account opens on, not
    # only because its opening balance is on the day before.
    Account.find(copy_account.id).set_opening_anchor_balance(balance: 0, date: Date.current - 3)
    materialize(copy_account)
    assert_equal [ BigDecimal("0") ], copy_account.balances.where(date: ...Date.current).pluck(:balance, :cash_balance).flatten.uniq
  end

  test "a copy first recorded on a past day after the split holds nothing the day before" do
    first_day = Date.new(2026, 10, 23)
    @main.update!(
      current_balance: 1350,
      raw_positions_payload: @main.raw_positions_payload + [ position(13, 1001, mirror: 9, units: 2, amount: 190, pnl: 20) ],
      raw_balance_history_payload: @main.raw_balance_history_payload.map { |day| day["date"] == first_day.iso8601 ? day.merge("total" => "1330") : day }
    )
    snapshot(9, first_day, total: 300, cash: 100, holdings: { "1001" => [ 2, 200 ] })
    snapshot(9, Date.current, total: 310, cash: 100, holdings: { "1001" => [ 2, 210 ] })
    copy_account = set_up_copy(9)

    process_all

    assert_equal [ [ :to_copy, first_day, BigDecimal("100") ] ], transfers(copy_account)
    assert_copy_opens copy_account, first_day, total: 300, cash: 100
    assert_equal BigDecimal("310"), totals(copy_account)[Date.current]
    assert_equal BigDecimal("0"), holding(copy_account, securities(:aapl), SPLIT_ON).qty
    assert_equal BigDecimal("1020"), totals(@main_account)[SPLIT_ON]
    assert_accounts_add_up copy_account
  end

  test "a day no sync recorded a copy keeps the day before, and eToro's daily total stays split" do
    copy_account = set_up_copy(7)
    @main.portfolio_snapshots.where(date: Date.new(2026, 10, 23)).delete_all

    process_all

    assert_equal BigDecimal("500"), totals(copy_account)[Date.new(2026, 10, 23)]
    assert_equal BigDecimal("530"), totals(@main_account)[Date.new(2026, 10, 23)]
    assert_copy_opens copy_account, SPLIT_ON, total: 500, cash: 50
    assert_accounts_add_up copy_account
  end

  test "a copy first recorded today after a day eToro sent no figures for holds nothing that day" do
    @main.update!(
      current_balance: 1240,
      raw_positions_payload: @main.raw_positions_payload + [ position(13, 1001, mirror: 9, units: 1, amount: 140, pnl: 10) ],
      raw_balance_history_payload: @main.raw_balance_history_payload.reject { |day| day["date"] == "2026-10-23" }
    )
    snapshot(9, Date.current, total: 200, cash: 50, holdings: { "1001" => [ 1, 150 ] })
    copy_account = set_up_copy(9)

    process_all

    assert_copy_opens copy_account, Date.current, total: 200, cash: 50
    # The main account holds the whole of the copy that day: today's cash,
    # the copy's among it, and the holdings recorded that day.
    assert_equal BigDecimal("1080"), totals(@main_account)[Date.new(2026, 10, 23)]
    assert_equal BigDecimal("470"), cash_on(@main_account, [ Date.new(2026, 10, 23) ]).sole
    assert_accounts_add_up copy_account
  end

  test "a copy first recorded today holds nothing before it when one of its positions is no holding" do
    @item.update!(raw_instruments_payload: @item.raw_instruments_payload.merge("1003" => { "symbol" => "CMDTY", "name" => "A commodity", "type_id" => 2 }))
    commodity = position(14, 1003, mirror: 9, units: 1, amount: 35, pnl: 5).except("settlementTypeID")
    @main.update!(current_balance: 1280, raw_positions_payload: @main.raw_positions_payload + [ position(13, 1001, mirror: 9, units: 1, amount: 140, pnl: 10), commodity ])
    snapshot(9, Date.current, total: 240, cash: 50, holdings: { "1001" => [ 1, 150 ], "1003" => [ 1, 40 ] })
    copy_account = set_up_copy(9)

    process_all

    # The holdings import takes the commodity for a CFD, so its value is cash
    # and moves with the transfer.
    assert_equal [ [ :to_copy, Date.current, BigDecimal("90") ] ], transfers(copy_account)
    assert_copy_opens copy_account, Date.current, total: 240, cash: 90
    assert_equal [ securities(:aapl).id ], copy_account.holdings.where(date: Date.current).where.not(qty: 0).pluck(:security_id)
    assert_accounts_add_up copy_account

    Account.find(copy_account.id).set_opening_anchor_balance(balance: 0, date: Date.current - 3)
    materialize(copy_account)
    assert_equal [ BigDecimal("0") ], copy_account.balances.where(date: ...Date.current).pluck(:balance, :cash_balance).flatten.uniq
  end

  test "a copy closed the day before holds nothing from that day" do
    copy_account = set_up_copy(7)
    @main.portfolio_snapshots.where(mirror_id: 7, date: Date.current).delete_all
    @main.portfolio_snapshots.find_by!(mirror_id: 7, date: Date.new(2026, 10, 23)).update!(closed: true, total: 0, cash: 0, holdings: {})
    @main.update!(raw_positions_payload: @main.raw_positions_payload.first(1))

    process_all

    assert_equal [ [ :to_copy, SPLIT_ON, BigDecimal("50") ], [ :to_main, Date.new(2026, 10, 23), BigDecimal("500") ] ], transfers(copy_account)
    days = [ SPLIT_ON, Date.new(2026, 10, 23), Date.current ]
    assert_equal [ 500, 0, 0 ], days.map { |date| totals(copy_account)[date] }
    assert_equal [ 50, 0, 0 ], cash_on(copy_account, days)
    assert_equal [ 2, 0, 0 ], days.map { |date| holding(copy_account, securities(:msft), date)&.qty || 0 }
    assert_accounts_add_up copy_account
  end

  test "a position the user sold today is no longer held today" do
    copy_account = set_up_copy(7)
    @main.portfolio_snapshots.find_by!(mirror_id: 0, date: Date.current).update!(total: 400, cash: 400, holdings: {})
    @main.update!(raw_positions_payload: @main.raw_positions_payload.drop(1))

    process_all

    assert_equal [ 1, 0 ], [ Date.new(2026, 10, 23), Date.current ].map { |date| holding(@main_account, securities(:aapl), date)&.qty || 0 }
    assert_equal [ 420, 520 ], cash_on(@main_account, [ Date.new(2026, 10, 23), Date.current ])
    assert_equal BigDecimal("520"), totals(@main_account)[Date.current]
    assert_accounts_add_up copy_account
  end

  test "money added to or taken out of a copy later moves as a transfer, kept on the next sync" do
    copy_account = set_up_copy(7)
    @main.portfolio_snapshots.find_by!(mirror_id: 7, date: Date.new(2026, 10, 23)).update!(total: 610, deposits: 100)
    @main.portfolio_snapshots.find_by!(mirror_id: 7, date: Date.current).update!(total: 590, deposits: 100, withdrawals: 30)
    @main.update!(current_balance: 1110, raw_balance_history_payload: @main.raw_balance_history_payload.map { |day| day["date"] == "2026-10-23" ? day.merge("total" => "1130") : day })

    process_all

    expected = [
      [ :to_copy, SPLIT_ON, BigDecimal("50") ],
      [ :to_copy, Date.new(2026, 10, 23), BigDecimal("100") ],
      [ :to_main, Date.current, BigDecimal("30") ]
    ]
    assert_equal expected, transfers(copy_account)
    assert_equal BigDecimal("520"), totals(@main_account)[Date.new(2026, 10, 23)]
    assert_equal BigDecimal("1110"), totals(@main_account)[Date.current] + totals(copy_account)[Date.current]

    ids = copy_transfers.order(:id).pluck(:id)
    process_all
    assert_equal ids, copy_transfers.order(:id).pluck(:id)
  end

  test "a closed copy keeps its account and history, and its last value moves back" do
    copy_account = set_up_copy(7)
    @main.portfolio_snapshots.find_by!(mirror_id: 7, date: Date.current).update!(closed: true, total: 0, cash: 0, holdings: {})
    @main.update!(raw_positions_payload: @main.raw_positions_payload.first(1))

    process_all

    assert_equal [ [ :to_copy, SPLIT_ON, BigDecimal("50") ], [ :to_main, Date.current, BigDecimal("510") ] ], transfers(copy_account)
    assert_equal({ SPLIT_ON => 500, Date.new(2026, 10, 23) => 510, Date.current => 0 }, totals(copy_account).slice(SPLIT_ON, Date.new(2026, 10, 23), Date.current))
    assert_equal BigDecimal("1040"), totals(@main_account)[Date.current]
    assert_equal [ 50, 0 ], cash_on(copy_account, [ Date.new(2026, 10, 23), Date.current ])
    assert_empty copy_account.holdings.where(date: Date.current).where.not(qty: 0)
    assert Account.exists?(copy_account.id)
    assert_equal Date.current, @main.copy_accounts.sole.copy_closed_on
  end

  test "a sync later on a copy's first day updates its opening transfer in place" do
    @main.update!(current_balance: 1240)
    snapshot(9, Date.current, total: 200, cash: 200, holdings: {})
    copy_account = set_up_copy(9)
    process_all
    transfer = copy_transfers.sole
    entry_ids = [ transfer.inflow_transaction.entry.id, transfer.outflow_transaction.entry.id ]

    @main.portfolio_snapshots.find_by!(mirror_id: 9, date: Date.current).update!(total: 210, cash: 210)
    @main.update!(current_balance: 1250)
    process_all

    assert_equal [ transfer.id ], copy_transfers.pluck(:id)
    assert_equal entry_ids, [ transfer.reload.inflow_transaction.entry.id, transfer.outflow_transaction.entry.id ]
    assert_equal [ [ :to_copy, Date.current, BigDecimal("210") ] ], transfers(copy_account)
    assert_equal BigDecimal("210"), transfer.amount
  end

  test "a disabled copy keeps its history and its value stays out of the main account" do
    copy_account = set_up_copy(7)
    process_all
    main_before = totals(@main_account)
    copy_before = totals(copy_account)

    copy_account.disable!
    process(@main)
    materialize(@main_account)

    assert_equal main_before, totals(@main_account)
    assert_equal copy_before, totals(copy_account)
    assert_equal [ [ :to_copy, SPLIT_ON, BigDecimal("50") ] ], transfers(copy_account)

    # Net worth counts a disabled account up to the day before it was
    # disabled, and the accounts add up to eToro's total until then.
    assert_equal Date.current, copy_account.reload.disabled_at.to_date
    [ SPLIT_ON, Date.new(2026, 10, 23) ].each do |date|
      assert_equal etoro_total(date), totals(@main_account)[date] + totals(copy_account)[date], "the accounts add up to eToro's total on #{date}"
    end

    copy_account.enable!
    process_all
    assert_equal main_before, totals(@main_account)
  end

  test "a disabled copy is emptied too once the main account is no longer split, and synced again" do
    copy_account = set_up_copy(7)
    process_all
    copy_account.disable!
    @main.update!(display_mode: :holdings)
    travel 10.minutes # past the account's earlier syncs

    assert_difference -> { copy_account.syncs.count }, 1 do
      @item.reload.process_accounts
    end
    [ @main_account, copy_account ].each { |account| materialize(account) }

    assert_empty copy_account.entries.where(source: "etoro")
    assert_equal [ BigDecimal("0") ], copy_account.balances.distinct.pluck(:balance)
    [ SPLIT_ON, Date.new(2026, 10, 23) ].each do |date|
      assert_equal etoro_total(date), totals(@main_account)[date] + (totals(copy_account)[date] || 0), "the accounts add up to eToro's total on #{date}"
    end
  end

  test "a position counted as owned before eToro described its instrument is no holding once eToro describes it as a CFD" do
    commodity = Security.create!(ticker: "CMDTY", name: "Commodity", offline: true)
    Security::Resolver.stubs(:new).with("CMDTY").returns(stub(resolve: commodity))
    @item.update!(raw_instruments_payload: @item.instruments_map.merge("1004" => { "symbol" => "CMDTY", "type_id" => 2 }))
    @main.portfolio_snapshots.find_by!(mirror_id: 7, date: Date.new(2026, 10, 23)).update!(holdings: {
      "1002" => { "units" => "2", "value" => "450" },
      "1004" => { "units" => "1", "value" => "10", "assumed_units" => "1", "assumed_value" => "10" }
    })
    copy_account = set_up_copy(7)

    process_all

    assert_empty copy_account.holdings.where(security: commodity).where.not(qty: 0)
    assert_accounts_add_up copy_account
  end

  test "money added to a copy on a day after one eToro sent no deposits for still moves as a transfer" do
    copy_account = set_up_copy(7)
    @main.portfolio_snapshots.find_by!(mirror_id: 7, date: Date.new(2026, 10, 23)).update!(deposits: nil)
    @main.portfolio_snapshots.find_by!(mirror_id: 7, date: Date.current).update!(total: 620, deposits: 100)
    @main.update!(current_balance: 1140)

    process_all

    assert_equal [ [ :to_copy, SPLIT_ON, BigDecimal("50") ], [ :to_copy, Date.current, BigDecimal("100") ] ], transfers(copy_account)
    assert_accounts_add_up copy_account
  end

  test "unlinking a copy's account leaves the prices eToro gives the main account's securities" do
    priced = Security.create!(ticker: "PRCD", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.new(2026, 10, 23), price: 10, currency: "USD")
    instruments = @item.reload.instruments_map.deep_dup
    instruments["1001"]["price_history"] = { "security_id" => priced.id, "currency" => "USD", "written_from" => "2026-10-23" }
    @item.update!(raw_instruments_payload: instruments)
    copy_account = set_up_copy(7)

    copy_account.account_providers.reload.destroy_all

    assert_equal EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON, priced.reload.offline_reason
    assert_equal 1, priced.prices.count
  end

  test "a copy not set up as an account stays in the main account's investments" do
    process(@main)
    materialize(@main_account)

    investments = EtoroAccount::TotalsProcessor.security_for(@main_account)
    assert_equal BigDecimal("1020"), totals(@main_account)[SPLIT_ON]
    assert_equal BigDecimal("500"), holding(@main_account, investments, SPLIT_ON).amount
    assert_equal BigDecimal("520"), holding(@main_account, investments, Date.current).amount
    assert_equal BigDecimal("1040"), Account.find(@main_account.id).balance
    assert_empty copy_transfers
  end

  test "switching to holdings empties the copy accounts, and switching back rebuilds them" do
    copy_account = set_up_copy(7)
    process_all

    @main.update!(display_mode: :holdings)
    process_all

    assert_empty copy_transfers
    assert_equal [ BigDecimal("0") ], copy_account.balances.distinct.pluck(:balance)
    assert_empty copy_account.holdings
    assert_equal BigDecimal("1020"), totals(@main_account)[SPLIT_ON]
    assert_equal BigDecimal("470"), holding(@main_account, securities(:msft), Date.current).amount
    assert_empty @main_account.holdings.where("external_id LIKE ?", "#{EtoroAccount::CopiesProcessor::HOLDING_PREFIX}%")

    @main.update!(display_mode: :copies)
    process_all

    assert_equal [ [ :to_copy, SPLIT_ON, BigDecimal("50") ] ], transfers(copy_account)
    assert_equal BigDecimal("510"), totals(copy_account)[Date.new(2026, 10, 23)]
    assert_equal BigDecimal("520"), totals(@main_account)[Date.new(2026, 10, 23)]
    assert_nil holding(@main_account, securities(:msft), Date.current)&.then { |row| row.qty.zero? ? nil : row }
  end

  test "switching to totals empties the copy accounts and shows the whole account as totals" do
    copy_account = set_up_copy(7)
    process_all

    @main.update!(display_mode: :totals)
    process_all

    investments = EtoroAccount::TotalsProcessor.security_for(@main_account)
    assert_empty copy_transfers
    assert_equal [ investments.id ], @main_account.holdings.distinct.pluck(:security_id)
    assert_equal BigDecimal("620"), holding(@main_account, investments, Date.new(2026, 10, 23)).amount
    assert_equal BigDecimal("1030"), totals(@main_account)[Date.new(2026, 10, 23)]
    assert_equal BigDecimal("0"), Account.find(copy_account.id).balance
  end

  test "a copy shows only its mirror's positions and the main account only those the user opened" do
    set_up_copy(7)
    copy = @main.copy_accounts.sole

    assert_equal [ 12 ], copy.held_positions.map { |position| position["positionID"] }
    assert_equal [ 11 ], @main.held_positions.map { |position| position["positionID"] }

    @main.update!(display_mode: :holdings)
    assert_equal [ 11, 12 ], @main.reload.held_positions.map { |position| position["positionID"] }
    assert_equal [ 12 ], copy.reload.held_positions.map { |position| position["positionID"] }
  end

  private

    # Nothing in the copy account before its first day, and on it the copy's
    # value and cash as recorded, its cash arrived by the transfer and its
    # holdings as holdings.
    def assert_copy_opens(copy_account, first_day, total:, cash:)
      before = copy_account.balances.where(date: ...first_day)
      assert_equal [ first_day.prev_day ], before.pluck(:date), "the copy account starts the day before its first day"
      assert_equal [ BigDecimal("0"), BigDecimal("0") ], [ before.sole.balance, before.sole.cash_balance ], "the copy holds nothing the day before its first day"

      opening = copy_account.balances.find_by!(date: first_day)
      assert_equal [ BigDecimal(total.to_s), BigDecimal(cash.to_s) ], [ opening.balance, opening.cash_balance ]
      assert_equal [ 0, 0 ], [ opening.start_cash_balance, opening.start_non_cash_balance ]
      assert_equal [ BigDecimal(cash.to_s), 0, 0 ], [ opening.cash_inflows, opening.cash_adjustments, opening.non_cash_adjustments ]
    end

    # The main account and its copies are eToro's total on each day eToro
    # reported one, and today.
    def assert_accounts_add_up(*copy_accounts)
      days = @main.reload.raw_balance_history_payload.map { |day| Date.parse(day["date"]) } << Date.current
      days.each do |date|
        sum = [ @main_account, *copy_accounts ].sum { |account| totals(account)[date] || 0 }
        assert_equal etoro_total(date), sum, "the accounts add up to eToro's total on #{date}"
      end
    end

    def set_up_copy(mirror_id)
      copy = @main.copy_accounts.create!(
        etoro_item: @item, mirror_id: mirror_id, etoro_account_id: "#{@main.etoro_account_id}-copy-#{mirror_id}",
        name: "eToro copy: trader#{mirror_id}", currency: "USD", display_mode: :copies
      )
      account = Account.create_from_etoro_account(copy)
      copy.ensure_account_provider!(account)
      account
    end

    def process(etoro_account)
      EtoroAccount::Processor.new(EtoroAccount.find(etoro_account.id)).process
    end

    def process_all
      @main.copy_accounts.each { |copy| process(copy) }
      process(@main)
      [ @main_account, *@main.copy_accounts.filter_map(&:current_account) ].each { |account| materialize(account) }
    end

    def materialize(account)
      Balance::Materializer.new(Account.find(account.id), strategy: :reverse).materialize_balances
    end

    def totals(account)
      account.balances.order(:date).to_h { |balance| [ balance.date, balance.balance ] }
    end

    def cash_on(account, dates)
      dates.map { |date| account.balances.find_by!(date: date).cash_balance }
    end

    def etoro_total(date)
      day = @main.reload.raw_balance_history_payload.find { |snapshot| snapshot["date"] == date.iso8601 }
      BigDecimal(day ? day["total"] : @main.current_balance.to_s)
    end

    def holding(account, security, date)
      account.holdings.find_by(security: security, date: date)
    end

    # [direction, date, amount] of each transfer between the main account and the copy.
    def transfers(copy_account)
      copy_transfers.includes(inflow_transaction: :entry, outflow_transaction: :entry).map do |transfer|
        outflow = transfer.outflow_transaction.entry
        inflow = transfer.inflow_transaction.entry
        assert_equal [ outflow.amount, outflow.date ], [ -inflow.amount, inflow.date ]
        direction = outflow.account_id == @main_account.id && inflow.account_id == copy_account.id ? :to_copy : :to_main
        [ direction, outflow.date, outflow.amount ]
      end.sort_by { |_direction, date, _amount| date }
    end

    def copy_transfers
      Transfer.where(outflow_transaction_id: Transaction.joins(:entry).where(entries: { source: "etoro" }).select(:id))
    end

    def snapshot(mirror_id, date, total:, cash:, holdings:, deposits: 0, withdrawals: 0)
      @main.portfolio_snapshots.create!(
        mirror_id: mirror_id, date: date, total: total, cash: cash,
        deposits: (deposits unless mirror_id.zero?), withdrawals: (withdrawals unless mirror_id.zero?),
        username: ("trader#{mirror_id}" unless mirror_id.zero?),
        holdings: holdings.transform_values { |units, value| { "units" => units.to_s, "value" => value.to_s } }
      )
    end

    def position(id, instrument_id, mirror:, units:, amount:, pnl:)
      {
        "positionID" => id, "instrumentID" => instrument_id, "mirrorID" => mirror, "isBuy" => true, "leverage" => 1,
        "units" => units, "amount" => amount, "unitsBaseValueDollars" => amount, "openDateTime" => "2026-03-01T09:00:00Z",
        "settlementTypeID" => 1, "unrealizedPnL" => { "pnL" => pnl }
      }
    end
end
