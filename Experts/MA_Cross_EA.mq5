//+------------------------------------------------------------------+
//|                                                 MA_Cross_EA.mq5 |
//|                        Moving Average Crossover Expert Advisor  |
//+------------------------------------------------------------------+
//
// WHAT THIS EA DOES
// ------------------
// Core signal (unchanged from the original tutorial idea): it watches a
// "fast" Moving Average and a "slow" Moving Average calculated on CLOSED
// bars. When the fast MA crosses above the slow MA it buys; when it
// crosses below, it sells.
//
// On top of that core signal this version adds a set of professional
// risk-management building blocks whose entire purpose is to cut losing
// trades short and let winners run further, which is the only honest way
// to raise an EA's daily results:
//
//   1. An optional higher-degree TREND FILTER MA: a crossover is only
//      traded if it agrees with the direction of a longer-term average,
//      which filters out a lot of the whipsaw trades that a raw
//      crossover takes in a ranging market.
//   2. An optional MINIMUM CROSSOVER DISTANCE filter: ignores crosses
//      where the two MAs are barely touching (usually noise).
//   3. An optional MAXIMUM SPREAD filter: refuses to open a trade when
//      the spread is abnormally wide (illiquid/news moments).
//   4. ATR-based, volatility-adaptive Stop Loss / Take Profit (optional,
//      falls back to fixed points): a fixed number of points is not the
//      same risk on every symbol or in every market condition; the
//      Average True Range scales the stop to the CURRENT volatility of
//      whatever symbol the EA is attached to.
//   5. Percent-of-balance position sizing (optional, falls back to a
//      fixed lot size): risks a fixed percentage of the account balance
//      per trade instead of a fixed number of lots, so the position size
//      automatically matches both the account size and the stop
//      distance.
//   6. Break-even stop and a trailing stop: once a trade is far enough
//      in profit, its stop loss is moved to protect that profit instead
//      of letting a winning trade turn into a loss.
//   7. A daily profit target and a daily maximum loss ("circuit
//      breakers"): once today's realized result (computed straight from
//      the account's own trade history, so it is always correct even
//      after a terminal restart) reaches the target or the loss limit,
//      the EA stops opening new trades for the rest of the day.
//   8. An optional cap on the number of new trades per day.
//
// IMPORTANT, HONEST DISCLAIMER
// -----------------------------
// No piece of code can GUARANTEE a fixed daily dollar profit. Markets are
// probabilistic: a strategy has a statistical edge (or it doesn't), and
// individual days will always vary - some will be flat, some negative,
// occasionally a good day will far exceed a "target". What this EA CAN
// do is:
//   - stop trading once a day's target is hit, so it does not give back
//     an already-good day chasing more, and
//   - stop trading once a day's maximum loss is hit, so a bad day cannot
//     turn into a catastrophic one.
// The InpDailyProfitTargetUSD / InpDailyMaxLossUSD inputs below are
// therefore "ceiling and floor" switches, not a promise. Whether $500/day
// is realistic depends entirely on your account size, the leverage you
// use and the risk you take (InpRiskPercent) - on a small account,
// pushing towards a large fixed dollar target means taking a dangerously
// large risk per trade, which raises the chance of blowing the account,
// not of reliably hitting the target. Size these numbers, and
// InpRiskPercent, to match your real account and risk tolerance.
//
// Every input below is a plain input variable (no arrays, no custom
// structures), so every one of them can still be optimized in the
// MetaTrader Strategy Tester.
//+------------------------------------------------------------------+
#property copyright "Educational MA Crossover EA"
#property version   "2.00"
#property strict

// This pulls in the ready-made "CTrade" class that MetaTrader ships with
// every installation. CTrade already knows how to send buy orders, sell
// orders, modify and close positions safely, so we do not have to build
// all of that from scratch.
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| A small custom enumeration used by the InpLotMode input below.    |
//| It lets the position-sizing method itself be chosen in the inputs |
//| (and swept in the optimizer) instead of being hard-coded.         |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED        = 0, // Fixed lot size (InpLotSize)
   LOT_MODE_RISK_PERCENT = 1  // Risk InpRiskPercent % of account balance per trade
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//| Everything declared with "input" shows up in the EA's properties |
//| dialog AND in the Strategy Tester optimizer, so every one of them |
//| can be tweaked or optimized without touching the source code.    |
//+------------------------------------------------------------------+
input group "===== General Settings ====="
input ulong               InpMagicNumber    = 202608001;     // Magic number (unique ID for this EA's trades)
input ulong               InpSlippagePoints = 30;             // Maximum allowed slippage, in points
input string              InpTradeComment   = "MA Cross EA";  // Comment attached to every trade

