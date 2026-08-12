//+------------------------------------------------------------------+
//|                                        Grid_Martingale_EA.mq5   |
//|             Single-Direction Grid / Martingale Expert Advisor   |
//+------------------------------------------------------------------+
//
// WHAT THIS EA DOES (matches the referenced video)
// ---------------------------------------------------------------------
// It always trades in ONE fixed direction (SELL by default, like the
// video). When it is flat, it opens a first small position. If price
// keeps moving against that position by at least InpGridStepPoints, it
// adds ANOTHER position in the same direction, with a bigger lot size
// than the last one (InpLotMultiplier times bigger). This repeats, up to
// InpMaxGridLevels positions, exactly like the phone screen in the video
// showed a growing list of same-direction trades with growing lot sizes
// (0.01 -> 0.02 -> ... -> 0.50) as price moved against them. When price
// finally turns back, the WHOLE basket is usually deep in floating
// profit at once (because every position benefits from the turn, and
// the later, bigger positions do most of the work) - the EA then closes
// every position in the basket together and starts over.
//
// HONEST DISCLAIMER - PLEASE READ BEFORE USING THIS ON A REAL ACCOUNT
// -----------------------------------------------------------------------
// This is a MARTINGALE / GRID strategy, not scalping. It is fundamentally
// different from (and much riskier than) the other two EAs in this
// repository:
//   - It has NO per-trade stop loss. A single position can float at a
//     loss indefinitely while the grid keeps adding to it.
//   - Loss grows with every added level, and each new level is BIGGER
//     than the last, so the deeper the grid goes, the faster losses can
//     accelerate if price does not turn back.
//   - The video shows this working (a losing basket eventually turning
//     into a large profit), but a video only shows what happened ONCE.
//     If price trends strongly against the chosen direction for long
//     enough - which happens on real markets, including Gold - the grid
//     can run out of free margin and the BROKER will forcibly liquidate
//     positions at the worst possible time (a "stop out"), not this EA.
//   - Content that shows an account growing from $30 to $10,000+ this way
//     is showing you the times it worked. It is not showing you the
//     times a similar grid did not turn back in time.
// Because of this, this EA adds ONE thing the video did not show: a
// basket-wide "circuit breaker" (InpBasketMaxLossPercent) that closes
// every position in the basket if the FLOATING LOSS reaches a percentage
// of your account balance, so a bad run ends on the EA's terms instead of
// the broker's. It is a plain input, so you are free to set it to 0 to
// disable it and run the strategy exactly as shown in the video with no
// limit at all - but that reintroduces the unlimited-loss risk described
// above, so this is not recommended.
//
// SAFETY / DESIGN NOTES (shared with the other EAs in this repository)
// -----------------------------------------------------------------------
//   - Every trade carries InpMagicNumber, and every loop that inspects or
//     touches positions filters by both this magic number AND the
//     chart's symbol, so this EA never interferes with other EAs or with
//     your manual trades.
//   - Nothing about the state of the grid (how many levels are open, the
//     average entry price, the floating profit) is cached in a variable
//     - it is recalculated from the terminal's own live position list on
//     every tick, so a MetaTrader restart cannot desynchronize the EA
//     from reality. The only thing persisted across a restart is the
//     "paused until" timestamp set after the circuit breaker fires
//     (via a terminal Global Variable), so the EA does not immediately
//     start a brand new grid straight after protecting the account.
//   - Every parameter is a plain input (no arrays), so everything can be
//     optimized in the Strategy Tester.
//+------------------------------------------------------------------+
#property copyright "Educational Grid/Martingale EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_GRID_DIRECTION
{
   GRID_SELL = 0, // Always sell (matches the referenced video)
   GRID_BUY  = 1  // Always buy
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "===== General Settings ====="
input ulong               InpMagicNumber    = 202608020;         // Magic number (unique ID for this EA's trades)
input ulong               InpSlippagePoints = 30;                 // Maximum allowed slippage, in points
input string              InpTradeComment   = "Grid Martingale";  // Comment attached to every trade

input group "===== Grid Settings ====="
input ENUM_GRID_DIRECTION InpGridDirection  = GRID_SELL; // Direction the grid always trades in
input double               InpBaseLot        = 0.01;      // Lot size of the FIRST position in a grid cycle
input double               InpLotMultiplier  = 1.5;       // Each new level's lot = previous level's lot * this
input int                 InpMaxGridLevels  = 10;        // Maximum number of positions in one grid cycle
input int                 InpGridStepPoints = 200;       // Adverse move (points) required before adding the next level
input int                 InpMaxSpreadPoints = 50;        // Max spread allowed to open a level, in points (0 = off)

input group "===== Basket Profit / Loss (applies to the WHOLE grid at once) ====="
input double InpBasketTakeProfitPercent = 2.0;  // Close the whole basket once floating profit >= this % of balance (0 = off)
input double InpBasketTakeProfitUSD     = 0.0;  // Close the whole basket once floating profit >= this many USD (0 = off)
input double InpBasketMaxLossPercent    = 20.0; // Close the whole basket once floating LOSS >= this % of balance (0 = off, NOT recommended)
input int    InpPauseMinutesAfterStop   = 60;   // After the loss circuit breaker fires, wait this many minutes before starting a new grid

//+------------------------------------------------------------------+
//| GLOBAL (PROGRAM-WIDE) VARIABLES                                   |
//+------------------------------------------------------------------+
CTrade trade;
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
   if(InpBasketMaxLossPercent <= 0.0)
      Print("Grid_Martingale_EA: warning - InpBasketMaxLossPercent is 0/disabled. The grid can now lose money "
            "with NO limit, exactly like an unprotected version of the referenced video. This is not recommended.");

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
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Read the current state of our grid straight from the broker's
   //     own position list - nothing is cached, so this is always correct
   //     even right after a terminal restart. ------------------------------
   int    count        = 0;
   double totalLots     = 0.0;
   double weightedPrice = 0.0;
   double totalProfit   = 0.0;
   double extremePrice  = 0.0;
   GetBasketStats(count, totalLots, weightedPrice, totalProfit, extremePrice);

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

      if(InpBasketMaxLossPercent > 0.0)
      {
         double lossLimitUSD = balance * InpBasketMaxLossPercent / 100.0;
         if(totalProfit <= -lossLimitUSD)
         {
            PrintFormat("Grid_Martingale_EA: basket max loss reached (%.2f <= -%.2f) - closing all %d positions to protect the account.",
                        totalProfit, lossLimitUSD, count);
            CloseAllOwnPositions();
            SetPauseUntil(TimeCurrent() + InpPauseMinutesAfterStop * 60);
            return;
         }
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

   bool isSell = (InpGridDirection == GRID_SELL);

   // --- No grid open yet: start one with the first, smallest position ---
   if(count == 0)
   {
      OpenGridLevel(isSell, 0);
      return;
   }

   // --- A grid is already running: maybe add the next level -------------
   if(count >= InpMaxGridLevels)
      return; // at the cap - just wait for the basket TP or the loss circuit breaker

   double currentPrice = isSell ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double adverseMove  = isSell ? (currentPrice - extremePrice) : (extremePrice - currentPrice);

   if(adverseMove >= InpGridStepPoints * _Point)
      OpenGridLevel(isSell, count);
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
//| and the "extreme" open price of the basket - the highest entry    |
//| price for a SELL grid, the lowest for a BUY grid - which is what  |
//| a new level's distance is measured from.                          |
//+------------------------------------------------------------------+
void GetBasketStats(int &count, double &totalLots, double &weightedPrice, double &totalProfit, double &extremePrice)
{
   count         = 0;
   totalLots     = 0.0;
   weightedPrice = 0.0;
   totalProfit   = 0.0;
   extremePrice  = 0.0;

   bool isSell = (InpGridDirection == GRID_SELL);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      double volume    = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      count++;
      totalLots     += volume;
      weightedPrice += volume * openPrice;
      totalProfit   += profit;

      if(count == 1)
         extremePrice = openPrice;
      else if(isSell)
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
