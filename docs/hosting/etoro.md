# Setting Up eToro

[eToro](https://www.etoro.com) offers a public API that reports your own portfolio. You
create a read-only key pair on eToro and give it to Sure, which then talks to eToro
directly on your behalf.

> [!NOTE]
> The integration reads your **real** trading account only. eToro's virtual (demo)
> portfolio, eToro Money and other account types are not imported. The trading account
> must be held in US dollars, as eToro's investment accounts are; a sync of an account
> eToro reports in another currency fails and says so, without importing anything.

## 1. Create an API Key

1. On eToro, go to **Settings > Trading > API Key Management** and choose **Create New Key**.
2. Pick the **Real** environment and the **Read** permission. eToro asks you to confirm
   with a code it sends you.
3. Copy the public API key and the user key eToro generates. A key with the Read
   permission cannot place trades or move money.

## 2. Add eToro to Sure

1. In Sure, go to **Settings > Bank sync** and find the **eToro** panel.
2. Paste the public API key and the user key, then save.
3. The first sync discovers your trading account. Create a new investment account from it,
   or link it to an existing manual investment account. Balances you recorded on that
   account before linking it are kept: eToro's daily balance is not recorded on those days.

## 3. What Is Imported

- **Balance**: the trading account's equity as eToro reports it (cash, the margin in open
  positions and their unrealised P&L), in US dollars.
- **Holdings**: real assets — stocks, ETFs and crypto — held directly or through
  copy-trading. Each security is one holding, valued at eToro's figures. eToro sometimes
  lists one stock on two lines, such as `ABCD` and `ABCD.RTH`; both count towards the same
  holding. A position eToro stops reporting is closed in Sure on the next sync. A stock
  listed outside the US stays on its own exchange (`QZX.L` in London is not `QZX` in
  New York), even when your price provider only knows the ticker elsewhere; if no provider
  lists it there, it is kept there with eToro's prices (see [Price history](#price-history)).
- **Trades**: each real-asset position becomes a buy on the day it opened and a sell for
  each close, partial closes included.
- **Daily account value**: eToro's end-of-day equity for the last 12 months, recorded as
  balance reconciliations. The account's charts include this history even where it
  predates your first trade.
- **Price history**: eToro's daily prices of the securities the account holds or held
  that no price provider covers, so their past value follows the market instead of
  staying at the last trade's price (see [Price history](#price-history)).

Every sync updates the balance and positions, fetches only the trades, daily values and
prices that are new since the last one, and refreshes eToro's details of every instrument
in use. When eToro renames a ticker or moves a listing, the next sync moves the holding and
its trades to the new security, together with the holdings eToro reported on earlier days. A
holding you moved to another security in Sure keeps its trades there; if eToro then
renames its instrument, both move to the new security. The holdings eToro reported on
earlier days stay on the old security, and those days count the moved units twice, when:

- another instrument is still on the old security;
- the instruments that were on it now go to different securities; or
- it still has trades of a position eToro no longer lists, as after linking the account to
  a new eToro connection, whose trade history starts later.

## Holdings, totals or per copy portfolio

Each linked eToro account has a **Show as** setting in its eToro card on the Accounts page
(admins only). It can be changed when no sync is running; changing it starts a sync that
rebuilds the account.

- **Holdings** (the default) imports the holdings, trades and price history described
  above.
- **Totals only** shows the account as eToro reports it as a whole. On every day of eToro's
  daily account value, and today, the account's balance is eToro's total and its cash is
  eToro's cash; everything else, held directly or through copy-trading, is a single holding
  named "eToro investments", worth the total less the cash. Use it when the holdings history
  is wrong, as when most positions are copy-trading mirrors whose closes eToro's trade
  history leaves out.
- **Per copy portfolio** shows each copy-trading portfolio as an account of its own, named
  "eToro copy: " and the trader you copy, beside the eToro account, which keeps the
  positions you opened yourself and your available cash (see below).

