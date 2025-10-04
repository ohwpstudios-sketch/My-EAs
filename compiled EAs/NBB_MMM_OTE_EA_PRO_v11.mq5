//+------------------------------------------------------------------+
//|                                            NBB_MMM_OTE_EA_PRO.mq5 |
//|                                   Author: GH Wealth Makers Elite   |
//|                                         (c) 2025, GH Wealth Makers |
//+------------------------------------------------------------------+
//| Market Maker Model with OTE entries, structural confirmation,     |
//| D1+H1 bias confluence, adaptive secondary fib (ATR percentile),   |
//| pending expiry + cooldown, optional news pause, partial TP and    |
//| structural trailing.                                              |
//+------------------------------------------------------------------+
#property copyright   "2025 GH Wealth Makers Elite"
#property link        "https://ghwealthmakerselite.xyz/"
#property version     "1.000"
#property strict

#include <Trade/Trade.mqh>

// Toggle News pause (0 = compile-safe off; 1 = requires MT5 Economic Calendar support)
#define USE_NEWS_PAUSE 0

//=============================== INPUTS ===============================//
// Trade & Risk
input ulong   InpMagicNumber           = 86531011;   // Magic Number
input bool    InpUseRiskPercent       = true;       // Use risk % (true) or fixed lot (false)
input double  InpFixedLot             = 0.10;       // Fixed lot size when UseRiskPercent=false
input double  InpRiskPercent          = 0.5;        // Risk % of equity per trade
input double  InpMaxSpreadPoints      = 150.0;      // Max spread (points)
input int     InpMaxSlippagePoints    = 20;         // Max slippage (points)
input int     InpMaxOpenPositions     = 2;          // Max open positions (this symbol)

// Bias
enum BiasMode { BIAS_AUTO=0, BIAS_LONG=1, BIAS_SHORT=2 };
input BiasMode InpBiasMode            = BIAS_AUTO;  // Trading bias mode
input int     InpBiasFastEMA          = 20;         // Bias fast EMA (D1)
input int     InpBiasSlowEMA          = 50;         // Bias slow EMA (D1)
input bool    InpUseH1Confluence      = true;       // Require H1 EMA(20/50) to agree with D1 bias

// Confirmation & Entry
input ENUM_TIMEFRAMES InpConfirmTF    = PERIOD_M15; // Confirmation timeframe (15m or 30m)
input ENUM_TIMEFRAMES InpRefineTF     = PERIOD_M5;  // Refinement timeframe
input int     InpSwingLookback        = 12;         // Bars to scan swings for breaker
input double  InpMinDispATR           = 1.2;        // Min displacement body multiple of ATR(14)
input double  InpFibEntryMin          = 0.50;       // Min Fib entry (0.50)
input double  InpFibEntryMax          = 0.79;       // Max Fib entry (0.79)
input bool    InpUseDualLimits        = true;       // Place two limit orders at 62% & SecondaryFib
input double  InpSecondaryFib         = 0.705;      // Secondary Fib when dual limits enabled
input bool    InpUseStructureFilter   = true;       // Require BOS/CHoCH + FVG near OTE
input double  InpFVGMaxDistPoints     = 50;         // Max distance from entry to FVG midpoint (points)

// Adaptive secondary fib (ATR percentile)
input bool    InpAdaptiveSecondaryFib = true;       // Adapt secondary fib by ATR percentile
input int     InpATRPeriod            = 14;         // ATR period
input int     InpATRLookback          = 200;        // ATR lookback for percentile (bars)
input double  InpSecFibMin            = 0.66;       // Min secondary fib
input double  InpSecFibMax            = 0.72;       // Max secondary fib

// Stops / BE / trailing / partials
enum StopMode { STOP_AT_100=0, STOP_AT_90=1 };
input StopMode InpStopMode            = STOP_AT_100;// Stop: 1.00 or 0.90 fib
input bool    InpUseATRStopPad        = false;      // Add ATR padding to SL
input double  InpATRPadMult           = 0.0;        // ATR pad multiplier
input double  InpBEFibLevel           = 0.20;       // Breakeven trigger fib level
input double  InpPartialTP1Pct        = 50.0;       // Partial TP % at fib 0.0 (0 disables)
input double  InpRunnerADRMult        = 0.50;       // Runner target: ADR * multiplier

