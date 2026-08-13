//+------------------------------------------------------------------+
//|                                   XAUUSD_Basket_Scalper_EA.mq5  |
//|            Multi-Timeframe Trend-Aligned Basket Scalper (M1)    |
//+------------------------------------------------------------------+
//
// STRATEJI OZETI
// ---------------
// Trend filtresi M5 (EMA TrendEMAFast > TrendEMASlow ve kapanis >
// TrendEMAFast), tetik M1 (EMAFast/EMASlow kesisimi veya EMASlow'a
// cekilip tekrar ayni yonde kapanma), RSI(14) bandi, ADX(14) minimum
// esigi, son mumun yonu ve govde/ATR orani, spread filtresi. Sinyal
// olustugunda BatchOrderCount adet ESIT lotlu emir tek sepette acilir.
// Sepet; para bazli TP/SL, basabas, trailing-profit, maksimum sure ve
// trend bozulmasi kurallariyla TOPLU yonetilir. Martingale / zarar
// yonunde grid / kayiptan sonra lot artirma YOKTUR - bu EA'da hicbir
// kosulda uygulanmaz.
//
// GIRDI ADINDA KUCUK SAPMALAR (istenen listeye gore, gerekce ile)
// -------------------------------------------------------------------
//   - "TrendEMA" tek girdisi yerine TrendEMAFast + TrendEMASlow: strateji
//     metni M5'te iki ayri EMA (50 ve 200) istiyor, tek girdiyle bu ifade
//     edilemezdi.
//   - BodyMinATRRatio / BodyMaxATRRatio eklendi: "govde minimum ATR
//     oranini karsilamali ama spike olmamali" kurali icin isimlendirilmis
//     bir esik gerekliydi, listede yoktu.
//   - MaxDailyBaskets eklendi: guvenlik filtreleri bolumunde istenen
//     "maksimum gunluk sepet sayisi" icin, ana girdi listesinde adi
//     gecmiyordu.
//   - UseAddOnProfit / AddOnProfitStepMoney eklendi: "istege bagli ekleme
//     modu" ozelligi icin (varsayilan kapali, kaybederken asla eklemez,
//     hep sepetteki mevcut esit lotla ekler).
//
// RESTART GUVENLIGI
// -------------------
// Sepetin kendisi (kac pozisyon, ortalama fiyat, yon, floating kar/zarar,
// en eski acilis zamani) HER TICK'TE canli pozisyon listesinden yeniden
// hesaplanir - hicbir yerde onbelleklenmez, terminal yeniden baslasa da
// gercekle senkron kalir. Sadece zamanla biriken sayaclar (trailing
// zirve kari, ardisik kayip sayisi, bugunku sepet sayisi, gunluk
// kilit, equity zirvesi) terminal Global Degisken olarak diske
// yazilir, boylece o sayaclar da restart sonrasi kaybolmaz.
//+------------------------------------------------------------------+
#property copyright "Educational Basket Scalper EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ENUMS                                                              |
//+------------------------------------------------------------------+
enum ENUM_SIGNAL_MODE
{
   SIGNAL_FAST     = 0, // Fast: gevsetilmis esikler, daha sik sinyal
   SIGNAL_BALANCED = 1, // Balanced: girdi degerleri aynen kullanilir
   SIGNAL_SAFE     = 2  // Safe: siki esikler, daha az ama daha secici sinyal
};

enum ENUM_TRIGGER_MODE
{
   TRIGGER_EVERY_TICK = 0, // Sinyal her tick'te yeniden degerlendirilir
   TRIGGER_NEW_M1_BAR = 1  // Sinyal sadece yeni bir M1 mumu acildiginda degerlendirilir (verimli, onerilir)
};

enum ENUM_LOT_MODE
{
   LOT_FIXED       = 0, // Her emir icin sabit lot (FixedLot)
   LOT_RISK_PERCENT = 1 // Sepetin toplam riskine gore otomatik lot
};

enum ENUM_BASKET_SIDE
{
   BASKET_NONE = 0,
   BASKET_BUY  = 1,
   BASKET_SELL = 2
};

//+------------------------------------------------------------------+
//| INPUTS                                                             |
//+------------------------------------------------------------------+
input group "===== General ====="
input ulong             MagicNumber    = 202608100;              // Magic number
input string             TradeComment   = "XAUUSD Basket Scalper"; // Trade comment
input ENUM_SIGNAL_MODE   SignalMode     = SIGNAL_BALANCED;         // Signal strictness preset
input ENUM_TRIGGER_MODE  TriggerMode    = TRIGGER_NEW_M1_BAR;      // How often the entry signal is evaluated

input group "===== Lot / Basket Sizing ====="
input ENUM_LOT_MODE  LotMode              = LOT_FIXED; // Volume mode
input double          FixedLot             = 0.01;      // Used when LotMode = Fixed
input double          RiskPercentPerBasket = 1.0;       // % of balance risked by the WHOLE basket (used when LotMode = Risk percent)
input int             BatchOrderCount      = 3;          // Orders opened per signal (1-10)
input int             MaxPositions         = 3;          // Hard cap on positions in one basket (>= BatchOrderCount)
input double          MaxLotPerOrder       = 0.50;       // Safety cap: max lot on any single order
input double          MaxTotalLot          = 1.00;       // Safety cap: max combined lot for the whole basket

input group "===== M1 Entry EMAs ====="
input int EMAFast = 9;  // M1 fast EMA period
input int EMASlow = 21; // M1 slow EMA period

input group "===== M5 Trend Filter ====="
input int TrendEMAFast = 50;  // M5 fast trend EMA period
input int TrendEMASlow = 200; // M5 slow trend EMA period

input group "===== RSI (M1) ====="
input int    RSIPeriod  = 14;
input double RSIBuyMin  = 52.0;
input double RSIBuyMax  = 70.0;
input double RSISellMin = 30.0;
input double RSISellMax = 48.0;

