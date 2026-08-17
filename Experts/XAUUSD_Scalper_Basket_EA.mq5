//+------------------------------------------------------------------+
//|                                XAUUSD_Scalper_Basket_EA.mq5      |
//|        Same-Direction Basket + Balance-Tiered Lot "Scalper"      |
//+------------------------------------------------------------------+
//
// KULLANIM NOTU (once oku)
// -------------------------
// - Bu EA HEDGING hesap gerektirir (ayni yonde onlarca ayri pozisyon
//   ustuste acar). Netting hesapta OnInit basarisiz olur ve EA baslamaz.
// - Basamakli lot tablosunun ust kademeleri (orn. 0.65 lot XAUUSD) yuksek
//   kaldirac ister (~1:1000+). Dusuk kaldiracta teminat yetersizligi
//   nedeniyle emirler sessizce reddedilir (log'da InpDebug ile gorulur).
// - Pozisyonlarin TEK TEK stop-loss'u YOKTUR; sepet TOPLU yonetilir.
//   InpUseBasketSL / InpUseDailyGuard varsayilan ACIK - KAPATMADAN once
//   riskini anladigindan emin ol. Gercek parada kullanmadan once Strateji
//   Test Cihazi'nda uzun pencerede (1-3 ay, "every tick based on real
//   ticks") test et.
//
// STRATEJI OZETI
// ---------------
// Her tur icin tek bir yon secilir (InpDirMode). O yonde ilk ("seed")
// pozisyon acilir; fiyat InpGridStepPoints kadar hareket ettikce ayni
// yonde yeni pozisyonlar eklenir (basket/grid). Sepetin lotu tur boyunca
// kilitlenebilir (InpLockLotPerBasket) ve hesap bakiyesine gore
// basamakli olarak buyur (InpLotTiers). Sepetin TOPLAM floating kari bir
// hedefe ulasinca TUM pozisyonlar birlikte kapatilir, kisa bir bekleme
// (InpReArmDelaySec) sonrasi yeni bir tur icin yon yeniden degerlendirilir.
//+------------------------------------------------------------------+
#property copyright "Educational Scalper Basket EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ENUMS                                                              |
//+------------------------------------------------------------------+
enum ENUM_DIR_MODE
{
   DIR_M1_EMA   = 0, // M1 EMA9/EMA21 + ADX filtresi (iki yonlu)
   DIR_BUY_ONLY = 1, // Sadece BUY (test)
   DIR_SELL_ONLY = 2 // Sadece SELL (test)
};

