class EtoroItem::Importer
  include CurrencyNormalizable
  include EtoroAccount::DataHelpers

  TRADING_ACCOUNT_TYPE = "Trading".freeze

  # eToro reports a position's amount and cost in USD and its P&L in the
  # account currency, so the two add up only in a USD account.
  SUPPORTED_CURRENCY = "USD".freeze
  USD_CURRENCY_ID = 1

  # eToro serves daily balances for the last year less a day, and the trade
  # history walk keeps only the trades closed within that window. Trades
  # stored by earlier syncs stay, and a buy is dated on the day its position
  # opened, so the holdings history still reaches back before the window,
  # where no daily balance pins it.
  HISTORY_WINDOW_DAYS = 364

  # Recent days are fetched again on every sync, in case eToro amended them.
  BALANCE_HISTORY_OVERLAP_DAYS = 3

  # A safety stop for the trade history walk, far above any real account.
  MAX_TRADE_HISTORY_PAGES = 200

  TradeHistory = Data.define(:trades, :complete)

  attr_reader :etoro_item, :provider

  def initialize(etoro_item, provider:)
    @etoro_item = etoro_item
    @provider = provider
    @partial_failures = []
    @rate_limited_at = nil
  end

  # Imports the primary trading account. The PnL endpoint describes the real
  # account as a whole, so its positions belong to that one account.
  # Positions and the balance must arrive; the histories, instrument metadata
  # and prices are kept from the last sync when eToro fails to send them, and
  # those failures are returned for the sync to report. An account not held
  # in USD is refused before anything is stored.
  def import
    # Before asking eToro anything, so that a key eToro now refuses does not
    # keep its prices on securities no account values with them.
    etoro_item.release_unused_prices!

    balance = primary_trading_balance
    raise Provider::Etoro::ApiError, "eToro returned no trading account" unless balance

    currency = account_currency(balance)
    ensure_supported_currency!(currency)

    account_id = field(balance, "accountId").to_s.presence || "real"
    etoro_account = etoro_item.etoro_accounts.find_or_initialize_by(etoro_account_id: account_id)
    today = Date.current
    window_start = today - HISTORY_WINDOW_DAYS

    portfolio = provider.fetch_portfolio
    ensure_supported_currency!(currency, field(field(portfolio, "clientPortfolio") || portfolio, "accountCurrencyId"))
    positions = open_positions(portfolio)
    history = fetch_trades(etoro_account, window_start)
    snapshots = fetch_balance_snapshots(etoro_account, account_id, today, window_start)

    ActiveRecord::Base.transaction do
      etoro_account.assign_attributes(
        name: I18n.t("etoro_items.defaults.name"),
        account_type: "trading",
        currency: currency,
        current_balance: parse_decimal(field(balance, "balance")) || BigDecimal("0"),
        cash_balance: available_cash(balance, portfolio),
        raw_positions_payload: positions,
        position_settlement_types: (etoro_account.position_settlement_types || {}).merge(settlement_types_of(positions)),
        last_positions_sync: Time.current
      )

      if history
        etoro_account.raw_trades_payload = merge_trades(etoro_account.raw_trades_payload, history.trades)
        # An unfinished walk leaves no watermark: the trades it stored would
        # otherwise end the next walk before the ones it missed.
        etoro_account.trades_synced_through = history.complete ? today : nil
      end

      unless snapshots.nil?
        etoro_account.raw_balance_history_payload = merge_snapshots(etoro_account.raw_balance_history_payload, snapshots)
      end

      etoro_account.save!
      etoro_item.update!(status: :good)
    end

    refresh_instruments!(etoro_account)
    import_price_history!(etoro_account)

    { success: true, partial_failures: @partial_failures, rate_limited_at: @rate_limited_at }
  end

  private

    # The currency eToro names for the account, USD when it names none.
    def account_currency(balance)
      reported = field(balance, "currency")
      parse_currency(reported) || reported.presence&.to_s || SUPPORTED_CURRENCY
    end

    # Refuses an account not held in USD rather than book its USD position
    # figures in another currency. eToro's own example omits
    # accountCurrencyId, so only an ID it does send is checked.
    def ensure_supported_currency!(currency, currency_id = nil)
      return if currency == SUPPORTED_CURRENCY && (currency_id.blank? || currency_id.to_i == USD_CURRENCY_ID)

      raise Provider::Etoro::UnsupportedAccountError,
        "eToro account currency #{currency_id.blank? ? currency : "ID #{currency_id}"} is not supported yet; Sure imports USD eToro accounts only"
    end

    # The Trading entry already linked when there is one, so a second Trading
    # entry eToro starts listing cannot take its place.
    def primary_trading_balance
      data = provider.fetch_balances(account_types: TRADING_ACCOUNT_TYPE)
      trading = Array(field(data, "balances")).select { |balance| field(balance, "accountType").to_s.casecmp?(TRADING_ACCOUNT_TYPE) }
      stored_ids = etoro_item.etoro_accounts.filter_map(&:etoro_account_id)

      trading.find { |balance| stored_ids.include?(field(balance, "accountId").to_s) } ||
        trading.find { |balance| !field(balance, "subType").to_s.casecmp?("subAccount") }
    end

    # Direct positions and those held through copy-trading mirrors. A
    # response without a positions list is not an empty portfolio: stored as
    # one, it would close every holding.
    def open_positions(data)
      portfolio = field(data, "clientPortfolio") || data
      direct = field(portfolio, "positions")
      raise Provider::Etoro::ApiError.new("eToro returned a portfolio without positions", status_code: 200) unless direct.is_a?(Array)

      mirrored = Array(field(portfolio, "mirrors")).flat_map { |mirror| Array(field(mirror, "positions")) }

      (direct + mirrored).uniq { |position| field(position, "positionID").to_s }
    end

    # Walks the trade history from the newest close back and keeps the trades
    # closed within the window. Only an empty page ends the history, since a
    # short one can have more after it. As later pages are older, a page with
    # no trade not yet known ends the walk too: trades this walk has read are
    # known, which also stops a walk eToro answers with the same page, and so
    # are the stored ones once a walk has finished. Returns nil, leaving the
    # stored trades as they are, when eToro fails partway.
    def fetch_trades(etoro_account, window_start)
      known = etoro_account.trades_synced_through ? trade_keys(etoro_account.raw_trades_payload) : Set.new
      trades = []

      1.upto(MAX_TRADE_HISTORY_PAGES) do |page|
        batch = provider.fetch_trade_history_page(min_date: window_start, page: page)
        return TradeHistory.new(trades: trades, complete: true) if batch.empty?

        kept = batch.select { |trade| closed_since?(trade, window_start) }
        added = kept.reject { |trade| known.include?(trade_key(trade)) }
        trades.concat(kept)
        return TradeHistory.new(trades: trades, complete: true) if added.empty?

        known.merge(added.map { |trade| trade_key(trade) })
      end

      capture_truncated_trade_history(etoro_account, window_start, trades)
      TradeHistory.new(trades: trades, complete: false)
    rescue Provider::Etoro::ApiError => e
      capture_partial_failure(:trade_history, e, etoro_account)
      nil
    end

    def fetch_balance_snapshots(etoro_account, account_id, today, window_start)
      return skip_after_rate_limit(:balance_history) if rate_limited?

      latest_stored = Array(etoro_account.raw_balance_history_payload).filter_map { |snapshot| parse_date(snapshot["date"]) }.max
      from_date = latest_stored ? [ latest_stored - BALANCE_HISTORY_OVERLAP_DAYS, window_start ].max : window_start

      data = provider.fetch_balance_history(account_type: TRADING_ACCOUNT_TYPE, account_id: account_id, from_date: from_date, to_date: today)
      Array(field(data, "snapshots")).filter_map { |snapshot| normalize_snapshot(snapshot, account_id) }
    rescue Provider::Etoro::ApiError => e
      capture_partial_failure(:balance_history, e, etoro_account)
      nil
    end

    # One day's figures for this account: its own breakdown, or a single one
    # naming no account. The day's totals stand in only when there is no
    # breakdown at all, since they add up every account listed; a day whose
    # breakdowns are all other accounts' is skipped.
    def normalize_snapshot(snapshot, account_id)
      date = parse_date(field(snapshot, "date"))
      return nil unless date

      breakdowns = Array(field(snapshot, "accountSnapshots"))
      own = breakdowns.find { |breakdown| field(breakdown, "accountId").to_s == account_id }
      own ||= breakdowns.first if breakdowns.one? && field(breakdowns.first, "accountId").blank?
      return nil if own.nil? && breakdowns.any?

      total, cash, currency = if own
        [ field(own, "total"), field(own, "cash"), field(own, "currency") ]
      else
        [ field(snapshot, "totalBalance"), field(snapshot, "totalCash"), field(snapshot, "totalCurrencyIso") ]
      end
      return nil if parse_decimal(total).nil?

      { "date" => date.iso8601, "total" => total.to_s, "cash" => cash&.to_s, "currency" => currency }.compact
    end

    # The cash eToro's daily balances count: the account's available cash
    # and what its copy-trading portfolios hold uninvested.
    def available_cash(balance, data)
      portfolio = field(data, "clientPortfolio") || data
      mirrored = Array(field(portfolio, "mirrors")).sum(BigDecimal("0")) { |mirror| parse_decimal(field(mirror, "availableAmount")) || 0 }

      (parse_decimal(field(field(balance, "equityDetails"), "available")) || BigDecimal("0")) + mirrored
    end

    def merge_trades(existing, fetched)
      (Array(existing) + Array(fetched))
        .reverse
        .uniq { |trade| trade_key(trade) }
        .reverse
    end

    def trade_key(trade)
      [ field(trade, "positionId").to_s, field(trade, "closeTimestamp").to_s ]
    end

    def trade_keys(trades)
      Array(trades).to_set { |trade| trade_key(trade) }
    end

    def closed_since?(trade, date)
      closed_on = parse_date(field(trade, "closeTimestamp"))
      closed_on.present? && closed_on >= date
    end

    def merge_snapshots(existing, fetched)
      (Array(existing) + Array(fetched))
        .reverse
        .uniq { |snapshot| snapshot["date"] }
        .sort_by { |snapshot| snapshot["date"] }
    end

    # Asks eToro on every sync about every instrument in use, as a ticker or
    # listing can change under an instrument ID. Each field eToro answers
    # replaces the cached one, and a field it leaves out keeps the old value.
    # After a rate limit the cache is kept as it is, and the skip is reported
    # only when some instrument has no details at all.
    def refresh_instruments!(etoro_account)
      ids = instrument_ids(etoro_account)
      return if ids.empty?

      cached = etoro_item.instruments_map

      if rate_limited?
        skip_after_rate_limit(:instrument_metadata) if (ids - cached.keys).any?
        return
      end

      fetched = provider.fetch_instruments(ids.map(&:to_i)).each_with_object({}) do |instrument, map|
        id = field(instrument, "instrumentID").to_s
        next if id.blank?

        map[id] = {
          "symbol" => field(instrument, "symbolFull"),
          "name" => field(instrument, "instrumentDisplayName"),
          "type_id" => field(instrument, "instrumentTypeID"),
          "exchange_id" => field(instrument, "exchangeID")
        }.compact
      end

      merged = cached.merge(fetched) { |_id, stored, latest| stored.is_a?(Hash) ? stored.merge(latest) : latest }
      etoro_item.update!(raw_instruments_payload: merged) if merged != cached

      undescribed = ids - merged.keys
      capture_undescribed_instruments(etoro_account, undescribed) if undescribed.any?
    rescue Provider::Etoro::ApiError => e
      capture_partial_failure(:instrument_metadata, e, etoro_account)
    end

    # eToro answered without these instruments. Their positions and trades
    # are left out, and their value counts as cash, until it describes them.
    def capture_undescribed_instruments(etoro_account, ids)
      @partial_failures << {
        what: :instrument_metadata,
        message: I18n.t("etoro_items.sync.partial_failures.instruments_not_described", count: ids.size)
      }

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::Importer - eToro returned no details for #{ids.size} instrument(s); their positions and trades are not imported.",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: { instrument_ids: ids.first(100), count: ids.size }
      )
    end

    def instrument_ids(etoro_account)
      records = Array(etoro_account.raw_positions_payload) + Array(etoro_account.raw_trades_payload)
      records.filter_map { |record| field(record, "instrumentID")&.to_s.presence }.uniq
    end

    # Daily prices for the account's past holdings, once its instruments are
    # described (see EtoroItem::PriceHistoryImporter). Like the histories,
    # what eToro does not send now, a later sync fetches, and the positions
    # and balances saved before them stand whatever happens to them, a key
    # the price endpoints refuse among it: the account's own endpoints have
    # just taken it.
    def import_price_history!(etoro_account)
      if rate_limited? && etoro_account.current_account
        skip_after_rate_limit(:price_history) if instrument_ids(etoro_account).any?
        return
      end

      result = EtoroItem::PriceHistoryImporter.new(etoro_item, etoro_account, provider: provider).import
      @partial_failures.concat(result.partial_failures)
      @rate_limited_at ||= result.rate_limited_at
    rescue => e
      @partial_failures << { what: :price_history, message: e.message }

      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "EtoroItem::Importer - Failed to import the price history: #{e.class} - #{e.message}",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: { error_class: e.class.name, backtrace: Array(e.backtrace).first(5) }
      )
    end

    # eToro counts requests per user key, and both histories draw on one
    # quota. Once it throttles a fetch, the remaining ones are left to the
    # next sync rather than each waiting out a Retry-After of its own.
    def rate_limited?
      @rate_limited_at.present?
    end

    def skip_after_rate_limit(what)
      @partial_failures << { what: what, message: I18n.t("etoro_items.sync.partial_failures.skipped_after_rate_limit") }
      nil
    end

    def capture_partial_failure(what, error, etoro_account)
      @rate_limited_at ||= Time.current if error.is_a?(Provider::Etoro::RateLimitError)
      @partial_failures << { what: what, message: error.message }

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::Importer - Failed to fetch #{what.to_s.humanize(capitalize: false)}: #{error.message}. Keeping the stored copy.",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: { status_code: error.status_code, error_class: error.class.name }
      )
    end

    def capture_truncated_trade_history(etoro_account, window_start, trades)
      @partial_failures << {
        what: :trade_history,
        message: I18n.t("etoro_items.sync.partial_failures.trade_history_truncated", pages: MAX_TRADE_HISTORY_PAGES)
      }

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::Importer - Trade history still had trades after #{MAX_TRADE_HISTORY_PAGES} pages; older trades were not fetched.",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: {
          min_date: window_start.iso8601,
          pages: MAX_TRADE_HISTORY_PAGES,
          trades: trades.size,
          oldest_close: trades.filter_map { |trade| field(trade, "closeTimestamp") }.min
        }
      )
    end
end