In totals mode Sure keeps no eToro trades, per-position holdings or eToro prices for the
account: switching to it deletes them, and the securities eToro priced for the account go
back to Sure as they do when the account is unlinked. A trade you added by hand stays. The
investments holding has no cost basis, so the account shows no investment returns, and as a
holding cannot be worth less than nothing, a day whose cash exceeds its total shows a zero
holding and the total as cash. A day eToro sent no figures for keeps the investments value of
the day before it and the cash of the day after it; a day with a total but no cash keeps the
total and the investments value of the day before. The account's history starts the day
before eToro's first daily value. Sure still fetches the positions and the trade history, but
no instrument details or prices.

Switching back to **Holdings** removes the investments holding and rebuilds the holdings and
trades from the positions and trades Sure has stored, then fetches the price history again.
The holdings eToro reported on earlier days are not restored; the history before today is
worked back from the trades. Trades that only an earlier eToro connection of the account
stored are not restored either.

### Per copy portfolio

Each copy account holds the copy's open positions, valued at eToro's figures, and the cash
the copy holds uninvested; the eToro account holds the positions you opened and the rest of
the account. Together they are eToro's total. Each copy eToro lists becomes an account to
set up from the eToro card (**Set up accounts**), and so does a copy you start later. A copy
you do not set up stays in the eToro account, as part of a holding named "eToro
investments".

eToro reports no past figures of a copy, so Sure records each copy, and the positions you
opened, on every sync, whatever the account is shown as, from the first sync after this
version is installed. What is exact, and from when:

- **Before the first day Sure recorded the account** the eToro account holds the whole
  account, as in totals mode: eToro's daily total and cash, with the rest as the
  investments holding. The copy accounts have no history then.
- **From the first day a copy was recorded** its account's daily value is the copy's value
  that day, as the day's last sync saw it, and its holdings are the copy's positions that
  day. A day no sync ran keeps the day before. The eToro account's daily value is eToro's
  daily total less the copies', and its holdings are the positions you opened that day.
  As Sure records a copy during the day and eToro's daily total is taken at the end of it,
  the eToro account absorbs the difference, so the accounts always add up to eToro's total.
- **Money moving.** On a copy's first day its positions move from the eToro account to the
  copy account as the copy's holdings, and its cash, the rest of its value, as a transfer,
  so the copy account holds nothing the day before. Money you add to or take out of a copy
  later, as eToro counts it between two syncs, moves as a transfer on the day Sure sees it.
  When you stop copying, the copy's last recorded value moves back on the day Sure no longer
  finds the copy; the copy account stays, with its history, at zero from then on, and the
  setup page shows it as closed. A copy closed before you set it up is no longer offered. A
  sync later on a copy's first day updates that day's transfer to the copy's latest cash.
- **Disabling a copy account** leaves it as it was that day: net worth counts it until the
  day before, as for any disabled account, and its value stays out of the eToro account,
  so from that day net worth no longer includes the copy. Enabling it again brings it up
  to date on the next sync. Deleting a copy account gives its value back to the eToro
  account over the whole history, as if the copy had not been set up. Unlinking one does
  the same, while the unlinked account stays as a manual account Sure no longer updates;
  delete it to keep the copy from counting twice.

Sure keeps no trades of eToro's positions in this mode, as the closed-trade history does
not say which copy a position belonged to; the past holdings come from Sure's own records
only. The positions' cost basis is known only for today. eToro's prices are still fetched
for the securities the eToro account and its copy accounts hold, as all of them are your
own accounts, in any mode (so switching away from copies keeps the prices), and still not
for a security another of your accounts holds.

Switching from per copy portfolio to holdings or totals removes the transfers and the past
holdings the split wrote from the eToro account, and empties each copy account: its
holdings, eToro entries and balance go, while the account stays linked. A disabled copy
account is emptied too, so the eToro account, which then counts the copy's positions, is
not counted twice with it. Copies not set up are dropped. Switching back rebuilds the copy accounts and the split from Sure's records, so
the history is the same as before; a copy you have to set up again is offered once more.

## Price history