input group "===== ADX (M1) ====="
input int    ADXPeriod = 14;
input double MinADX    = 20.0;

input group "===== ATR / Candle Filters (M1) ====="
input int    ATRPeriod        = 14;
input int    MinATR           = 50;    // Minimum M1 ATR, in points (0 = off)
input int    MaxATR           = 1000;  // Maximum M1 ATR, in points (0 = off)
input double BodyMinATRRatio  = 0.15;  // Last candle body must be >= this * ATR
input double BodyMaxATRRatio  = 2.50;  // Last candle body must be <= this * ATR (rejects spike candles)
input double StopATRMultiplier = 2.0;  // Real broker-side emergency SL distance = ATR * this

input group "===== Execution ====="
input int   MaxSpreadPoints    = 200; // Max spread to open/add, in points
input ulong MaxSlippagePoints  = 30;  // Max slippage, in points

input group "===== Basket Exit (money-based) ====="
input double BasketProfitMoney       = 5.0;  // Close whole basket at this floating profit, USD
input double BasketLossMoney         = 4.0;  // Close whole basket at this floating loss, USD
input double BasketTrailStartMoney   = 3.0;  // Start trailing once floating profit reaches this
input double BasketTrailDistanceMoney = 1.5; // Close if profit falls back this far from its peak
input double BreakEvenStartMoney     = 2.0;  // Move every order's real SL to break-even at this floating profit
input int    MaxBasketMinutes        = 120;  // Force-close the basket after this many minutes (0 = off)
input int    CooldownBars            = 2;    // M1 bars to wait after a basket closes before a new one can open

input group "===== Optional Add-On (profit-only, equal lot, never martingale) ====="
input bool   UseAddOnProfit      = false; // Allow adding one more equal-lot order while the basket is winning
input double AddOnProfitStepMoney = 2.0;  // Every this much extra floating profit unlocks one more order

input group "===== Session Filter ====="
input bool   UseSessionFilter = true;
input string SessionStart     = "07:00"; // Server time, HH:MM
input string SessionEnd       = "20:00"; // Server time, HH:MM

input group "===== News Filter (built-in MT5 Economic Calendar) ====="
input bool UseNewsFilter     = false;
input int  NewsMinutesBefore = 30;
input int  NewsMinutesAfter  = 30;

input group "===== Daily / Account Protection ====="
input double MaxDailyLossPercent      = 2.0;   // % of balance
input double MaxDailyProfitPercent    = 0.0;   // % of balance (0 = off: never lock in gains early, let winners run)
input double MaxEquityDrawdownPercent = 10.0;  // % from the highest equity ever seen by this EA
input int    MaxConsecutiveLosses     = 3;
input int    CooldownAfterLossMinutes = 60;
input double MinimumMarginLevel       = 150.0; // %, skip new baskets below this (0 = off)
input int    MaxDailyBaskets          = 6;     // 0 = off

input group "===== Friday Close ====="
input bool   CloseFriday     = true;
input string FridayCloseTime = "21:00"; // Server time, HH:MM

input group "===== Direction / UI ====="
input bool AllowBuy      = true;
input bool AllowSell     = true;
input bool ShowDashboard = true;

//+------------------------------------------------------------------+
//| GLOBALS                                                            |
//+------------------------------------------------------------------+
CTrade trade;

int g_emaFastHandle  = INVALID_HANDLE; // M1
int g_emaSlowHandle  = INVALID_HANDLE; // M1
int g_trendFastHandle = INVALID_HANDLE; // M5
int g_trendSlowHandle = INVALID_HANDLE; // M5
int g_rsiHandle       = INVALID_HANDLE; // M1
int g_adxHandle       = INVALID_HANDLE; // M1
int g_atrHandle       = INVALID_HANDLE; // M1

datetime g_lastEvalBarTime = 0;
bool     g_isNettingAccount = false;
string   g_blockedReason = "";

string g_gvPrefix; // unique per magic+symbol, used to namespace all persisted Global Variables below

