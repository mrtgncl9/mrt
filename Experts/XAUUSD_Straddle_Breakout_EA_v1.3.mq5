//+------------------------------------------------------------------+
//|                       XAUUSD_Straddle_Breakout_EA_v1.3.mq5       |
//|         Buy Stop + Sell Stop Straddle Breakout "Gap" Bot         |
//+------------------------------------------------------------------+
//
// SURUM: 1.3 - Bu, "Scalper Basket" ailesinden TAMAMEN AYRI bir EA.
// Kendi surum sirasi var (v1.0, v1.1, ...), Basket EA'nin v1.x'i ile
// KARISTIRILMAMALI - iki farkli strateji, iki farkli dosya ailesi.
//
// v1.1: mantikta degisiklik yok, sadece tek-dosya teslimat.
// v1.2: GERCEK MANTIK DUZELTMESI - kisa pencereli backtest (200$
// baslangic, GOLD M1, 2026.08.12) net -148.59 (%74.30 dususu) verdi;
// kazanma orani iyiydi (%67.38) ama ortalama kayip (-4.28$) ortalama
// kazancin (1.68$) ~2.5 kati buyuktu. Sebep: trailing SABIT point
// (150pt baslat / 80pt takip) kullaniyordu, ama SL mesafesi ATR'ye gore
// degisiyordu (orn. 265pt) - kazananlar SL mesafesinin cok altinda
// erken kesiliyor, kaybedenler tam SL'e kadar gidiyordu. Duzeltme:
// trailing artik pozisyonun KENDI baslangic SL mesafesine ORANTILI
// (InpTrailStartRiskMult / InpTrailStepRiskMult).
// v1.3: v1.2'nin AYNI ayarlarla ~1 aylik uzun pencerede test edilmesi,
// kisa pencerenin iyimserliginin buyuk olcude gurultu oldugunu ortaya
// cikardi - Kar Faktoru 0.95'ten 0.83'e, kazanma orani %46.7'den
// %43.1'e geriledi, maksimum dusus %79.37'ye ulasti. Log incelemesi,
// kayiplarin buyuk kisminin piyasa YATAY/SIKISIKKEN acilan straddle'larin
// iki yonu de yanlis kirilimla (whipsaw) yemesinden geldigini gosterdi.
// Eklenen InpUseVolatilityFilter, guncel ATR kendi InpVolAvgPeriod'luk
// ortalamasinin altindaysa yeni straddle acilmasini engeller - bu bir
// HIPOTEZ, kesin cozum degil, tekrar uzun pencerede dogrulanmali.
//
// KULLANIM NOTU (once oku)
// -------------------------
// - Bu strateji bir kullanicinin paylastigi kisa bir video kaydina
//   dayanarak, GOZLEMLENEN DAVRANISTAN yeniden yazilmistir (Buy Stop +
//   Sell Stop "straddle", sabit kucuk lot, degisken/ATR tabanli SL).
//   Videoda tam olarak okunamayan degerler (gap mesafesi, SL katsayisi,
//   trailing parametreleri) TAHMINI varsayilanlarla dolduruldu - gercek
//   kullanima gecmeden once Strateji Test Cihazi'nda kalibre edilmesi
//   sarttir.
// - Sepet EA'sinin aksine bu EA aninda tek pozisyon tutar (Buy Stop/Sell
//   Stop'tan sadece biri tetiklenir, digeri hemen iptal edilir) - bu
//   yuzden HEDGING hesap sart degildir, netting hesapta da calisir.
// - Her pozisyonun GERCEK, broker taraflı SL'i vardir (emir yerlesirken
//   birlikte gonderilir) - stopsuz degildir.
//
// STRATEJI OZETI
// ---------------
// Ne pozisyon ne bekleyen emir yokken: mevcut fiyatin InpGapPoints kadar
// ustune BUY STOP, altina SELL STOP yerlestirilir (ikisi de InpLot lot).
// Biri tetiklenip gercek pozisyona donusunce, digeri hemen silinir (OCO).
// Pozisyon SL/TP (veya trailing) ile kapaninca, InpReArmDelaySec sonra
// yeni bir straddle kurulur. Bekleyen emirler InpMaxPendingAgeSec'ten
// eskirse veya fiyat merkezden InpRefreshDriftPoints kadar uzaklasirsa,
// iptal edilip guncel fiyata yeniden ortalanir (stale straddle onlenir).
//+------------------------------------------------------------------+
#property copyright "Educational Straddle Breakout EA"
#property version   "1.3"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                             |
//+------------------------------------------------------------------+
input group "===== Genel ====="
input string InpSymbolOverride = "";                 // Broker sembol adi farkliysa (orn. XAUUSDm, GOLD#) - bos = grafik sembolu
input ulong  InpMagic          = 20260817101;         // Magic number (Basket EA'dan FARKLI olmali)
input string InpTradeComment   = "StraddleGap";       // Emir yorumu
input bool   InpDebug          = true;                // Durum degisikliklerini logla

