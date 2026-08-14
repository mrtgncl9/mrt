//+------------------------------------------------------------------+
//|                                          MERT_UNIVERSAL_EA_V4.mq5 |
//|         Session Range Breakout (Opening-Range) — any symbol       |
//|                          Multi-session edition                    |
//|                                                                   |
//|  Daily flow per ENABLED SESSION (server time), independently:     |
//|   1. Between StartHour/Min and EndHour/Min, capture that          |
//|      session's High/Low.                                          |
//|   2. At EndHour/Min, place Buy Stop @ High and Sell Stop @ Low     |
//|      (OCO) - tagged with that session's OWN magic number.         |
//|   3. When one fills, the opposite pending (same session) is       |
//|      deleted immediately.                                          |
//|   4. At CloseHour/Min, close that session's trades and delete its  |
//|      pendings.                                                     |
//|                                                                   |
//|  v4.1 change: the original design armed ONE breakout per day,     |
//|  which is why it looked like "too few trades" - a single opening- |
//|  range attempt is what the strategy IS. To trade more often while |
//|  keeping the exact same, tested logic, up to THREE independent    |
//|  sessions (e.g. Asia/London/New York opens) now run in parallel,  |
//|  each with its own magic number (InpMagicBase + session index),   |
//|  so up to 3 breakout attempts/day instead of 1 - without ever     |
//|  mixing one session's positions/orders with another's, and        |
//|  without loosening the entry logic itself (no "more trades by     |
//|  making the filters worse").                                       |
//|                                                                   |
//|  - Strict magic isolation, per session (never touches other EAs'  |
//|    trades, and sessions never touch each other's trades either).  |
//|  - Any symbol / timeframe.                                        |
//|  - Restores state after MT5 restart (server-side orders + GV      |
//|    per-day-per-session latches recomputed from history).          |
//|  - Optimizer-safe inputs (numeric / enum / bool only).            |
//|  - Range drawn on chart (rectangle + breakout level lines), one   |
//|    color-coded set per session.                                    |
//+------------------------------------------------------------------+
#property copyright "Mert"
#property version   "4.10"
#property strict

#include <Trade\Trade.mqh>

//--- SL mode (optimizer-safe enum)
enum ENUM_SL_MODE
  {
   SL_NONE     = 0,  // No stop loss
   SL_OPPOSITE = 1,  // Opposite side of range
   SL_POINTS   = 2   // Fixed points
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Identity / Isolation ==="
input long               InpMagicBase   = 20260812;       // Base magic; session N uses InpMagicBase+N-1
input ulong              InpDeviation   = 20;              // Max slippage (points)

input group "=== Session 1 (server time, 0-23 / 0-59) ==="
input bool               InpUseSession1  = true;           // Enable session 1
input int                InpS1StartHour  = 3;              // Range start hour
input int                InpS1StartMin   = 0;              // Range start minute
input int                InpS1EndHour    = 6;              // Range end hour (orders placed)
input int                InpS1EndMin     = 0;              // Range end minute
input int                InpS1CloseHour  = 18;             // Close/cancel hour
input int                InpS1CloseMin   = 0;              // Close/cancel minute

input group "=== Session 2 (optional - more trades/day) ==="
input bool               InpUseSession2  = true;           // Enable session 2
input int                InpS2StartHour  = 7;
input int                InpS2StartMin   = 0;
input int                InpS2EndHour    = 8;
input int                InpS2EndMin     = 0;
input int                InpS2CloseHour  = 16;
input int                InpS2CloseMin   = 0;

input group "=== Session 3 (optional - more trades/day) ==="
input bool               InpUseSession3  = true;           // Enable session 3
input int                InpS3StartHour  = 12;
input int                InpS3StartMin   = 0;
input int                InpS3EndHour    = 13;
input int                InpS3EndMin     = 0;
input int                InpS3CloseHour  = 21;
input int                InpS3CloseMin   = 0;

input group "=== Range / Direction (shared by all sessions) ==="
input ENUM_TIMEFRAMES    InpRangeTF      = PERIOD_CURRENT; // TF used to measure each range
input bool                InpTradeBuy     = true;           // Place Buy Stop @ high
input bool                InpTradeSell    = true;           // Place Sell Stop @ low

input group "=== Stop Loss ==="
input ENUM_SL_MODE       InpSLMode       = SL_OPPOSITE;    // SL mode
input double              InpSLPoints     = 300;            // SL points (SL_POINTS mode)

input group "=== Take Profit ==="
input double              InpTPRangeMult  = 1.0;            // TP = range size * this (0 = no TP)

input group "=== Money Management ==="
input double              InpRiskPercent  = 1.0;            // Risk per trade (% of balance)
input double              InpFixedLot     = 0.11;           // Fixed lot (>0 overrides risk%)
input double              InpMaxLot       = 0.0;            // Max lot cap (0 = symbol max)

input group "=== Visuals ==="
input bool                InpShowVisuals  = true;           // Draw ranges on chart
input color               InpRangeColor   = clrSlateGray;   // Range rectangle color
input color               InpBuyColor     = clrLimeGreen;   // Buy level color
input color               InpSellColor    = clrTomato;      // Sell level color

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   trade;

struct SessionCfg
  {
   bool    enabled;
   int     startHour, startMin, endHour, endMin, closeHour, closeMin;
   long    magic;
   string  gvArm;      // GV key: day this session's breakout was armed
   string  gvClose;    // GV key: day this session's close was executed
   string  objPrefix;  // chart-object prefix (session-scoped)
   string  tag;         // short label used in trade comments and logs
  };

SessionCfg g_sessions[3];

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
datetime DayStart(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

datetime TodayAt(datetime now, int h, int m)
  {
   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.hour = h; dt.min = m; dt.sec = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Position / order counters (magic + symbol scoped)                |
//+------------------------------------------------------------------+
int CountPositions(long magic)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)    continue;
      c++;
     }
   return c;
  }