// Sessions / Orders
input bool    InpUseSessions          = true;       // Trade during sessions only
input int     InpLondonOpenHour       = 7;          // London open hour (broker time)
input int     InpNewYorkOpenHour      = 12;         // New York open hour (broker time)
input int     InpLondonCloseHour      = 16;         // London close hour (broker time)
input int     InpPendingExpiryMin     = 90;         // Cancel pendings after N minutes
input int     InpCooldownMin          = 30;         // Cooldown minutes after cancellation

// News pause (MT5 Economic Calendar)
input bool    InpUseNewsPause         = false;      // Pause around high-impact news
input int     InpNewsPauseBeforeMin   = 30;         // Minutes before news to pause
input int     InpNewsPauseAfterMin    = 30;         // Minutes after news to pause
input bool    InpNewsHighImpactOnly   = true;       // Only high importance
input string  InpNewsCurrencies       = "USD,EUR,GBP"; // CSV of currencies to watch

// Notifications / Logging
input bool    InpEnablePush           = false;      // Push notifications on key events
input bool    InpWriteCSVJournal      = false;      // Write journal CSV

//============================= GLOBALS =================================//
CTrade   Trade;
MqlTick  g_tick;

double gFibEntryMin = 0.50;
double gFibEntryMax = 0.79;
double gSecondaryFib = 0.705;

datetime g_cooldownUntil = 0;
bool     g_partialDone   = false;

//============================= STRUCTS =================================//
struct FibLeg
{
   bool      valid;
   bool      isShort;
   double    A;     // swing anchor 1
   double    B;     // swing anchor 2
   datetime  tA;
   datetime  tB;
   double    entryMin;
   double    entryMax;
   double    fib0;  // target anchor
   double    fib1;  // stop anchor
};

FibLeg g_leg;

//============================= HELPERS =================================//
void Notify(const string msg){ if(InpEnablePush) SendNotification("[NBB_OTE] "+msg); }

double PointsToPrice(double pts){ return pts*_Point; }
double PriceToPoints(double d){ return d/_Point; }

int    BarsOnTF(const string sym, ENUM_TIMEFRAMES tf){ return (int)Bars(sym, tf); }

double MAValue(const string sym, ENUM_TIMEFRAMES tf, int period, ENUM_MA_METHOD method, ENUM_APPLIED_PRICE price, int shift)
{
   int h = iMA(sym, tf, period, 0, method, price);
   if(h==INVALID_HANDLE) return 0.0;
   double b[]; if(CopyBuffer(h, 0, shift, 1, b)<1) return 0.0;
   return b[0];
}

