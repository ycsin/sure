# Setting Up moomoo

[moomoo](https://www.moomoo.com) is a brokerage run by Futu, with entities in Singapore,
the US, Hong Kong, Malaysia, Australia, Japan and Canada. Sure reads moomoo accounts
through [moomoo OpenAPI](https://open.moomoo.com/api/overview/getting-started), with
read-only OAuth access that you grant on moomoo's own consent page. Sure never stores
your moomoo password and has no code that places or cancels orders.

This provider is an **alpha prototype**. It has been built from moomoo's documentation
and has not yet been run against a live account; see
[Unverified assumptions](#unverified-assumptions).

## Before you start

- You need a moomoo account that is fully opened. You don't need a developer account or
  an API key.
- Sure registers an OAuth client with moomoo for its own address, so the address you use
  to open Sure is the one moomoo sends you back to. The moomoo panel in
  **Settings > Providers** shows it, for example
  `https://sure.example.com/moomoo_items/callback`.
- Behind a reverse proxy that doesn't pass the public host and scheme on to Sure, set
  `MOOMOO_REDIRECT_URI` to the public callback address.

## 1. Connect

1. In Sure, go to **Settings > Providers** and open **moomoo**.
2. Click **Connect moomoo**. Sure registers itself with moomoo and opens moomoo's
   consent page.
3. Sign in to moomoo. Tick only **trade:read** and the trading accounts you want in Sure,
   then confirm. Sure needs `trade:read` and at least one account; it doesn't need
   `quote:read`. Leave **trade:write** unticked. A consent that lets Sure place orders,
   or lacks `trade:read` or an account, is refused: Sure keeps nothing from it, and a
   connection you already had stays as it was.
4. You come back to Sure's **Set Up moomoo Accounts** dialog while the first sync
   discovers your accounts. Click **Refresh** until they appear, then create a Sure
   account for each, or link one to an existing manual account of the same type: a cash
   account for a moomoo cash account (see below), an investment account for the others.

To share more trading accounts, or fewer, with a connection you already have, click
**Change accounts** on its row in the moomoo panel (or in its menu on the Accounts page).
It runs moomoo's consent again for the same connection, and your linked accounts keep
their history.

Clicking **Connect moomoo** again connects another moomoo login. A consent you abandon
leaves a connection marked **Waiting for authorization**, which the next **Connect
moomoo** reuses. If two **Connect moomoo** consents run at once, the first to finish is
kept and the other asks you to connect again.

## 2. What is imported

**Accounts.** Each trading account you shared becomes a moomoo account in Sure. A
securities account, including a universal account that can also trade futures or
crypto, can be linked as an Investment (brokerage) account, or, once split by currency,
as cash and stocks accounts (see below). Futures-only and crypto accounts, and moomoo
Japan margin and derivative accounts, are discovered and listed as not supported yet.

**Account currency.** moomoo converts an account's totals into the currency Sure asks
for. Sure asks for the home currency of the moomoo entity that holds the account:

| moomoo entity (`security_firm`) | Account currency |
| --- | --- |
| moomoo Singapore (`FUTUSG`) | SGD |
| Futu Securities Hong Kong (`FUTUSECURITIES`) | HKD |
| moomoo US (`FUTUINC`) | USD |
| moomoo Malaysia (`FUTUMY`) | MYR |
| moomoo Australia (`FUTUAU`) | AUD |
| moomoo Japan (`FUTUJP`) | JPY |
| moomoo Canada (`FUTUCA`) | USD (moomoo has no CAD) |

If moomoo answers in a different currency before you link the account, the account takes
that currency. Once linked, an account keeps its currency: a balance reported in another
currency is not applied, and the sync logs an error instead.

**Balance.** The account balance is moomoo's total net assets. Cash is the total minus
the holdings Sure imports, valued with Sure's exchange rates, so anything Sure doesn't
model (short positions, options, futures, forex) is counted as cash and the total stays
equal to moomoo's. Without an exchange rate, Sure uses moomoo's own cash figure.

**Accounts in more than one currency.** Sure keeps one cash balance per account, in the
account's currency. A moomoo account that holds more than one currency, for example a
moomoo Singapore account with Singapore dollars and US dollars, is split by currency into
a cash account for each currency and a stocks account for each currency with positions or
trades, each in its own currency: for example `moomoo SG ••3456 (SGD cash)`,
`moomoo SG ••3456 (USD cash)` and `moomoo SG ••3456 (USD stocks)`. An account counts as
holding a currency when it has cash or positions in it, or trades or cash movements in it
that Sure has stored.

An account that only ever holds one currency, its home currency or another, stays one
Investment account with its cash and its stocks, and pays for its trades from its own
cash, as most brokerage accounts in Sure do. It is split only once a second currency
appears.

- **Cash accounts** get their currency's cash log: deposits, withdrawals, dividends
  (including those of money market funds such as moomoo Cash Plus), taxes, fees and
  currency exchanges. Their balance is the currency's cash, which counts the money market
  funds moomoo sweeps idle cash into.
- **Stocks accounts** get their currency's positions and trades. Each trade is paid from
  the cash account of its currency: Sure books the fill's value out of the cash account
  for a buy, or into it for a sell, and the opposite amount in the stocks account, and
  links the two as a transfer. The stocks account's cash stays at zero, and the cash
  account's history shows the buys and sells. The cash side is dated in the broker's
  timezone, like the cash log, and the stocks side on the trade's date, so a US trade
  made after midnight Singapore time is paid on the Singapore day after it. moomoo reports fees per order only, so the
  transfers carry none; the cash log's fee rows reach the cash account on their own. A
  transfer you unlink stays unlinked. Positions Sure doesn't import, such as options,
  count as the stocks account's cash, so its total stays equal to moomoo's, except on
  the days before the split that are restated (see below).
- Cash accounts are cash (Depository, checking) accounts, so their money shows under
  Cash in net worth and on the Accounts page, like the cash a bank holds for you. Stocks
  accounts are Investment (brokerage) accounts. An existing manual cash account can be
  linked as a cash account, and a manual investment account as a stocks account.
- The transfers that pay for trades are plain funds movements on both sides, not
  investment contributions, so they stay out of budgets: the money only moves inside
  your moomoo account. Sure marks the buys' payments the way you would by turning off
  **Investment contribution** on a transfer, so later syncs and Sure's own repairs keep
  them so; you can turn it on for any of them, and that choice is kept too.
- A deposit from your bank account, or a withdrawal to it, moves money between two cash
  accounts. Sure imports it as a funds movement without an activity label; once it is
  matched with the bank's side as a transfer, both sides are funds movements, as for any
  transfer between your own cash accounts. A currency exchange between two moomoo cash
  accounts is a funds movement too, even when one of them is a manual investment account
  you linked, since it only converts cash inside your moomoo account.
- A cash account that Sure set up as an Investment account before cash accounts were
  cash accounts becomes a cash account on the next sync. It keeps its name, its page,
  its link to moomoo, and every transaction, transfer and balance; it moves from
  Investments to Cash on the Accounts page and in net worth, and shows categories
  instead of activity labels. Its deposits and withdrawals lose the Contribution and
  Withdrawal labels, and deposits the investment contribution kind and the Investment
  Contributions category those labels gave them. Whatever you changed yourself stays:
  a kind or category you chose, a category a rule set, or a label you picked; editing
  only a deposit's notes or name keeps the rest from being reset. A transfer to or from
  it takes the kinds Sure gives a transfer between cash accounts, unless you chose its
  kind. An Investment account you created yourself and linked to a moomoo cash account
  stays as it is. A cash account that still holds trades of its currency's stocks
  account, as the account you already linked can at the split, becomes a cash account
  in the sync that moves them. A trade you edited moves only once you set up that stocks
  account; until then the cash account stays an Investment account, and each sync
  notes in the debug log that it is waiting on trades or holdings.
- The account you already linked keeps its link and its history. If its currency has
  positions or trades it becomes that currency's stocks account, and the currency's cash
  shows up in **Set Up moomoo Accounts** as a new cash account; otherwise it becomes the
  currency's cash account. Each other account shows up there to create or link.
- Until a currency's cash account is set up, its cash and cash log aren't imported
  anywhere, as for any account not set up: the stocks account doesn't take that cash,
  and still books its side of each trade. Once the cash account is set up, the cash log comes
  in there and the trades are paid from it. Until a stocks account is set up, its
  positions and trades aren't imported anywhere, though the cash account still books
  what each trade paid or received. The sync summary lists each account still to set
  up; until then, your accounts in Sure come to less than moomoo's total.
- Each sync keeps the day before's balance as a reconciliation that earlier days are
  worked back from. When the account you already linked becomes a stocks account, the
  ones it recorded before the split, which still counted its cash and any other
  currency, are restated as the value of the holdings imported that day, so the cash
  isn't counted again on every earlier day once the cash account has it; positions Sure
  doesn't import, such as options, are left out of those days. One for a day with no
  holdings imported is removed, as are those of an account that becomes a cash account.
  A balance you entered by hand, or changed by hand in any way after a sync recorded it,
  even only its notes, is left as it is, so it may still count the cash; edit its amount
  if it does.
- Trades and cash movements that a linked account was given in another currency before
  the split are removed from it, and are imported into that currency's account once you
  set it up. Its holdings are removed too; as moomoo only reports today's positions, the
  new account gets today's, and its earlier days' holdings are worked back from its
  trades.
- A trade or cash movement you edited stays where it is until the account it belongs in
  is set up, and then moves there.
- A currency exchange is a transfer between the two currencies' cash accounts, once both
  are set up.
- Today's balance of a cash account is its currency's cash; a stocks account's is the
  market value of its positions. moomoo reports cash per currency as buying power, which
  includes moomoo Cash Plus. Its total comes to about 99% of the account's cash and fund
  assets, so Sure scales each currency's figure to make them add up exactly; together,
  the accounts come to moomoo's total, with the positions valued in their own currencies.
  When the figures are more than 5% apart, or Sure has no exchange rate to compare them,
  Sure doesn't divide them: an account not split yet stays whole, and a split one keeps
  its last balances, with an error in the sync summary.
- Earlier balances are worked back from each account's own trades, transfers and cash
  movements. The growth of a money market fund such as moomoo Cash Plus isn't in the cash
  log, so the further back a day is, the more a cash account's balance can be off by that
  growth.

**Holdings.** Long stock and fund positions, each in the currency it trades in, so a US
share in a Singapore account is a USD holding. A position moomoo stops listing, or lists
with nothing left, is closed on the day of that sync. The cost basis is the average cost
per share, worked out from moomoo's market value and unrealized P&L; moomoo's own
"diluted" cost, which falls as you sell at a gain, is not used. When moomoo marks its
cost invalid or leaves out the unrealized P&L, Sure averages the imported buys instead.
Sure looks each code up by ticker and exchange:

| moomoo code | Ticker | Exchange (MIC) | Trade date timezone |
| --- | --- | --- | --- |
| `SG.D05` | `D05` | SGX (`XSES`) | Asia/Singapore |
| `US.AAPL`, `US.BRK.B` | `AAPL`, `BRK.B` | any US exchange | America/New_York |
| `HK.00700` | `0700` | HKEX (`XHKG`) | Asia/Hong_Kong |
| `SH.600519`, `SZ.000001` | `600519`, `000001` | Shanghai (`XSHG`), Shenzhen (`XSHE`) | Asia/Shanghai |
| `JP.7203` | `7203` | Japan Exchange (`XJPX`) | Asia/Tokyo |
| `AU.BHP` | `BHP` | ASX (`XASX`) | Australia/Sydney |
| `BMS.1155` | `1155` | Bursa Malaysia (`XKLS`) | Asia/Kuala_Lumpur |
| `KR.005930` | `005930` | Korea Exchange (`XKRX`) | Asia/Seoul |
| `CA.SHOP` | `SHOP` | any Canadian exchange | America/Toronto |

A code Sure can't look up is kept as an offline security, named as moomoo names it. Once
a code has a security in an account, later syncs keep it there rather than looking it up
again, so a search that fails one day can't move its holdings and trades.

**Trades.** Every buy and sell fill in each securities market of the account
(Singapore, US, Hong Kong, China A-shares, Japan, Australia, Malaysia, Canada and
Korea), going back up to two years. Each fill is a trade in its order's currency, dated
in its market's timezone. A fill moomoo later changes is updated, and one it cancels
removes its trade, unless you edited that trade in Sure.

### Cash movements

moomoo's cash log becomes transactions: bank deposits and withdrawals, dividends,
coupons, taxes withheld, fees, and currency exchanges, each in the currency of the balance
moomoo shows beside it and dated in the broker's timezone (Singapore time for moomoo SG).
In an account split by currency, each row goes to its currency's cash account, and the
two rows of a currency exchange are linked as a transfer.
Trade rows are skipped, as the trades come from the fills, and so are subscriptions to
and redemptions from money market funds such as moomoo Cash Plus, which count as cash.

## 3. Not imported yet

- **Fees on trades.** Trades carry no fees; the cash log's fee rows come in as separate
  transactions instead (see Cash movements).
- **Short sales and buy-backs, options, futures, forex and crypto**, accounts that only
  trade futures or crypto, and moomoo Japan margin and derivative accounts, whose
  balances moomoo reports one asset category at a time.
- **Balance history before the trades Sure has.** moomoo has no daily balance history,
  so earlier values come only from the imported trades.

## 4. Syncing

moomoo allows 100 requests a minute from one IP address. Sure spaces each sync's
requests at least 0.7 seconds apart, waits for moomoo's `Retry-After` when it is rate
limited, and spends at most 250 requests per sync. The most important data comes first:
accounts, balances and positions, then recent trades and cash log entries, then older
history. When the budget runs out, Sure keeps what it fetched and the next sync carries
on; the connection shows **Older history still importing** until the two years are in.

A first sync of a Singapore universal account trading in four markets takes about 90
requests, roughly two minutes. After that, each sync re-reads the last week of trades,
to pick up fills moomoo amended, and the last three days of cash log entries, which
takes about 16 requests. After a longer pause, a sync reads the newest 89 days first. The
rest of the time since the last sync is read with the older history, ahead of it, and
each sync picks up where the previous one stopped.

Fills and orders are fetched in windows of 89 days, inside moomoo's 90-day limit per
query. A window with more than 2,000 fills in one market is read on from its oldest fill
with further requests. A market whose trade history fails on five syncs in a row stops
showing as importing, but every sync still retries it.

If moomoo won't answer for one shared account, the others still sync; that account keeps
its last balance and holdings, and the error shows in the connection's sync summary.
Only when no shared account can be read does the sync fail. Either way, an account
moomoo doesn't answer for on five syncs in a row no longer counts as importing older
history. An account you stopped sharing keeps the balance and holdings of the day it
was last fetched, as does one whose balance moomoo reports in another currency or
without a total. That one's new trades, even if you link the account meanwhile, are
imported with its next usable balance, so the holdings history before them isn't
counted twice.

## 5. Reconnecting

Access tokens last two hours and are renewed automatically; if moomoo's token endpoint
is briefly unavailable, Sure keeps using the current token until it expires. moomoo ends a
connection that hasn't been used for 14 days, so keep automatic syncing on; the moomoo
panel warns after 10 days without a sync. When moomoo no longer accepts the connection,
or the permissions you granted aren't enough, the connection shows **Reconnect required**
and a **Reconnect** button, which runs moomoo's consent again for the same connection.
Your linked accounts are matched up again by moomoo's account id, so they keep their
history.

If you open Sure at a new address, the next **Connect moomoo**, **Reconnect** or
**Change accounts** there registers Sure again for that address. An existing connection
keeps its registration, and keeps syncing, until that consent completes. A consent then
still open at the old address has to be started again.

## 6. Removing a connection

**Remove** in the moomoo panel unlinks the accounts and deletes the connection; the
accounts in Sure keep their data. moomoo has no API to revoke access, so also remove
Sure in the moomoo OpenAPI dashboard
([open.moomoo.com/dashboard](https://open.moomoo.com/dashboard)).

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `MOOMOO_REDIRECT_URI` | derived from the request | Callback URL Sure registers with moomoo. Set it when a proxy doesn't forward the public host and scheme. |
| `MOOMOO_MAX_REQUESTS_PER_SYNC` | `250` | Requests one sync may make before leaving the rest for the next sync. |
| `MOOMOO_MIN_REQUEST_INTERVAL` | `0.7` | Seconds between the requests of one sync. Raise it if other clients share Sure's IP address. |
| `MOOMOO_HISTORY_DAYS` | `730` | How far back trades are imported (at most 730). |

## Unverified assumptions

These come from moomoo's documentation, which shows only examples for US accounts, and
need a live connection, ideally a moomoo Singapore universal account, to confirm:

1. A moomoo Singapore login can complete the consent, and the account comes back with
   `security_firm` `FUTUSG` and `enable_market` listing Singapore (6) and, for a universal
   account, the US (2), Hong Kong (1) and China A-shares (4).
2. moomoo accepts an `https` callback on your own domain, and `http://localhost:3000`.
   Its documentation only shows `http://localhost:60355/callback`. A refused address
   shows moomoo's reason when you click **Connect moomoo**.
3. moomoo accepts a `scope` when Sure registers. Sure registers again without one if
   moomoo refuses the request in any way; either way, the boxes you tick on the consent
   page are what limits access; moomoo documents no scope parameter for the consent page.
4. A cancelled consent comes back with OAuth's `error=access_denied`, and the token
   endpoint reports a dead refresh token as `invalid_grant` (a bare 400 or 401 is
   treated the same way). A refresh repeats the granted `scope`.
5. A refresh token lasts as long as it is used every 14 days (stated for moomoo's MCP
   server, assumed for OpenAPI).
6. Errors may come with HTTP 200 and `"s":"error"` or with a 4xx/5xx status; Sure
   handles both, and treats both HTTP 429 and error `-12011` as a rate limit.
7. The funds endpoint honours `currency=SGD` for a Singapore universal account and
   echoes it back. If not, see **Account currency** above.
8. Position values (`market_val`) are in each position's own `currency`, and positions
   cover every market of the account. Funds such as moomoo's cash management funds
   appear as `FUND` positions. `unrealized_pl` is measured against the average cost, as
   in moomoo's OpenD API, so market value less it is the cost of the position. An
   account with no positions returns an empty list or a null `d`.
9. `fills_history` and `orders_history` accept explicit 89-day ranges reaching two years
   back and list the newest rows first, so a window cut short resumes from its oldest row;
   `deal_id` is unique within an account; a fill's `updated_time` changes when moomoo
   changes or cancels it. Today's fills are read separately, in case the history lags.
10. Singapore codes look like `SG.D05`, Malaysian ones like `BMS.1155`.
11. Error `-12009` means a missing permission. On the account list, or on the balances
    or positions of every shared account, it asks you to reconnect; on one account of
    several, or on trades and cash logs, it is logged and the sync carries on.
12. The cash log outside moomoo SG: the timezone of `created_time` (Singapore time on
    moomoo SG, where the balance names each row's currency and fees are rows of their own).
13. Funds outside moomoo SG list cash per currency as `<market>_net_cash_power` (`us_`,
    `sg_`, `hk_`, `cn_`, `jp_`, `au_`, `my_`, `kr_`), including money market funds, and
    `cn_` is offshore yuan (CNH). On moomoo SG the per-currency figures add up to about
    99% of `cash` plus `funds_assets`; elsewhere a larger gap stops the split by currency.

Sync problems are logged under **Settings > Debug** with the source `moomoo`.
