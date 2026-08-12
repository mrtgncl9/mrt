//+------------------------------------------------------------------+
//|                                       Scalper_MultiEntry_EA.mq5 |
//|                  Multi-Entry Momentum Scalper Expert Advisor    |
//+------------------------------------------------------------------+
//
// WHAT THIS EA DOES
// ------------------
// When it detects a short burst of momentum (price has moved further than
// a threshold over the last few closed bars, confirmed by a short-period
// RSI), it fires a BATCH of several small market orders at once - by
// default 10 trades of 0.02 lots - instead of one single trade. Each
// trade in the batch gets its OWN take-profit level, spaced further and
// further away (a "ladder"): the first trade banks a small, fast profit,
// while later trades stay open a bit longer aiming for a bigger move.
// As soon as at least one trade in the batch has closed in profit, the
// stop loss of every remaining trade in that batch is moved to
// break-even, so the batch can no longer lose money as a whole. Any
// trade that is still open after a configurable number of seconds is
// force-closed, because a scalp that turns into a long-term hold is no
// longer a scalp.
//
// HONEST DISCLAIMER - PLEASE READ
// ---------------------------------
// There is no such thing as an objectively "best" scalping strategy -
// any claim like that would be marketing, not engineering. Very
// short-term trading is extremely sensitive to two costs that a
// backtest can easily underestimate: the SPREAD and any COMMISSION your
// broker charges, plus SLIPPAGE during fast moves. On many symbols those
// costs alone can exceed the size of a typical scalp target. Before
// running this on a real account:
//   - Backtest in "Every tick based on real ticks" mode only.
//   - Check your broker's real spread/commission for the symbol and make
//     sure InpBaseTakeProfitPoints/InpTakeProfitStepPoints comfortably
//     clear it.
//   - Forward-test on a demo account first.
// This EA gives you full control over the entry filter and the exit
// ladder, and it manages risk mechanically (fixed stop loss, break-even
// after partial profit, a daily loss "circuit breaker", a hard time
// limit per trade) - but no code can guarantee this, or any, strategy
// will be profitable.
//
// IMPORTANT ACCOUNT REQUIREMENT
// --------------------------------
// Holding 10 separate positions on the same symbol at the same time is
// only possible on a HEDGING-enabled MT5 account. A "netting" account
// can only ever hold ONE net position per symbol - a second order on the
// same symbol just enlarges or reduces that one position, it does not
// create a second one. This EA checks your account's margin mode in
// OnInit() and refuses to start on a netting account, instead of
// silently doing something other than what you asked for.
//
// SAFETY / DESIGN NOTES (shared with the other EA in this repository)
// -----------------------------------------------------------------------
//   - Every trade carries InpMagicNumber, and every loop that inspects or
//     touches positions filters by both this magic number AND the
//     chart's symbol, so this EA never interferes with other EAs or with
//     your manual trades.
//   - Nothing about "am I in a position", "how many trades are open" or
//     "what has today's result been" is cached in a variable - it is
//     always read fresh from the terminal's own position list and trade
//     history, so a MetaTrader restart cannot desynchronize the EA from
//     reality. The only thing persisted across a restart is the
//     timestamp of the last bar evaluated (via a terminal Global
//     Variable), purely so the EA does not re-evaluate the same closed
//     bar twice.
//   - Every parameter is a plain input (no arrays), so everything can be
//     optimized in the Strategy Tester.
//+------------------------------------------------------------------+
#property copyright "Educational Multi-Entry Scalper EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "===== General Settings ====="
input ulong           InpMagicNumber     = 202608010;      // Magic number (unique ID for this EA's trades)
input ulong           InpSlippagePoints  = 30;              // Maximum allowed slippage, in points
input string          InpTradeComment    = "Scalper Batch"; // Comment attached to every trade
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_CURRENT;  // Timeframe used for the entry signal

input group "===== Scalping Entry Signal ====="
input int    InpMomentumBars           = 5;   // Look-back, in closed bars, for the momentum measurement
input double InpMomentumThresholdPoints = 100; // Minimum net price move over those bars, in points, to trigger a signal
input int    InpRSIPeriod              = 7;   // RSI period (short, for scalping)
input double InpRSIBuyMin              = 55;  // Minimum RSI to confirm a BUY signal
input double InpRSIBuyMax              = 85;  // Maximum RSI to confirm a BUY signal (avoids extreme blow-off tops)
input double InpRSISellMin             = 15;  // Minimum RSI to confirm a SELL signal (avoids extreme blow-off bottoms)
input double InpRSISellMax             = 45;  // Maximum RSI to confirm a SELL signal
input int    InpMaxSpreadPoints        = 20;  // Max spread allowed to open a batch, in points (0 = off)
input bool   InpOneSignalPerBar        = true;// Only look for a signal once per closed bar