input group "===== Straddle / Giris ====="
input double InpLot                  = 0.01;  // Her iki bekleyen emir icin de sabit lot
input int    InpGapPoints            = 150;   // Fiyattan Buy/Sell Stop'a mesafe, points (TAHMINI - kalibre et)
input int    InpMaxPendingAgeSec     = 180;   // Bu sureden eski bekleyen emir cifti iptal edilip yeniden kurulur (0 = kapali)
input int    InpRefreshDriftPoints   = 300;   // Fiyat, straddle merkezinden bu kadar uzaklasirsa yeniden kurulur (0 = kapali)
input int    InpReArmDelaySec        = 2;     // Pozisyon kapandiktan sonra yeni straddle icin bekleme (saniye)

input group "===== Volatilite Filtresi (v1.3) ====="
input bool   InpUseVolatilityFilter = true;  // true: piyasa kendi ortalamasina gore SIKISIKKEN yeni straddle acma (whipsaw azaltir)
input int    InpVolAvgPeriod        = 50;    // Ortalama ATR'nin hesaplandigi bar sayisi
input double InpVolMinRatio         = 1.0;   // Guncel ATR >= (ortalama ATR * bu oran) olmali, yoksa straddle acilmaz

input group "===== Stop Loss / Take Profit / Trailing ====="
input bool             InpUseATRStopLoss = true;        // true: SL mesafesi ATR'ye gore degisken; false: sabit InpFixedSLPoints
input ENUM_TIMEFRAMES   InpATRTimeframe   = PERIOD_M1;   // ATR hesaplanacak zaman dilimi
input int               InpATRPeriod      = 14;          // ATR periyodu
input double            InpATRMultiplier  = 2.0;         // SL mesafesi = ATR(points) * bu katsayi
input int               InpFixedSLPoints  = 300;         // InpUseATRStopLoss=false ise (veya ATR hesaplanamazsa) kullanilan sabit SL, points
input bool              InpUseTP          = false;       // true: sabit take-profit de ekle
input int               InpTPPoints       = 600;         // InpUseTP=true ise TP mesafesi, points
input bool              InpUseTrailing    = true;        // true: pozisyon kar ettikce SL'i pesinden surukle
input double            InpTrailStartRiskMult = 1.0;     // Trailing, pozisyonun KENDI baslangic SL mesafesinin bu katini kadar kardan itibaren baslar
input double            InpTrailStepRiskMult  = 0.6;     // SL, fiyatin KENDI baslangic SL mesafesinin bu kati kadar gerisinde tutulur

input group "===== Risk Korumalari ====="
input double InpMarginBufferPercent = 20.0; // Serbest teminat, gereken teminatin bu kadar fazlasi olmali
input int    InpMaxSpreadPoints     = 0;    // 0 = kapali; >0 ise bu spreadin uzerinde yeni straddle kurulmaz
input bool   InpUseDailyGuard       = true; // Gunluk zarar limiti (gerceklesen + floating)
input double InpDailyMaxLossUSD     = 20.0; // Gunluk zarar limiti (USD) - asilinca o gun icin durur