int CountOrders(long magic)
  {
   int c = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)    continue;
      c++;
     }
   return c;
  }

void ClosePositions(long magic)
  {
   trade.SetExpertMagicNumber(magic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)    continue;
      trade.PositionClose(tk);
     }
  }

void DeleteOrders(long magic)
  {
   trade.SetExpertMagicNumber(magic);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)    continue;
      trade.OrderDelete(tk);
     }
  }

//+------------------------------------------------------------------+
//| Volume normalization                                             |
//+------------------------------------------------------------------+
double NormalizeVolume(double vol)
  {
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpMaxLot > 0.0) vmax = MathMin(vmax, InpMaxLot);
   if(vstep <= 0.0) vstep = 0.01;

   vol = MathRound(vol / vstep) * vstep;
   vol = MathMax(vmin, MathMin(vmax, vol));
   int digits = (int)MathMax(0, -MathLog10(vstep) + 0.5);
   return NormalizeDouble(vol, digits);
  }

//+------------------------------------------------------------------+
//| Lot from risk% and SL distance (price units)                     |
//+------------------------------------------------------------------+
double CalcLot(double slDistancePrice)
  {
   if(InpFixedLot > 0.0)
      return NormalizeVolume(InpFixedLot);
   if(slDistancePrice <= 0.0 || InpRiskPercent <= 0.0)
      return NormalizeVolume(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return NormalizeVolume(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return NormalizeVolume(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

   return NormalizeVolume(riskMoney / lossPerLot);
  }

//+------------------------------------------------------------------+
//| Measure session range from history                               |
//+------------------------------------------------------------------+
bool ComputeRange(datetime rangeStart, datetime rangeEnd, double &high, double &low)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, InpRangeTF, rangeStart, rangeEnd - 1, r);
   if(n <= 0) return false;

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < n; i++)
     {
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low  < lo) lo = r[i].low;
     }
   if(hi <= -DBL_MAX || lo >= DBL_MAX || hi <= lo) return false;

   high = hi;
   low  = lo;
   return true;
  }

