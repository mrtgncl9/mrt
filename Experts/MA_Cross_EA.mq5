//+------------------------------------------------------------------+
//|                                                 MA_Cross_EA.mq5 |
//|                        Moving Average Crossover Expert Advisor  |
//+------------------------------------------------------------------+
//
// WHAT THIS EA DOES
// ------------------
// It watches two Moving Averages (a "fast" one and a "slow" one) that are
// calculated on the CLOSED bars of the chart it is attached to.
//
//   * When the fast MA crosses ABOVE the slow MA  -> it opens a BUY.
//   * When the fast MA crosses BELOW the slow MA  -> it opens a SELL.
//
// This is exactly the strategy described in the tutorial video: a fast
// moving average and a slow moving average are plotted on the chart and
// every time they cross, a trade is opened in the direction of the cross.
//
// On top of the video's logic this EA adds the safety features that are
// required to run unattended on a real or demo account:
//   - It only ever opens/modifies/closes positions that carry ITS OWN
//     magic number, so it can safely share an account with other EAs
//     or with your own manual trades.
//   - It always reads the CURRENT state of the account (open positions)
//     from the trade server instead of remembering it in a variable, so
//     if MetaTrader/the terminal restarts, it immediately "knows" what
//     is already open and will not open duplicate trades.
//   - It also stores the timestamp of the last bar it evaluated in a
//     terminal Global Variable, which survives a terminal restart, so it
//     will not re-evaluate (and potentially re-trade) a bar it has
//     already processed.
//   - Every input that defines the strategy (MA periods, method, applied
//     price, timeframe, lot size, stop loss/take profit, magic number...)
//     is a plain "input" variable, which means every single one of them
//     can be optimized in the MetaTrader Strategy Tester.
//   - It works on ANY symbol/timeframe because it never hard-codes pip
//     sizes, digits, minimum stop distances or lot steps - all of that is
//     read from the broker/symbol at run time with SymbolInfoDouble() /
//     SymbolInfoInteger().
//
// The code below is heavily commented on purpose so that every single
// line can be understood even without prior programming experience.
//+------------------------------------------------------------------+
#property copyright "Educational MA Crossover EA"
#property version   "1.00"
#property strict

// This one line pulls in the ready-made "CTrade" class that MetaTrader
// ships with every installation. CTrade already knows how to send buy
// orders, sell orders, close positions, etc. in a safe way, so we do not
// have to build all of that from scratch.
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//| Everything declared with "input" shows up in the EA's properties |
//| dialog AND in the Strategy Tester optimizer, so every one of them |
//| can be tweaked or optimized without touching the source code.    |
//+------------------------------------------------------------------+
input group "===== General Settings ====="
input ulong               InpMagicNumber    = 202608001;     // Magic number (unique ID for this EA's trades)
input double              InpLotSize        = 0.01;          // Trade volume, in lots
input ulong               InpSlippagePoints = 30;             // Maximum allowed slippage, in points
input string              InpTradeComment   = "MA Cross EA";  // Comment attached to every trade

input group "===== Moving Average Settings ====="
input int                 InpFastMAPeriod   = 20;             // Fast MA period
input int                 InpSlowMAPeriod   = 200;            // Slow MA period
input ENUM_MA_METHOD      InpMAMethod       = MODE_SMA;       // MA method (SMA / EMA / SMMA / LWMA)
input ENUM_APPLIED_PRICE  InpAppliedPrice   = PRICE_CLOSE;    // Price used to calculate the MAs
input ENUM_TIMEFRAMES     InpMATimeframe    = PERIOD_CURRENT; // Timeframe used to calculate the MAs

input group "===== Risk Management ====="
input int                 InpStopLossPoints   = 500;          // Stop loss, in points (0 = no stop loss)
input int                 InpTakeProfitPoints = 1000;         // Take profit, in points (0 = no take profit)

input group "===== Trade Behaviour ====="
input bool                InpCloseOpposite  = true;           // Close an opposite position before opening a new one
input bool                InpOneSignalPerBar = true;          // Only look for a signal once per closed bar