Sure values past holdings at each day's price. A security a price provider covers
(**Settings > Self-Hosting**) takes its prices from that provider as usual. For the ones no
provider covers, which is common for listings outside the US, Sure stores eToro's own daily
prices of the instruments in your account until a provider is found for them.

**Prices from eToro.** These prices are eToro's market data, fetched with your key for your
own use (see the terms below).

- **How far back**: from the day the account first bought an instrument until today, or
  until its last sale once it is no longer held. A trade an earlier eToro connection of the
  account stored counts, as after linking the account to a new connection whose trade
  history starts later; a trade added by hand does not. Each trading day takes eToro's
  close, and a day without one, such as a weekend or the venue's holiday, the close before
  it, as price providers' prices do. The day still trading is left for a later sync, and
  today's value is eToro's own, from the open positions.
- **Which price**: eToro's bid at the end of its trading day, which closes at 17:00 New York
  time for every venue. It can differ a little from the exchange's official closing price.
- **Splits**: eToro's daily prices are as traded, so a split shows in them as a jump. Sure
  compares them with eToro's split-adjusted history to find each split and stores every
  price on today's shares, as price providers do. A position closed before a split goes
  on today's shares too: its units are scaled by the split and its price by the inverse,
  for the same money, so the holdings history counts one kind of share throughout. One
  closed on the day eToro's prices switch goes on the shares its closing price was on.
  Splits of n for 1 or 1 for n up to 1000 and 3 or 5 for 2 are applied, and so, within
  eToro's daily history of about the last four years, are bonus issues of one share for
  every 3, 4, 5, 10 or 20 held; a change in eToro's history that matches none of them is
  logged and not applied.
- **Later splits**: a split restates the earlier prices and trades on the sync that finds
  it. eToro's split-adjusted history can show a split a session or more after its prices
  switch, so a jump in the prices that it does not explain yet is checked again on the
  following syncs for up to a week, and then taken as a move in price. A split too small to
  make the prices jump by about 30%, such as a bonus issue, is found by a check against
  that history about once a week while the instrument is held (see Requests below). One
  that history shows only on the newest day read is taken once a later day confirms it, as
  a single day off in either of eToro's histories looks the same.
- **Securities a price provider covers**: eToro's prices are not stored for them, but their
  closed positions follow eToro's splits too, unless the provider stored its prices before
  a split. Sure keeps those as the provider sent them, on the shares of the time, so the
  positions closed before that split keep the units they closed with.
- **Currency**: prices are stored in the currency the listing trades in: pounds for London,
  which eToro quotes in pence, euros, Hong Kong dollars and so on. Sure converts them into
  the account's currency with its exchange rate provider, so it stores a price only for the
  days it has an exchange rate for; when rates for a currency are missing, the sync summary
  says so and the next sync tries again.
- **Which securities**: only those this eToro account alone holds or trades that are kept
  without market prices, as no price provider was found for them or Sure's regular check of
  price providers stopped finding one, and that have no prices yet: one whose provider
  stopped finding it keeps the provider's earlier prices, and eToro adds none. That check goes on for them, but a check that fails
  no longer counts against them or deletes eToro's prices, and once one finds a provider,
  the provider's prices take over. Sure deletes the prices it stored from eToro then, and
  when another account starts holding or trading one, you choose a price provider for it,
  eToro stops pricing it, or you unlink or disable the account or delete the connection,
  unless another eToro connection linked to an account prices the security. Unlinking the
  account or deleting the connection deletes them at once, disabling the account on the
  next sync even if eToro refuses it, and the others on the next sync.
- **Requests**: the first sync reads each instrument's history once, with up to three
  requests for each instrument. Later syncs read only the days since, about one request for
  each instrument still held once its trading day has ended, and check for splits again
  when the prices jump, and about once a week with one more request for each instrument
  still held. A day eToro has not sent yet is asked for again once another session has
  ended, or six hours after the last time. A sync stops at about 300 such requests, spaced
  to stay within eToro's limits, and leaves the rest to the next sync. The weekly checks
  take only the requests a sync has to spare, the instruments checked longest ago first, so
  with more than about 250 instruments held a round of them takes longer than a week. An
  instrument eToro fails to answer for is asked after the others on the next sync; after
  three failures in a row the rest wait for the next sync. A split check eToro fails to
  answer is made on a later sync, after the other checks, and after three in a row the
  other checks wait for the next sync too, while the prices are still read.

