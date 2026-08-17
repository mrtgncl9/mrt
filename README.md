# MT5 Expert Advisors

MetaTrader 5 (MQL5) Expert Advisors:

- **MA Cross EA** — a fast/slow Moving Average crossover trend-follower.
- **Scalper Multi-Entry EA** — a momentum-burst scalper that opens a
  batch of several small trades at once with a staggered take-profit
  ladder.
- **Grid Martingale EA** — a single-direction grid that adds
  progressively larger positions as price moves against it, closing the
  whole basket together on a profit target. **High risk — read its
  section below before using it.**
- **XAUUSD Scalper Basket EA** — a single-direction basket that adds
  same-side positions on a tight price grid, with lot size stepped up in
  tiers as account balance grows. **High risk, no per-trade stop loss —
  read its section below before using it.**

## Files

- `Experts/MA_Cross_EA.mq5` — MA crossover trend-following EA.
- `Experts/Scalper_MultiEntry_EA.mq5` — multi-entry momentum scalper EA.
- `Experts/Grid_Martingale_EA.mq5` — single-direction grid/martingale EA.
- `Experts/XAUUSD_Scalper_Basket_EA.mq5` — same-direction basket EA with
  balance-tiered lot sizing.

## Installation

1. Copy the `.mq5` file(s) you want to use into your MetaTrader 5 data
   folder, under `MQL5/Experts/` (in MetaEditor: `File → Open Data
   Folder → MQL5 → Experts`).
2. Open each file in MetaEditor and press **Compile** (F7). It should
   compile with 0 errors and 0 warnings.
3. In MetaTrader 5, open the **Navigator** panel (Ctrl+N), find the EA
   under **Expert Advisors**, and drag it onto any chart.

## Key design points

- **Magic number** (`InpMagicNumber`): every position the EA opens is
  tagged with this number, and the EA only ever looks at, modifies, or
  closes positions that both match this magic number *and* the chart's
  symbol. This lets it coexist safely with other EAs or manual trades on
  the same account.
- **Works on any symbol/timeframe**: no pip size, digits, minimum stop
  distance, or lot step is hard-coded — everything is read live from the
  broker via `SymbolInfoDouble`/`SymbolInfoInteger`, so the EA can be
  attached to any instrument.
- **Restart-safe**: the EA never trusts an in-memory variable to know
  "am I in a position?" — it always asks the trade server directly
  (`PositionGetTicket`/`PositionGetInteger`). The timestamp of the last
  bar it processed is also persisted with `GlobalVariableSet`/
  `GlobalVariableGet`, which MetaTrader saves to disk, so a terminal
  restart does not cause the EA to re-evaluate (and potentially
  re-trade) a bar it already handled.
- **Optimizer-friendly**: every parameter that defines the strategy is a
  plain `input` (no arrays, no complex structures), so all of them can be
  optimized directly in the Strategy Tester.

## v2 additions (loss-reduction / risk-management)

- Optional trend filter MA, minimum crossover-distance filter, and max
  spread filter — fewer, higher-quality signals.
- Optional ATR-based (volatility-adaptive) stop loss / take profit,
  falling back to fixed points.
- Optional percent-of-balance position sizing, falling back to a fixed
  lot size.
- Break-even stop move and a trailing stop, so open profit is protected
  instead of being given back.
- Daily profit target and daily max-loss "circuit breakers" that stop new
  trades for the rest of the day once hit — computed live from the
  account's own trade history (`HistorySelect`/`HistoryDealGet*`), so
  there is nothing to restore after a restart.

**No EA can guarantee a fixed daily dollar profit.** The daily
target/loss inputs are a ceiling and a floor, not a promise — size them,
and `InpRiskPercent`, to match your real account balance and risk
tolerance.

See the extensive inline comments in `MA_Cross_EA.mq5` for a line-by-line
explanation of how the code works.

## Scalper Multi-Entry EA