//+------------------------------------------------------------------+
//| GLOBAL (PROGRAM-WIDE) VARIABLES                                  |
//| These are declared outside of any function, so their value is   |
//| kept in memory for as long as the EA is running.                 |
//+------------------------------------------------------------------+
CTrade   trade;                  // The trading object we use to send/close orders
int      g_fastMAHandle = INVALID_HANDLE; // "handle" (ID number) of the fast MA indicator
int      g_slowMAHandle = INVALID_HANDLE; // "handle" (ID number) of the slow MA indicator
datetime g_lastBarTime  = 0;              // Timestamp of the last bar we already evaluated
string   g_gvName;                        // Name used to store g_lastBarTime as a terminal Global Variable

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
   if(InpLotSize <= 0.0)
   {
      Print("MA_Cross_EA: lot size must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Create the two Moving Average indicators -----------------------
   // iMA() does not calculate the indicator itself, it only returns a
   // "handle", i.e. a number that identifies this specific indicator
   // (symbol + timeframe + period + method + applied price). We keep the
   // handle in a global variable so we only have to create it once,
   // instead of on every single tick.
   g_fastMAHandle = iMA(_Symbol, InpMATimeframe, InpFastMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   g_slowMAHandle = iMA(_Symbol, InpMATimeframe, InpSlowMAPeriod, 0, InpMAMethod, InpAppliedPrice);

   if(g_fastMAHandle == INVALID_HANDLE || g_slowMAHandle == INVALID_HANDLE)
   {
      Print("MA_Cross_EA: failed to create one of the moving average indicators.");
      return(INIT_FAILED);
   }

   // --- Configure the trading object ------------------------------------
   trade.SetExpertMagicNumber(InpMagicNumber);      // Tag every trade we send with our magic number
   trade.SetDeviationInPoints(InpSlippagePoints);    // Maximum acceptable slippage
   trade.SetTypeFillingBySymbol(_Symbol);            // Let CTrade pick a filling mode this symbol supports
   trade.SetAsyncMode(false);                        // Wait for the trade server's answer before continuing

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

   // Note: we deliberately do NOT store "are we currently in a position"
   // in a variable. Instead, every time we need that information we ask
   // the trade server directly (see HasOpenPosition() below). That way
   // the EA's idea of its own position is always 100% in sync with
   // reality, even right after MetaTrader has been restarted.

   PrintFormat("MA_Cross_EA initialized on %s (%s) | Magic=%I64u | Fast=%d Slow=%d",
               _Symbol, EnumToString(InpMATimeframe), InpMagicNumber, InpFastMAPeriod, InpSlowMAPeriod);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//| Called automatically when the EA is removed from the chart, the   |
//| terminal is closed, the symbol/timeframe is changed, etc.         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release the indicator handles we created in OnInit(). This frees the
   // memory/resources MetaTrader allocated for them. It does NOT close
   // any open trades - trades belong to the account, not to the EA.
   if(g_fastMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastMAHandle);
   if(g_slowMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowMAHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//| Called automatically every time a new price quote (tick) arrives  |
//| for the symbol the EA is attached to.                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Make sure there is enough history to calculate both MAs ---------
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

   // --- Detect a crossover -------------------------------------------------
   // fastMA[0]/slowMA[0] = values on the last closed bar
   // fastMA[1]/slowMA[1] = values on the bar before that
   bool bullishCross = (fastMA[0] > slowMA[0] && fastMA[1] <= slowMA[1]); // fast crossed ABOVE slow
   bool bearishCross = (fastMA[0] < slowMA[0] && fastMA[1] >= slowMA[1]); // fast crossed BELOW slow

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

   if(bullishCross)
      OpenBuy();
   else // bearishCross
      OpenSell();
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
//| Works out safe Stop Loss / Take Profit prices for a new trade,    |
//| making sure the distance is never smaller than what the broker    |
//| requires for this symbol (its "stops level"/"freeze level").      |
//+------------------------------------------------------------------+
void CalculateStops(const bool isBuy, const double entryPrice, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   long stopsLevelPoints  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long minDistPoints     = (long)MathMax((double)stopsLevelPoints, (double)freezeLevelPoints);

   if(InpStopLossPoints > 0)
   {
      double slPoints = MathMax((double)InpStopLossPoints, (double)minDistPoints);
      double slDist   = slPoints * _Point;
      sl = isBuy ? entryPrice - slDist : entryPrice + slDist;
      sl = NormalizeDouble(sl, _Digits);
   }

   if(InpTakeProfitPoints > 0)
   {
      double tpPoints = MathMax((double)InpTakeProfitPoints, (double)minDistPoints);
      double tpDist   = tpPoints * _Point;
      tp = isBuy ? entryPrice + tpDist : entryPrice - tpDist;
      tp = NormalizeDouble(tp, _Digits);
   }
}

//+------------------------------------------------------------------+
//| Opens a BUY position, unless we already have one.                 |
//| If InpCloseOpposite is true, any open SELL (ours) is closed first.|
//+------------------------------------------------------------------+
void OpenBuy()
{
   if(HasOpenPosition(POSITION_TYPE_BUY))
      return; // already long, nothing more to do

   if(InpCloseOpposite)
      ClosePositionsByType(POSITION_TYPE_SELL);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl, tp;
   CalculateStops(true, price, sl, tp);
   double lots = NormalizeLot(InpLotSize);

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
void OpenSell()
{
   if(HasOpenPosition(POSITION_TYPE_SELL))
      return; // already short, nothing more to do

   if(InpCloseOpposite)
      ClosePositionsByType(POSITION_TYPE_BUY);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp;
   CalculateStops(false, price, sl, tp);
   double lots = NormalizeLot(InpLotSize);

   if(!trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment))
      PrintFormat("MA_Cross_EA: SELL failed on %s | retcode=%d (%s)",
                  _Symbol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
      PrintFormat("MA_Cross_EA: SELL opened on %s | lots=%.2f price=%.5f sl=%.5f tp=%.5f",
                  _Symbol, lots, price, sl, tp);
}
//+------------------------------------------------------------------+
