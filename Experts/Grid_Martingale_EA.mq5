//+------------------------------------------------------------------+
//|                                        Grid_Martingale_EA.mq5   |
//|             Single-Direction Grid / Martingale Expert Advisor   |
//+------------------------------------------------------------------+
//
// WHAT THIS EA DOES (matches the referenced video, plus v2 fixes below)
// ---------------------------------------------------------------------
// It trades one direction at a time. When it is flat, it opens a first
// small position. If price keeps moving against that position by at
// least InpGridStepPoints, it adds ANOTHER position in the same
// direction, with a bigger lot size than the last one (InpLotMultiplier
// times bigger). This repeats, up to InpMaxGridLevels positions, exactly
// like the phone screen in the referenced video showed a growing list of
// same-direction trades with growing lot sizes (0.01 -> 0.02 -> ... ->
// 0.50) as price moved against them. When price finally turns back, the
// WHOLE basket is usually deep in floating profit at once (because every
// position benefits from the turn, and the later, bigger positions do
// most of the work) - the EA then closes every position in the basket
// together and starts over.
//
// WHAT CHANGED IN v2 - AND WHY
// -----------------------------
// v1 always sold, no matter what the market was doing. A real backtest
// on GOLD (2026.08.03-2026.08.12, results supplied by the user) showed
// exactly the failure mode described in v1's disclaimer: the grid kept
// selling into a rising market, lost 98% of the account's balance at the
// worst point, and finished the test at a net loss. That is not "an
// unlucky video," that is what fighting the trend with a strategy that
// adds size to a loser actually does. Two fixes:
//
//   1. TREND-ADAPTIVE DIRECTION (InpGridDirection = Auto, now the
//      default). Instead of always selling, a new grid cycle checks a
//      longer-term trend filter MA (InpTrendTimeframe/InpTrendMAPeriod)
//      and only sells when price is BELOW it, only buys when price is
//      ABOVE it. This is the direct fix for "don't open the wrong
//      direction": the grid now opens in the direction the market is
//      already leaning, instead of guessing (or always betting one way).
//      Once a cycle is open its direction does not flip - that is read
//      back from the open positions themselves, not re-decided mid-cycle.
//
//   2. A LOSS FLOOR THAT DOES NOT SHRINK. v1's only loss limit was a
//      PERCENTAGE of the current balance. After several losing cycles in
//      a row that percentage shrinks along with the balance, so repeated
//      bad cycles compound down towards zero (0.8 x 0.8 x 0.8 x ... in
//      the tested case). v2 adds InpBasketMaxLossUSD, a FIXED dollar
//      floor that does not shrink, used together with the percentage
//      (whichever is tighter fires first) - plus InpDailyMaxLossUSD, a
//      daily cap (read from the account's own trade history, so it is
//      restart-safe) that stops the EA from starting ANY new cycle once
//      a day's realized loss is already too large, so a single bad
//      trending day cannot compound through many grid cycles.
//
// HONEST DISCLAIMER - PLEASE READ BEFORE USING THIS ON A REAL ACCOUNT
// -----------------------------------------------------------------------
// This is still a MARTINGALE / GRID strategy, not scalping, and it is
// still fundamentally riskier than the other two EAs in this repository:
// individual levels carry no per-trade stop loss, and each new level is
// bigger than the last. The trend filter and the new loss floors reduce
// the two failure modes actually observed in testing, but they do not
// make this strategy safe in an absolute sense - a strong enough move
// against an open basket, between two ticks, can still lose more than
// intended before the circuit breakers can react (backtest with "every
// tick based on real ticks" and forward-test on demo before risking real
// funds).
//
// SAFETY / DESIGN NOTES (shared with the other EAs in this repository)
// -----------------------------------------------------------------------
//   - Every trade carries InpMagicNumber, and every loop that inspects or
//     touches positions filters by both this magic number AND the
//     chart's symbol, so this EA never interferes with other EAs or with
//     your manual trades.
//   - Nothing about the state of the grid (how many levels are open, its
//     direction, the average entry price, the floating profit) is cached
//     in a variable - it is all recalculated from the terminal's own
//     live position list and trade history on every tick, so a
//     MetaTrader restart cannot desynchronize the EA from reality. The
//     only thing persisted across a restart is the "paused until"
//     timestamp set after the per-cycle circuit breaker fires (via a
//     terminal Global Variable), so the EA does not immediately start a
//     brand new grid straight after protecting the account.
//   - Every parameter is a plain input (no arrays), so everything can be
//     optimized in the Strategy Tester.
//+------------------------------------------------------------------+
#property copyright "Educational Grid/Martingale EA"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_GRID_DIRECTION
{
   GRID_AUTO = 0, // Automatic: pick BUY/SELL from the trend filter at the start of each cycle (recommended)
   GRID_SELL = 1, // Always sell, regardless of trend
   GRID_BUY  = 2  // Always buy, regardless of trend
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "===== General Settings ====="
input ulong               InpMagicNumber    = 202608020;         // Magic number (unique ID for this EA's trades)
input ulong               InpSlippagePoints = 30;                 // Maximum allowed slippage, in points
input string              InpTradeComment   = "Grid Martingale";  // Comment attached to every trade

input group "===== Grid Settings ====="
input ENUM_GRID_DIRECTION InpGridDirection   = GRID_AUTO; // Direction the grid trades in (Auto = trend-adaptive)
input double               InpBaseLot         = 0.01;      // Lot size of the FIRST position in a grid cycle
input double               InpLotMultiplier   = 1.5;       // Each new level's lot = previous level's lot * this
input int                 InpMaxGridLevels   = 10;        // Maximum number of positions in one grid cycle
input int                 InpGridStepPoints  = 200;       // Adverse move (points) required before adding the next level
input int                 InpMaxSpreadPoints = 50;        // Max spread allowed to open a level, in points (0 = off)

input group "===== Trend Filter (used when InpGridDirection = Auto) ====="
input ENUM_TIMEFRAMES InpTrendTimeframe = PERIOD_H1; // Timeframe the trend filter MA is calculated on
input int             InpTrendMAPeriod  = 200;       // Trend filter MA period: price below it = sell bias, above = buy bias

input group "===== Basket Profit / Loss (applies to the WHOLE grid cycle at once) ====="
input double InpBasketTakeProfitPercent = 2.0;  // Close the whole basket once floating profit >= this % of balance (0 = off)
input double InpBasketTakeProfitUSD     = 0.0;  // Close the whole basket once floating profit >= this many USD (0 = off)
input double InpBasketMaxLossPercent    = 20.0; // Close the whole basket once floating LOSS >= this % of balance (0 = off)
input double InpBasketMaxLossUSD        = 25.0; // Close the whole basket once floating LOSS >= this many fixed USD (0 = off)
input int    InpPauseMinutesAfterStop   = 60;   // After the per-cycle loss breaker fires, wait this many minutes before a new cycle

input group "===== Daily Risk Limit ====="
input double InpDailyMaxLossUSD = 60.0; // Do not start ANY new grid cycle once today's realized loss reaches this (0 = off)

//+------------------------------------------------------------------+
//| GLOBAL (PROGRAM-WIDE) VARIABLES                                   |
//+------------------------------------------------------------------+
CTrade trade;
int    g_trendMAHandle = INVALID_HANDLE;
string g_gvPauseName;

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpBaseLot <= 0.0)
   {
      Print("Grid_Martingale_EA: InpBaseLot must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpMaxGridLevels <= 0)
   {
      Print("Grid_Martingale_EA: InpMaxGridLevels must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLotMultiplier <= 0.0)
   {
      Print("Grid_Martingale_EA: InpLotMultiplier must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpGridStepPoints <= 0)
   {
      Print("Grid_Martingale_EA: InpGridStepPoints must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpGridDirection == GRID_AUTO && InpTrendMAPeriod <= 0)
   {
      Print("Grid_Martingale_EA: InpTrendMAPeriod must be greater than zero when InpGridDirection = Auto.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpBasketMaxLossPercent <= 0.0 && InpBasketMaxLossUSD <= 0.0)
      Print("Grid_Martingale_EA: warning - both InpBasketMaxLossPercent and InpBasketMaxLossUSD are 0/disabled. "
            "The grid can now lose money with NO limit per cycle. This is not recommended.");

   // The trend filter MA is only needed in Auto mode.
   if(InpGridDirection == GRID_AUTO)
   {
      g_trendMAHandle = iMA(_Symbol, InpTrendTimeframe, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
      if(g_trendMAHandle == INVALID_HANDLE)
      {
         Print("Grid_Martingale_EA: failed to create the trend filter moving average.");
         return(INIT_FAILED);
      }
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   // Restart-safe "paused until" timestamp - see the long comment at the
   // top of this file for why nothing else needs to be restored.
   g_gvPauseName = "Grid_Martingale_EA_" + IntegerToString((long)InpMagicNumber) + "_" + _Symbol + "_pauseuntil";

   PrintFormat("Grid_Martingale_EA initialized on %s | Magic=%I64u | Direction=%s | MaxLevels=%d BaseLot=%.2f Multiplier=%.2f",
               _Symbol, InpMagicNumber, EnumToString(InpGridDirection), InpMaxGridLevels, InpBaseLot, InpLotMultiplier);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_trendMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendMAHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Read the current state of our grid straight from the broker's
   //     own position list - nothing is cached, so this is always correct
   //     even right after a terminal restart. The basket's OWN direction
   //     (basketIsSell) is read back from its positions, not re-decided
   //     here, so a mid-cycle trend flip cannot make the EA mix BUY and
   //     SELL levels in the same basket. ------------------------------
   int    count        = 0;
   double totalLots     = 0.0;
   double weightedPrice = 0.0;
   double totalProfit   = 0.0;
   double extremePrice  = 0.0;
   bool   basketIsSell  = false;
   GetBasketStats(count, totalLots, weightedPrice, totalProfit, extremePrice, basketIsSell);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // --- Basket-wide take-profit / stop-loss, checked every tick ----------
   if(count > 0)
   {
      double tpTargetUSD = 0.0;
      bool   haveTarget  = false;

      if(InpBasketTakeProfitPercent > 0.0)
      {
         tpTargetUSD = balance * InpBasketTakeProfitPercent / 100.0;
         haveTarget  = true;
      }
      if(InpBasketTakeProfitUSD > 0.0)
      {
         tpTargetUSD = haveTarget ? MathMin(tpTargetUSD, InpBasketTakeProfitUSD) : InpBasketTakeProfitUSD;
         haveTarget  = true;
      }

      if(haveTarget && totalProfit >= tpTargetUSD)
      {
         PrintFormat("Grid_Martingale_EA: basket take-profit reached (%.2f >= %.2f) - closing all %d positions.",
                     totalProfit, tpTargetUSD, count);
         CloseAllOwnPositions();
         return;
      }

      // The loss floor is the TIGHTER (smaller) of a percentage of the
      // current balance and a fixed dollar amount, so repeated losing
      // cycles cannot compound the percentage down towards nothing - see
      // the "WHAT CHANGED IN v2" note at the top of this file.
      double lossLimitUSD = 0.0;
      bool   haveLossLimit = false;

      if(InpBasketMaxLossPercent > 0.0)
      {
         lossLimitUSD  = balance * InpBasketMaxLossPercent / 100.0;
         haveLossLimit = true;
      }
      if(InpBasketMaxLossUSD > 0.0)
      {
         lossLimitUSD  = haveLossLimit ? MathMin(lossLimitUSD, InpBasketMaxLossUSD) : InpBasketMaxLossUSD;
         haveLossLimit = true;
      }

      if(haveLossLimit && totalProfit <= -lossLimitUSD)
      {
         PrintFormat("Grid_Martingale_EA: basket max loss reached (%.2f <= -%.2f) - closing all %d positions to protect the account.",
                     totalProfit, lossLimitUSD, count);
         CloseAllOwnPositions();
         SetPauseUntil(TimeCurrent() + InpPauseMinutesAfterStop * 60);
         return;
      }
   }

   // --- After a stop-loss event, wait before starting a new grid --------
   if(IsPaused())
      return;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   if(InpMaxSpreadPoints > 0)
   {
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPoints > InpMaxSpreadPoints)
         return;
   }

   // --- No grid open yet: decide a direction and start a new cycle ------
   if(count == 0)
   {
      // A bad trending day should not be allowed to burn through cycle
      // after cycle - check the account's own realized history for today
      // before starting anything new (restart-safe: nothing cached).
      if(InpDailyMaxLossUSD > 0.0)
      {
         double todayProfit     = 0.0;
         int    todayEntryDeals = 0;
         GetTodayStats(todayProfit, todayEntryDeals);
         if(todayProfit <= -InpDailyMaxLossUSD)
            return; // already lost enough today - wait for tomorrow
      }

      bool isSell;
      if(InpGridDirection == GRID_SELL)
         isSell = true;
      else if(InpGridDirection == GRID_BUY)
         isSell = false;
      else if(!TryDetermineTrendDirection(isSell))
         return; // trend filter data not ready yet, try again next tick

      OpenGridLevel(isSell, 0);
      return;
   }

   // --- A grid is already running: maybe add the next level -------------
   if(count >= InpMaxGridLevels)
      return; // at the cap - just wait for the basket TP or the loss circuit breaker

   double currentPrice = basketIsSell ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double adverseMove  = basketIsSell ? (currentPrice - extremePrice) : (extremePrice - currentPrice);

   if(adverseMove >= InpGridStepPoints * _Point)
      OpenGridLevel(basketIsSell, count);
}

//+------------------------------------------------------------------+
//| Reads the trend filter MA and returns, via isSell, which direction|
//| a NEW grid cycle should open in: true (sell) when the last closed |
//| bar's close is below the MA, false (buy) when it is above. Returns|
//| false (as a function result) if the indicator data was not ready  |
//| yet, so the caller can simply wait for the next tick.              |
//+------------------------------------------------------------------+
bool TryDetermineTrendDirection(bool &isSell)
{
   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   if(CopyBuffer(g_trendMAHandle, 0, 1, 1, maBuf) != 1)
      return(false);

   double closePrev = iClose(_Symbol, InpTrendTimeframe, 1);
   if(closePrev <= 0.0)
      return(false);

   isSell = (closePrev < maBuf[0]);
   return(true);
}

//+------------------------------------------------------------------+
//| Opens the next grid level. levelIndex is 0 for the first position |
//| of a cycle, 1 for the second, and so on - the lot size grows with |
//| it (InpBaseLot * InpLotMultiplier ^ levelIndex).                   |
//+------------------------------------------------------------------+
void OpenGridLevel(const bool isSell, const int levelIndex)
{
   double lots = NormalizeLot(InpBaseLot * MathPow(InpLotMultiplier, levelIndex));
   double price = isSell ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Individual grid levels intentionally have no per-trade SL/TP - risk
   // is managed for the basket AS A WHOLE (see the take-profit/stop-loss
   // block in OnTick), exactly like the video, where the individual
   // trades were not shown with their own stop losses either.
   bool ok = isSell ? trade.Sell(lots, _Symbol, price, 0.0, 0.0, InpTradeComment)
                     : trade.Buy(lots, _Symbol, price, 0.0, 0.0, InpTradeComment);

   if(ok)
      PrintFormat("Grid_Martingale_EA: level %d opened on %s | %s %.2f lots @ %.5f",
                  levelIndex + 1, _Symbol, isSell ? "SELL" : "BUY", lots, price);
   else
      PrintFormat("Grid_Martingale_EA: level %d failed on %s | retcode=%d (%s)",
                  levelIndex + 1, _Symbol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Reads every open position that belongs to this EA (same symbol and|
//| magic number) in a single pass and reports: how many there are,   |
//| their combined volume, their volume-weighted average open price   |
//| (via totalLots/weightedPrice), their combined floating profit,    |
//| the "extreme" open price of the basket (the highest entry price   |
//| for a SELL basket, the lowest for a BUY basket - what a new        |
//| level's distance is measured from), and the basket's OWN direction|
//| (basketIsSell), read from its positions' actual type rather than  |
//| from the input, so a mid-cycle trend change never mixes BUY and   |
//| SELL levels in the same basket.                                    |
//+------------------------------------------------------------------+
void GetBasketStats(int &count, double &totalLots, double &weightedPrice, double &totalProfit, double &extremePrice, bool &basketIsSell)
{
   count         = 0;
   totalLots     = 0.0;
   weightedPrice = 0.0;
   totalProfit   = 0.0;
   extremePrice  = 0.0;
   basketIsSell  = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      double             volume    = PositionGetDouble(POSITION_VOLUME);
      double             openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double             profit    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      ENUM_POSITION_TYPE type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      count++;
      totalLots     += volume;
      weightedPrice += volume * openPrice;
      totalProfit   += profit;

      if(count == 1)
      {
         extremePrice = openPrice;
         basketIsSell = (type == POSITION_TYPE_SELL);
      }
      else if(basketIsSell)
         extremePrice = MathMax(extremePrice, openPrice);
      else
         extremePrice = MathMin(extremePrice, openPrice);
   }
}

//+------------------------------------------------------------------+
//| Closes EVERY open position that belongs to this EA (same symbol   |
//| and magic number), regardless of direction.                        |
//+------------------------------------------------------------------+
void CloseAllOwnPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket, InpSlippagePoints))
         PrintFormat("Grid_Martingale_EA: failed to close position #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Adds up today's realized profit (net of swap and commission) for  |
//| our symbol and magic number, straight from the account's own deal |
//| history. Reading it live (instead of caching it) means this is    |
//| automatically correct after a restart.                             |
//+------------------------------------------------------------------+
void GetTodayStats(double &profit, int &entryDeals)
{
   profit     = 0.0;
   entryDeals = 0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime dayStart = StructToTime(dt);

   if(!HistorySelect(dayStart, TimeCurrent()))
      return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;

      profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
              + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
              + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         entryDeals++;
   }
}

//+------------------------------------------------------------------+
//| Stores the time until which new grids are paused, in a terminal   |
//| Global Variable so it survives a MetaTrader restart.               |
//+------------------------------------------------------------------+
void SetPauseUntil(const datetime untilTime)
{
   GlobalVariableSet(g_gvPauseName, (double)untilTime);
}

//+------------------------------------------------------------------+
//| Returns true if we are still inside a post-stop-loss pause window.|
//+------------------------------------------------------------------+
bool IsPaused()
{
   if(!GlobalVariableCheck(g_gvPauseName))
      return(false);

   datetime untilTime = (datetime)GlobalVariableGet(g_gvPauseName);
   return(TimeCurrent() < untilTime);
}

//+------------------------------------------------------------------+
//| Rounds a requested lot size to a volume the broker will accept:   |
//| respects the symbol's minimum, maximum and step.                  |
//+------------------------------------------------------------------+
double NormalizeLot(const double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double normalized = MathRound(lots / stepLot) * stepLot;
   normalized = MathMax(minLot, MathMin(maxLot, normalized));

   int stepDigits = (int)MathRound(-MathLog10(stepLot));
   if(stepDigits < 0)
      stepDigits = 0;

   return NormalizeDouble(normalized, stepDigits);
}
//+------------------------------------------------------------------+
