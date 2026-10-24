require "test_helper"

class EtoroItemImporterTest < ActiveSupport::TestCase
  WINDOW_START = Date.new(2025, 10, 25)

  setup do
    @item = etoro_items(:configured_item)
    @provider = mock("etoro_provider")
    travel_to Date.new(2026, 10, 24)
  end

  test "imports the primary trading account with its positions, trades and daily balances" do
    expect_balances(total: 12_500, available: 300)
    @provider.expects(:fetch_portfolio).returns({
      "clientPortfolio" => {
        "positions" => [ { "positionID" => 1, "instrumentID" => 1001, "units" => 2, "settlementTypeID" => 1 } ],
        "mirrors" => [ { "mirrorID" => 7, "availableAmount" => 45.5, "positions" => [ { "positionID" => 2, "instrumentID" => 1002, "units" => 5, "settlementTypeID" => 0 } ] } ]
      }
    })
    expect_trade_pages(
      [ trade(3, "2026-05-01T10:00:00Z", instrument: 1003), trade(9, "2025-03-01T10:00:00Z", instrument: 1004) ],
      []
    )
    @provider.expects(:fetch_balance_history)
      .with(account_type: "Trading", account_id: "acc-1", from_date: WINDOW_START, to_date: Date.new(2026, 10, 24))
      .returns({
        "snapshots" => [
          { "date" => "2026-10-22", "accountSnapshots" => [ { "accountId" => "acc-1", "currency" => "USD", "total" => 12_000.5, "cash" => 250 } ] },
          { "date" => "2026-10-23", "totalBalance" => 12_100, "totalCash" => 260, "totalCurrencyIso" => "USD", "accountSnapshots" => [] }
        ]
      })
    @provider.expects(:fetch_instruments).with { |ids| ids.sort == [ 1001, 1002, 1003 ] }.returns([
      { "instrumentID" => 1001, "symbolFull" => "AAPL", "instrumentDisplayName" => "Apple", "instrumentTypeID" => 5, "exchangeID" => 4 },
      { "instrumentID" => 1002, "symbolFull" => "XCN", "instrumentDisplayName" => "Examplecoin", "instrumentTypeID" => 10 },
      { "instrumentID" => 1003, "symbolFull" => "TUVW", "instrumentDisplayName" => "Tuvw Motors", "instrumentTypeID" => 5, "exchangeID" => 4 }
    ])

    result = EtoroItem::Importer.new(@item, provider: @provider).import

    assert result[:success]
    assert_empty result[:partial_failures]
    assert_nil result[:rate_limited_at]

    account = @item.etoro_accounts.find_by!(etoro_account_id: "acc-1")
    assert_equal BigDecimal("12500"), account.current_balance
    assert_equal BigDecimal("345.5"), account.cash_balance, "cash a copy-trading portfolio holds counts, as in eToro's daily balances"
    assert_equal "USD", account.currency
    assert_equal [ "1", "2" ], account.raw_positions_payload.map { |position| position["positionID"].to_s }
    assert_equal({ "1" => 1, "2" => 0 }, account.position_settlement_types)
    assert_equal [ 3 ], account.raw_trades_payload.map { |closed| closed["positionId"] }, "trades closed before the window are not kept"
    assert_equal Date.new(2026, 10, 24), account.trades_synced_through
    assert_equal [
      { "date" => "2026-10-22", "total" => "12000.5", "cash" => "250", "currency" => "USD" },
      { "date" => "2026-10-23", "total" => "12100", "cash" => "260", "currency" => "USD" }
    ], account.raw_balance_history_payload
    assert_equal "XCN", @item.reload.instruments_map.dig("1002", "symbol")
    assert_equal 4, @item.instruments_map.dig("1001", "exchange_id")
  end

  test "a day's figures come from this account's own breakdown, never from other accounts'" do
    importer = EtoroItem::Importer.new(@item, provider: @provider)
    others = {
      "date" => "2026-10-22", "totalBalance" => 5000, "totalCurrencyIso" => "USD",
      "accountSnapshots" => [
        { "accountId" => "acc-2", "currency" => "USD", "total" => 3000 },
        { "accountId" => "acc-3", "currency" => "USD", "total" => 2000 }
      ]
    }
    another = others.merge("totalBalance" => 3000, "accountSnapshots" => others["accountSnapshots"].first(1))
    unlabelled = others.merge("totalBalance" => 3000, "accountSnapshots" => [ { "currency" => "USD", "total" => 3000 } ])

    assert_nil importer.send(:normalize_snapshot, others, "acc-1")
    assert_nil importer.send(:normalize_snapshot, another, "acc-1")
    assert_equal({ "date" => "2026-10-22", "total" => "3000", "currency" => "USD" }, importer.send(:normalize_snapshot, unlabelled, "acc-1"))
  end

  test "reads past short pages until an empty one" do
    expect_quiet_sync
    expect_trade_pages(
      [ trade(1, "2026-10-20T10:00:00Z"), trade(2, "2026-10-19T10:00:00Z") ],
      [ trade(3, "2026-09-01T10:00:00Z") ],
      []
    )

    EtoroItem::Importer.new(@item, provider: @provider).import

    account = etoro_accounts(:main_account).reload
    assert_equal [ 1, 2, 3 ], account.raw_trades_payload.map { |closed| closed["positionId"] }
    assert_equal Date.new(2026, 10, 24), account.trades_synced_through
  end

  test "stops at a page older than the window" do
    expect_quiet_sync
    expect_trade_pages(
      [ trade(1, "2026-10-20T10:00:00Z"), trade(2, "2025-10-01T10:00:00Z") ],
      [ trade(3, "2025-06-01T10:00:00Z") ]
    )
    @provider.expects(:fetch_trade_history_page).with(min_date: WINDOW_START, page: 3).never

    EtoroItem::Importer.new(@item, provider: @provider).import

    account = etoro_accounts(:main_account).reload
    assert_equal [ 1 ], account.raw_trades_payload.map { |closed| closed["positionId"] }
    assert_equal Date.new(2026, 10, 24), account.trades_synced_through
  end

  test "a later sync stops at the first page that adds nothing new and merges what it read" do
    account = etoro_accounts(:main_account)
    account.update!(
      etoro_account_id: "acc-1",
      trades_synced_through: Date.new(2026, 10, 20),
      raw_trades_payload: [ trade(3, "2026-05-01T10:00:00Z", net_profit: 1), trade(5, "2026-04-01T10:00:00Z") ],
      raw_balance_history_payload: [ { "date" => "2026-10-20", "total" => "100" } ]
    )
    @item.update!(raw_instruments_payload: { "1001" => { "symbol" => "AAPL" } })

    expect_balances(total: 200, available: 10)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [] } })
    expect_trade_pages(
      [ trade(4, "2026-10-21T10:00:00Z"), trade(3, "2026-05-01T10:00:00Z", net_profit: 2) ],
      [ trade(5, "2026-04-01T10:00:00Z") ]
    )
    @provider.expects(:fetch_trade_history_page).with(min_date: WINDOW_START, page: 3).never
    @provider.expects(:fetch_balance_history).with(has_entries(from_date: Date.new(2026, 10, 17))).returns({
      "snapshots" => [ { "date" => "2026-10-20", "totalBalance" => 150, "totalCurrencyIso" => "USD" } ]
    })
    @provider.expects(:fetch_instruments).with([ 1001 ]).returns([
      { "instrumentID" => 1001, "symbolFull" => "AAPL", "instrumentDisplayName" => "Apple", "instrumentTypeID" => 5, "exchangeID" => 4 }
    ])

    EtoroItem::Importer.new(@item, provider: @provider).import

    account.reload
    assert_equal({ 3 => 2, 4 => nil, 5 => nil }, account.raw_trades_payload.to_h { |closed| [ closed["positionId"], closed["netProfit"] ] })
    assert_equal Date.new(2026, 10, 24), account.trades_synced_through
    assert_equal [ { "date" => "2026-10-20", "total" => "150", "currency" => "USD" } ], account.raw_balance_history_payload
    assert_equal({ "symbol" => "AAPL", "name" => "Apple", "type_id" => 5, "exchange_id" => 4 }, @item.reload.instruments_map["1001"])
  end

  test "a later answer that leaves out a field keeps the one already known" do
    @item.update!(raw_instruments_payload: { "1001" => { "symbol" => "AAPL", "type_id" => 5, "exchange_id" => 4 } })
    expect_quiet_sync(positions: [ { "positionID" => 1, "instrumentID" => 1001, "settlementTypeID" => 1 } ])
    expect_trade_pages([])
    @provider.expects(:fetch_instruments).with([ 1001 ]).returns([
      { "instrumentID" => 1001, "symbolFull" => "AAPL", "instrumentDisplayName" => "Apple Inc." }
    ])

    EtoroItem::Importer.new(@item, provider: @provider).import

    assert_equal({ "symbol" => "AAPL", "name" => "Apple Inc.", "type_id" => 5, "exchange_id" => 4 }, @item.reload.instruments_map["1001"])
  end

  test "a rate limit leaves cached instrument details as they are without reporting them" do
    @item.update!(raw_instruments_payload: { "1001" => { "symbol" => "AAPL", "type_id" => 5 } })
    expect_balances(total: 200, available: 10)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [ { "positionID" => 1, "instrumentID" => 1001 } ] } })
    @provider.expects(:fetch_trade_history_page)
      .raises(Provider::Etoro::RateLimitError.new("eToro rate limit exceeded.", status_code: 429))
    @provider.expects(:fetch_instruments).never

    result = EtoroItem::Importer.new(@item, provider: @provider).import

    assert_equal [ :trade_history, :balance_history ], result[:partial_failures].map { |failure| failure[:what] }
    assert_equal({ "symbol" => "AAPL", "type_id" => 5 }, @item.reload.instruments_map["1001"])
  end

  test "reports instruments eToro leaves out of its answer" do
    expect_balances(total: 200, available: 10)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [
      { "positionID" => 1, "instrumentID" => 1001, "settlementTypeID" => 1 },
      { "positionID" => 2, "instrumentID" => 1009, "settlementTypeID" => 1 }
    ] } })
    expect_trade_pages([])
    @provider.expects(:fetch_balance_history).returns({ "snapshots" => [] })
    @provider.expects(:fetch_instruments).with([ 1001, 1009 ]).returns([
      { "instrumentID" => 1001, "symbolFull" => "AAPL", "instrumentTypeID" => 5, "exchangeID" => 4 }
    ])

    result = nil
    assert_difference -> { DebugLogEntry.where(level: "warn", provider_key: "etoro").count }, 1 do
      result = EtoroItem::Importer.new(@item, provider: @provider).import
    end

    assert_equal [ :instrument_metadata ], result[:partial_failures].map { |failure| failure[:what] }
    assert_equal I18n.t("etoro_items.sync.partial_failures.instruments_not_described", count: 1), result[:partial_failures].first[:message]
    assert_equal [ "1009" ], DebugLogEntry.where(level: "warn", provider_key: "etoro").order(:created_at).last.metadata["instrument_ids"]
    assert_equal [ "1001" ], @item.reload.instruments_map.keys
  end

  test "a walk the page cap cuts short is kept, reported and leaves no watermark" do
    account = etoro_accounts(:main_account)
    account.update!(trades_synced_through: Date.new(2026, 10, 20))
    expect_quiet_sync
    pages = Array.new(EtoroItem::Importer::MAX_TRADE_HISTORY_PAGES) { |page| [ trade(page + 1, "2026-10-20T10:00:00Z") ] }
    @provider.expects(:fetch_trade_history_page).times(EtoroItem::Importer::MAX_TRADE_HISTORY_PAGES).returns(*pages)

    result = nil
    assert_difference -> { DebugLogEntry.where(level: "warn", provider_key: "etoro").count }, 1 do
      result = EtoroItem::Importer.new(@item, provider: @provider).import
    end

    account.reload
    assert_equal EtoroItem::Importer::MAX_TRADE_HISTORY_PAGES, account.raw_trades_payload.size
    assert_nil account.trades_synced_through
    assert_equal [ :trade_history ], result[:partial_failures].map { |failure| failure[:what] }
  end

  test "keeps the stored history when eToro fails to return it" do
    stored_trades = [ trade(3, "2026-05-01T10:00:00Z") ]
    account = etoro_accounts(:main_account)
    account.update!(
      etoro_account_id: "acc-1",
      trades_synced_through: Date.new(2026, 10, 20),
      raw_trades_payload: stored_trades,
      raw_balance_history_payload: [ { "date" => "2026-10-20", "total" => "100" } ]
    )
    @item.update!(status: :requires_update, raw_instruments_payload: { "1001" => { "symbol" => "AAPL" } })

    expect_balances(total: 200, available: 10)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [] } })
    @provider.expects(:fetch_trade_history_page)
      .raises(Provider::Etoro::ApiError.new("eToro API error (status 404)", status_code: 404))
    @provider.expects(:fetch_balance_history)
      .raises(Provider::Etoro::TransientError.new("eToro API unavailable (status 502)", status_code: 502))
    @provider.expects(:fetch_instruments).with([ 1001 ]).returns([ { "instrumentID" => 1001, "symbolFull" => "AAPL" } ])

    result = EtoroItem::Importer.new(@item, provider: @provider).import

    account.reload
    assert_equal stored_trades, account.raw_trades_payload
    assert_equal Date.new(2026, 10, 20), account.trades_synced_through
    assert_equal [ { "date" => "2026-10-20", "total" => "100" } ], account.raw_balance_history_payload
    assert_equal BigDecimal("200"), account.current_balance
    assert @item.reload.good?
    assert_equal [ :trade_history, :balance_history ], result[:partial_failures].map { |failure| failure[:what] }
  end

  test "a trade history failure partway keeps the stored trades as they were" do
    account = etoro_accounts(:main_account)
    account.update!(trades_synced_through: Date.new(2026, 10, 20), raw_trades_payload: [ trade(3, "2026-05-01T10:00:00Z") ])
    expect_quiet_sync
    @provider.expects(:fetch_trade_history_page).with(min_date: WINDOW_START, page: 1).returns([ trade(4, "2026-10-22T10:00:00Z") ])
    @provider.expects(:fetch_trade_history_page).with(min_date: WINDOW_START, page: 2)
      .raises(Provider::Etoro::TransientError, "eToro /trading/info/trade/history request failed: Net::ReadTimeout")

    result = EtoroItem::Importer.new(@item, provider: @provider).import

    account.reload
    assert_equal [ 3 ], account.raw_trades_payload.map { |closed| closed["positionId"] }
    assert_equal Date.new(2026, 10, 20), account.trades_synced_through
    assert_equal [ :trade_history ], result[:partial_failures].map { |failure| failure[:what] }
  end

  test "a rate limit leaves the remaining optional fetches to the next sync" do
    expect_balances(total: 200, available: 10)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [ { "positionID" => 1, "instrumentID" => 1001 } ] } })
    @provider.expects(:fetch_trade_history_page)
      .raises(Provider::Etoro::RateLimitError.new("eToro rate limit exceeded.", status_code: 429))
    @provider.expects(:fetch_balance_history).never
    @provider.expects(:fetch_instruments).never

    result = EtoroItem::Importer.new(@item, provider: @provider).import

    assert result[:success]
    assert_equal Time.current, result[:rate_limited_at]
    assert_equal [ :trade_history, :balance_history, :instrument_metadata ], result[:partial_failures].map { |failure| failure[:what] }
    assert_equal [ "1" ], @item.etoro_accounts.find_by!(etoro_account_id: "acc-1").raw_positions_payload.map { |position| position["positionID"].to_s }
  end

  test "an instrument lookup that fails after the account is saved does not fail the import" do
    expect_balances(total: 200, available: 10)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [ { "positionID" => 1, "instrumentID" => 1001 } ] } })
    expect_trade_pages([])
    @provider.expects(:fetch_balance_history).returns({ "snapshots" => [] })
    @provider.expects(:fetch_instruments).raises(Provider::Etoro::RateLimitError.new("eToro rate limit exceeded.", status_code: 429))

    result = EtoroItem::Importer.new(@item, provider: @provider).import

    assert result[:success]
    assert_equal [ :instrument_metadata ], result[:partial_failures].map { |failure| failure[:what] }
    assert_equal({}, @item.reload.instruments_map)
  end

  test "an authentication failure on an optional fetch still fails the import" do
    expect_balances(total: 200, available: 10)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [] } })
    expect_trade_pages([])
    @provider.expects(:fetch_balance_history).raises(Provider::Etoro::AuthenticationError, "eToro authentication failed (403).")

    assert_raises(Provider::Etoro::AuthenticationError) { EtoroItem::Importer.new(@item, provider: @provider).import }
  end

  test "imports a trading account with a zero balance" do
    expect_balances(total: 0, available: 0)
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [] } })
    expect_trade_pages([])
    @provider.expects(:fetch_balance_history).returns({ "snapshots" => [] })

    assert EtoroItem::Importer.new(@item, provider: @provider).import[:success]

    account = @item.etoro_accounts.find_by!(etoro_account_id: "acc-1")
    assert_equal BigDecimal("0"), account.current_balance
    assert_equal BigDecimal("0"), account.cash_balance
  end

  test "prefers the trading account already linked" do
    @provider.expects(:fetch_balances).with(account_types: "Trading").returns({
      "balances" => [
        { "accountId" => "other", "accountType" => "Trading", "currency" => "USD", "balance" => 0 },
        { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "USD", "balance" => 900 }
      ]
    })
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [] } })
    expect_trade_pages([])
    @provider.expects(:fetch_balance_history).with(has_entries(account_id: "etoro_trading_1")).returns({ "snapshots" => [] })

    assert_no_difference "EtoroAccount.count" do
      EtoroItem::Importer.new(@item, provider: @provider).import
    end

    assert_equal BigDecimal("900"), etoro_accounts(:main_account).reload.current_balance
  end

  test "a portfolio without a positions list fails the import and keeps the stored positions" do
    account = etoro_accounts(:main_account)
    account.update!(raw_positions_payload: [ { "positionID" => 1, "instrumentID" => 1001 } ])
    @provider.expects(:fetch_balances).returns({
      "balances" => [ { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "USD", "balance" => 100 } ]
    })
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "credit" => 100 } })

    assert_raises(Provider::Etoro::ApiError) { EtoroItem::Importer.new(@item, provider: @provider).import }
    assert_equal [ "1" ], account.reload.raw_positions_payload.map { |position| position["positionID"].to_s }
  end

  test "remembers the settlement type of positions that have since closed" do
    account = etoro_accounts(:main_account)
    account.update!(position_settlement_types: { "13" => 0 })
    expect_quiet_sync(positions: [ { "positionID" => 14, "instrumentID" => 1001, "settlementTypeID" => 1 } ])
    expect_trade_pages([])

    EtoroItem::Importer.new(@item, provider: @provider).import

    assert_equal({ "13" => 0, "14" => 1 }, account.reload.position_settlement_types)
  end

  test "fails when eToro reports no trading account" do
    @provider.expects(:fetch_balances).returns({ "balances" => [ { "accountType" => "Cash", "accountId" => "cash-1" } ] })

    assert_raises(Provider::Etoro::ApiError) { EtoroItem::Importer.new(@item, provider: @provider).import }
  end

  test "refuses a trading account held in a currency other than USD before fetching anything else" do
    stored = etoro_accounts(:main_account).attributes
    @provider.expects(:fetch_balances).returns({
      "balances" => [ { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "GBP", "balance" => 5000, "equityDetails" => { "available" => 3240 } } ]
    })
    @provider.expects(:fetch_portfolio).never
    @provider.expects(:fetch_trade_history_page).never
    @provider.expects(:fetch_balance_history).never

    error = assert_raises(Provider::Etoro::UnsupportedAccountError) { EtoroItem::Importer.new(@item, provider: @provider).import }

    assert_match "GBP", error.message
    assert_not_kind_of Provider::Etoro::ApiError, error
    assert_equal stored, etoro_accounts(:main_account).reload.attributes
  end

  test "refuses a portfolio eToro reports in a currency other than USD" do
    stored = etoro_accounts(:main_account).attributes
    @provider.expects(:fetch_balances).returns({
      "balances" => [ { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "USD", "balance" => 100 } ]
    })
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "accountCurrencyId" => 2, "positions" => [] } })
    @provider.expects(:fetch_trade_history_page).never
    @provider.expects(:fetch_balance_history).never

    error = assert_raises(Provider::Etoro::UnsupportedAccountError) { EtoroItem::Importer.new(@item, provider: @provider).import }

    assert_match "ID 2", error.message
    assert_equal stored, etoro_accounts(:main_account).reload.attributes
  end

  test "imports a USD account whether or not eToro sends its currency ID" do
    @provider.expects(:fetch_balances).returns({
      "balances" => [ { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "usd", "balance" => 100 } ]
    })
    @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "accountCurrencyId" => 1, "positions" => [] } })
    @provider.stubs(:fetch_balance_history).returns({ "snapshots" => [] })
    expect_trade_pages([])

    assert EtoroItem::Importer.new(@item, provider: @provider).import[:success]
    assert_equal "USD", etoro_accounts(:main_account).reload.currency
  end

  test "a network failure on an optional fetch keeps the stored copy and saves the rest" do
    base = "https://public-api.etoro.com/api/v1"
    json = { "Content-Type" => "application/json" }
    account = etoro_accounts(:main_account)
    account.update!(raw_balance_history_payload: [ { "date" => "2026-10-20", "total" => "100" } ])
    stub_request(:get, "#{base}/balances").with(query: hash_including({}))
      .to_return(status: 200, headers: json, body: { balances: [ { accountId: "etoro_trading_1", accountType: "Trading", currency: "USD", balance: 1500 } ] }.to_json)
    stub_request(:get, "#{base}/trading/info/real/pnl").to_return(status: 200, headers: json, body: { clientPortfolio: { positions: [] } }.to_json)
    stub_request(:get, "#{base}/trading/info/trade/history").with(query: hash_including({})).to_return(status: 200, headers: json, body: [].to_json)
    stub_request(:get, "#{base}/balances/trading/etoro_trading_1/history").with(query: hash_including({})).to_raise(Errno::EHOSTUNREACH)
    provider = Provider::Etoro.new(api_key: "key", user_key: "user")
    provider.stubs(:sleep)

    result = EtoroItem::Importer.new(@item, provider: provider).import

    assert result[:success]
    assert_equal [ :balance_history ], result[:partial_failures].map { |failure| failure[:what] }
    account.reload
    assert_equal BigDecimal("1500"), account.current_balance
    assert_equal [ { "date" => "2026-10-20", "total" => "100" } ], account.raw_balance_history_payload
  end

  private

    def expect_balances(total:, available:)
      @provider.expects(:fetch_balances).with(account_types: "Trading").returns({
        "balances" => [
          { "accountId" => "acc-1", "accountType" => "Trading", "currency" => "USD", "balance" => total, "equityDetails" => { "available" => available } }
        ]
      })
    end

    # A sync of the fixture account in which only the trade history matters.
    def expect_quiet_sync(positions: [])
      @provider.expects(:fetch_balances).with(account_types: "Trading").returns({
        "balances" => [ { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "USD", "balance" => 100 } ]
      })
      @provider.expects(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => positions } })
      @provider.stubs(:fetch_balance_history).returns({ "snapshots" => [] })
      @provider.stubs(:fetch_instruments).returns([ { "instrumentID" => 1001, "symbolFull" => "AAPL", "instrumentTypeID" => 5, "exchangeID" => 4 } ])
    end

    def expect_trade_pages(*pages)
      pages.each.with_index(1) do |batch, page|
        @provider.expects(:fetch_trade_history_page).with(min_date: WINDOW_START, page: page).returns(batch)
      end
    end

    def trade(position_id, closed_at, instrument: 1001, net_profit: nil)
      { "positionId" => position_id, "instrumentId" => instrument, "closeTimestamp" => closed_at, "netProfit" => net_profit }.compact
    end
end