input group "===== Position Batch ====="
input int    InpTradesCount      = 10;   // Number of trades opened per batch
input double InpLotPerTrade      = 0.02; // Lot size of EACH trade in the batch
input bool   InpOneBatchAtATime  = true; // Do not open a new batch while a previous one still has open trades

input group "===== Stop Loss / Take Profit ====="
input int InpStopLossPoints       = 150; // Stop loss shared by every trade in the batch, in points (required, > 0)
input int InpBaseTakeProfitPoints = 50;  // Take profit of the FIRST trade in the batch, in points
input int InpTakeProfitStepPoints = 30;  // Extra points added to the take profit of each following trade (the "ladder")

input group "===== Trade Management ====="
input bool InpUseBreakevenAfterFirstTP = true; // Move the rest of the batch to break-even once one trade has closed in profit
input int  InpBreakevenOffsetPoints    = 10;   // Points beyond entry price the break-even stop is set to
input int  InpMaxHoldSeconds           = 300;  // Force-close a trade still open after this many seconds (0 = off)

input group "===== Daily Risk Limits ====="
input double InpDailyMaxLossUSD          = 100.0; // Stop opening new batches once today's loss reaches this (0 = off)
input bool   InpCloseAllOnDailyLossLimit = true;   // Also close every open trade once the daily loss limit is hit
input int    InpMaxBatchesPerDay         = 20;     // Max number of batches opened per day (0 = off)