input group "===== Moving Average Settings ====="
input int                 InpFastMAPeriod   = 20;             // Fast MA period
input int                 InpSlowMAPeriod   = 200;            // Slow MA period
input ENUM_MA_METHOD      InpMAMethod       = MODE_SMA;       // MA method (SMA / EMA / SMMA / LWMA)
input ENUM_APPLIED_PRICE  InpAppliedPrice   = PRICE_CLOSE;    // Price used to calculate the MAs
input ENUM_TIMEFRAMES     InpMATimeframe    = PERIOD_CURRENT; // Timeframe used to calculate the MAs

input group "===== Signal Filters (fewer, better trades) ====="
input int                 InpTrendMAPeriod      = 400; // Higher-degree trend filter MA period (0 = off)
input double               InpMinCrossDistPoints = 0;   // Minimum MA gap at the crossover, in points (0 = off)
input int                 InpMaxSpreadPoints    = 0;   // Max spread allowed to open a trade, in points (0 = off)

input group "===== Position Sizing ====="
input ENUM_LOT_MODE       InpLotMode      = LOT_MODE_FIXED; // How trade volume is calculated
input double               InpLotSize      = 0.01;           // Fixed lot size (used when InpLotMode = Fixed)
input double               InpRiskPercent  = 1.0;            // Risk % of balance per trade (used when InpLotMode = Risk percent)

input group "===== Stop Loss / Take Profit ====="
input bool                 InpUseATRStops     = true;  // Use ATR (volatility-based) stops instead of fixed points
input int                 InpATRPeriod       = 14;    // ATR period (used when InpUseATRStops = true)
input double               InpATRMultiplierSL = 2.0;   // Stop loss = ATR * this multiplier
input double               InpATRMultiplierTP = 3.0;   // Take profit = ATR * this multiplier
input int                 InpStopLossPoints   = 500;   // Fixed stop loss, in points (used when InpUseATRStops = false, 0 = none)
input int                 InpTakeProfitPoints = 1000;  // Fixed take profit, in points (used when InpUseATRStops = false, 0 = none)

input group "===== Trade Management ====="
input bool                InpUseBreakeven           = true; // Move stop loss to break-even once in enough profit
input int                 InpBreakevenTriggerPoints = 300;  // Profit (points) needed to trigger break-even
input int                 InpBreakevenOffsetPoints  = 20;   // Points beyond entry price the break-even stop is set to
input bool                InpUseTrailingStop        = true; // Trail the stop loss behind price once in profit
input int                 InpTrailingStopPoints     = 300;  // Distance (points) kept between price and the trailing stop
input int                 InpTrailingStepPoints     = 50;   // Minimum improvement (points) before the stop is moved again

input group "===== Daily Risk Limits ====="
input double               InpDailyProfitTargetUSD     = 500.0; // Stop opening new trades once today's profit reaches this (0 = off)
input bool                 InpCloseAllOnDailyTarget    = false;  // Also close open positions once the daily target is hit
input double               InpDailyMaxLossUSD          = 250.0; // Stop opening new trades once today's loss reaches this (0 = off)
input bool                 InpCloseAllOnDailyLossLimit = true;   // Also close open positions once the daily loss limit is hit
input int                 InpMaxTradesPerDay          = 0;     // Max number of new trades per day (0 = off)

input group "===== Trade Behaviour ====="
input bool                 InpCloseOpposite   = true; // Close an opposite position before opening a new one
input bool                 InpOneSignalPerBar = true; // Only look for a signal once per closed bar