#define GV_BASKETPEAK   (g_gvPrefix + "_basketpeak")
#define GV_CONSECLOSS   (g_gvPrefix + "_consecloss")
#define GV_PAUSEUNTIL   (g_gvPrefix + "_pauseuntil")
#define GV_PEAKEQUITY   (g_gvPrefix + "_peakequity")
#define GV_EQUITYSTOP   (g_gvPrefix + "_equitystop")
#define GV_LASTCLOSEBAR (g_gvPrefix + "_lastclosebar")
#define GV_DAILYCOUNT   (g_gvPrefix + "_dailycount")
#define GV_DAILYCOUNTDAY (g_gvPrefix + "_dailycountday")

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(BatchOrderCount < 1 || BatchOrderCount > 10)
   {
      Print("XAUUSD_Basket_Scalper_EA: BatchOrderCount must be between 1 and 10.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxPositions < BatchOrderCount)
   {
      Print("XAUUSD_Basket_Scalper_EA: MaxPositions must be >= BatchOrderCount.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(LotMode == LOT_FIXED && FixedLot <= 0.0)
   {
      Print("XAUUSD_Basket_Scalper_EA: FixedLot must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(LotMode == LOT_RISK_PERCENT && RiskPercentPerBasket <= 0.0)
   {
      Print("XAUUSD_Basket_Scalper_EA: RiskPercentPerBasket must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(EMAFast <= 0 || EMASlow <= 0 || EMAFast >= EMASlow)
   {
      Print("XAUUSD_Basket_Scalper_EA: EMAFast must be > 0 and smaller than EMASlow.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(TrendEMAFast <= 0 || TrendEMASlow <= 0 || TrendEMAFast >= TrendEMASlow)
   {
      Print("XAUUSD_Basket_Scalper_EA: TrendEMAFast must be > 0 and smaller than TrendEMASlow.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(StopATRMultiplier <= 0.0)
   {
      Print("XAUUSD_Basket_Scalper_EA: StopATRMultiplier must be greater than zero - every order needs a real emergency stop.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_emaFastHandle   = iMA(_Symbol, PERIOD_M1, EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle   = iMA(_Symbol, PERIOD_M1, EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_trendFastHandle = iMA(_Symbol, PERIOD_M5, TrendEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_trendSlowHandle = iMA(_Symbol, PERIOD_M5, TrendEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_rsiHandle       = iRSI(_Symbol, PERIOD_M1, RSIPeriod, PRICE_CLOSE);
   g_adxHandle       = iADX(_Symbol, PERIOD_M1, ADXPeriod);
   g_atrHandle       = iATR(_Symbol, PERIOD_M1, ATRPeriod);

   if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE ||
      g_trendFastHandle == INVALID_HANDLE || g_trendSlowHandle == INVALID_HANDLE ||
      g_rsiHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("XAUUSD_Basket_Scalper_EA: failed to create one or more indicator handles.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_gvPrefix = "XAUUSDBasketEA_" + IntegerToString((long)MagicNumber) + "_" + _Symbol;

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_isNettingAccount = (marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(g_isNettingAccount)
      Print("XAUUSD_Basket_Scalper_EA: WARNING - this account is NOT hedging. Multiple same-symbol orders will "
            "be merged by the broker into a single net position instead of staying as separate tickets. The EA "
            "will keep running and its money-based basket math still works (it just reflects one merged "
            "position instead of several), but this is shown on the dashboard so you are aware of it.");

   if(ShowDashboard)
      CreateDashboard();

   PrintFormat("XAUUSD_Basket_Scalper_EA initialized on %s | Magic=%I64u | BatchOrderCount=%d LotMode=%s",
               _Symbol, MagicNumber, BatchOrderCount, EnumToString(LotMode));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaFastHandle != INVALID_HANDLE)   IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE)   IndicatorRelease(g_emaSlowHandle);
   if(g_trendFastHandle != INVALID_HANDLE) IndicatorRelease(g_trendFastHandle);
   if(g_trendSlowHandle != INVALID_HANDLE) IndicatorRelease(g_trendSlowHandle);
   if(g_rsiHandle != INVALID_HANDLE)       IndicatorRelease(g_rsiHandle);
   if(g_adxHandle != INVALID_HANDLE)       IndicatorRelease(g_adxHandle);
   if(g_atrHandle != INVALID_HANDLE)       IndicatorRelease(g_atrHandle);

   RemoveDashboard();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - reliably notice closes we did not initiate   |
//| ourselves (e.g. the real broker-side emergency SL was hit while   |
//| disconnected), so leftover state from that basket is still        |
//| cleared even though our own CloseBasket() never ran.               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)MagicNumber)
      return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   if(CountOwnPositions() == 0)
      GlobalVariableSet(GV_BASKETPEAK, 0.0);
}

//+------------------------------------------------------------------+
//| OnTick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   double peakEquity = UpdatePeakEquity();
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double equityDDPct = (peakEquity > 0.0) ? (peakEquity - equity) / peakEquity * 100.0 : 0.0;

   if(!IsEquityStopTriggered() && MaxEquityDrawdownPercent > 0.0 && equityDDPct >= MaxEquityDrawdownPercent)
   {
      PrintFormat("XAUUSD_Basket_Scalper_EA: EMERGENCY equity stop - drawdown %.2f%% >= %.2f%%. Closing everything "
                  "and halting. Delete the '%s' global variable (or reattach with a different Magic) to resume.",
                  equityDDPct, MaxEquityDrawdownPercent, GV_EQUITYSTOP);
      CloseAllOwnPositions();
      GlobalVariableSet(GV_EQUITYSTOP, 1.0);
   }

   // Basket management (breakeven/trailing/money exits/time exit) reacts
   // every tick regardless of TriggerMode - only NEW ENTRY evaluation is
   // gated by TriggerMode.
   ManageOpenBasket();

   bool isNewBar = false;
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime != 0 && barTime != g_lastEvalBarTime)
   {
      isNewBar = true;
      // Trend-break controlled exit only needs to be checked once a bar,
      // using freshly closed data.
      CheckTrendBreakExit();
      g_lastEvalBarTime = barTime;
   }

   if(TriggerMode == TRIGGER_NEW_M1_BAR && !isNewBar)
   {
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   TryOpenNewBasket();

   if(ShowDashboard)
      UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Attempts to start a new basket if none is open and every filter   |
//| passes. Also handles the profit-only add-on to an existing basket.|
//+------------------------------------------------------------------+
void TryOpenNewBasket()
{
   int    count = 0;
   double totalLots = 0.0, weightedPrice = 0.0, totalProfit = 0.0, perOrderLot = 0.0;
   datetime earliestOpen = 0;
   ENUM_BASKET_SIDE side = BASKET_NONE;
   GetBasketStats(count, totalLots, weightedPrice, totalProfit, perOrderLot, earliestOpen, side);

   if(count > 0)
   {
      // A basket is already open - the only thing left to consider is the
      // optional, profit-only, equal-lot add-on.
      if(UseAddOnProfit && count < MaxPositions && totalProfit > 0.0)
      {
         int unlockedLevels = (int)MathFloor(totalProfit / AddOnProfitStepMoney);
         int alreadyAdded    = count - BatchOrderCount;
         if(unlockedLevels > alreadyAdded && (totalLots + perOrderLot) <= MaxTotalLot)
         {
            if(PassesExecutionFilters())
               OpenOneOrder(side == BASKET_BUY, perOrderLot, "add-on");
         }
      }
      return;
   }

   g_blockedReason = "";

   if(IsEquityStopTriggered())                 { g_blockedReason = "Equity stop active";           return; }
   if(!IsWithinCooldownBars())                  { g_blockedReason = "Cooldown bars after last close"; return; }
   if(IsPaused())                                { g_blockedReason = "Cooldown after consecutive losses"; return; }
   if(IsPastFridayClose())                       { g_blockedReason = "Friday close window";          return; }
   if(UseSessionFilter && !IsWithinSession())    { g_blockedReason = "Outside session hours";        return; }
   if(MinimumMarginLevel > 0.0)
   {
      double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(marginLevel > 0.0 && marginLevel < MinimumMarginLevel)
      { g_blockedReason = "Margin level too low"; return; }
   }

   double dailyProfit = GetTodayRealizedProfit();
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   if(MaxDailyLossPercent > 0.0 && dailyProfit <= -(balance * MaxDailyLossPercent / 100.0))
   { g_blockedReason = "Daily max loss reached"; return; }
   if(MaxDailyProfitPercent > 0.0 && dailyProfit >= (balance * MaxDailyProfitPercent / 100.0))
   { g_blockedReason = "Daily profit target reached"; return; }
   if(MaxDailyBaskets > 0 && GetDailyBasketCount() >= MaxDailyBaskets)
   { g_blockedReason = "Max daily baskets reached"; return; }

   if(!PassesExecutionFilters())
   { if(g_blockedReason == "") g_blockedReason = "Spread/session filter"; return; }

   if(UseNewsFilter && IsNewsBlackout())
   { g_blockedReason = "News blackout window"; return; }

   ENUM_BASKET_SIDE signal = EvaluateEntrySignal();
   if(signal == BASKET_NONE)
   { if(g_blockedReason == "") g_blockedReason = "No signal"; return; }
   if(signal == BASKET_BUY && !AllowBuy)
   { g_blockedReason = "BUY disabled by input"; return; }
   if(signal == BASKET_SELL && !AllowSell)
   { g_blockedReason = "SELL disabled by input"; return; }

   OpenBasket(signal == BASKET_BUY);
}

//+------------------------------------------------------------------+
//| Spread/slippage-level filters that must pass for ANY order,       |
//| whether it is the first order of a new basket or a profit add-on. |
//+------------------------------------------------------------------+
bool PassesExecutionFilters()
{
   if(MaxSpreadPoints > 0)
   {
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPoints > MaxSpreadPoints)
      {
         g_blockedReason = "Spread too wide";
         return(false);
      }
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Full entry-signal evaluation, using ONLY closed-bar data (index 1 |
//| and higher) on both M1 and M5 - never the still-forming bar 0, so |
//| there is no repaint / no lookahead.                                |
//+------------------------------------------------------------------+
ENUM_BASKET_SIDE EvaluateEntrySignal()
{
   // --- effective thresholds per SignalMode -----------------------------
   double adxThreshold   = MinADX;
   double rsiBuyMin = RSIBuyMin, rsiBuyMax = RSIBuyMax, rsiSellMin = RSISellMin, rsiSellMax = RSISellMax;
   double bodyMinRatio   = BodyMinATRRatio;
   if(SignalMode == SIGNAL_SAFE)
   {
      adxThreshold *= 1.3;
      rsiBuyMin += 5.0; rsiSellMax -= 5.0;
      bodyMinRatio *= 1.3;
   }
   else if(SignalMode == SIGNAL_FAST)
   {
      adxThreshold *= 0.7;
      rsiBuyMin -= 5.0; rsiSellMax += 5.0;
      bodyMinRatio *= 0.7;
   }

   // --- M5 trend filter ---------------------------------------------------
   double trendFast[], trendSlow[];
   ArraySetAsSeries(trendFast, true);
   ArraySetAsSeries(trendSlow, true);
   if(CopyBuffer(g_trendFastHandle, 0, 1, 1, trendFast) != 1) return(BASKET_NONE);
   if(CopyBuffer(g_trendSlowHandle, 0, 1, 1, trendSlow) != 1) return(BASKET_NONE);
   double m5Close = iClose(_Symbol, PERIOD_M5, 1);
   if(m5Close <= 0.0) return(BASKET_NONE);

   bool bullTrend = (trendFast[0] > trendSlow[0]) && (m5Close > trendFast[0]);
   bool bearTrend = (trendFast[0] < trendSlow[0]) && (m5Close < trendFast[0]);

   // --- M1 fast/slow EMA (2 closed bars, for the cross AND the pullback) -
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   if(CopyBuffer(g_emaFastHandle, 0, 1, 2, emaFast) != 2) return(BASKET_NONE);
   if(CopyBuffer(g_emaSlowHandle, 0, 1, 2, emaSlow) != 2) return(BASKET_NONE);

   double open1  = iOpen(_Symbol, PERIOD_M1, 1);
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double high1  = iHigh(_Symbol, PERIOD_M1, 1);
   double low1   = iLow(_Symbol, PERIOD_M1, 1);
   if(open1 <= 0.0 || close1 <= 0.0) return(BASKET_NONE);

   bool crossUp   = emaFast[0] > emaSlow[0] && emaFast[1] <= emaSlow[1];
   bool crossDown = emaFast[0] < emaSlow[0] && emaFast[1] >= emaSlow[1];
   bool pullbackUp   = (emaFast[0] > emaSlow[0]) && (low1 <= emaSlow[0])  && (close1 > emaSlow[0]);
   bool pullbackDown = (emaFast[0] < emaSlow[0]) && (high1 >= emaSlow[0]) && (close1 < emaSlow[0]);

   bool m1TriggerBuy  = crossUp   || pullbackUp;
   bool m1TriggerSell = crossDown || pullbackDown;

   // --- RSI ----------------------------------------------------------------
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(g_rsiHandle, 0, 1, 1, rsiBuf) != 1) return(BASKET_NONE);
   double rsi = rsiBuf[0];
   bool rsiOkBuy  = (rsi >= rsiBuyMin  && rsi <= rsiBuyMax);
   bool rsiOkSell = (rsi >= rsiSellMin && rsi <= rsiSellMax);

   // --- ADX ------------------------------------------------------------------
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(g_adxHandle, 0, 1, 1, adxBuf) != 1) return(BASKET_NONE);
   bool adxOk = (adxBuf[0] >= adxThreshold);

   // --- ATR: volatility range + candle body/spike filter ----------------
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) != 1) return(BASKET_NONE);
   double atrValue  = atrBuf[0];
   double atrPoints = atrValue / _Point;
   bool volOk = (MinATR <= 0 || atrPoints >= MinATR) && (MaxATR <= 0 || atrPoints <= MaxATR);

   double body = MathAbs(close1 - open1);
   bool bodyOk = (atrValue > 0.0) && (body >= bodyMinRatio * atrValue) && (body <= BodyMaxATRRatio * atrValue);

   bool bullCandle = close1 > open1;
   bool bearCandle = close1 < open1;

   if(!volOk)  { g_blockedReason = "ATR outside allowed range"; return(BASKET_NONE); }
   if(!adxOk)  { g_blockedReason = "ADX below minimum";         return(BASKET_NONE); }
   if(!bodyOk) { g_blockedReason = "Candle body/spike filter";  return(BASKET_NONE); }

   bool buyOk  = bullTrend && m1TriggerBuy  && rsiOkBuy  && bullCandle;
   bool sellOk = bearTrend && m1TriggerSell && rsiOkSell && bearCandle;

   if(buyOk)  return(BASKET_BUY);
   if(sellOk) return(BASKET_SELL);

   g_blockedReason = "Trend/EMA/RSI conditions not aligned";
   return(BASKET_NONE);
}

//+------------------------------------------------------------------+
//| Opens a brand-new basket of BatchOrderCount equal-lot orders.     |
//+------------------------------------------------------------------+
void OpenBasket(const bool isBuy)
{
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   double atrValue = (CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) == 1) ? atrBuf[0] : 0.0;
   double slPrice  = CalcEmergencySL(isBuy, price, atrValue);

   double lotPerOrder;
   if(LotMode == LOT_RISK_PERCENT)
      lotPerOrder = CalcRiskLotPerOrder(isBuy, price, slPrice, BatchOrderCount);
   else
      lotPerOrder = NormalizeLot(FixedLot);

   lotPerOrder = MathMin(lotPerOrder, MaxLotPerOrder);
   lotPerOrder = NormalizeLot(lotPerOrder);

   if(lotPerOrder * BatchOrderCount > MaxTotalLot)
      lotPerOrder = NormalizeLot(MaxTotalLot / BatchOrderCount);

   if(lotPerOrder <= 0.0)
   {
      Print("XAUUSD_Basket_Scalper_EA: computed lot per order is 0 - basket not opened.");
      return;
   }

   int filled = 0;
   for(int i = 0; i < BatchOrderCount; i++)
      if(OpenOneOrder(isBuy, lotPerOrder, "batch"))
         filled++;

   if(filled == 0)
      return; // nothing opened, no basket to track

   IncrementDailyBasketCount();
   PrintFormat("XAUUSD_Basket_Scalper_EA: basket opened %s | %d/%d orders filled | lot/order=%.2f",
               isBuy ? "BUY" : "SELL", filled, BatchOrderCount, lotPerOrder);
}

//+------------------------------------------------------------------+
//| Sends a single market order with a real broker-side emergency SL. |
//| Retries a small, bounded number of times on failure (never grows  |
//| the lot to "catch up" for a failed sibling order - that would     |
//| silently exceed the intended basket risk).                         |
//+------------------------------------------------------------------+
bool OpenOneOrder(const bool isBuy, const double lot, const string tag)
{
   const int MAX_RETRIES = 2;

   for(int attempt = 0; attempt <= MAX_RETRIES; attempt++)
   {
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      double atrValue = (CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) == 1) ? atrBuf[0] : 0.0;
      double sl = CalcEmergencySL(isBuy, price, atrValue);

      bool ok = isBuy ? trade.Buy(lot, _Symbol, price, sl, 0.0, TradeComment)
                       : trade.Sell(lot, _Symbol, price, sl, 0.0, TradeComment);

      if(ok)
         return(true);

      PrintFormat("XAUUSD_Basket_Scalper_EA: %s order failed (attempt %d/%d) | %s %.2f lots | retcode=%d (%s)",
                  tag, attempt + 1, MAX_RETRIES + 1, isBuy ? "BUY" : "SELL", lot,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Real, broker-side emergency stop loss distance = ATR * multiplier,|
//| clamped to the symbol's minimum stop/freeze distance. This is the |
//| backstop that still protects the account if the terminal loses    |
//| connection and the EA cannot manage the basket virtually.          |
//+------------------------------------------------------------------+
double CalcEmergencySL(const bool isBuy, const double price, const double atrValue)
{
   long stopsLevelPoints  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLevelPoints, (double)freezeLevelPoints) * _Point;

   double dist = (atrValue > 0.0) ? atrValue * StopATRMultiplier : (200 * _Point);
   dist = MathMax(dist, minDist);

   double sl = isBuy ? price - dist : price + dist;
   return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
//| Money-risk based lot sizing via OrderCalcProfit(): computes the   |
//| real dollar loss of 1.0 lot at the planned emergency-SL distance, |
//| then sizes the WHOLE basket to risk RiskPercentPerBasket % of the |
//| balance, split equally across BatchOrderCount orders.              |
//+------------------------------------------------------------------+
double CalcRiskLotPerOrder(const bool isBuy, const double entryPrice, const double slPrice, const int orderCount)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercentPerBasket / 100.0;

   double profitFor1Lot = 0.0;
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entryPrice, slPrice, profitFor1Lot))
      return NormalizeLot(FixedLot); // fall back to the fixed lot if the broker can't price this right now

   double lossPer1Lot = MathAbs(profitFor1Lot);
   if(lossPer1Lot <= 0.0)
      return NormalizeLot(FixedLot);

   double desiredTotalLots = MathMin(riskAmount / lossPer1Lot, MaxTotalLot);
   double perOrder = desiredTotalLots / orderCount;
   return NormalizeLot(MathMin(perOrder, MaxLotPerOrder));
}

//+------------------------------------------------------------------+
//| Runs every tick: computes live basket stats and applies breakeven,|
//| trailing-profit, money TP/SL and the max-duration exit.            |
//+------------------------------------------------------------------+
void ManageOpenBasket()
{
   int    count = 0;
   double totalLots = 0.0, weightedPrice = 0.0, totalProfit = 0.0, perOrderLot = 0.0;
   datetime earliestOpen = 0;
   ENUM_BASKET_SIDE side = BASKET_NONE;
   GetBasketStats(count, totalLots, weightedPrice, totalProfit, perOrderLot, earliestOpen, side);

   if(count == 0)
      return;

   if(BasketProfitMoney > 0.0 && totalProfit >= BasketProfitMoney)
   { CloseBasket("basket take-profit reached", totalProfit); return; }

   if(BasketLossMoney > 0.0 && totalProfit <= -BasketLossMoney)
   { CloseBasket("basket max loss reached", totalProfit); return; }

   if(MaxBasketMinutes > 0 && earliestOpen > 0 && (TimeCurrent() - earliestOpen) >= MaxBasketMinutes * 60)
   { CloseBasket("max basket duration reached", totalProfit); return; }

   if(BasketTrailStartMoney > 0.0 && totalProfit >= BasketTrailStartMoney)
   {
      double peak = GlobalVariableCheck(GV_BASKETPEAK) ? GlobalVariableGet(GV_BASKETPEAK) : 0.0;
      if(totalProfit > peak)
      {
         peak = totalProfit;
         GlobalVariableSet(GV_BASKETPEAK, peak);
      }
      if(peak - totalProfit >= BasketTrailDistanceMoney)
      { CloseBasket("basket trailing-profit pullback", totalProfit); return; }
   }

   if(BreakEvenStartMoney > 0.0 && totalProfit >= BreakEvenStartMoney)
      ApplyBreakEven(side);
}

//+------------------------------------------------------------------+
//| Once a bar closes, checks whether the M5 trend that justified the |
//| open basket's direction has flipped against it, and exits in a    |
//| controlled way if so (rather than waiting for the money stop).    |
//+------------------------------------------------------------------+
void CheckTrendBreakExit()
{
   int    count = 0;
   double totalLots = 0.0, weightedPrice = 0.0, totalProfit = 0.0, perOrderLot = 0.0;
   datetime earliestOpen = 0;
   ENUM_BASKET_SIDE side = BASKET_NONE;
   GetBasketStats(count, totalLots, weightedPrice, totalProfit, perOrderLot, earliestOpen, side);
   if(count == 0 || side == BASKET_NONE)
      return;

   double trendFast[], trendSlow[];
   ArraySetAsSeries(trendFast, true);
   ArraySetAsSeries(trendSlow, true);
   if(CopyBuffer(g_trendFastHandle, 0, 1, 1, trendFast) != 1) return;
   if(CopyBuffer(g_trendSlowHandle, 0, 1, 1, trendSlow) != 1) return;
   double m5Close = iClose(_Symbol, PERIOD_M5, 1);
   if(m5Close <= 0.0) return;

   bool bullTrend = (trendFast[0] > trendSlow[0]) && (m5Close > trendFast[0]);
   bool bearTrend = (trendFast[0] < trendSlow[0]) && (m5Close < trendFast[0]);

   if(side == BASKET_BUY && !bullTrend && bearTrend)
      CloseBasket("M5 trend flipped against open BUY basket", totalProfit);
   else if(side == BASKET_SELL && !bearTrend && bullTrend)
      CloseBasket("M5 trend flipped against open SELL basket", totalProfit);
}

//+------------------------------------------------------------------+
//| Moves every order's REAL broker-side stop loss to its own entry   |
//| price (plus a small buffer in the profit direction) once the      |
//| basket is far enough in profit.                                    |
//+------------------------------------------------------------------+
void ApplyBreakEven(const ENUM_BASKET_SIDE side)
{
   const int BUFFER_POINTS = 20;

   long stopsLevelPoints  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLevelPoints, (double)freezeLevelPoints) * _Point;

   bool isBuy = (side == BASKET_BUY);
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double beSL = isBuy ? openPrice + BUFFER_POINTS * _Point : openPrice - BUFFER_POINTS * _Point;
      bool improved = isBuy ? (currentSL < beSL) : (currentSL <= 0.0 || currentSL > beSL);
      if(!improved) continue;

      bool farEnough = isBuy ? (price - beSL) >= minDist : (beSL - price) >= minDist;
      if(!farEnough) continue;

      double newSL = NormalizeDouble(beSL, _Digits);
      if(!trade.PositionModify(ticket, newSL, currentTP))
         PrintFormat("XAUUSD_Basket_Scalper_EA: failed to move #%I64u to break-even | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Closes the whole basket, records the win/loss outcome for the     |
//| consecutive-loss counter, and resets per-basket persisted state.  |
//+------------------------------------------------------------------+
void CloseBasket(const string reason, const double finalProfit)
{
   PrintFormat("XAUUSD_Basket_Scalper_EA: closing basket - %s (P/L=%.2f)", reason, finalProfit);
   CloseAllOwnPositions();

   GlobalVariableSet(GV_BASKETPEAK, 0.0);

   int consecLosses = GlobalVariableCheck(GV_CONSECLOSS) ? (int)GlobalVariableGet(GV_CONSECLOSS) : 0;
   if(finalProfit < 0.0)
   {
      consecLosses++;
      GlobalVariableSet(GV_CONSECLOSS, consecLosses);
      if(MaxConsecutiveLosses > 0 && consecLosses >= MaxConsecutiveLosses)
      {
         GlobalVariableSet(GV_PAUSEUNTIL, (double)(TimeCurrent() + CooldownAfterLossMinutes * 60));
         PrintFormat("XAUUSD_Basket_Scalper_EA: %d consecutive losing baskets - pausing new baskets for %d minutes.",
                     consecLosses, CooldownAfterLossMinutes);
      }
   }
   else
   {
      GlobalVariableSet(GV_CONSECLOSS, 0.0);
   }

   GlobalVariableSet(GV_LASTCLOSEBAR, (double)iTime(_Symbol, PERIOD_M1, 0));
}

//+------------------------------------------------------------------+
//| Reads every open position that belongs to this EA in one pass:    |
//| count, combined lots, volume-weighted average price, combined     |
//| floating P/L (profit+swap+commission), one representative per-    |
//| order lot size, the earliest open time, and the basket's side.    |
//+------------------------------------------------------------------+
void GetBasketStats(int &count, double &totalLots, double &weightedPrice, double &totalProfit,
                     double &perOrderLot, datetime &earliestOpen, ENUM_BASKET_SIDE &side)
{
   count = 0; totalLots = 0.0; weightedPrice = 0.0; totalProfit = 0.0; perOrderLot = 0.0;
   earliestOpen = 0; side = BASKET_NONE;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      double volume    = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      // Open positions only expose PROFIT and SWAP live; any commission is
      // charged against the account as separate deals and is already
      // reflected in ACCOUNT_PROFIT/history, not in a per-position field.
      double profit    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      count++;
      totalLots     += volume;
      weightedPrice += volume * openPrice;
      totalProfit   += profit;
      perOrderLot    = volume; // all orders in a basket are equal-lot by design

      if(earliestOpen == 0 || openTime < earliestOpen)
         earliestOpen = openTime;

      if(count == 1)
         side = (type == POSITION_TYPE_BUY) ? BASKET_BUY : BASKET_SELL;
   }
}

//+------------------------------------------------------------------+
//| Counts open positions belonging to this EA (symbol + magic).      |
//+------------------------------------------------------------------+
int CountOwnPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      count++;
   }
   return(count);
}

//+------------------------------------------------------------------+
//| Closes every open position belonging to this EA (symbol + magic). |
//+------------------------------------------------------------------+
void CloseAllOwnPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      if(!trade.PositionClose(ticket, MaxSlippagePoints))
         PrintFormat("XAUUSD_Basket_Scalper_EA: failed to close #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Rounds a lot size to what the broker accepts (min/max/step).      |
//+------------------------------------------------------------------+
double NormalizeLot(const double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double normalized = MathRound(lots / stepLot) * stepLot;
   normalized = MathMax(minLot, MathMin(maxLot, normalized));

   int stepDigits = (int)MathRound(-MathLog10(stepLot));
   if(stepDigits < 0) stepDigits = 0;

   return NormalizeDouble(normalized, stepDigits);
}

//+------------------------------------------------------------------+
//| Midnight (server time) of the given moment.                       |
//+------------------------------------------------------------------+
datetime GetDayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Today's realized P/L (profit+swap+commission) for this EA, read   |
//| live from the account's own deal history - restart-safe.          |
//+------------------------------------------------------------------+
double GetTodayRealizedProfit()
{
   double profit = 0.0;
   datetime dayStart = GetDayStart(TimeCurrent());
   if(!HistorySelect(dayStart, TimeCurrent()))
      return(profit);

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)MagicNumber) continue;

      profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
              + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
              + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }
   return(profit);
}

//+------------------------------------------------------------------+
//| Number of baskets this EA has opened today (persisted counter,    |
//| auto-resets when the stored day no longer matches today).         |
//+------------------------------------------------------------------+
int GetDailyBasketCount()
{
   datetime today = GetDayStart(TimeCurrent());
   if(!GlobalVariableCheck(GV_DAILYCOUNTDAY) || (datetime)GlobalVariableGet(GV_DAILYCOUNTDAY) != today)
      return(0);
   if(!GlobalVariableCheck(GV_DAILYCOUNT))
      return(0);
   return((int)GlobalVariableGet(GV_DAILYCOUNT));
}

void IncrementDailyBasketCount()
{
   datetime today = GetDayStart(TimeCurrent());
   int count = GetDailyBasketCount() + 1;
   GlobalVariableSet(GV_DAILYCOUNTDAY, (double)today);
   GlobalVariableSet(GV_DAILYCOUNT, (double)count);
}

//+------------------------------------------------------------------+
//| Tracks the highest equity this EA has ever seen (persisted), and  |
//| returns it - used for the emergency drawdown stop.                 |
//+------------------------------------------------------------------+
double UpdatePeakEquity()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double peak = GlobalVariableCheck(GV_PEAKEQUITY) ? GlobalVariableGet(GV_PEAKEQUITY) : equity;
   if(equity > peak)
   {
      peak = equity;
      GlobalVariableSet(GV_PEAKEQUITY, peak);
   }
   return(peak);
}

bool IsEquityStopTriggered()
{
   return(GlobalVariableCheck(GV_EQUITYSTOP) && GlobalVariableGet(GV_EQUITYSTOP) > 0.5);
}

//+------------------------------------------------------------------+
//| Post-consecutive-loss cooldown window (persisted, restart-safe).  |
//+------------------------------------------------------------------+
bool IsPaused()
{
   if(!GlobalVariableCheck(GV_PAUSEUNTIL))
      return(false);
   datetime untilTime = (datetime)GlobalVariableGet(GV_PAUSEUNTIL);
   return(TimeCurrent() < untilTime);
}

//+------------------------------------------------------------------+
//| CooldownBars M1 bars must pass after a basket closes before a new |
//| one can open - measured with iBarShift so it is restart-safe      |
//| (the reference timestamp, not a bar count, is what is persisted). |
//+------------------------------------------------------------------+
bool IsWithinCooldownBars()
{
   if(CooldownBars <= 0)
      return(true);
   if(!GlobalVariableCheck(GV_LASTCLOSEBAR))
      return(true);

   datetime lastCloseBar = (datetime)GlobalVariableGet(GV_LASTCLOSEBAR);
   if(lastCloseBar <= 0)
      return(true);

   int barsSince = iBarShift(_Symbol, PERIOD_M1, lastCloseBar, false);
   if(barsSince < 0)
      return(true); // reference bar not found in history - do not block forever

   return(barsSince >= CooldownBars);
}

//+------------------------------------------------------------------+
//| "HH:MM" -> hour/minute. Returns false on a malformed string.      |
//+------------------------------------------------------------------+
bool ParseHHMM(const string s, int &hour, int &minute)
{
   string parts[];
   int n = StringSplit(s, ':', parts);
   if(n != 2) return(false);
   hour   = (int)StringToInteger(parts[0]);
   minute = (int)StringToInteger(parts[1]);
   return(hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59);
}

bool IsWithinSession()
{
   int sh, sm, eh, em;
   if(!ParseHHMM(SessionStart, sh, sm) || !ParseHHMM(SessionEnd, eh, em))
      return(true); // malformed input - fail open rather than block all trading silently

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = sh * 60 + sm;
   int endMinutes   = eh * 60 + em;

   if(startMinutes <= endMinutes)
      return(nowMinutes >= startMinutes && nowMinutes < endMinutes);
   return(nowMinutes >= startMinutes || nowMinutes < endMinutes); // overnight session
}

bool IsPastFridayClose()
{
   if(!CloseFriday)
      return(false);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week != 5)
      return(false);

   int fh, fm;
   if(!ParseHHMM(FridayCloseTime, fh, fm))
      return(false);

   int nowMinutes = dt.hour * 60 + dt.min;
   return(nowMinutes >= (fh * 60 + fm));
}

//+------------------------------------------------------------------+
//| High-impact USD news blackout, via MT5's built-in Economic        |
//| Calendar (no external DLL/service). Requires the terminal's       |
//| calendar data to be available (normal in live/demo; the Strategy  |
//| Tester needs its own calendar cache, see the usage notes).        |
//+------------------------------------------------------------------+
bool IsNewsBlackout()
{
   datetime now  = TimeCurrent();
   datetime from = now - 2 * 24 * 3600;
   datetime to   = now + 2 * 24 * 3600;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, "USD");
   if(n <= 0)
      return(false);

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;

      datetime eventTime = values[i].time;
      if(now >= eventTime - NewsMinutesBefore * 60 && now <= eventTime + NewsMinutesAfter * 60)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| DASHBOARD (simple top-left multi-line label)                      |
//+------------------------------------------------------------------+
#define DASHBOARD_NAME "XAUUSDBasketEA_Panel"

void CreateDashboard()
{
   if(ObjectFind(0, DASHBOARD_NAME) < 0)
      ObjectCreate(0, DASHBOARD_NAME, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, DASHBOARD_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, DASHBOARD_NAME, OBJPROP_XDISTANCE, 12);
   ObjectSetInteger(0, DASHBOARD_NAME, OBJPROP_YDISTANCE, 16);
   ObjectSetInteger(0, DASHBOARD_NAME, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, DASHBOARD_NAME, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, DASHBOARD_NAME, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, DASHBOARD_NAME, OBJPROP_BACK, false);
   ObjectSetInteger(0, DASHBOARD_NAME, OBJPROP_SELECTABLE, false);
}

void RemoveDashboard()
{
   if(ObjectFind(0, DASHBOARD_NAME) >= 0)
      ObjectDelete(0, DASHBOARD_NAME);
}

void UpdateDashboard()
{
   int    count = 0;
   double totalLots = 0.0, weightedPrice = 0.0, totalProfit = 0.0, perOrderLot = 0.0;
   datetime earliestOpen = 0;
   ENUM_BASKET_SIDE side = BASKET_NONE;
   GetBasketStats(count, totalLots, weightedPrice, totalProfit, perOrderLot, earliestOpen, side);

   double atrBuf[]; ArraySetAsSeries(atrBuf, true);
   double atrValue = (CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) == 1) ? atrBuf[0] : 0.0;
   double adxBuf[]; ArraySetAsSeries(adxBuf, true);
   double adxValue = (CopyBuffer(g_adxHandle, 0, 1, 1, adxBuf) == 1) ? adxBuf[0] : 0.0;

   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   double trendFast[], trendSlow[];
   ArraySetAsSeries(trendFast, true); ArraySetAsSeries(trendSlow, true);
   string trendTxt = "n/a";
   if(CopyBuffer(g_trendFastHandle, 0, 1, 1, trendFast) == 1 && CopyBuffer(g_trendSlowHandle, 0, 1, 1, trendSlow) == 1)
      trendTxt = (trendFast[0] > trendSlow[0]) ? "BULLISH" : "BEARISH";

   string sideTxt = (side == BASKET_BUY) ? "BUY" : (side == BASKET_SELL) ? "SELL" : "-";

   string status = IsEquityStopTriggered() ? "EQUITY STOP" : (count > 0 ? "IN BASKET" : "WATCHING");

   string text = StringFormat(
      "XAUUSD Basket Scalper\n"
      "Status........: %s\n"
      "Signal mode...: %s\n"
      "M5 trend......: %s\n"
      "Spread........: %d pts\n"
      "ATR / ADX.....: %.2f / %.1f\n"
      "Positions.....: %d (%s)\n"
      "Total lot.....: %.2f\n"
      "Basket P/L....: %.2f\n"
      "Daily P/L.....: %.2f\n"
      "Daily baskets.: %d/%d\n"
      "Loss lock.....: %s\n"
      "Blocked by....: %s",
      status, EnumToString(SignalMode), trendTxt, (int)spreadPoints, atrValue, adxValue,
      count, sideTxt, totalLots, totalProfit, GetTodayRealizedProfit(),
      GetDailyBasketCount(), MaxDailyBaskets,
      IsPaused() ? "ACTIVE" : "clear",
      (count == 0 && g_blockedReason != "") ? g_blockedReason : "-"
   );

   ObjectSetString(0, DASHBOARD_NAME, OBJPROP_TEXT, text);
}
//+------------------------------------------------------------------+