enum ENUM_LOT_SIZING_MODE
{
   LOT_SIZING_TIERS  = 0, // InpLotTiers tablosuna gore basamakli
   LOT_SIZING_LINEAR = 1, // InpLotPerBalance* katsayilarina gore dogrusal
   LOT_SIZING_FIXED  = 2  // InpFixedLot sabit
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
input group "===== Genel ====="
input string InpSymbolOverride = "";                 // Broker sembol adi farkliysa (orn. XAUUSDm, GOLD#) - bos = grafik sembolu
input ulong  InpMagic          = 20260815001;         // Magic number
input string InpTradeComment   = "Scalper Basket";    // Emir yorumu
input bool   InpDebug          = true;                // Her M1 barinda "neden islem yok" logu

input group "===== Yon Mantigi ====="
input ENUM_DIR_MODE InpDirMode      = DIR_M1_EMA; // Yon secim modu
input int            InpEMAFastPeriod = 9;         // M1 hizli EMA periyodu
input int            InpEMASlowPeriod = 21;        // M1 yavas EMA periyodu
input int            InpADXPeriod     = 14;        // M1 ADX periyodu
input double         InpADXThreshold  = 20.0;      // Bu esigin altinda yon sinyali verilmez

input group "===== Basamakli Lot (bakiyeye gore) ====="
input ENUM_LOT_SIZING_MODE InpLotSizingMode = LOT_SIZING_TIERS;               // Lot hesaplama modu
input string  InpLotTiers          = "630:0.05;990:0.15;1300:0.65";           // "bakiye:lot;bakiye:lot;..." kucukten buyuge (TIERS modu)
input double  InpLotPerBalanceBase = 0.05;   // LINEAR modu: baslangic lot
input double  InpLotPerBalanceStep = 300.0;  // LINEAR modu: her bu kadar $ bakiyede bir kademe
input double  InpLotPerBalanceIncr = 0.05;   // LINEAR modu: kademe basi lot artisi
input double  InpFixedLot          = 0.05;   // FIXED modu: sabit lot
input bool    InpLockLotPerBasket  = true;   // true: sepet acikken lot sabit kalir, yeni turda bakiyeye gore yeniden hesaplanir
input bool    InpSeedLotSmaller    = false;  // true: sepetin ilk pozisyonu bir kademe kucuk acilir (eklemeler tam kademede)

input group "===== Sepet / Grid ====="
input int  InpGridStepPoints        = 100;  // Yeni pozisyon ekleme adimi, points cinsinden (XAUUSD point genelde 0.01$ ise 100pt=1.00$; 3-30pt ~ 0.03-0.30$ icin kucult)
input int  InpMaxPositions          = 20;   // Sepette olabilecek maksimum ayni-yon pozisyon sayisi
input bool InpAddOnAdverseOnly      = true; // true: sadece fiyat aleyhe giderken ekle; false: her adimda (lehte de) ekle
input int  InpMinSecondsBetweenAdds = 5;    // Eklemeler arasi minimum saniye

input group "===== Sepet Kapatma ====="
input double InpTargetPerPosUSD = 2.0;  // Sepet hedefi = acik pozisyon sayisi x bu deger (USD) - lot kademesine gore olcekle (bkz. asagidaki not)
input double InpBasketTargetUSD = 0.0;  // >0 ise sabit toplam USD hedefi kullanilir (InpTargetPerPosUSD'yi ezer)
input bool   InpUseTrailing     = false; // Sepet karini kilitleyen trailing
input double InpTrailStartUSD   = 3.0;   // Trailing bu floating kardan itibaren baslar
input double InpTrailStepUSD    = 1.0;   // Zirveden bu kadar geri cekilirse sepet kapatilir
input int    InpReArmDelaySec   = 5;     // Sepet kapandiktan sonra yeni tur icin bekleme (saniye)

input group "===== Risk Korumalari ====="
// NOT: InpBasketMaxLossUSD ve InpTargetPerPosUSD, InpLotTiers/InpFixedLot'taki EN BUYUK lot
// ile tutarli olmali. Orn. 0.65 lot XAUUSD'de 1$'lik fiyat hareketi ~65$ demektir; kucuk bir
// zarar limiti (eskiden varsayilan 20$) bu lotta ilk pozisyon daha grid'e eklenemeden, sadece
// spread yuzunden aninda tetiklenir ve sepet HICBIR ZAMAN kar hedefine ulasamaz. OnInit() bu
// tutarsizligi InpUseBasketSL acikken otomatik tespit edip baslatmayi reddeder.
input bool   InpUseBasketSL       = true;  // Sepet toplam zarari bu degeri asarsa TUMUNU kapat
input double InpBasketMaxLossUSD  = 200.0; // Sepet zarar limiti (USD) - en buyuk lot kademesiyle tutarli olmali
input bool   InpUseDailyGuard     = true;  // Gunluk zarar limiti (gerceklesen + floating)
input double InpDailyMaxLossUSD   = 400.0; // Gunluk zarar limiti (USD) - asilinca o gun icin tum yeni turlar durur
input double InpMarginBufferPercent = 20.0; // Serbest teminat, gereken teminatin bu kadar fazlasi olmali
input int    InpMaxSpreadPoints   = 0;      // 0 = kapali; >0 ise bu spreadin uzerinde yeni/eklenen emir gonderilmez

input group "===== Panel ====="
input bool InpShowPanel = true; // Ekran paneli goster

//+------------------------------------------------------------------+
//| GLOBALS                                                            |
//+------------------------------------------------------------------+
CTrade trade;

string g_symbol = "";
string g_blockedReason = "";
datetime g_lastBarTime = 0;

int g_emaFastHandle = INVALID_HANDLE;
int g_emaSlowHandle = INVALID_HANDLE;
int g_adxHandle      = INVALID_HANDLE;

struct LotTier
{
   double balance;
   double lot;
};
LotTier g_tiers[];

string g_gvPrefix;
#define GV_LASTCLOSETIME (g_gvPrefix + "_lastclose")
#define GV_TRAILPEAK     (g_gvPrefix + "_trailpeak")
#define GV_LOCKEDLOT     (g_gvPrefix + "_lockedlot")
#define GV_DAILYBLOCKDAY (g_gvPrefix + "_dailyblockday")

#define PANEL_NAME "ScalperBasketEA_Panel"

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = (InpSymbolOverride != "") ? InpSymbolOverride : _Symbol;
   if(!SymbolSelect(g_symbol, true))
   {
      PrintFormat("Scalper_Basket_EA: sembol bulunamadi/secilemedi: %s", g_symbol);
      return(INIT_FAILED);
   }

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("Scalper_Basket_EA: bu EA sadece HEDGING hesaplarda calisir (ayni yonde coklu pozisyon acar). "
            "Netting hesapta baslatilmadi.");
      return(INIT_FAILED);
   }

   if(InpGridStepPoints <= 0)
   { Print("Scalper_Basket_EA: InpGridStepPoints 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpMaxPositions < 1)
   { Print("Scalper_Basket_EA: InpMaxPositions en az 1 olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpMinSecondsBetweenAdds < 0)
   { Print("Scalper_Basket_EA: InpMinSecondsBetweenAdds negatif olamaz."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpTargetPerPosUSD <= 0.0 && InpBasketTargetUSD <= 0.0)
   { Print("Scalper_Basket_EA: InpTargetPerPosUSD veya InpBasketTargetUSD'den en az biri > 0 olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpMarginBufferPercent < 0.0)
   { Print("Scalper_Basket_EA: InpMarginBufferPercent negatif olamaz."); return(INIT_PARAMETERS_INCORRECT); }

   if(InpLotSizingMode == LOT_SIZING_TIERS)
   {
      if(!ParseLotTiers(InpLotTiers))
      { Print("Scalper_Basket_EA: InpLotTiers ayristirilamadi veya gecerli kademe yok."); return(INIT_PARAMETERS_INCORRECT); }
   }
   else if(InpLotSizingMode == LOT_SIZING_LINEAR)
   {
      if(InpLotPerBalanceBase <= 0.0 || InpLotPerBalanceStep <= 0.0 || InpLotPerBalanceIncr < 0.0)
      { Print("Scalper_Basket_EA: LINEAR lot parametreleri gecersiz."); return(INIT_PARAMETERS_INCORRECT); }
   }
   else // LOT_SIZING_FIXED
   {
      if(InpFixedLot <= 0.0)
      { Print("Scalper_Basket_EA: InpFixedLot 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }
   }

   // En buyuk configured lot (TIERS -> en ust kademe, FIXED -> InpFixedLot; LINEAR bakiyeyle
   // sinirsiz buyudugu icin bu kontrolden muaf tutulur, kullanici zaten dokumantasyonda uyarilir)
   // ile InpBasketMaxLossUSD/InpTargetPerPosUSD tutarli mi diye kontrol et. Tutarsizsa (zarar
   // limiti tek bir grid adimindan bile kucukse) sepet HICBIR ZAMAN kar hedefine ulasamadan,
   // ilk pozisyon acilir acilmaz spread + kucuk bir gurultuyle SL'e carpar - bu net bir ayar
   // hatasidir, "stratejinin dogal riski" degil, bu yuzden EA'yi baslatmadan once yakalanir.
   double maxConfiguredLot = 0.0;
   if(InpLotSizingMode == LOT_SIZING_TIERS)
   {
      for(int i = 0; i < ArraySize(g_tiers); i++)
         maxConfiguredLot = MathMax(maxConfiguredLot, g_tiers[i].lot);
   }
   else if(InpLotSizingMode == LOT_SIZING_FIXED)
   {
      maxConfiguredLot = InpFixedLot;
   }

   if(InpUseBasketSL && maxConfiguredLot > 0.0)
   {
      double moneyPerGridStep = CalcMoneyPerPoint(maxConfiguredLot) * InpGridStepPoints;
      if(moneyPerGridStep > 0.0 && InpBasketMaxLossUSD < moneyPerGridStep)
      {
         PrintFormat("Scalper_Basket_EA: AYAR HATASI - en buyuk lot kademesi (%.2f lot) ile "
                     "InpGridStepPoints (%d pt) kadar TEK bir aleyhe hareket ~%.2f USD zarar demek, "
                     "ama InpBasketMaxLossUSD sadece %.2f USD. Sepet SL'i ilk pozisyon grid'e "
                     "eklenemeden (spread + kucuk bir hareketle) aninda tetiklenir - hicbir tur kar "
                     "hedefine ulasamaz. InpBasketMaxLossUSD'yi en az %.2f USD'ye cikarin ya da bu "
                     "lot kademesini kucultun.",
                     maxConfiguredLot, InpGridStepPoints, moneyPerGridStep, InpBasketMaxLossUSD,
                     moneyPerGridStep * 3.0);
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   if(InpEMAFastPeriod <= 0 || InpEMASlowPeriod <= 0 || InpEMAFastPeriod >= InpEMASlowPeriod)
   { Print("Scalper_Basket_EA: InpEMAFastPeriod > 0 ve InpEMASlowPeriod'dan kucuk olmali."); return(INIT_PARAMETERS_INCORRECT); }

   g_emaFastHandle = iMA(g_symbol, PERIOD_M1, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(g_symbol, PERIOD_M1, InpEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_adxHandle      = iADX(g_symbol, PERIOD_M1, InpADXPeriod);

   if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE)
   { Print("Scalper_Basket_EA: gosterge handle'lari olusturulamadi."); return(INIT_FAILED); }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(g_symbol);
   trade.SetAsyncMode(false);

   g_gvPrefix = "ScalperBasketEA_" + IntegerToString((long)InpMagic) + "_" + g_symbol;

   if(InpShowPanel) CreatePanel();

   PrintFormat("Scalper_Basket_EA baslatildi | Sembol=%s Magic=%I64u DirMode=%s LotMode=%s",
               g_symbol, InpMagic, EnumToString(InpDirMode), EnumToString(InpLotSizingMode));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   if(g_adxHandle != INVALID_HANDLE)     IndicatorRelease(g_adxHandle);
   RemovePanel();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - basket'in bizim disimizda (manuel kapama,     |
//| margin call, broker tarafi) sifirlandigi durumlarda kalinti        |
//| kilitli-lot / trailing-zirve state'ini temizler.                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagic) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   if(CountOwnPositions() == 0)
   {
      GlobalVariableSet(GV_TRAILPEAK, 0.0);
      GlobalVariableSet(GV_LOCKEDLOT, 0.0);
      GlobalVariableSet(GV_LASTCLOSETIME, (double)TimeCurrent());
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   bool isNewBar = false;
   datetime barTime = iTime(g_symbol, PERIOD_M1, 0);
   if(barTime != 0 && barTime != g_lastBarTime)
   {
      isNewBar = true;
      g_lastBarTime = barTime;
   }

   ManageBasket();

   int count = 0;
   double totalLots = 0.0, totalProfit = 0.0, lastAddPrice = 0.0;
   datetime lastAddTime = 0;
   ENUM_BASKET_SIDE side = BASKET_NONE;
   GetBasketStats(count, totalLots, totalProfit, side, lastAddTime, lastAddPrice);

   if(count == 0)
      TryOpenNewBasket();
   else
      TryAddToBasket(count, side, lastAddTime, lastAddPrice);

   if(InpDebug && isNewBar)
      PrintFormat("Scalper_Basket_EA: bar=%s durum=%s", TimeToString(barTime, TIME_MINUTES),
                  (g_blockedReason == "") ? "OK" : g_blockedReason);

   if(InpShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| Sepet toplu yonetimi: gunluk kilit, sepet SL, kar hedefi, trailing |
//+------------------------------------------------------------------+
void ManageBasket()
{
   int count = 0;
   double totalLots = 0.0, totalProfit = 0.0, lastAddPrice = 0.0;
   datetime lastAddTime = 0;
   ENUM_BASKET_SIDE side = BASKET_NONE;
   GetBasketStats(count, totalLots, totalProfit, side, lastAddTime, lastAddPrice);

   if(count == 0)
      return;

   if(InpUseDailyGuard && !IsDailyBlocked())
   {
      double dailyPL = GetTodayRealizedProfit() + totalProfit;
      if(dailyPL <= -InpDailyMaxLossUSD)
      {
         CloseAllPositions("gunluk zarar limitine ulasildi");
         SetDailyBlocked();
         return;
      }
   }

   if(InpUseBasketSL && totalProfit <= -InpBasketMaxLossUSD)
   { CloseAllPositions("sepet zarar limitine ulasildi"); return; }

   double target = (InpBasketTargetUSD > 0.0) ? InpBasketTargetUSD : (count * InpTargetPerPosUSD);
   if(target > 0.0 && totalProfit >= target)
   { CloseAllPositions("sepet kar hedefine ulasildi"); return; }

   if(InpUseTrailing && totalProfit >= InpTrailStartUSD)
   {
      double peak = GlobalVariableCheck(GV_TRAILPEAK) ? GlobalVariableGet(GV_TRAILPEAK) : 0.0;
      if(totalProfit > peak)
      {
         peak = totalProfit;
         GlobalVariableSet(GV_TRAILPEAK, peak);
      }
      if(peak - totalProfit >= InpTrailStepUSD)
      { CloseAllPositions("trailing kar geri cekilmesi"); return; }
   }
}

//+------------------------------------------------------------------+
//| Bos iken yeni bir tur (yon + seed pozisyon) baslatmayi dener.      |
//+------------------------------------------------------------------+
void TryOpenNewBasket()
{
   g_blockedReason = "";

   if(TimeCurrent() - GetLastCloseTime() < InpReArmDelaySec)
   { g_blockedReason = "yeniden kurulum bekleniyor"; return; }

   if(InpUseDailyGuard && IsDailyBlocked())
   { g_blockedReason = "gunluk zarar kilidi aktif"; return; }

   if(InpMaxSpreadPoints > 0 && CurrentSpreadPoints() > InpMaxSpreadPoints)
   { g_blockedReason = "spread cok genis"; return; }

   ENUM_BASKET_SIDE dir = EvaluateDirection();
   if(dir == BASKET_NONE)
   { if(g_blockedReason == "") g_blockedReason = "yon sinyali yok"; return; }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot = InpSeedLotSmaller ? ComputeSeedLot(balance) : ComputeLotForBalance(balance);
   lot = NormalizeLot(lot);
   if(lot <= 0.0)
   { g_blockedReason = "lot hesaplanamadi"; return; }

   bool isBuy = (dir == BASKET_BUY);
   if(!HasEnoughMargin(isBuy, lot))
   { g_blockedReason = "serbest teminat yetersiz"; return; }

   if(OpenOnePosition(isBuy, lot, "seed"))
   {
      double fullLot = ComputeLotForBalance(balance);
      GlobalVariableSet(GV_LOCKEDLOT, NormalizeLot(fullLot));
      if(InpDebug)
         PrintFormat("Scalper_Basket_EA: yeni sepet acildi | %s seed_lot=%.2f kilitli_lot=%.2f bakiye=%.2f",
                     isBuy ? "BUY" : "SELL", lot, NormalizeLot(fullLot), balance);
   }
}

//+------------------------------------------------------------------+
//| Acik sepete grid adimina gore yeni pozisyon eklemeyi dener.        |
//+------------------------------------------------------------------+
void TryAddToBasket(const int count, const ENUM_BASKET_SIDE side, const datetime lastAddTime, const double lastAddPrice)
{
   g_blockedReason = "";

   if(count >= InpMaxPositions)
   { g_blockedReason = "maksimum pozisyon sayisina ulasildi"; return; }

   if(TimeCurrent() - lastAddTime < InpMinSecondsBetweenAdds)
   { g_blockedReason = "eklemeler arasi bekleme suresi"; return; }

   if(InpMaxSpreadPoints > 0 && CurrentSpreadPoints() > InpMaxSpreadPoints)
   { g_blockedReason = "spread cok genis"; return; }

   bool isBuy = (side == BASKET_BUY);
   double price = isBuy ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double stepPrice = InpGridStepPoints * point;

   // Alici icin fiyat dusunce, satici icin fiyat yukselince "aleyhe" hareket pozitif olur.
   double diff = isBuy ? (lastAddPrice - price) : (price - lastAddPrice);

   bool shouldAdd = InpAddOnAdverseOnly ? (diff >= stepPrice) : (MathAbs(diff) >= stepPrice);
   if(!shouldAdd)
   { g_blockedReason = "grid adimi henuz asilmadi"; return; }

   double lot = InpLockLotPerBasket ? GetLockedLot() : ComputeLotForBalance(AccountInfoDouble(ACCOUNT_BALANCE));
   lot = NormalizeLot(lot);
   if(lot <= 0.0)
   { g_blockedReason = "lot hesaplanamadi"; return; }

   if(!HasEnoughMargin(isBuy, lot))
   { g_blockedReason = "serbest teminat yetersiz"; return; }

   if(OpenOnePosition(isBuy, lot, "add") && InpDebug)
      PrintFormat("Scalper_Basket_EA: sepete eklendi | %s lot=%.2f pozisyon#%d", isBuy ? "BUY" : "SELL", lot, count + 1);
}

//+------------------------------------------------------------------+
//| Yon secimi: DIR_BUY_ONLY / DIR_SELL_ONLY sabit, DIR_M1_EMA icin    |
//| EMA9/EMA21 trend yonu + ADX minimum esigi (kapali M1 bari uzerinden|
//| - repaint/lookahead yok).                                          |
//+------------------------------------------------------------------+
ENUM_BASKET_SIDE EvaluateDirection()
{
   if(InpDirMode == DIR_BUY_ONLY)  return(BASKET_BUY);
   if(InpDirMode == DIR_SELL_ONLY) return(BASKET_SELL);

   if(!IsHandleReady(g_emaFastHandle) || !IsHandleReady(g_emaSlowHandle) || !IsHandleReady(g_adxHandle))
   { g_blockedReason = "gostergeler henuz hazir degil"; return(BASKET_NONE); }

   double emaFast[], emaSlow[], adx[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(adx, true);

   if(CopyBuffer(g_emaFastHandle, 0, 1, 1, emaFast) != 1) { g_blockedReason = "EMA verisi alinamadi"; return(BASKET_NONE); }
   if(CopyBuffer(g_emaSlowHandle, 0, 1, 1, emaSlow) != 1) { g_blockedReason = "EMA verisi alinamadi"; return(BASKET_NONE); }
   if(CopyBuffer(g_adxHandle, 0, 1, 1, adx) != 1)         { g_blockedReason = "ADX verisi alinamadi"; return(BASKET_NONE); }

   if(adx[0] < InpADXThreshold)
   { g_blockedReason = "ADX esik altinda"; return(BASKET_NONE); }

   if(emaFast[0] > emaSlow[0]) return(BASKET_BUY);
   if(emaFast[0] < emaSlow[0]) return(BASKET_SELL);

   g_blockedReason = "EMA'lar esit - yon yok";
   return(BASKET_NONE);
}

bool IsHandleReady(const int handle)
{
   if(handle == INVALID_HANDLE) return(false);
   return(BarsCalculated(handle) > 1);
}

//+------------------------------------------------------------------+
//| LOT HESABI (basamakli / dogrusal / sabit)                          |
//+------------------------------------------------------------------+
bool ParseLotTiers(const string s)
{
   ArrayResize(g_tiers, 0);
   string parts[];
   int n = StringSplit(s, ';', parts);
   for(int i = 0; i < n; i++)
   {
      string item = parts[i];
      StringTrimLeft(item);
      StringTrimRight(item);
      if(item == "") continue;

      string kv[];
      if(StringSplit(item, ':', kv) != 2) continue;

      double bal = StringToDouble(kv[0]);
      double lot = StringToDouble(kv[1]);
      if(bal <= 0.0 || lot <= 0.0) continue;

      int sz = ArraySize(g_tiers);
      ArrayResize(g_tiers, sz + 1);
      g_tiers[sz].balance = bal;
      g_tiers[sz].lot = lot;
   }

   int sz = ArraySize(g_tiers);
   for(int i = 1; i < sz; i++) // basit eklemeli siralama - kademe sayisi kucuk
   {
      LotTier key = g_tiers[i];
      int j = i - 1;
      while(j >= 0 && g_tiers[j].balance > key.balance)
      {
         g_tiers[j + 1] = g_tiers[j];
         j--;
      }
      g_tiers[j + 1] = key;
   }

   return(ArraySize(g_tiers) > 0);
}

int GetTierIndex(const double balance)
{
   int idx = -1;
   for(int i = 0; i < ArraySize(g_tiers); i++)
   {
      if(balance >= g_tiers[i].balance)
         idx = i;
      else
         break;
   }
   if(idx < 0 && ArraySize(g_tiers) > 0)
      idx = 0; // en dusuk kademenin altindaki bakiyeler de en kucuk lotu kullanir
   return(idx);
}

double ComputeLotForBalance(const double balance)
{
   if(InpLotSizingMode == LOT_SIZING_LINEAR)
   {
      double steps = MathFloor(balance / InpLotPerBalanceStep);
      return(InpLotPerBalanceBase + steps * InpLotPerBalanceIncr);
   }
   if(InpLotSizingMode == LOT_SIZING_FIXED)
      return(InpFixedLot);

   // LOT_SIZING_TIERS
   int idx = GetTierIndex(balance);
   if(idx < 0) return(0.0);
   return(g_tiers[idx].lot);
}

double ComputeSeedLot(const double balance)
{
   if(InpLotSizingMode != LOT_SIZING_TIERS)
      return(ComputeLotForBalance(balance)); // TIERS disinda "bir kademe kucuk" kavrami yok

   int idx = GetTierIndex(balance);
   if(idx <= 0) return(ComputeLotForBalance(balance));
   return(g_tiers[idx - 1].lot);
}

//+------------------------------------------------------------------+
//| Verilen lot icin 1 point'lik fiyat hareketinin gercek USD          |
//| karsiligi (OrderCalcProfit uzerinden, kontrat buyuklugu/quote      |
//| para birimi donusumu dahil) - OnInit() tutarlilik kontrolunde ve   |
//| ihtiyac halinde baska yerlerde kullanilir. Fiyat okunamazsa 0.     |
//+------------------------------------------------------------------+
double CalcMoneyPerPoint(const double lot)
{
   double price = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(price <= 0.0 || point <= 0.0 || lot <= 0.0) return(0.0);

   double profit = 0.0;
   if(!OrderCalcProfit(ORDER_TYPE_BUY, g_symbol, lot, price, price + point, profit))
      return(0.0);
   return(MathAbs(profit));
}

//+------------------------------------------------------------------+
//| EMIR GONDERME                                                      |
//+------------------------------------------------------------------+
bool HasEnoughMargin(const bool isBuy, const double lot)
{
   double price = isBuy ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(price <= 0.0) return(false);

   double marginRequired = 0.0;
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(type, g_symbol, lot, price, marginRequired))
      return(false);

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return(freeMargin >= marginRequired * (1.0 + InpMarginBufferPercent / 100.0));
}

bool OpenOnePosition(const bool isBuy, const double lot, const string tag)
{
   const int MAX_RETRIES = 2;

   for(int attempt = 0; attempt <= MAX_RETRIES; attempt++)
   {
      double price = isBuy ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);
      bool ok = isBuy ? trade.Buy(lot, g_symbol, price, 0.0, 0.0, InpTradeComment)
                       : trade.Sell(lot, g_symbol, price, 0.0, 0.0, InpTradeComment);
      if(ok)
         return(true);

      int retcode = trade.ResultRetcode();
      if(retcode == TRADE_RETCODE_MARKET_CLOSED || retcode == TRADE_RETCODE_PRICE_OFF)
      {
         if(InpDebug) PrintFormat("Scalper_Basket_EA: piyasa kapali/kote yok (retcode=%d) - sessiz geri cekiliyor.", retcode);
         return(false);
      }
      if(retcode == TRADE_RETCODE_NO_MONEY)
      {
         if(InpDebug) Print("Scalper_Basket_EA: yetersiz teminat (10019) - sessiz geri cekiliyor.");
         return(false);
      }

      if(InpDebug)
         PrintFormat("Scalper_Basket_EA: %s emri basarisiz (deneme %d/%d) | %s %.2f lot | retcode=%d (%s)",
                     tag, attempt + 1, MAX_RETRIES + 1, isBuy ? "BUY" : "SELL", lot,
                     retcode, trade.ResultRetcodeDescription());
   }
   return(false);
}

void CloseAllPositions(const string reason)
{
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(!trade.PositionClose(ticket))
         PrintFormat("Scalper_Basket_EA: pozisyon kapatilamadi #%I64u | retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   PrintFormat("Scalper_Basket_EA: sepet kapatildi - %s (P/L=%.2f)", reason, totalProfit);

   GlobalVariableSet(GV_LASTCLOSETIME, (double)TimeCurrent());
   GlobalVariableSet(GV_TRAILPEAK, 0.0);
   GlobalVariableSet(GV_LOCKEDLOT, 0.0);
}

//+------------------------------------------------------------------+
//| SEPET / POZISYON YARDIMCILARI                                      |
//+------------------------------------------------------------------+
void GetBasketStats(int &count, double &totalLots, double &totalProfit, ENUM_BASKET_SIDE &side,
                     datetime &lastAddTime, double &lastAddPrice)
{
   count = 0; totalLots = 0.0; totalProfit = 0.0; side = BASKET_NONE;
   lastAddTime = 0; lastAddPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      count++;
      totalLots += volume;
      totalProfit += profit;
      if(count == 1)
         side = (type == POSITION_TYPE_BUY) ? BASKET_BUY : BASKET_SELL;

      if(openTime >= lastAddTime)
      {
         lastAddTime = openTime;
         lastAddPrice = openPrice;
      }
   }
}

int CountOwnPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      count++;
   }
   return(count);
}

double GetLockedLot()
{
   if(!GlobalVariableCheck(GV_LOCKEDLOT)) return(0.0);
   return(GlobalVariableGet(GV_LOCKEDLOT));
}

datetime GetLastCloseTime()
{
   if(!GlobalVariableCheck(GV_LASTCLOSETIME)) return(0);
   return((datetime)GlobalVariableGet(GV_LASTCLOSETIME));
}

datetime GetDayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return(StructToTime(dt));
}

bool IsDailyBlocked()
{
   if(!GlobalVariableCheck(GV_DAILYBLOCKDAY)) return(false);
   return((datetime)GlobalVariableGet(GV_DAILYBLOCKDAY) == GetDayStart(TimeCurrent()));
}

void SetDailyBlocked()
{
   GlobalVariableSet(GV_DAILYBLOCKDAY, (double)GetDayStart(TimeCurrent()));
   PrintFormat("Scalper_Basket_EA: gunluk zarar limiti asildi - %s icin yeni tur acilmayacak.",
               TimeToString(TimeCurrent(), TIME_DATE));
}

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
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != g_symbol) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)InpMagic) continue;

      profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
              + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
              + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }
   return(profit);
}

long CurrentSpreadPoints()
{
   return(SymbolInfoInteger(g_symbol, SYMBOL_SPREAD));
}

double NormalizeLot(const double lots)
{
   double minLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0) stepLot = 0.01;

   double normalized = MathRound(lots / stepLot) * stepLot;
   normalized = MathMax(minLot, MathMin(maxLot, normalized));

   int stepDigits = (int)MathRound(-MathLog10(stepLot));
   if(stepDigits < 0) stepDigits = 0;

   return(NormalizeDouble(normalized, stepDigits));
}

//+------------------------------------------------------------------+
//| PANEL (basit sol-ust cok satirli etiket)                          |
//+------------------------------------------------------------------+
void CreatePanel()
{
   if(ObjectFind(0, PANEL_NAME) < 0)
      ObjectCreate(0, PANEL_NAME, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, PANEL_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, PANEL_NAME, OBJPROP_XDISTANCE, 12);
   ObjectSetInteger(0, PANEL_NAME, OBJPROP_YDISTANCE, 16);
   ObjectSetInteger(0, PANEL_NAME, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, PANEL_NAME, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, PANEL_NAME, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, PANEL_NAME, OBJPROP_BACK, false);
   ObjectSetInteger(0, PANEL_NAME, OBJPROP_SELECTABLE, false);
}

void RemovePanel()
{
   if(ObjectFind(0, PANEL_NAME) >= 0)
      ObjectDelete(0, PANEL_NAME);
}

void UpdatePanel()
{
   int count = 0;
   double totalLots = 0.0, totalProfit = 0.0, lastAddPrice = 0.0;
   datetime lastAddTime = 0;
   ENUM_BASKET_SIDE side = BASKET_NONE;
   GetBasketStats(count, totalLots, totalProfit, side, lastAddTime, lastAddPrice);

   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double freeMargin   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double dailyPL      = GetTodayRealizedProfit() + totalProfit;
   double target       = (InpBasketTargetUSD > 0.0) ? InpBasketTargetUSD : (count * InpTargetPerPosUSD);
   string sideTxt      = (side == BASKET_BUY) ? "BUY" : (side == BASKET_SELL) ? "SELL" : "-";

   string text = StringFormat(
      "Scalper Basket EA (%s)\n"
      "Yon..........: %s\n"
      "Pozisyon.....: %d/%d\n"
      "Sepet lot....: %.2f\n"
      "Floating P/L.: %.2f\n"
      "Hedef........: %.2f\n"
      "Bakiye.......: %.2f\n"
      "Serbest marj.: %.2f\n"
      "Gunluk P/L...: %.2f\n"
      "Gunluk kilit.: %s\n"
      "Durum........: %s",
      g_symbol, sideTxt, count, InpMaxPositions, totalLots, totalProfit, target,
      balance, freeMargin, dailyPL,
      IsDailyBlocked() ? "AKTIF" : "acik",
      (g_blockedReason == "") ? "OK" : g_blockedReason
   );

   ObjectSetString(0, PANEL_NAME, OBJPROP_TEXT, text);
}
//+------------------------------------------------------------------+
