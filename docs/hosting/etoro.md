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
  lists it there, it is kept without market prices and valued at eToro's figures.
- **Trades**: each real-asset position becomes a buy on the day it opened and a sell for
  each close, partial closes included.
- **Daily account value**: eToro's end-of-day equity for the last 12 months, recorded as
  balance reconciliations. The account's charts include this history even where it
  predates your first trade.

Every sync updates the balance and positions, fetches only the trades and daily values
that are new since the last one, and refreshes eToro's details of every instrument in use.
When eToro renames a ticker or moves a listing, the next sync moves the holding and its
trades to the new security, together with the holdings eToro reported on earlier days. A
holding you moved to another security in Sure keeps its trades there; if eToro then
renames its instrument, both move to the new security. The holdings eToro reported on
earlier days stay on the old security, and those days count the moved units twice, when:

- another instrument is still on the old security;
- the instruments that were on it now go to different securities; or
- it still has trades of a position eToro no longer lists, as after linking the account to
  a new eToro connection, whose trade history starts later.

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
- **Stock splits.** eToro restates an open position's units and price after a split, but
  a part of the position closed before the split can keep the units it closed with. Sure
  adds both into the position's buy, so between the buy and that close the holdings
  history counts the closed part in pre-split units (too few after a split, too many after
  a reverse split), and the difference shows as cash. Market prices Sure stored before a
  split are not adjusted either, so the history around a split can be off.
- **Rate limits.** eToro allows 60 requests a minute per user key, shared across most of its
  endpoints. When eToro throttles a sync, the history and instrument details it could not
  fetch are left for the next sync, and the sync summary says so.

## Troubleshooting

**Connection requires update**
eToro rejected the keys: they were deleted, expired, or lack the Read permission. Create a
new key on eToro and update it in the eToro panel.

**The sync summary lists errors for the trade history or the daily account value**
eToro did not return that history during the sync. Sure keeps what it stored before, and
the next sync tries again.

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