`Experts/Scalper_MultiEntry_EA.mq5` — on a momentum-burst signal (recent
price move over N bars beyond a threshold, confirmed by a short RSI), it
opens a **batch of `InpTradesCount` (default 10) trades at
`InpLotPerTrade` (default 0.02) lots each**, all in the same direction.
Each trade in the batch gets its own take-profit, spaced further away
than the previous one (`InpBaseTakeProfitPoints` +
`InpTakeProfitStepPoints` per trade) — a "ladder" that banks a small
profit fast on the first trade while later trades aim further. Once any
trade in the batch has closed in profit, every remaining trade's stop
loss is moved to break-even. Any trade still open after
`InpMaxHoldSeconds` is force-closed, and a daily max-loss limit
(`InpDailyMaxLossUSD`) stops new batches (and optionally closes
everything) once hit.

**Requires a hedging-enabled MT5 account.** Holding several separate
positions on one symbol at once is only possible in hedging mode; on a
netting account a second order on the same symbol just resizes the
existing position instead of opening a new one. The EA checks this in
`OnInit()` and refuses to start otherwise.

**No strategy is objectively "the best," and scalping is unusually
sensitive to spread/commission/slippage** — those costs can exceed a
small scalp target on some symbols/brokers. Backtest in "every tick
based on real ticks" mode, verify the take-profit ladder clears your
broker's real spread + commission, and forward-test on demo before
using real funds.

## Grid Martingale EA

`Experts/Grid_Martingale_EA.mq5` — trades one direction per cycle. When
flat, it opens a small first position (`InpBaseLot`). Every time price
moves `InpGridStepPoints` further against the basket, it adds another
same-direction position with a bigger lot (`InpBaseLot *
InpLotMultiplier ^ level`), up to `InpMaxGridLevels`. The whole basket
closes together once floating profit reaches
`InpBasketTakeProfitPercent`/`InpBasketTakeProfitUSD`.

**This is a martingale/grid strategy, not scalping, and it is
meaningfully riskier than the other two EAs here:** individual trades
have no stop loss, and each added level is larger than the last. Left
unmanaged, a strong sustained move against the open direction can
exhaust free margin and get positions forcibly liquidated by the broker
at the worst possible moment.

### v2: fixes found by an actual backtest

A user-supplied backtest (GOLD, 2026.08.03–2026.08.12) of v1 — which
always sold, no matter what the market was doing — lost 98% of the
account's balance at its worst point and finished net-negative. v2 fixes
the two causes:

1. **`InpGridDirection = Auto` (new default).** A new cycle now checks a
   trend filter MA (`InpTrendTimeframe`/`InpTrendMAPeriod`) and only
   sells below it, only buys above it, instead of always betting one
   way. A cycle's direction is locked in from its actual open positions
   once started, so a mid-cycle trend flip cannot mix BUY and SELL
   levels in the same basket. `GRID_SELL`/`GRID_BUY` are still available
   to force a fixed direction.
2. **A loss floor that cannot shrink.** v1's only loss limit was a
   percentage of the *current* balance, so repeated losing cycles
   compounded it down towards zero. v2 uses the tighter of
   `InpBasketMaxLossPercent` and a new fixed `InpBasketMaxLossUSD` per
   cycle, plus a new `InpDailyMaxLossUSD` — read live from the account's
   own trade history — that stops the EA from starting any further
   cycles once a day's realized loss is already too large.

These reduce the two failure modes actually observed in testing, but
this is still not a "safe" strategy in an absolute sense — a fast enough
move against an open basket can still lose more than intended between
ticks. Backtest with "every tick based on real ticks" and forward-test
on demo before risking real funds.

## XAUUSD Scalper Basket EA

