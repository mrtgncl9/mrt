# MT5 Expert Advisors

Two MetaTrader 5 (MQL5) Expert Advisors:

- **MA Cross EA** — a fast/slow Moving Average crossover trend-follower.
- **Scalper Multi-Entry EA** — a momentum-burst scalper that opens a
  batch of several small trades at once with a staggered take-profit
  ladder.

## Files

- `Experts/MA_Cross_EA.mq5` — MA crossover trend-following EA.
- `Experts/Scalper_MultiEntry_EA.mq5` — multi-entry momentum scalper EA.

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