//+------------------------------------------------------------------+
//| GLOBAL (PROGRAM-WIDE) VARIABLES                                  |
//| These are declared outside of any function, so their value is   |
//| kept in memory for as long as the EA is running.                 |
//+------------------------------------------------------------------+
CTrade   trade;                  // The trading object we use to send/close/modify orders
int      g_fastMAHandle  = INVALID_HANDLE; // handle (ID number) of the fast MA indicator
int      g_slowMAHandle  = INVALID_HANDLE; // handle (ID number) of the slow MA indicator
int      g_trendMAHandle = INVALID_HANDLE; // handle of the optional trend filter MA (stays INVALID_HANDLE if disabled)
int      g_atrHandle     = INVALID_HANDLE; // handle of the optional ATR indicator (stays INVALID_HANDLE if disabled)
datetime g_lastBarTime   = 0;              // timestamp of the last bar we already evaluated
string   g_gvName;                         // name used to store g_lastBarTime as a terminal Global Variable

//+------------------------------------------------------------------+
//| OnInit                                                           |
//| Called automatically ONE TIME whenever the EA is attached to a   |
//| chart, whenever the terminal restarts, and whenever you change   |
//| an input, the timeframe, or the symbol on the chart.             |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Basic sanity checks on the inputs -----------------------------
   // We refuse to start with a configuration that could not possibly
   // work, instead of silently doing something wrong.
   if(InpFastMAPeriod <= 0 || InpSlowMAPeriod <= 0)
   {
      Print("MA_Cross_EA: MA periods must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpFastMAPeriod >= InpSlowMAPeriod)
   {
      Print("MA_Cross_EA: the fast MA period must be smaller than the slow MA period.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLotMode == LOT_MODE_FIXED && InpLotSize <= 0.0)
   {
      Print("MA_Cross_EA: fixed lot size must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLotMode == LOT_MODE_RISK_PERCENT && InpRiskPercent <= 0.0)
   {
      Print("MA_Cross_EA: risk percent must be greater than zero when using risk-percent sizing.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLotMode == LOT_MODE_RISK_PERCENT && !InpUseATRStops && InpStopLossPoints <= 0)
      Print("MA_Cross_EA: warning - risk-percent sizing needs a stop distance; with ATR stops off and "
            "InpStopLossPoints = 0 it will fall back to the fixed InpLotSize.");

   // --- Create the Moving Average indicators ---------------------------
   // iMA() does not calculate the indicator itself, it only returns a
   // "handle", i.e. a number that identifies this specific indicator
   // (symbol + timeframe + period + method + applied price). We keep the
   // handles in global variables so we only have to create them once,
   // instead of on every single tick.
   g_fastMAHandle = iMA(_Symbol, InpMATimeframe, InpFastMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   g_slowMAHandle = iMA(_Symbol, InpMATimeframe, InpSlowMAPeriod, 0, InpMAMethod, InpAppliedPrice);

   if(g_fastMAHandle == INVALID_HANDLE || g_slowMAHandle == INVALID_HANDLE)
   {
      Print("MA_Cross_EA: failed to create the fast/slow moving average indicators.");
      return(INIT_FAILED);
   }

   // The trend filter MA is optional: only create it if the user asked
   // for it (period > 0).
   if(InpTrendMAPeriod > 0)
   {
      g_trendMAHandle = iMA(_Symbol, InpMATimeframe, InpTrendMAPeriod, 0, InpMAMethod, InpAppliedPrice);
      if(g_trendMAHandle == INVALID_HANDLE)
      {
         Print("MA_Cross_EA: failed to create the trend filter moving average.");
         return(INIT_FAILED);
      }
   }

   // The ATR indicator is only needed for volatility-based stops.
   if(InpUseATRStops)
   {
      g_atrHandle = iATR(_Symbol, InpMATimeframe, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
      {
         Print("MA_Cross_EA: failed to create the ATR indicator.");
         return(INIT_FAILED);
      }
   }

   // --- Configure the trading object ------------------------------------
   trade.SetExpertMagicNumber(InpMagicNumber);      // tag every trade we send with our magic number
   trade.SetDeviationInPoints(InpSlippagePoints);    // maximum acceptable slippage
   trade.SetTypeFillingBySymbol(_Symbol);            // let CTrade pick a filling mode this symbol supports
   trade.SetAsyncMode(false);                        // wait for the trade server's answer before continuing

   // --- Restore state after a restart ------------------------------------
   // We build a unique name for a "Global Variable of the terminal". Those
   // variables are written to disk by MetaTrader and survive a terminal
   // restart. We use it to remember the timestamp of the last bar we
   // already evaluated, so that after a restart we do not evaluate (and
   // potentially re-trade) the same bar a second time.
   g_gvName = "MA_Cross_EA_" + IntegerToString((long)InpMagicNumber) + "_" + _Symbol + "_" + EnumToString(InpMATimeframe) + "_lastbar";

   if(GlobalVariableCheck(g_gvName))
      g_lastBarTime = (datetime)GlobalVariableGet(g_gvName);
   else
      g_lastBarTime = 0;

   // Note: we deliberately do NOT store "are we currently in a position",
   // "today's profit so far" or "how many trades today" in variables.
   // Instead, every time that information is needed we ask the trade
   // server / the account's own trade history directly (see
   // HasOpenPosition() and GetTodayStats() below). That way the EA's idea
   // of its own state is always 100% in sync with reality, even right
   // after MetaTrader has been restarted.

   PrintFormat("MA_Cross_EA initialized on %s (%s) | Magic=%I64u | Fast=%d Slow=%d | LotMode=%s",
               _Symbol, EnumToString(InpMATimeframe), InpMagicNumber, InpFastMAPeriod, InpSlowMAPeriod,
               EnumToString(InpLotMode));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//| Called automatically when the EA is removed from the chart, the   |
//| terminal is closed, the symbol/timeframe is changed, etc.         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release every indicator handle we created in OnInit(). This frees
   // the memory/resources MetaTrader allocated for them. It does NOT
   // close any open trades - trades belong to the account, not to the EA.
   if(g_fastMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastMAHandle);
   if(g_slowMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowMAHandle);
   if(g_trendMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendMAHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//| Called automatically every time a new price quote (tick) arrives  |
//| for the symbol the EA is attached to.                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Break-even/trailing management must react to price on every tick,
   // not just once per bar, so it runs first and unconditionally.
   ManageOpenPositions();

   // --- Make sure there is enough history to calculate the MAs ----------
   if(Bars(_Symbol, InpMATimeframe) < InpSlowMAPeriod + 3)
      return;

   // --- Only look for a new signal once a bar has actually closed -------
   // iTime(...,0) returns the OPEN time of the current (still forming)
   // bar. That value changes exactly once, at the moment a new bar
   // begins - which is also the moment the previous bar has just closed.
   datetime currentBarTime = iTime(_Symbol, InpMATimeframe, 0);
   if(currentBarTime == 0)
      return; // history/data not ready yet

   if(InpOneSignalPerBar && currentBarTime == g_lastBarTime)
      return; // we already evaluated this bar, nothing new to do

   // --- Read the last two CLOSED values of each moving average ----------
   // Index 1 = the most recently closed bar, index 2 = the bar before it.
   // We deliberately skip index 0 (the still-forming bar) because its
   // value keeps changing tick by tick and would give unreliable signals.
   double fastMA[], slowMA[];
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);

   if(CopyBuffer(g_fastMAHandle, 0, 1, 2, fastMA) != 2)
      return; // could not read the fast MA values yet, try again next tick
   if(CopyBuffer(g_slowMAHandle, 0, 1, 2, slowMA) != 2)
      return; // could not read the slow MA values yet, try again next tick

   // --- Optional trend filter -------------------------------------------
   // Only allow a bullish signal if the market is above the trend MA, and
   // a bearish signal if it is below - this filters out crossovers that
   // happen while the bigger picture is going nowhere (the main source of
   // whipsaw losses on a plain crossover system).
   bool trendBullOK = true;
   bool trendBearOK = true;
   if(g_trendMAHandle != INVALID_HANDLE)
   {
      double trendMA[];
      ArraySetAsSeries(trendMA, true);
      if(CopyBuffer(g_trendMAHandle, 0, 1, 1, trendMA) != 1)
         return; // trend data not ready yet, try again next tick

      double closePrev = iClose(_Symbol, InpMATimeframe, 1);
      trendBullOK = (closePrev > trendMA[0]);
      trendBearOK = (closePrev < trendMA[0]);
   }

   // --- Optional ATR value for volatility-based stops --------------------
   double atrValue = 0.0;
   if(InpUseATRStops && g_atrHandle != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) == 1)
         atrValue = atrBuf[0];
   }

   // --- Optional minimum crossover distance filter ------------------------
   // Ignores crosses where the fast and slow MA are barely touching, which
   // are usually just market noise rather than a genuine change of
   // direction.
   bool crossDistOK = true;
   if(InpMinCrossDistPoints > 0)
      crossDistOK = (MathAbs(fastMA[0] - slowMA[0]) >= InpMinCrossDistPoints * _Point);

   // --- Detect a crossover -------------------------------------------------
   // fastMA[0]/slowMA[0] = values on the last closed bar
   // fastMA[1]/slowMA[1] = values on the bar before that
   bool bullishCross = (fastMA[0] > slowMA[0] && fastMA[1] <= slowMA[1]) && trendBullOK && crossDistOK;
   bool bearishCross = (fastMA[0] < slowMA[0] && fastMA[1] >= slowMA[1]) && trendBearOK && crossDistOK;

   // Remember that we evaluated this bar, and persist it so it survives a
   // terminal restart. We do this regardless of whether a signal fired,
   // so we never re-evaluate the same closed bar twice.
   g_lastBarTime = currentBarTime;
   GlobalVariableSet(g_gvName, (double)g_lastBarTime);

   if(!bullishCross && !bearishCross)
      return; // nothing to do on this bar

   // --- Do not attempt to trade if trading is not currently allowed -----
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("MA_Cross_EA: trading is not allowed right now (AutoTrading off or terminal restriction).");
      return;
   }

   // --- Daily circuit breakers -------------------------------------------
   // Computed straight from the account's own trade history (filtered to
   // OUR symbol and magic number), so it is correct even right after a
   // terminal restart - there is nothing to "restore" because nothing was
   // ever cached.
   double todayProfit = 0.0;
   int    todayTrades  = 0;
   GetTodayStats(todayProfit, todayTrades);

   if(InpDailyMaxLossUSD > 0.0 && todayProfit <= -InpDailyMaxLossUSD)
   {
      PrintFormat("MA_Cross_EA: daily max loss reached (today P/L=%.2f) - no new trades until tomorrow.", todayProfit);
      if(InpCloseAllOnDailyLossLimit)
         CloseAllOwnPositions();
      return;
   }

   if(InpDailyProfitTargetUSD > 0.0 && todayProfit >= InpDailyProfitTargetUSD)
   {
      PrintFormat("MA_Cross_EA: daily profit target reached (today P/L=%.2f) - no new trades until tomorrow.", todayProfit);
      if(InpCloseAllOnDailyTarget)
         CloseAllOwnPositions();
      return;
   }

   if(InpMaxTradesPerDay > 0 && todayTrades >= InpMaxTradesPerDay)
   {
      PrintFormat("MA_Cross_EA: max trades per day reached (%d) - no new trades until tomorrow.", todayTrades);
      return;
   }

   if(bullishCross)
      OpenBuy(atrValue);
   else // bearishCross
      OpenSell(atrValue);
}

//+------------------------------------------------------------------+
//| Returns true if a position with OUR magic number, on OUR symbol, |
//| of the given type (BUY or SELL) is currently open.               |
//+------------------------------------------------------------------+
bool HasOpenPosition(const ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i); // also selects the position for the Get*() calls below
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Closes every open position that belongs to THIS EA (same symbol   |
//| and magic number) and matches the given type (BUY or SELL).       |
//+------------------------------------------------------------------+
void ClosePositionsByType(const ENUM_POSITION_TYPE type)
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
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      if(!trade.PositionClose(ticket, InpSlippagePoints))
         PrintFormat("MA_Cross_EA: failed to close position #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Closes EVERY open position that belongs to this EA (same symbol   |
//| and magic number), regardless of type. Used by the daily circuit  |
//| breakers.                                                          |
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
         PrintFormat("MA_Cross_EA: failed to close position #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Adds up today's realized profit (net of swap and commission) and  |
//| counts how many trades this EA has opened today, by reading the   |
//| account's own deal history for our symbol and magic number. Since |
//| this reads straight from the trade server's history rather than a |
//| cached variable, it is automatically correct after a restart.     |
//+------------------------------------------------------------------+
void GetTodayStats(double &profit, int &tradesOpened)
{
   profit       = 0.0;
   tradesOpened = 0;

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
         tradesOpened++;
   }
}

//+------------------------------------------------------------------+
//| Manages every open position that belongs to this EA: moves the    |
//| stop loss to break-even once far enough in profit, and/or trails  |
//| it behind price. Runs on every tick so it reacts to price          |
//| immediately, not just once per bar.                                |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!InpUseBreakeven && !InpUseTrailingStop)
      return;

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

      ENUM_POSITION_TYPE type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double             currentSL = PositionGetDouble(POSITION_SL);
      double             currentTP = PositionGetDouble(POSITION_TP);
      double             price     = (type == POSITION_TYPE_BUY)
                                      ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitPoints = (type == POSITION_TYPE_BUY)
                             ? (price - openPrice) / _Point
                             : (openPrice - price) / _Point;

      double candidateSL = currentSL;
      bool   improved     = false;

      if(InpUseBreakeven && profitPoints >= InpBreakevenTriggerPoints)
      {
         double beSL = (type == POSITION_TYPE_BUY)
                       ? openPrice + InpBreakevenOffsetPoints * _Point
                       : openPrice - InpBreakevenOffsetPoints * _Point;
         if(IsBetterStop(type, beSL, candidateSL, InpTrailingStepPoints))
         {
            candidateSL = beSL;
            improved    = true;
         }
      }

      if(InpUseTrailingStop && profitPoints >= InpTrailingStopPoints)
      {
         double trailSL = (type == POSITION_TYPE_BUY)
                          ? price - InpTrailingStopPoints * _Point
                          : price + InpTrailingStopPoints * _Point;
         if(IsBetterStop(type, trailSL, candidateSL, InpTrailingStepPoints))
         {
            candidateSL = trailSL;
            improved    = true;
         }
      }

      if(!improved)
         continue;

      // Never send a stop that is closer to price than the broker allows -
      // that would just be rejected, so we skip it quietly and try again
      // on a later tick once price has moved further.
      bool farEnough = (type == POSITION_TYPE_BUY)
                        ? (price - candidateSL) >= minDist
                        : (candidateSL - price) >= minDist;
      if(!farEnough)
         continue;

      candidateSL = NormalizeDouble(candidateSL, _Digits);
      if(!trade.PositionModify(ticket, candidateSL, currentTP))
         PrintFormat("MA_Cross_EA: failed to modify SL on #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Returns true if "candidate" is a stop-loss price that protects    |
//| MORE profit than "current" (and is therefore worth sending to the |
//| broker), for the given position type. A candidate of 0 (no stop)  |
//| is never considered an improvement. Requiring the improvement to  |
//| be at least stepPoints keeps us from re-sending a practically      |
//| identical stop on every single tick.                              |
//+------------------------------------------------------------------+
bool IsBetterStop(const ENUM_POSITION_TYPE type, const double candidate, const double current, const int stepPoints)
{
   if(candidate <= 0.0)
      return(false);
   if(current <= 0.0)
      return(true); // position currently has no stop loss at all

   double step = stepPoints * _Point;
   if(type == POSITION_TYPE_BUY)
      return(candidate > current + step);
   else
      return(candidate < current - step);
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
//| Works out a position size that risks InpRiskPercent % of the      |
//| current account balance, given the planned distance (in price,    |
//| not points) between entry and stop loss. Falls back to the fixed  |
//| InpLotSize if that distance or the symbol's tick data is unusable.|
//+------------------------------------------------------------------+
double CalcRiskLot(const double slDistancePrice)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0 || slDistancePrice <= 0.0)
      return NormalizeLot(InpLotSize); // not enough information, fall back to the fixed lot input

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return NormalizeLot(InpLotSize);

   return NormalizeLot(riskAmount / lossPerLot);
}

//+------------------------------------------------------------------+
//| Works out safe Stop Loss / Take Profit prices for a new trade,    |
//| either from the ATR (if InpUseATRStops is true and a valid ATR    |
//| value was supplied) or from the fixed point inputs, and makes     |
//| sure the distance is never smaller than what the broker requires  |
//| for this symbol (its "stops level"/"freeze level").                |
//+------------------------------------------------------------------+
void CalculateStops(const bool isBuy, const double entryPrice, const double atrValue, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   long stopsLevelPoints  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLevelPoints, (double)freezeLevelPoints) * _Point;

   double slDist = 0.0, tpDist = 0.0;
   if(InpUseATRStops && atrValue > 0.0)
   {
      slDist = atrValue * InpATRMultiplierSL;
      tpDist = atrValue * InpATRMultiplierTP;
   }
   else
   {
      slDist = InpStopLossPoints * _Point;
      tpDist = InpTakeProfitPoints * _Point;
   }

   if(slDist > 0.0)
   {
      slDist = MathMax(slDist, minDist);
      sl = isBuy ? entryPrice - slDist : entryPrice + slDist;
      sl = NormalizeDouble(sl, _Digits);
   }

   if(tpDist > 0.0)
   {
      tpDist = MathMax(tpDist, minDist);
      tp = isBuy ? entryPrice + tpDist : entryPrice - tpDist;
      tp = NormalizeDouble(tp, _Digits);
   }
}

//+------------------------------------------------------------------+
//| Opens a BUY position, unless we already have one.                 |
//| If InpCloseOpposite is true, any open SELL (ours) is closed first.|
//+------------------------------------------------------------------+
void OpenBuy(const double atrValue)
{
   if(HasOpenPosition(POSITION_TYPE_BUY))
      return; // already long, nothing more to do

   if(InpMaxSpreadPoints > 0)
   {
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPoints > InpMaxSpreadPoints)
      {
         PrintFormat("MA_Cross_EA: BUY skipped on %s, spread %d points > max %d.", _Symbol, spreadPoints, InpMaxSpreadPoints);
         return;
      }
   }

   if(InpCloseOpposite)
      ClosePositionsByType(POSITION_TYPE_SELL);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl, tp;
   CalculateStops(true, price, atrValue, sl, tp);

   double lots = (InpLotMode == LOT_MODE_RISK_PERCENT)
                 ? CalcRiskLot(MathAbs(price - sl))
                 : NormalizeLot(InpLotSize);

   if(!trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment))
      PrintFormat("MA_Cross_EA: BUY failed on %s | retcode=%d (%s)",
                  _Symbol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
      PrintFormat("MA_Cross_EA: BUY opened on %s | lots=%.2f price=%.5f sl=%.5f tp=%.5f",
                  _Symbol, lots, price, sl, tp);
}

//+------------------------------------------------------------------+
//| Opens a SELL position, unless we already have one.                |
//| If InpCloseOpposite is true, any open BUY (ours) is closed first. |
//+------------------------------------------------------------------+
void OpenSell(const double atrValue)
{
   if(HasOpenPosition(POSITION_TYPE_SELL))
      return; // already short, nothing more to do

   if(InpMaxSpreadPoints > 0)
   {
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPoints > InpMaxSpreadPoints)
      {
         PrintFormat("MA_Cross_EA: SELL skipped on %s, spread %d points > max %d.", _Symbol, spreadPoints, InpMaxSpreadPoints);
         return;
      }
   }

   if(InpCloseOpposite)
      ClosePositionsByType(POSITION_TYPE_BUY);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp;
   CalculateStops(false, price, atrValue, sl, tp);

   double lots = (InpLotMode == LOT_MODE_RISK_PERCENT)
                 ? CalcRiskLot(MathAbs(price - sl))
                 : NormalizeLot(InpLotSize);

   if(!trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment))
      PrintFormat("MA_Cross_EA: SELL failed on %s | retcode=%d (%s)",
                  _Symbol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
      PrintFormat("MA_Cross_EA: SELL opened on %s | lots=%.2f price=%.5f sl=%.5f tp=%.5f",
                  _Symbol, lots, price, sl, tp);
}
//+------------------------------------------------------------------+