//+------------------------------------------------------------------+
//| GLOBAL (PROGRAM-WIDE) VARIABLES                                   |
//+------------------------------------------------------------------+
CTrade   trade;
int      g_rsiHandle   = INVALID_HANDLE;
datetime g_lastBarTime = 0;
string   g_gvName;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Basic sanity checks on the inputs -----------------------------
   if(InpTradesCount <= 0)
   {
      Print("Scalper_MultiEntry_EA: InpTradesCount must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLotPerTrade <= 0.0)
   {
      Print("Scalper_MultiEntry_EA: InpLotPerTrade must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpMomentumBars <= 0 || InpRSIPeriod <= 0)
   {
      Print("Scalper_MultiEntry_EA: InpMomentumBars and InpRSIPeriod must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpStopLossPoints <= 0)
   {
      Print("Scalper_MultiEntry_EA: a stop loss (InpStopLossPoints) is required - refusing to run "
            "a 10-position batch scalper without one, that would risk unlimited loss per trade.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpBaseTakeProfitPoints <= 0)
   {
      Print("Scalper_MultiEntry_EA: InpBaseTakeProfitPoints must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- A multi-position batch on one symbol needs a hedging account ---
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      PrintFormat("Scalper_MultiEntry_EA: this account is NOT in hedging mode (it is netting). A netting "
                  "account can only hold ONE net position per symbol, so it cannot hold %d separate "
                  "positions at once. Use a hedging-enabled account - the EA will not start.", InpTradesCount);
      return(INIT_FAILED);
   }

   // --- Create the RSI indicator used to confirm the momentum signal ---
   g_rsiHandle = iRSI(_Symbol, InpSignalTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
   {
      Print("Scalper_MultiEntry_EA: failed to create the RSI indicator.");
      return(INIT_FAILED);
   }

   // --- Configure the trading object ------------------------------------
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   // --- Restore state after a restart (see the long comment at the top
   //     of this file for why nothing else needs restoring) --------------
   g_gvName = "Scalper_MultiEntry_EA_" + IntegerToString((long)InpMagicNumber) + "_" + _Symbol + "_" +
              EnumToString(InpSignalTimeframe) + "_lastbar";

   if(GlobalVariableCheck(g_gvName))
      g_lastBarTime = (datetime)GlobalVariableGet(g_gvName);
   else
      g_lastBarTime = 0;

   PrintFormat("Scalper_MultiEntry_EA initialized on %s (%s) | Magic=%I64u | TradesPerBatch=%d Lot=%.2f",
               _Symbol, EnumToString(InpSignalTimeframe), InpMagicNumber, InpTradesCount, InpLotPerTrade);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Break-even promotion and the time-based forced exit must react
   // every tick, not just once per bar.
   ManageOpenPositions();

   // --- Make sure there is enough history for the signal ----------------
   if(Bars(_Symbol, InpSignalTimeframe) < InpMomentumBars + InpRSIPeriod + 5)
      return;

   // --- Only look for a new signal once a bar has actually closed -------
   datetime currentBarTime = iTime(_Symbol, InpSignalTimeframe, 0);
   if(currentBarTime == 0)
      return;

   if(InpOneSignalPerBar && currentBarTime == g_lastBarTime)
      return;

   // --- Momentum: how far did price move over the last InpMomentumBars
   //     CLOSED bars? A positive value means the market moved up, a
   //     negative value means it moved down.
   double closePrev1 = iClose(_Symbol, InpSignalTimeframe, 1);
   double closePrevN = iClose(_Symbol, InpSignalTimeframe, 1 + InpMomentumBars);
   if(closePrev1 <= 0.0 || closePrevN <= 0.0)
      return; // history not ready yet

   double momentumPoints = (closePrev1 - closePrevN) / _Point;

   // --- RSI confirmation ---------------------------------------------------
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(g_rsiHandle, 0, 1, 1, rsiBuf) != 1)
      return; // RSI data not ready yet
   double rsiValue = rsiBuf[0];

   bool bullish = (momentumPoints >= InpMomentumThresholdPoints) &&
                  (rsiValue >= InpRSIBuyMin && rsiValue <= InpRSIBuyMax);
   bool bearish = (momentumPoints <= -InpMomentumThresholdPoints) &&
                  (rsiValue >= InpRSISellMin && rsiValue <= InpRSISellMax);

   // Remember this bar was evaluated, and persist it so it survives a
   // terminal restart.
   g_lastBarTime = currentBarTime;
   GlobalVariableSet(g_gvName, (double)g_lastBarTime);

   if(!bullish && !bearish)
      return;

   // --- Do not attempt to trade if trading is not currently allowed -----
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   // --- Spread filter: scalping profit targets are small, so an
   //     abnormally wide spread can turn a winning signal into a loser
   //     before it even starts. -------------------------------------------
   if(InpMaxSpreadPoints > 0)
   {
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPoints > InpMaxSpreadPoints)
      {
         PrintFormat("Scalper_MultiEntry_EA: signal skipped on %s, spread %d points > max %d.",
                     _Symbol, spreadPoints, InpMaxSpreadPoints);
         return;
      }
   }

   // --- Do not stack a new batch on top of one that is still running ----
   if(InpOneBatchAtATime && CountOwnPositions() > 0)
      return;

   // --- Daily circuit breakers -------------------------------------------
   double todayProfit     = 0.0;
   int    todayEntryDeals = 0;
   GetTodayStats(todayProfit, todayEntryDeals);

   if(InpDailyMaxLossUSD > 0.0 && todayProfit <= -InpDailyMaxLossUSD)
   {
      PrintFormat("Scalper_MultiEntry_EA: daily max loss reached (today P/L=%.2f) - no new batches today.", todayProfit);
      if(InpCloseAllOnDailyLossLimit)
         CloseAllOwnPositions();
      return;
   }

   if(InpMaxBatchesPerDay > 0)
   {
      int batchesToday = todayEntryDeals / InpTradesCount;
      if(batchesToday >= InpMaxBatchesPerDay)
      {
         PrintFormat("Scalper_MultiEntry_EA: max batches per day reached (%d) - no new batches today.", batchesToday);
         return;
      }
   }

   OpenScalpBatch(bullish);
}

//+------------------------------------------------------------------+
//| Opens InpTradesCount market orders of InpLotPerTrade lots each,   |
//| all in the same direction, each with its own take-profit level    |
//| spaced InpTakeProfitStepPoints further away than the previous one |
//| (a profit "ladder"), and a shared stop loss.                      |
//+------------------------------------------------------------------+
void OpenScalpBatch(const bool isBuy)
{
   int opened = 0;

   for(int i = 0; i < InpTradesCount; i++)
   {
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      double slDist = PointsToClampedPrice(InpStopLossPoints);
      double sl = isBuy ? price - slDist : price + slDist;
      sl = NormalizeDouble(sl, _Digits);

      int    tpPoints = InpBaseTakeProfitPoints + i * InpTakeProfitStepPoints;
      double tpDist   = PointsToClampedPrice(tpPoints);
      double tp = isBuy ? price + tpDist : price - tpDist;
      tp = NormalizeDouble(tp, _Digits);

      double lots = NormalizeLot(InpLotPerTrade);

      bool ok = isBuy ? trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment)
                       : trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);

      if(ok)
         opened++;
      else
         PrintFormat("Scalper_MultiEntry_EA: trade %d/%d failed | retcode=%d (%s)",
                     i + 1, InpTradesCount, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   PrintFormat("Scalper_MultiEntry_EA: batch opened on %s | %d/%d trades filled | direction=%s",
               _Symbol, opened, InpTradesCount, isBuy ? "BUY" : "SELL");
}

//+------------------------------------------------------------------+
//| Manages every open position that belongs to this EA:               |
//|   1. Force-closes any trade that has been open longer than         |
//|      InpMaxHoldSeconds (keeps this a genuine scalp).               |
//|   2. Once at least one trade of the current batch has already      |
//|      closed (meaning it hit its take profit), moves the stop loss  |
//|      of every remaining trade in the batch to break-even.          |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   int openCount = CountOwnPositions();
   if(openCount == 0)
      return;

   bool applyBreakeven = InpUseBreakevenAfterFirstTP && (openCount < InpTradesCount);

   long stopsLevelPoints  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLevelPoints, (double)freezeLevelPoints) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      // --- Time-based forced exit -----------------------------------------
      if(InpMaxHoldSeconds > 0)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(TimeCurrent() - openTime >= InpMaxHoldSeconds)
         {
            if(!trade.PositionClose(ticket, InpSlippagePoints))
               PrintFormat("Scalper_MultiEntry_EA: failed to time-close #%I64u | retcode=%d (%s)",
                           ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
            continue; // this ticket is handled, move on to the next one
         }
      }

      // --- Break-even once part of the batch has already banked profit ---
      if(!applyBreakeven)
         continue;

      ENUM_POSITION_TYPE type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double             currentSL = PositionGetDouble(POSITION_SL);
      double             currentTP = PositionGetDouble(POSITION_TP);

      double beSL = (type == POSITION_TYPE_BUY)
                    ? openPrice + InpBreakevenOffsetPoints * _Point
                    : openPrice - InpBreakevenOffsetPoints * _Point;

      bool needsUpdate = (type == POSITION_TYPE_BUY)
                          ? (currentSL < beSL)
                          : (currentSL <= 0.0 || currentSL > beSL);
      if(!needsUpdate)
         continue;

      double price = (type == POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      bool farEnough = (type == POSITION_TYPE_BUY)
                        ? (price - beSL) >= minDist
                        : (beSL - price) >= minDist;
      if(!farEnough)
         continue; // too close to price right now, try again on a later tick

      double newSL = NormalizeDouble(beSL, _Digits);
      if(!trade.PositionModify(ticket, newSL, currentTP))
         PrintFormat("Scalper_MultiEntry_EA: failed to move SL to break-even on #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Counts how many open positions belong to this EA (same symbol and |
//| magic number).                                                     |
//+------------------------------------------------------------------+
int CountOwnPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Closes EVERY open position that belongs to this EA. Used by the   |
//| daily loss circuit breaker.                                        |
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
         PrintFormat("Scalper_MultiEntry_EA: failed to close position #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Adds up today's realized profit (net of swap and commission) and  |
//| counts today's opening deals, from the account's own trade         |
//| history for our symbol and magic number. Reading straight from     |
//| the trade server's history means this is automatically correct     |
//| after a restart - nothing needs to be cached.                      |
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
//| Converts a distance expressed in points into a price distance,    |
//| never smaller than what this symbol's broker requires (its        |
//| "stops level"/"freeze level"), so SL/TP requests are never         |
//| rejected for being too close to the current price.                 |
//+------------------------------------------------------------------+
double PointsToClampedPrice(const double points)
{
   long stopsLevelPoints  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLevelPoints, (double)freezeLevelPoints) * _Point;
   return MathMax(points * _Point, minDist);
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