`Experts/XAUUSD_Scalper_Basket_EA.mq5` — models the "aynı yön basket +
basamaklı lot" behavior: each cycle picks one direction (`InpDirMode`:
M1 EMA9/EMA21 trend + ADX filter, or forced BUY/SELL for testing) and
opens `InpBatchCount` positions **at once** (default 1 = the original
single "seed" position; set it higher, e.g. 10, for a fast simultaneous
burst entry). If `InpMaxPositions` is larger than `InpBatchCount`, price
moving `InpGridStepPoints` further (by default only *against* the
basket — `InpAddOnAdverseOnly`) adds further same-direction positions on
top of the batch, up to `InpMaxPositions`; set them equal to open the
batch and never grid-add beyond it. Individual positions have **no stop
loss or take profit** — the basket is managed as a whole, and closes
entirely once its combined floating profit reaches a target
(`InpTargetPerPosUSD` × open position count, or a fixed
`InpBasketTargetUSD`), after which a short `InpReArmDelaySec` pause runs
before the next cycle re-evaluates direction. A small
`InpTargetPerPosUSD` relative to the batch's combined lot means the
whole batch can close within seconds of a small favorable move — the
"hızlı al çık" (fast in-and-out) behavior.

**Lot size is not fixed — it steps up in tiers as account balance
grows**, e.g. `InpLotTiers = "630:0.05;990:0.15;1300:0.65"` (balance ≥
$630 → 0.05 lots, ≥ $990 → 0.15, ≥ $1300 → 0.65). The lot is locked for
the whole basket (`InpLockLotPerBasket`) and only re-evaluated against
the current balance when a new cycle starts. `InpLotSizingMode` can
switch to a linear balance coefficient or a plain fixed lot instead of
the tier table, and `InpSeedLotSmaller` can open the first position of a
basket one tier smaller than the additions.

**Requires a hedging-enabled MT5 account** — `OnInit()` refuses to start
otherwise, since the whole strategy depends on holding many same-symbol
positions at once. Before every order it checks free margin via
`OrderCalcMargin()` (skipping silently, not spamming errors, if it would
not leave `InpMarginBufferPercent` headroom) and backs off quietly on a
closed market or no-quotes response.

**This is materially riskier than the other EAs here**: positions carry
no individual stop, the profit target is small relative to the basket's
unbounded downside, and the balance-tiered lot means the position size
grows automatically as the account grows — both while winning and while
losing. `InpUseBasketSL` (per-cycle max loss) and `InpUseDailyGuard`
(daily max loss, checked against realized + floating P/L) default to
**on** — do not disable them without understanding the consequence.
Backtest in "every tick based on real ticks" mode over a long window
(1–3 months) and forward-test on demo before using real funds; the
lot-tier ladder (e.g. 0.05 → 0.15 → 0.65) accelerates both directions,
so a losing streak grows the position size just as fast as a winning
one does.

### v1.10: fixed a self-defeating default combination found by backtest

A backtest reported every single cycle closing at a loss, never once
reaching the profit target. Cause: on a typical Strategy Tester deposit
(≥ $1300), the default `InpLotTiers` immediately selects its largest
tier (0.65 lots), where a $1 XAUUSD move is worth ~$65 — but the old
defaults (`InpBasketMaxLossUSD = 20`, `InpTargetPerPosUSD = 0.5`) were
sized for a much smaller lot. At 0.65 lots the basket stop-loss was
smaller than the spread cost of opening a single position, so it
triggered essentially immediately, before the basket had any realistic
chance to reach its profit target. Fixed two ways:

1. **New defaults** (`InpBasketMaxLossUSD = 200`, `InpTargetPerPosUSD =
   2.0`, `InpDailyMaxLossUSD = 400`) sized to be workable with the
   largest tier in the default `InpLotTiers` table.
2. **`OnInit()` now refuses to start** if `InpBasketMaxLossUSD` is
   smaller than the USD cost of one `InpGridStepPoints` move at the
   largest configured lot (largest `InpLotTiers` entry, or
   `InpFixedLot`) — this combination can never produce a winning cycle,
   so it is caught as a parameter error instead of silently losing
   money. `LOT_SIZING_LINEAR` mode is exempt since its lot grows
   unbounded with balance by design.

This does not make the strategy safe — it only ensures the configured
risk/reward numbers are internally consistent with the configured lot
size instead of contradicting it.