double ATRValue(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iATR(sym, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double b[]; if(CopyBuffer(h, 0, shift, 1, b)<1) return 0.0;
   return b[0];
}

double ATRPercentile(const string sym, ENUM_TIMEFRAMES tf, int period, int lookback)
{
   int h = iATR(sym, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   int cnt = MathMin(lookback, BarsOnTF(sym, tf)-period-5);
   if(cnt<=5) return 0.0;
   double b[]; if(CopyBuffer(h, 0, 0, cnt, b)<cnt) return 0.0;
   double curr = b[0];
   int le=0;
   for(int i=0;i<cnt;i++) if(b[i]<=curr) le++;
   return (double)le/(double)cnt; // 0..1
}

double ADR(const string sym, int days=14)
{
   int bars = Bars(sym, PERIOD_D1);
   int n = MathMin(days+1, bars-1);
   if(n<=1) return 0.0;
   double rng=0.0;
   for(int i=1;i<=n;i++)
   {
      double hi=iHigh(sym, PERIOD_D1, i);
      double lo=iLow (sym, PERIOD_D1, i);
      rng += (hi-lo);
   }
   return rng/n;
}

bool CheckSpreadOK()
{
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread<=0) return true;
   return (spread <= InpMaxSpreadPoints);
}

// Parse CSV currencies into array
int ParseCurrencies(string list, string &out[])
{
   StringReplace(list, " ", ""); // trim spaces
   int n = StringSplit(list, ',', out);
   return n;
}

// News window check (compile-safe stub; always returns false unless you wire a news source)
bool IsNewsWindowActive()
{
   return false;
}

// Sessions window (LO/NYO/LC), very simple hour-based filter
bool InSession()
{
   if(!InpUseSessions) return true;
   MqlDateTime mt; TimeToStruct(TimeCurrent(), mt);
   int h = mt.hour;
   bool lo  = (h>=InpLondonOpenHour && h<InpLondonCloseHour);
   bool nyo = (h>=InpNewYorkOpenHour && h<InpLondonCloseHour);
   return (lo || nyo);
}

//========================== BIAS & STRUCTURE ===========================//

bool GetBias(bool &sellOnly, bool &buyOnly)
{
   sellOnly=false; buyOnly=false;
   if(InpBiasMode==BIAS_LONG){ buyOnly=true; return true; }
   if(InpBiasMode==BIAS_SHORT){ sellOnly=true; return true; }

   // D1 EMA 20/50
   double emaF_D1 = MAValue(_Symbol, PERIOD_D1, InpBiasFastEMA, MODE_EMA, PRICE_CLOSE, 1);
   double emaS_D1 = MAValue(_Symbol, PERIOD_D1, InpBiasSlowEMA, MODE_EMA, PRICE_CLOSE, 1);
   if(emaF_D1==0 || emaS_D1==0) return false;

   int dirD1 = (emaF_D1>emaS_D1)? +1 : (emaF_D1<emaS_D1? -1 : 0);
   if(!InpUseH1Confluence)
   {
      if(dirD1>0) buyOnly=true; else if(dirD1<0) sellOnly=true;
      return true;
   }

   // H1 EMA 20/50
   double emaF_H1 = MAValue(_Symbol, PERIOD_H1, InpBiasFastEMA, MODE_EMA, PRICE_CLOSE, 1);
   double emaS_H1 = MAValue(_Symbol, PERIOD_H1, InpBiasSlowEMA, MODE_EMA, PRICE_CLOSE, 1);
   if(emaF_H1==0 || emaS_H1==0) return false;
   int dirH1 = (emaF_H1>emaS_H1)? +1 : (emaF_H1<emaS_H1? -1 : 0);

   int agree = dirD1 * dirH1;
   if(agree>0){ if(dirD1>0) buyOnly=true; else sellOnly=true; }
   else { sellOnly=false; buyOnly=false; } // no trade if not aligned

   return true;
}

// Simple swing utilities
double SwingHigh(const string sym, ENUM_TIMEFRAMES tf, int i)
{
   double h  = iHigh(sym, tf, i);
   double h1 = iHigh(sym, tf, i+1);
   double h2 = iHigh(sym, tf, i+2);
   if(h>h1 && h>h2) return h;
   return 0.0;
}
double SwingLow(const string sym, ENUM_TIMEFRAMES tf, int i)
{
   double l  = iLow(sym, tf, i);
   double l1 = iLow(sym, tf, i+1);
   double l2 = iLow(sym, tf, i+2);
   if(l<l1 && l<l2) return l;
   return 0.0;
}

// 3-candle FVG detection: bullish if L1>H3; bearish if H1<L3 (indexes relative to shift)
bool HasFVG(const string sym, ENUM_TIMEFRAMES tf, int shift, bool bullish)
{
   double h0=iHigh(sym, tf, shift+2), l0=iLow(sym, tf, shift+2);
   double h1=iHigh(sym, tf, shift+1), l1=iLow(sym, tf, shift+1);
   double h2=iHigh(sym, tf, shift+0), l2=iLow(sym, tf, shift+0);
   if(bullish) return (l1>h2);
   else        return (h1<l2);
}

// Find FVG midpoint nearest to a price within max distance (points)
bool FVGNearPrice(const string sym, ENUM_TIMEFRAMES tf, int look, double price, double maxDistPts, bool bullish, double &midOut)
{
   for(int s=1; s<=look; s++)
   {
      if(HasFVG(sym, tf, s, bullish))
      {
         double h2=iHigh(sym, tf, s), l1=iLow(sym, tf, s+1);
         double mid = (h2+l1)/2.0;
         double dPts = PriceToPoints(MathAbs(mid - price));
         if(dPts <= maxDistPts){ midOut=mid; return true; }
      }
   }
   return false;
}

// Detect simplified breaker+displacement and build leg (A,B); returns true when found
bool FindBreakerAndDisplacement(FibLeg &leg)
{
   leg.valid=false; leg.isShort=false; leg.A=0; leg.B=0; leg.tA=0; leg.tB=0; leg.entryMin=0; leg.entryMax=0; leg.fib0=0; leg.fib1=0;
   int LB = MathMax(6, InpSwingLookback);
   int last = 1; // last closed bar on confirm TF

   // Shorts pattern
   for(int i=last+3; i<=last+LB; i++)
   {
      double H0=iHigh(_Symbol, InpConfirmTF, i);
      double L1=iLow (_Symbol, InpConfirmTF, i-1);
      double H2=iHigh(_Symbol, InpConfirmTF, i-2);
      double L3=iLow (_Symbol, InpConfirmTF, i-3);
      if(!(H2>H0 && L3<L1)) continue;

      double body = MathAbs(iClose(_Symbol, InpConfirmTF, last)-iOpen(_Symbol, InpConfirmTF, last));
      double atr  = ATRValue(_Symbol, InpConfirmTF, InpATRPeriod, last);
      double close= iClose(_Symbol, InpConfirmTF, last);
      if(atr<=0) continue;
      if(body < InpMinDispATR*atr) continue;
      if(close > L1) continue; // need displacement close below prior swing low

      leg.isShort=true;
      leg.A = H0; leg.B=L3; leg.tA=iTime(_Symbol, InpConfirmTF, i); leg.tB=iTime(_Symbol, InpConfirmTF, i-3);
      leg.valid=true; break;
   }
   if(leg.valid) return true;

   // Longs pattern
   for(int i=last+3; i<=last+LB; i++)
   {
      double L0=iLow (_Symbol, InpConfirmTF, i);
      double H1=iHigh(_Symbol, InpConfirmTF, i-1);
      double L2=iLow (_Symbol, InpConfirmTF, i-2);
      double H3=iHigh(_Symbol, InpConfirmTF, i-3);
      if(!(L2<L0 && H3>H1)) continue;

      double body = MathAbs(iClose(_Symbol, InpConfirmTF, last)-iOpen(_Symbol, InpConfirmTF, last));
      double atr  = ATRValue(_Symbol, InpConfirmTF, InpATRPeriod, last);
      double close= iClose(_Symbol, InpConfirmTF, last);
      if(atr<=0) continue;
      if(body < InpMinDispATR*atr) continue;
      if(close < H1) continue; // need displacement close above prior swing high

      leg.isShort=false;
      leg.A = L0; leg.B=H3; leg.tA=iTime(_Symbol, InpConfirmTF, i); leg.tB=iTime(_Symbol, InpConfirmTF, i-3);
      leg.valid=true; break;
   }
   return leg.valid;
}

// Extra structural filter: BOS/CHoCH + FVG near OTE zone
bool ConfirmStructureAndFVG(const FibLeg &leg, double entry1, double entry2)
{
   if(!InpUseStructureFilter) return true;
   int last = 1;
   bool ok=false;
   if(leg.isShort)
   {
      // BOS: recent low taking previous swing low
      for(int i=3;i<=InpSwingLookback;i++)
      {
         double swl = SwingLow(_Symbol, InpConfirmTF, i);
         if(swl!=0 && iLow(_Symbol, InpConfirmTF, last) < swl){ ok=true; break; }
      }
      if(!ok) return false;
      double mid; bool fvg = FVGNearPrice(_Symbol, InpConfirmTF, InpSwingLookback, (entry2>0? entry2:entry1), InpFVGMaxDistPoints, false, mid);
      return fvg;
   }
   else
   {
      for(int i=3;i<=InpSwingLookback;i++)
      {
         double swh = SwingHigh(_Symbol, InpConfirmTF, i);
         if(swh!=0 && iHigh(_Symbol, InpConfirmTF, last) > swh){ ok=true; break; }
      }
      if(!ok) return false;
      double mid; bool fvg = FVGNearPrice(_Symbol, InpConfirmTF, InpSwingLookback, (entry2>0? entry2:entry1), InpFVGMaxDistPoints, true, mid);
      return fvg;
   }
}

// Compute entry zone and fib anchors
void ComputeFibZone(FibLeg &leg)
{
   if(leg.isShort)
   {
      double range = leg.A - leg.B;
      leg.entryMin = leg.B + range*gFibEntryMin;
      leg.entryMax = leg.B + range*gFibEntryMax;
      leg.fib0 = leg.B;
      leg.fib1 = (InpStopMode==STOP_AT_100 ? leg.A : (leg.B + range*0.90));
   }
   else
   {
      double range = leg.B - leg.A;
      leg.entryMin = leg.A + range*gFibEntryMin;
      leg.entryMax = leg.A + range*gFibEntryMax;
      leg.fib0 = leg.B;
      leg.fib1 = (InpStopMode==STOP_AT_100 ? leg.A : (leg.A + (leg.B-leg.A)*0.10));
   }
}

// Adaptive secondary fib from ATR percentile
double SecondaryFibDynamic(const FibLeg &leg)
{
   if(!InpAdaptiveSecondaryFib) return gSecondaryFib;
   double p = ATRPercentile(_Symbol, InpConfirmTF, InpATRPeriod, InpATRLookback);
   p = MathMax(0.0, MathMin(1.0, p));
   double sec = InpSecFibMin + (InpSecFibMax-InpSecFibMin)*p;
   // Clamp inside entry band as a safety
   if(sec<gFibEntryMin) sec=gFibEntryMin+0.01;
   if(sec>gFibEntryMax) sec=gFibEntryMax-0.01;
   return sec;
}

//=========================== ORDER MANAGEMENT ==========================//
bool OpenOTEOrders(const FibLeg &leg)
{
   if(!leg.valid) return false;

   // compute primary & (optional) secondary entry from leg
   double entry1=0.0, entry2=0.0;
   if(leg.isShort)
   {
      entry1 = leg.A - (leg.A - leg.B)*0.62;
      if(InpUseDualLimits)
      {
         double sec = SecondaryFibDynamic(leg);
         entry2 = leg.A - (leg.A - leg.B)*sec;
      }
   }
   else
   {
      entry1 = leg.A + (leg.B - leg.A)*0.62;
      if(InpUseDualLimits)
      {
         double sec = SecondaryFibDynamic(leg);
         entry2 = leg.A + (leg.B - leg.A)*sec;
      }
   }

   // Only place if within permitted zone
   if(!(entry1>=leg.entryMin-1e-10 && entry1<=leg.entryMax+1e-10)) entry1=0.0;
   if(InpUseDualLimits && !(entry2>=leg.entryMin-1e-10 && entry2<=leg.entryMax+1e-10)) entry2=0.0;

   if(InpUseStructureFilter)
   {
      if(!ConfirmStructureAndFVG(leg, entry1, entry2)) return false;
   }

   double sl = leg.fib1;
   double tp = leg.fib0;
   int placed=0;

   if(entry1>0.0)
   {
      double stopPts = PriceToPoints(MathAbs(sl - entry1));
      double lot = CalculateLotSize(stopPts);
      if(lot>0)
      {
         bool ok = (leg.isShort? Trade.SellLimit(lot, entry1, _Symbol, sl, tp) :
                                  Trade.BuyLimit (lot, entry1, _Symbol, sl, tp) );
         if(ok){ placed++; Notify("Placed limit #1"); LogCSV("LIMIT","limit1"); }
      }
   }
   if(entry2>0.0)
   {
      double stopPts = PriceToPoints(MathAbs(sl - entry2));
      double lot = CalculateLotSize(stopPts);
      if(lot>0)
      {
         bool ok = (leg.isShort? Trade.SellLimit(lot, entry2, _Symbol, sl, tp) :
                                  Trade.BuyLimit (lot, entry2, _Symbol, sl, tp) );
         if(ok){ placed++; Notify("Placed limit #2"); LogCSV("LIMIT","limit2"); }
      }
   }
   return (placed>0);
}

// Cancel expired pending orders and set cooldown if any were cancelled
void CleanupExpiredPendings()
{
   if(InpPendingExpiryMin<=0) return;
   datetime now = TimeCurrent();
   bool cancelled=false;

   int total=(int)OrdersTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=(long)InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t!=ORDER_TYPE_BUY_LIMIT && t!=ORDER_TYPE_SELL_LIMIT) continue;

      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(now - setup >= InpPendingExpiryMin*60)
      {
         Trade.OrderDelete(ticket);
         cancelled=true;
      }
   }
   if(cancelled)
   {
      g_cooldownUntil = now + InpCooldownMin*60;
      Notify("Pending expired -> cooldown started");
      LogCSV("COOLDOWN","Started");
   }
}

