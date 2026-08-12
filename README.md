# MA Cross EA

A MetaTrader 5 (MQL5) Expert Advisor implementing a fast/slow Moving
Average crossover strategy, based on the classic "MA crossover" tutorial
strategy: open a **BUY** when the fast MA crosses above the slow MA, and
a **SELL** when the fast MA crosses below the slow MA.

## File

- `Experts/MA_Cross_EA.mq5` — the complete, self-contained Expert Advisor.

## Installation

1. Copy `Experts/MA_Cross_EA.mq5` into your MetaTrader 5 data folder, under
   `MQL5/Experts/` (in MetaEditor: `File → Open Data Folder → MQL5 →
   Experts`).
2. Open the file in MetaEditor and press **Compile** (F7). It should
   compile with 0 errors and 0 warnings.
3. In MetaTrader 5, open the **Navigator** panel (Ctrl+N), find
   `MA_Cross_EA` under **Expert Advisors**, and drag it onto any chart.

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

See the extensive inline comments in `MA_Cross_EA.mq5` for a line-by-line
explanation of how the code works.