//+------------------------------------------------------------------+
//| Compute SL / TP for a given side                                 |
//+------------------------------------------------------------------+
void BuildExits(bool isBuy, double entry, double rHigh, double rLow,
                double &sl, double &tp, double &slDist)
  {
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double rangeSize = rHigh - rLow;

   sl = 0.0; tp = 0.0; slDist = 0.0;

   //--- stop loss
   if(InpSLMode == SL_OPPOSITE)
     {
      // SL exactly at the opposite end of the range (no clamp)
      sl     = isBuy ? NormalizeDouble(rLow,  digits)
                     : NormalizeDouble(rHigh, digits);
      slDist = rangeSize;
     }
   else if(InpSLMode == SL_POINTS)
     {
      slDist = InpSLPoints * point;
      if(slDist < minStop) slDist = minStop;
      sl = isBuy ? NormalizeDouble(entry - slDist, digits)
                 : NormalizeDouble(entry + slDist, digits);
     }

   //--- take profit: multiple of the day's range size (0 = disabled)
   if(InpTPRangeMult > 0.0)
     {
      double tpDist = rangeSize * InpTPRangeMult;
      if(tpDist < minStop) tpDist = minStop;   // nudge out to broker minimum
      tp = isBuy ? NormalizeDouble(entry + tpDist, digits)
                 : NormalizeDouble(entry - tpDist, digits);
     }
   // else tp stays 0.0 -> no take profit
  }