double CalculateLotSize(double stopPoints)
{
   if(stopPoints<=0) return 0.0;
   if(!InpUseRiskPercent) return InpFixedLot;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt = equity * (InpRiskPercent/100.0);

   // money per point per lot
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point    = _Point;
   if(tickSize<=0 || tickValue<=0 || point<=0) return 0.0;
   double moneyPerPointPerLot = tickValue * (point / tickSize);
   double moneyRiskPerLot = moneyPerPointPerLot * stopPoints;
   if(moneyRiskPerLot<=0) return 0.0;

   double lots = riskAmt / moneyRiskPerLot;

   // Clamp to step/min/max
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step>0) lots = MathFloor(lots/step)*step;
   if(minL>0) lots = MathMax(lots, minL);
   if(maxL>0) lots = MathMin(lots, maxL);
   return lots;
}

// Breakeven, partial TP and structural trailing
void ApplyBreakevenAndTrail(const FibLeg &leg)
{
   if(!leg.valid) return;

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string sym; PositionGetString(POSITION_SYMBOL, sym); if(sym!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double vol   = PositionGetDouble(POSITION_VOLUME);

      // Breakeven on fib crossing
      bool doBE=false; double priceBE=entry;
      if(type==POSITION_TYPE_SELL)
      {
         double trigger = leg.B + (leg.A - leg.B)*InpBEFibLevel;
         if(g_tick.bid <= trigger - 1e-10) { doBE=true; priceBE=entry; }
      }
      else if(type==POSITION_TYPE_BUY)
      {
         double trigger = leg.A + (leg.B - leg.A)*InpBEFibLevel;
         if(g_tick.ask >= trigger + 1e-10) { doBE=true; priceBE=entry; }
      }
      if(doBE)
      {
         if(type==POSITION_TYPE_BUY && sl < priceBE-1e-10) Trade.PositionModify(_Symbol, priceBE, tp);
         if(type==POSITION_TYPE_SELL && sl > priceBE+1e-10) Trade.PositionModify(_Symbol, priceBE, tp);
      }

      // Partial TP at fib0 (once per symbol)
      if(InpPartialTP1Pct>0 && !g_partialDone)
      {
         double tgt = leg.fib0;
         bool hit=false;
         if(type==POSITION_TYPE_BUY && g_tick.bid >= tgt-1e-10) hit=true;
         if(type==POSITION_TYPE_SELL && g_tick.ask <= tgt+1e-10) hit=true;
         if(hit)
         {
            double part = MathMax(0.01, vol*(InpPartialTP1Pct/100.0));
            part = MathMin(part, vol-0.01);
            if(part>0 && part<vol && Trade.PositionClosePartial(_Symbol, part))
            {
               g_partialDone=true;
               Notify("Partial TP executed");
               LogCSV("PARTIAL","TP1 done");
               // Set runner TP to ADR target
               double adr = ADR(_Symbol, 14);
               double newTP = tp;
               if(type==POSITION_TYPE_BUY)  newTP = entry + InpRunnerADRMult*adr;
               if(type==POSITION_TYPE_SELL) newTP = entry - InpRunnerADRMult*adr;
               Trade.PositionModify(_Symbol, PositionGetDouble(POSITION_SL), newTP);
            }
         }
      }

      // Structural trailing on RefineTF: use last swing
      if(type==POSITION_TYPE_BUY)
      {
         // trail to last swing low if higher than current SL
         double bestSL=sl;
         for(int k=2;k<=MathMin(10, InpSwingLookback);k++)
         {
            double swl = SwingLow(_Symbol, InpRefineTF, k);
            if(swl>0 && swl>bestSL && swl<g_tick.bid) bestSL=swl;
         }
         if(bestSL>sl) Trade.PositionModify(_Symbol, bestSL, PositionGetDouble(POSITION_TP));
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double bestSL=sl;
         for(int k=2;k<=MathMin(10, InpSwingLookback);k++)
         {
            double swh = SwingHigh(_Symbol, InpRefineTF, k);
            if(swh>0 && swh<bestSL && swh>g_tick.ask) bestSL=swh;
         }
         if(bestSL<sl) Trade.PositionModify(_Symbol, bestSL, PositionGetDouble(POSITION_TP));
      }
   }
}