eToro's API terms allow its market data for your own use with your own account. Sure
therefore asks only for the instruments in your account, with your key, uses the prices
only for the securities that account alone holds, and deletes them when that ends. Another
account that starts holding one is valued with them until the next sync notices it and
deletes them. Whenever Sure deletes eToro's prices of a security, the accounts that hold or
trade it have their history worked out again.

## Limitations

- **No cash movements.** eToro's API does not report deposits, withdrawals, dividends or
  fees. The daily account values keep the balance history right for the last 12 months.
  Before that window there are no daily values, so the history Sure shows there is
  synthetic: it is worked back from the trades alone, as if no money had moved in or out.
- **CFDs count as cash.** Positions eToro does not hold as real assets are not holdings:
  every leveraged or short position, every position in currencies, commodities and
  indices, and any unleveraged buy of a stock, ETF or crypto that eToro opened as a CFD.
  Their equity is part of the cash balance, which keeps the total equal to eToro's, so
  their profit and loss shows in the cash balance but not in Sure's investment returns.
  Money a copy-trading portfolio holds uninvested is cash too. Real assets held through
  copy-trading are holdings like any other, and their profit and loss counts in the
  returns.
- **Closed trades from the last 12 months only.** Positions closed before that are not
  imported. A position still open is imported with its buy on the day it opened, however
  long ago.
- **Some closed CFDs look like real assets.** eToro's trade history does not say whether a
  closed position was a CFD. Sure knows for positions it saw open on an earlier sync, and
  treats a position it never saw open as a real asset only when it was an unleveraged buy
  of a stock, ETF or crypto. A CFD of that kind is then imported as a buy and a sell, with
  a holding between the two dates. On the first sync that is every such CFD closed in the
  last 12 months, however long it was open; after that, only one that opens and closes
  between two syncs.
- **Stock splits.** Sure learns of a split from eToro's prices (see
  [Price history](#price-history)), which can switch to the new shares a trading day before
  the exchange does. Closes that a new eToro connection's trade history no longer lists
  stay on the shares they were stored on. Prices a price provider stored before a split
  stay as the provider sent them, on the old shares, while eToro restates open positions
  on the new ones, so the holdings history before such a split values those positions at
  the split's ratio times their worth.
- **Rate limits.** eToro allows 60 requests a minute per user key for the account and its
  history, and 120 a minute each for its market data and its price history. When eToro
  throttles a sync, the history, instrument details and prices it could not fetch are left
  for the next sync, and the sync summary says so.

## Troubleshooting

**Connection requires update**
eToro rejected the keys: they were deleted, expired, or lack the Read permission. Create a
new key on eToro and update it in the eToro panel.

**The sync summary lists errors for the trade history or the daily account value**
eToro did not return that history during the sync. Sure keeps what it stored before, and
the next sync tries again.

**The sync summary lists the price history**
eToro did not send some prices or refused the key for them, the sync reached its request
limit, or Sure has no exchange rates for a currency. The prices already stored stay, and
the next sync carries on. For missing exchange rates, check the exchange rate provider under
**Settings > Self-Hosting**.

**A position is missing from the holdings**
Sure imports an instrument once eToro has described it. Until then its position and trades
are left out and its value counts as cash, whether eToro's instrument details could not be
fetched or eToro answered without them; the sync summary lists this under "Instrument
details", every sync asks again, and holdings eToro stopped reporting stay open meanwhile.
A position eToro opened as a CFD, including an unleveraged buy of a stock, ETF or crypto,
counts as cash and never becomes a holding (see Limitations).

**Sync errors**
Provider sync failures are captured in Sure's debug log (super admin: **Settings > Debug**),
filtered by the `etoro` provider key.