//+------------------------------------------------------------------+
//| Place one stop order (with validation), for a given session      |
//+------------------------------------------------------------------+
void PlaceStop(const SessionCfg &s, bool isBuy, double level, double rHigh, double rLow)
  {
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry   = NormalizeDouble(level, digits);

   // stop-entry must sit beyond current price by >= stops level
   if(isBuy && entry < ask + minStop)
     { PrintFormat("%s: skip Buy Stop, price already at/above range high", s.tag); return; }
   if(!isBuy && entry > bid - minStop)
     { PrintFormat("%s: skip Sell Stop, price already at/below range low", s.tag); return; }

   double sl, tp, slDist;
   BuildExits(isBuy, entry, rHigh, rLow, sl, tp, slDist);

   // opposite-boundary SL must respect broker stops level relative to entry
   if(sl != 0.0 && MathAbs(entry - sl) < minStop)
     {
      PrintFormat("%s: skip %s, range too tight, SL inside stops level", s.tag, isBuy ? "Buy Stop" : "Sell Stop");
      return;
     }

   double lot = CalcLot(slDist);
   if(lot <= 0.0) return;

   trade.SetExpertMagicNumber(s.magic);
   bool ok = isBuy ? trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, s.tag)
                   : trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, s.tag);
   if(!ok)
      PrintFormat("%s: %s failed, retcode=%d (%s)", s.tag, isBuy ? "BuyStop" : "SellStop",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Draw range rectangle + breakout level lines for one session      |
//+------------------------------------------------------------------+
void DrawRange(const SessionCfg &s, datetime day, datetime rangeStart, datetime rangeEnd,
               datetime closeT, double high, double low)
  {
   if(!InpShowVisuals) return;
   if((bool)MQLInfoInteger(MQL_TESTER) && !(bool)MQLInfoInteger(MQL_VISUAL_MODE)) return;

   string tag  = (string)(long)day;
   string rect = s.objPrefix + "R_" + tag;
   string hl   = s.objPrefix + "H_" + tag;
   string ll   = s.objPrefix + "L_" + tag;

   if(ObjectFind(0, rect) < 0) ObjectCreate(0, rect, OBJ_RECTANGLE, 0, rangeStart, high, rangeEnd, low);
   ObjectSetInteger(0, rect, OBJPROP_TIME, 0, rangeStart);
   ObjectSetDouble (0, rect, OBJPROP_PRICE, 0, high);
   ObjectSetInteger(0, rect, OBJPROP_TIME, 1, rangeEnd);
   ObjectSetDouble (0, rect, OBJPROP_PRICE, 1, low);
   ObjectSetInteger(0, rect, OBJPROP_COLOR, InpRangeColor);
   ObjectSetInteger(0, rect, OBJPROP_BACK, true);
   ObjectSetInteger(0, rect, OBJPROP_FILL, true);

   if(ObjectFind(0, hl) < 0) ObjectCreate(0, hl, OBJ_TREND, 0, rangeEnd, high, closeT, high);
   ObjectSetInteger(0, hl, OBJPROP_TIME, 0, rangeEnd);
   ObjectSetDouble (0, hl, OBJPROP_PRICE, 0, high);
   ObjectSetInteger(0, hl, OBJPROP_TIME, 1, closeT);
   ObjectSetDouble (0, hl, OBJPROP_PRICE, 1, high);
   ObjectSetInteger(0, hl, OBJPROP_COLOR, InpBuyColor);
   ObjectSetInteger(0, hl, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, hl, OBJPROP_WIDTH, 2);

   if(ObjectFind(0, ll) < 0) ObjectCreate(0, ll, OBJ_TREND, 0, rangeEnd, low, closeT, low);
   ObjectSetInteger(0, ll, OBJPROP_TIME, 0, rangeEnd);
   ObjectSetDouble (0, ll, OBJPROP_PRICE, 0, low);
   ObjectSetInteger(0, ll, OBJPROP_TIME, 1, closeT);
   ObjectSetDouble (0, ll, OBJPROP_PRICE, 1, low);
   ObjectSetInteger(0, ll, OBJPROP_COLOR, InpSellColor);
   ObjectSetInteger(0, ll, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, ll, OBJPROP_WIDTH, 2);

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Arm breakout orders once per day, for one session                 |
//| (state-restore safe)                                               |
//+------------------------------------------------------------------+
void ArmIfNeeded(const SessionCfg &s, datetime day, datetime rangeStart, datetime rangeEnd, datetime closeT)
  {
   // already armed today?
   if(GlobalVariableCheck(s.gvArm) && (datetime)GlobalVariableGet(s.gvArm) == day)
      return;

   // if trades/orders already exist for today (e.g. GV lost after restart),
   // latch and skip to avoid duplicates
   if(CountPositions(s.magic) > 0 || CountOrders(s.magic) > 0)
     {
      GlobalVariableSet(s.gvArm, (double)day);
      return;
     }

   double high, low;
   if(!ComputeRange(rangeStart, rangeEnd, high, low))
      return;  // no data yet — retry next tick

   if(InpTradeBuy)  PlaceStop(s, true,  high, high, low);
   if(InpTradeSell) PlaceStop(s, false, low,  high, low);

   DrawRange(s, day, rangeStart, rangeEnd, closeT, high, low);
   GlobalVariableSet(s.gvArm, (double)day);
  }

//+------------------------------------------------------------------+
//| Validate one session's time inputs; returns false and logs on    |
//| failure.                                                           |
//+------------------------------------------------------------------+
bool ValidateSessionTimes(const string tag, int sh, int sm, int eh, int em, int ch, int cm)
  {
   if(sh < 0 || sh > 23 || eh < 0 || eh > 23 || ch < 0 || ch > 23 ||
      sm < 0 || sm > 59 || em < 0 || em > 59 || cm < 0 || cm > 59)
     { PrintFormat("Init fail: %s has an invalid time input", tag); return(false); }

   datetime probe = D'2000.01.01 00:00';
   datetime s = TodayAt(probe, sh, sm);
   datetime e = TodayAt(probe, eh, em);
   datetime c = TodayAt(probe, ch, cm);
   if(!(s < e && e <= c))
     { PrintFormat("Init fail: %s requires Start < End <= Close within the same day", tag); return(false); }

   return(true);
  }

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!InpTradeBuy && !InpTradeSell)
     { Print("Init fail: both directions disabled"); return(INIT_PARAMETERS_INCORRECT); }
   if(!InpUseSession1 && !InpUseSession2 && !InpUseSession3)
     { Print("Init fail: all three sessions are disabled - nothing to trade"); return(INIT_PARAMETERS_INCORRECT); }

   g_sessions[0].enabled   = InpUseSession1;
   g_sessions[0].startHour = InpS1StartHour; g_sessions[0].startMin = InpS1StartMin;
   g_sessions[0].endHour   = InpS1EndHour;   g_sessions[0].endMin   = InpS1EndMin;
   g_sessions[0].closeHour = InpS1CloseHour; g_sessions[0].closeMin = InpS1CloseMin;
   g_sessions[0].tag       = "MRB-S1";

   g_sessions[1].enabled   = InpUseSession2;
   g_sessions[1].startHour = InpS2StartHour; g_sessions[1].startMin = InpS2StartMin;
   g_sessions[1].endHour   = InpS2EndHour;   g_sessions[1].endMin   = InpS2EndMin;
   g_sessions[1].closeHour = InpS2CloseHour; g_sessions[1].closeMin = InpS2CloseMin;
   g_sessions[1].tag       = "MRB-S2";

   g_sessions[2].enabled   = InpUseSession3;
   g_sessions[2].startHour = InpS3StartHour; g_sessions[2].startMin = InpS3StartMin;
   g_sessions[2].endHour   = InpS3EndHour;   g_sessions[2].endMin   = InpS3EndMin;
   g_sessions[2].closeHour = InpS3CloseHour; g_sessions[2].closeMin = InpS3CloseMin;
   g_sessions[2].tag       = "MRB-S3";

   for(int i = 0; i < 3; i++)
     {
      if(!g_sessions[i].enabled) continue;
      if(!ValidateSessionTimes(g_sessions[i].tag, g_sessions[i].startHour, g_sessions[i].startMin,
                                g_sessions[i].endHour, g_sessions[i].endMin,
                                g_sessions[i].closeHour, g_sessions[i].closeMin))
         return(INIT_PARAMETERS_INCORRECT);

      g_sessions[i].magic     = InpMagicBase + i;
      g_sessions[i].gvArm     = StringFormat("MRB_ARM_%I64d_%s",   g_sessions[i].magic, _Symbol);
      g_sessions[i].gvClose   = StringFormat("MRB_CLOSE_%I64d_%s", g_sessions[i].magic, _Symbol);
      g_sessions[i].objPrefix = StringFormat("MRB_%I64d_",         g_sessions[i].magic);
     }

   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   for(int i = 0; i < 3; i++)
     {
      if(!g_sessions[i].enabled) continue;
      int existing = CountPositions(g_sessions[i].magic) + CountOrders(g_sessions[i].magic);
      if(existing > 0)
         PrintFormat("%s: state restored, %d live order(s)/position(s) on %s",
                     g_sessions[i].tag, existing, _Symbol);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // keep GV latches so state survives restart; tidy chart objects only
   // when removed from a live chart (preserve them in the tester report)
   if((bool)MQLInfoInteger(MQL_TESTER)) return;
   for(int i = 0; i < 3; i++)
      if(g_sessions[i].enabled)
         ObjectsDeleteAll(0, g_sessions[i].objPrefix);
  }

//+------------------------------------------------------------------+
//| Immediate OCO: when a session's stop fills, drop that session's   |
//| opposite pending (never another session's).                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   for(int i = 0; i < 3; i++)
     {
      if(!g_sessions[i].enabled) continue;
      if(CountPositions(g_sessions[i].magic) > 0 && CountOrders(g_sessions[i].magic) > 0)
         DeleteOrders(g_sessions[i].magic);
     }
  }