input group "===== Panel ====="
input bool InpShowPanel = true; // Ekran paneli goster

//+------------------------------------------------------------------+
//| GLOBALS                                                            |
//+------------------------------------------------------------------+
CTrade trade;

string   g_symbol = "";
string   g_blockedReason = "";
int      g_atrHandle = INVALID_HANDLE;

string g_gvPrefix;
#define GV_LASTCLOSETIME   (g_gvPrefix + "_lastclose")
#define GV_STRADDLE_TIME   (g_gvPrefix + "_straddletime")
#define GV_STRADDLE_CENTER (g_gvPrefix + "_straddlecenter")
#define GV_DAILYBLOCKDAY   (g_gvPrefix + "_dailyblockday")

#define PANEL_NAME "StraddleGapEA_Panel"

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = (InpSymbolOverride != "") ? InpSymbolOverride : _Symbol;
   if(!SymbolSelect(g_symbol, true))
   { PrintFormat("Straddle_EA: sembol bulunamadi/secilemedi: %s", g_symbol); return(INIT_FAILED); }

   if(InpLot <= 0.0)
   { Print("Straddle_EA: InpLot 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpGapPoints <= 0)
   { Print("Straddle_EA: InpGapPoints 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(!InpUseATRStopLoss && InpFixedSLPoints <= 0)
   { Print("Straddle_EA: InpUseATRStopLoss=false iken InpFixedSLPoints 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpUseATRStopLoss && InpATRMultiplier <= 0.0)
   { Print("Straddle_EA: InpATRMultiplier 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpReArmDelaySec < 0)
   { Print("Straddle_EA: InpReArmDelaySec negatif olamaz."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpMarginBufferPercent < 0.0)
   { Print("Straddle_EA: InpMarginBufferPercent negatif olamaz."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpUseTrailing && (InpTrailStartRiskMult <= 0.0 || InpTrailStepRiskMult <= 0.0))
   { Print("Straddle_EA: InpTrailStartRiskMult ve InpTrailStepRiskMult 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpUseTrailing && InpTrailStepRiskMult >= InpTrailStartRiskMult)
   { Print("Straddle_EA: InpTrailStepRiskMult, InpTrailStartRiskMult'tan kucuk olmali (yoksa trailing baslar baslamaz SL'i orijinal SL'den de yakina ceker)."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpUseVolatilityFilter && (InpVolAvgPeriod < 2 || InpVolMinRatio <= 0.0))
   { Print("Straddle_EA: InpVolAvgPeriod en az 2, InpVolMinRatio 0'dan buyuk olmali."); return(INIT_PARAMETERS_INCORRECT); }

   if(InpUseATRStopLoss || InpUseVolatilityFilter) // volatilite filtresi de ayni ATR handle'ini kullanir
   {
      g_atrHandle = iATR(g_symbol, InpATRTimeframe, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
      { Print("Straddle_EA: ATR handle olusturulamadi."); return(INIT_FAILED); }
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(g_symbol);
   trade.SetAsyncMode(false);

   g_gvPrefix = "StraddleGapEA_" + IntegerToString((long)InpMagic) + "_" + g_symbol;

   if(InpShowPanel) CreatePanel();

   PrintFormat("Straddle_EA baslatildi | Sembol=%s Magic=%I64u Lot=%.2f Gap=%dpt",
               g_symbol, InpMagic, InpLot, InpGapPoints);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   RemovePanel();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - pozisyon kapandigi anda yeniden kurulum       |
//| bekleme sayacini baslatir (restart-safe, GlobalVariable'a yazilir).|
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagic) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   GlobalVariableSet(GV_LASTCLOSETIME, (double)TimeCurrent());

   long positionId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(positionId > 0)
      GlobalVariableDel(g_gvPrefix + "_risk_" + IntegerToString(positionId)); // ApplyTrailing()'in sakladigi baslangic-risk kaydini temizle
}

//+------------------------------------------------------------------+
//| OnTick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   EnforceDailyGuard();
   ManageStraddle();
   if(InpShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| Ana durum makinesi: pozisyon acikken karsi tarafi iptal et + varsa |
//| trailing uygula; degilse bekleyen emirleri yonet (eskime/surukleme |
//| kontrolu) ya da hicbiri yoksa yeni straddle kur.                    |
//+------------------------------------------------------------------+
void ManageStraddle()
{
   g_blockedReason = "";

   ulong posTicket = 0;
   ENUM_POSITION_TYPE posType = POSITION_TYPE_BUY;
   if(GetOwnPosition(posTicket, posType))
   {
      CancelOppositePending(posType);
      if(InpUseTrailing) ApplyTrailing(posTicket, posType);
      g_blockedReason = "pozisyon acik";
      return;
   }

   ulong buyStop = 0, sellStop = 0;
   bool hasPending = GetOwnPendingOrders(buyStop, sellStop);

   if(hasPending)
   {
      bool bothPresent = (buyStop != 0 && sellStop != 0);
      if(!bothPresent)
      {
         // Yarim kalmis straddle (elle mudahale, kismi hata vs.) - temizle,
         // bir sonraki tick'te sifirdan kurulur.
         if(buyStop != 0)  trade.OrderDelete(buyStop);
         if(sellStop != 0) trade.OrderDelete(sellStop);
         g_blockedReason = "yarim straddle temizlendi";
         return;
      }

      double placedTime  = GlobalVariableCheck(GV_STRADDLE_TIME)   ? GlobalVariableGet(GV_STRADDLE_TIME)   : 0.0;
      double centerPrice = GlobalVariableCheck(GV_STRADDLE_CENTER) ? GlobalVariableGet(GV_STRADDLE_CENTER) : 0.0;
      double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
      double curMid = (SymbolInfoDouble(g_symbol, SYMBOL_ASK) + SymbolInfoDouble(g_symbol, SYMBOL_BID)) / 2.0;

      bool tooOld = (InpMaxPendingAgeSec > 0) && (placedTime > 0.0) &&
                    (TimeCurrent() - (datetime)placedTime > InpMaxPendingAgeSec);
      bool driftedTooFar = (InpRefreshDriftPoints > 0) && (centerPrice > 0.0) && (point > 0.0) &&
                            (MathAbs(curMid - centerPrice) / point > InpRefreshDriftPoints);

      if(tooOld || driftedTooFar)
      {
         trade.OrderDelete(buyStop);
         trade.OrderDelete(sellStop);
         if(InpDebug)
            PrintFormat("Straddle_EA: straddle yenileniyor (%s)", tooOld ? "eskidi" : "fiyat uzaklasti");
      }
      else
      {
         g_blockedReason = "straddle bekliyor";
      }
      return;
   }

   if(InpUseDailyGuard && IsDailyBlocked())
   { g_blockedReason = "gunluk zarar kilidi aktif"; return; }

   if(TimeCurrent() - GetLastCloseTime() < InpReArmDelaySec)
   { g_blockedReason = "yeniden kurulum bekleniyor"; return; }

   PlaceStraddle();
}

//+------------------------------------------------------------------+
//| Guncel fiyatin InpGapPoints kadar ustune/altina, ATR ya da sabit   |
//| mesafeli SL'li BUY STOP + SELL STOP cifti yerlestirir. Tek taraf   |
//| basarisiz olursa diger tarafi da iptal eder (yarim straddle        |
//| birakmaz).                                                          |
//+------------------------------------------------------------------+
void PlaceStraddle()
{
   if(InpMaxSpreadPoints > 0 && CurrentSpreadPoints() > InpMaxSpreadPoints)
   { g_blockedReason = "spread cok genis"; return; }

   if(!VolatilityFilterPasses())
   { g_blockedReason = "volatilite dusuk (piyasa sikisik)"; return; }

   double slDistPoints = CalcSLDistancePoints();
   if(slDistPoints <= 0.0)
   { g_blockedReason = "SL mesafesi hesaplanamadi"; return; }

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || point <= 0.0)
   { g_blockedReason = "fiyat okunamadi"; return; }

   if(!HasEnoughMargin(InpLot))
   { g_blockedReason = "serbest teminat yetersiz"; return; }

   double gapPrice     = InpGapPoints * point;
   double slDistPrice  = slDistPoints * point;

   double buyStopPrice  = NormalizeDouble(ask + gapPrice, _Digits);
   double sellStopPrice = NormalizeDouble(bid - gapPrice, _Digits);
   double buySL  = NormalizeDouble(buyStopPrice - slDistPrice, _Digits);
   double sellSL = NormalizeDouble(sellStopPrice + slDistPrice, _Digits);
   double buyTP  = InpUseTP ? NormalizeDouble(buyStopPrice + InpTPPoints * point, _Digits)  : 0.0;
   double sellTP = InpUseTP ? NormalizeDouble(sellStopPrice - InpTPPoints * point, _Digits) : 0.0;

   bool okBuy  = trade.BuyStop(InpLot, buyStopPrice, g_symbol, buySL, buyTP, ORDER_TIME_GTC, 0, InpTradeComment);
   int  buyRetcode = trade.ResultRetcode();
   bool okSell = trade.SellStop(InpLot, sellStopPrice, g_symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, InpTradeComment);
   int  sellRetcode = trade.ResultRetcode();

   if(!okBuy || !okSell)
   {
      if(InpDebug)
         PrintFormat("Straddle_EA: pending emir hatasi | buy=%s(%d) sell=%s(%d)",
                     okBuy ? "OK" : "FAIL", buyRetcode, okSell ? "OK" : "FAIL", sellRetcode);

      // Tek taraf basarili oldu diyeyse yarim straddle birakma, onu da iptal et.
      ulong bt = 0, st = 0;
      GetOwnPendingOrders(bt, st);
      if(bt != 0) trade.OrderDelete(bt);
      if(st != 0) trade.OrderDelete(st);
      g_blockedReason = "pending emir gonderilemedi";
      return;
   }

   GlobalVariableSet(GV_STRADDLE_CENTER, (ask + bid) / 2.0);
   GlobalVariableSet(GV_STRADDLE_TIME, (double)TimeCurrent());
   if(InpDebug)
      PrintFormat("Straddle_EA: yeni straddle | BUY STOP %.2f (SL %.2f) | SELL STOP %.2f (SL %.2f) | SLdist=%.0fpt",
                  buyStopPrice, buySL, sellStopPrice, sellSL, slDistPoints);
}

//+------------------------------------------------------------------+
//| SL mesafesi: ATR modunda (ATR(points) * InpATRMultiplier), ATR     |
//| hazir degilse veya kapaliysa InpFixedSLPoints'e duser.              |
//+------------------------------------------------------------------+
double CalcSLDistancePoints()
{
   if(InpUseATRStopLoss && IsHandleReady(g_atrHandle))
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) == 1 && atrBuf[0] > 0.0)
      {
         double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
         if(point > 0.0)
            return (atrBuf[0] / point) * InpATRMultiplier;
      }
   }
   return((double)InpFixedSLPoints);
}

bool IsHandleReady(const int handle)
{
   if(handle == INVALID_HANDLE) return(false);
   return(BarsCalculated(handle) > 1);
}

//+------------------------------------------------------------------+
//| v1.3: uzun pencereli backtest, kisa pencerede gorulmeyen bir zayif |
//| nokta ortaya cikardi - piyasa YATAY/SIKISIKKEN acilan straddle'lar |
//| genelde iki yonu de yanlis kirilimla (whipsaw) yiyor. Bu filtre,   |
//| guncel ATR kendi InpVolAvgPeriod barlik ortalamasinin altindaysa   |
//| (piyasa sakinse) yeni straddle acilmasini engeller. HIPOTEZ olarak |
//| eklendi - kesin cozum degil, tekrar uzun pencerede test edilmeli.  |
//+------------------------------------------------------------------+
bool VolatilityFilterPasses()
{
   if(!InpUseVolatilityFilter) return(true);
   if(InpVolAvgPeriod < 2) return(true);
   if(!IsHandleReady(g_atrHandle)) return(false);
   if(BarsCalculated(g_atrHandle) < InpVolAvgPeriod + 1) return(false);

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, InpVolAvgPeriod, atrBuf) != InpVolAvgPeriod)
      return(false);

   double current = atrBuf[0];
   double sum = 0.0;
   for(int i = 0; i < InpVolAvgPeriod; i++)
      sum += atrBuf[i];
   double avg = sum / InpVolAvgPeriod;
   if(avg <= 0.0) return(false);

   return(current >= avg * InpVolMinRatio);
}

//+------------------------------------------------------------------+
//| Pozisyon acilinca (Buy Stop ya da Sell Stop tetiklenince) karsi    |
//| taraftaki hala bekleyen emri hemen siler (OCO - one cancels other).|
//+------------------------------------------------------------------+
void CancelOppositePending(const ENUM_POSITION_TYPE posType)
{
   ulong buyStop = 0, sellStop = 0;
   if(!GetOwnPendingOrders(buyStop, sellStop)) return;

   if(posType == POSITION_TYPE_BUY && sellStop != 0)
      trade.OrderDelete(sellStop);
   else if(posType == POSITION_TYPE_SELL && buyStop != 0)
      trade.OrderDelete(buyStop);
}

//+------------------------------------------------------------------+
//| Trailing, SABIT point yerine pozisyonun KENDI baslangic SL         |
//| mesafesine ORANTILI calisir (InpTrailStartRiskMult / ...StepRiskMult|
//| katlari). Bir backtest'te sabit-point trailing (150pt baslat/80pt  |
//| takip) ile ATR-tabanli SL (orn. 265pt) arasindaki uyumsuzluk,      |
//| kazananlari SL mesafesinin cok altinda erken kesip kaybedenleri    |
//| tam SL'e kadar tasiyarak (avg kazanc $1.68 vs avg kayip -$4.28,    |
//| %67 kazanma oranina ragmen net zarar) hesabi eritmisti. Baslangic  |
//| SL mesafesi pozisyon ilk acildiginda GV'ye kaydedilir (ilk         |
//| ApplyTrailing cagrisinda, SL henuz trailing tarafindan degismeden  |
//| once) ve o pozisyon kapanana kadar SABIT kalir - boylece trailing  |
//| sonradan ATR degisse bile o islemin KENDI riskiyle olculur.        |
//+------------------------------------------------------------------+
void ApplyTrailing(const ulong ticket, const ENUM_POSITION_TYPE type)
{
   if(!PositionSelectByTicket(ticket)) return;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0.0) return;

   string riskKey = g_gvPrefix + "_risk_" + IntegerToString((long)ticket);
   double riskPoints;
   if(GlobalVariableCheck(riskKey))
      riskPoints = GlobalVariableGet(riskKey);
   else
   {
      riskPoints = (curSL > 0.0) ? MathAbs(openPrice - curSL) / point : (double)InpFixedSLPoints;
      GlobalVariableSet(riskKey, riskPoints);
   }
   if(riskPoints <= 0.0) return;

   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(g_symbol, SYMBOL_BID) : SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double profitPoints = (type == POSITION_TYPE_BUY) ? (price - openPrice) / point : (openPrice - price) / point;

   double startPoints = riskPoints * InpTrailStartRiskMult;
   double stepPoints   = riskPoints * InpTrailStepRiskMult;
   if(profitPoints < startPoints) return;

   double newSL = (type == POSITION_TYPE_BUY)
                  ? NormalizeDouble(price - stepPoints * point, _Digits)
                  : NormalizeDouble(price + stepPoints * point, _Digits);

   bool improved = (type == POSITION_TYPE_BUY) ? (newSL > curSL) : (curSL <= 0.0 || newSL < curSL);
   if(!improved) return;

   long stopsLevel = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * point;
   bool farEnough = (type == POSITION_TYPE_BUY) ? (price - newSL) >= minDist : (newSL - price) >= minDist;
   if(!farEnough) return;

   if(!trade.PositionModify(ticket, newSL, curTP) && InpDebug)
      PrintFormat("Straddle_EA: trailing SL guncellenemedi #%I64u retcode=%d (%s)",
                  ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Gunluk zarar limiti: gerceklesen + (varsa) floating P/L bu limiti  |
//| asarsa acik pozisyonu kapatir, bekleyen emirleri siler, o gun icin |
//| yeni straddle kurulmasini engeller.                                 |
//+------------------------------------------------------------------+
void EnforceDailyGuard()
{
   if(!InpUseDailyGuard || IsDailyBlocked()) return;

   ulong posTicket = 0;
   ENUM_POSITION_TYPE posType = POSITION_TYPE_BUY;
   double floatingPL = 0.0;
   if(GetOwnPosition(posTicket, posType) && PositionSelectByTicket(posTicket))
      floatingPL = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   double dailyPL = GetTodayRealizedProfit() + floatingPL;
   if(dailyPL > -InpDailyMaxLossUSD)
      return;

   if(posTicket != 0)
      trade.PositionClose(posTicket);

   ulong bt = 0, st = 0;
   if(GetOwnPendingOrders(bt, st))
   {
      if(bt != 0) trade.OrderDelete(bt);
      if(st != 0) trade.OrderDelete(st);
   }

   SetDailyBlocked();
   PrintFormat("Straddle_EA: gunluk zarar limiti asildi (P/L=%.2f) - gun icin durduruldu.", dailyPL);
}

//+------------------------------------------------------------------+
//| POZISYON / EMIR YARDIMCILARI                                       |
//+------------------------------------------------------------------+
bool GetOwnPosition(ulong &ticket, ENUM_POSITION_TYPE &type)
{
   ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      ticket = t;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return(true);
   }
   return(false);
}

bool GetOwnPendingOrders(ulong &buyStopTicket, ulong &sellStopTicket)
{
   buyStopTicket = 0; sellStopTicket = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagic) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)       buyStopTicket = ticket;
      else if(type == ORDER_TYPE_SELL_STOP) sellStopTicket = ticket;
   }
   return(buyStopTicket != 0 || sellStopTicket != 0);
}

bool HasEnoughMargin(const double lot)
{
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(ask <= 0.0) return(false);

   double marginRequired = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, g_symbol, lot, ask, marginRequired))
      return(false);

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return(freeMargin >= marginRequired * (1.0 + InpMarginBufferPercent / 100.0));
}

long CurrentSpreadPoints()
{
   return(SymbolInfoInteger(g_symbol, SYMBOL_SPREAD));
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
   ulong posTicket = 0;
   ENUM_POSITION_TYPE posType = POSITION_TYPE_BUY;
   bool inPosition = GetOwnPosition(posTicket, posType);
   double floatingPL = 0.0;
   if(inPosition && PositionSelectByTicket(posTicket))
      floatingPL = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   ulong buyStop = 0, sellStop = 0;
   bool hasPending = GetOwnPendingOrders(buyStop, sellStop);

   string statusTxt = inPosition ? (posType == POSITION_TYPE_BUY ? "POZISYON: BUY" : "POZISYON: SELL")
                                  : (hasPending ? "STRADDLE BEKLIYOR" : "KURULUM BEKLENIYOR");

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double dailyPL = GetTodayRealizedProfit() + floatingPL;

   string text = StringFormat(
      "Straddle Gap EA (%s)\n"
      "Durum........: %s\n"
      "Floating P/L.: %.2f\n"
      "SL mesafesi..: %.0f pt\n"
      "Bakiye.......: %.2f\n"
      "Serbest marj.: %.2f\n"
      "Gunluk P/L...: %.2f\n"
      "Gunluk kilit.: %s\n"
      "Not..........: %s",
      g_symbol, statusTxt, floatingPL, CalcSLDistancePoints(),
      balance, freeMargin, dailyPL,
      IsDailyBlocked() ? "AKTIF" : "acik",
      (g_blockedReason == "") ? "-" : g_blockedReason
   );

   ObjectSetString(0, PANEL_NAME, OBJPROP_TEXT, text);
}
//+------------------------------------------------------------------+