//=============================== INIT =================================//
int OnInit()
{
   Trade.SetExpertMagicNumber((long)InpMagicNumber);
   Trade.SetDeviationInPoints((int)InpMaxSlippagePoints);

   if(!SymbolInfoTick(_Symbol, g_tick))
   {
      Print("Failed to get initial tick"); return(INIT_FAILED);
   }

   // Sanitize fibs
   gFibEntryMin = InpFibEntryMin; gFibEntryMax = InpFibEntryMax; gSecondaryFib=InpSecondaryFib;
   if(gFibEntryMin<0.30 || gFibEntryMin>0.79) gFibEntryMin=0.50;
   if(gFibEntryMax<=gFibEntryMin || gFibEntryMax>0.90) gFibEntryMax=0.79;
   if(gSecondaryFib<=gFibEntryMin || gSecondaryFib>=gFibEntryMax) gSecondaryFib=0.705;

   return(INIT_SUCCEEDED);
}

//=============================== DEINIT ================================//
void OnDeinit(const int reason)
{
}

//=============================== TICK =================================//
void OnTick()
{
   if(!SymbolInfoTick(_Symbol, g_tick)) return;

   if(!CheckSpreadOK()) return;
   if(!InSession()) return;
   if(IsNewsWindowActive()) return;
   if(g_cooldownUntil>0 && TimeCurrent()<g_cooldownUntil) return;

   bool sellOnly=false, buyOnly=false;
   if(!GetBias(sellOnly, buyOnly)) return;

   FibLeg leg;
   if(!FindBreakerAndDisplacement(leg)) return;
   if(sellOnly && !leg.isShort) return;
   if(buyOnly  &&  leg.isShort) return;

   ComputeFibZone(leg);

   // Place OTE limits
   if(OpenOTEOrders(leg))
   {
      g_leg = leg; // store most recent leg for management
      g_partialDone=false;
   }

   // Expiry / management
   CleanupExpiredPendings();
   ApplyBreakevenAndTrail(g_leg);
}

//============================= JOURNALING ==============================//
void LogCSV(const string action, const string note)
{
   if(!InpWriteCSVJournal) return;
   string name = StringFormat("NBB_OTE_%s.csv", _Symbol);
   int fh = FileOpen(name, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ';');
   if(fh==INVALID_HANDLE){ Print("CSV open failed"); return; }
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS), action, note, (string)AccountInfoInteger(ACCOUNT_LOGIN), (string)InpMagicNumber);
   FileClose(fh);
}