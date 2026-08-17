# MT5 Expert Advisors

Three MetaTrader 5 (MQL5) Expert Advisors:

- **MA Cross EA** — a fast/slow Moving Average crossover trend-follower.
- **Scalper Multi-Entry EA** — a momentum-burst scalper that opens a
  batch of several small trades at once with a staggered take-profit
  ladder.
- **Grid Martingale EA** — a single-direction grid that adds
  progressively larger positions as price moves against it, closing the
  whole basket together on a profit target. **High risk — read its
  section below before using it.**

## Files

- `Experts/MA_Cross_EA.mq5` — MA crossover trend-following EA.
- `Experts/Scalper_MultiEntry_EA.mq5` — multi-entry momentum scalper EA.
- `Experts/Grid_Martingale_EA.mq5` — single-direction grid/martingale EA.
- `Experts/XAUUSD_Basket_Scalper_EA.mq5` — multi-timeframe (M5 trend / M1
  trigger) basket scalper with a confidence-score dashboard, no
  martingale. See the section below.
- `Experts/MERT_UNIVERSAL_EA_V4.mq5` — multi-session opening-range
  breakout EA (up to three sessions/trades per day).

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

## XAUUSD Basket Scalper v1.1: confidence score + live HUD

A follow-up request referenced a TikTok backtest video of a product
called "PoorToRichEA": **$15 deposit, 1:500 leverage, up to 12 grid
levels per basket**, compressed into a few minutes of simulated time to
show the balance jumping from ~$14 to $200+. That combination — a
near-zero deposit, maximum leverage, and a large same-direction grid —
is what makes a backtest chart look dramatic; it is not a description
of a strategy that survives real trading, and `Grid_Martingale_EA.mq5`
above already documents what actually happened (98% drawdown) the one
time this repo's own grid EA was pointed at the market without a trend
filter. That combination was **not** reproduced here.

What *was* worth taking from the video is the idea of a live, readable
dashboard that shows how strong the current buy/sell signal is, not
just a plain metric dump. `XAUUSD_Basket_Scalper_EA.mq5` (the
no-martingale, trend-filtered basket scalper documented above) now
has:

- **A continuous 0-100 confidence score**, computed separately for BUY
  and SELL, from the same five checks the entry filter already used
  (M5 trend alignment, M1 EMA trigger, RSI band, ADX strength, candle
  body/ATR quality) — each scored by *how strongly* it's met, not just
  pass/fail, and blended with fixed weights (`ComputeConfidence()` in
  the code). Optional `MinConfidencePercent` input turns this into an
  extra entry filter (0 = off, matches the old behavior exactly).
- **FLOW / MOM readouts**: FLOW is the bull/bear candle balance over
  the last `FlowMomLookbackBars` M1 bars; MOM is ATR-normalized price
  displacement over the same window — both refreshed every bar.
- **A redesigned on-chart HUD**: balance/equity/drawdown, spread/ATR,
  FLOW/MOM/CONFIDENCE, M5 trend, live entry state (SCANNING/IN
  BASKET/PAUSED/HALTED), open orders and side, basket and daily P/L,
  cooldown/ADX/margin, and the exact reason new entries are currently
  blocked — each line color-coded (green/red/orange) instead of one
  plain white text block.

None of this changes the underlying risk model: still equal-lot
baskets (no martingale), still a real broker-side ATR stop on every
order, still the daily-loss/equity-drawdown/session/news guards
described above. The confidence score makes the signal's quality
visible and gives you one more optional, tunable filter — it does not
promise a specific rate of return, and no EA can.