//+------------------------------------------------------------------+
//| Per-session daily flow: flatten at close time, else arm after the |
//| range has formed.                                                  |
//+------------------------------------------------------------------+
void ProcessSession(const SessionCfg &s, datetime now, datetime day)
  {
   datetime rangeStart = TodayAt(now, s.startHour, s.startMin);
   datetime rangeEnd    = TodayAt(now, s.endHour,   s.endMin);
   datetime closeT       = TodayAt(now, s.closeHour, s.closeMin);

   //--- close time: flatten & cancel once per day, then idle
   if(now >= closeT)
     {
      bool doneToday = (GlobalVariableCheck(s.gvClose) &&
                        (datetime)GlobalVariableGet(s.gvClose) == day);
      if(!doneToday)
        {
         ClosePositions(s.magic);
         DeleteOrders(s.magic);
         GlobalVariableSet(s.gvClose, (double)day);
        }
      return;
     }

   //--- OCO backup (in case a fill happened between transactions)
   if(CountPositions(s.magic) > 0 && CountOrders(s.magic) > 0)
      DeleteOrders(s.magic);

   //--- arm breakout orders after the range has formed
   if(now >= rangeEnd)
      ArmIfNeeded(s, day, rangeStart, rangeEnd, closeT);
  }

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();
   datetime day = DayStart(now);

   for(int i = 0; i < 3; i++)
      if(g_sessions[i].enabled)
         ProcessSession(g_sessions[i], now, day);
  }
//+------------------------------------------------------------------+
