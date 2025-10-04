//+------------------------------------------------------------------+
//|                                                NBB_MMM_OTE_EA.mq5 |
//|                                   Author: GH Wealth Makers Elite   |
//|                                         (c) 2025, GH Wealth Makers |
//+------------------------------------------------------------------+
#property copyright   "2025 GH Wealth Makers"
#property link        "https://ghwealthmakerselite.xyz/"
#property version     "1.0.2"
#property strict

#include <Trade/Trade.mqh>

//=============================== INPUTS ===============================//
input ulong   InpMagicNumber           = 86531011;   // Magic Number
input bool    InpUseRiskPercent       = true;       // Use risk % (true) or fixed lot (false)
input double  InpFixedLot             = 0.10;       // Fixed lot size when UseRiskPercent=false
input double  InpRiskPercent          = 1.0;        // Risk % of equity per trade (0.1..2.0 typical)

// Strategy/Bias
enum BiasMode { BIAS_AUTO=0, BIAS_LONG=1, BIAS_SHORT=2 };
input BiasMode InpBiasMode            = BIAS_AUTO;  // Trading bias mode
input int     InpBiasFastEMA          = 20;         // Bias fast EMA (D1)
input int     InpBiasSlowEMA          = 50;         // Bias slow EMA (D1)

// Confirmation & Entry
input ENUM_TIMEFRAMES InpConfirmTF    = PERIOD_M15; // Confirmation timeframe (15m or 30m)
input ENUM_TIMEFRAMES InpRefineTF     = PERIOD_M5;  // Refinement timeframe
input int     InpSwingLookback        = 12;         // Bars to scan swings for breaker (ConfirmTF)
input double  InpMinDispATR           = 1.0;        // Min displacement body multiple of ATR(14)
input double  InpFibEntryMin          = 0.50;       // Min Fib entry (0.50)
input double  InpFibEntryMax          = 0.79;       // Max Fib entry (0.79)
input bool    InpUseDualLimits        = true;       // Place two limit orders at 62% & 70.5%
input double  InpSecondaryFib         = 0.705;      // Secondary Fib when dual limits enabled

// Stop / TP / Management
enum StopMode { STOP_AT_100=0, STOP_AT_90=1 };
input StopMode InpStopMode            = STOP_AT_100;// Stop reference (1.00 or 0.90 fib)
input bool    InpUseATRStopPad        = false;      // Add ATR padding to SL
input double  InpATRPadMult           = 0.0;        // ATR padding multiplier if enabled
input int     InpATRPeriod            = 14;         // ATR period for displacement/SL pad
input double  InpBEFibLevel           = 0.20;       // Breakeven trigger at 20% fib
input bool    InpTrailAfterTPBreak    = true;       // Trail stop if price breaks TP with momentum
input double  InpTrailATRMult         = 1.0;        // ATR multiple for trailing after TP breach
input int     InpTrailATRPeriod       = 14;         // ATR period for trailing
input int     InpMaxScaleIns          = 1;          // Max additional entries after BE

// PD Arrays / Proximity
input bool    InpUsePrevDayLevels     = true;       // Use previous day high/low
input bool    InpUsePrevWeekLevels    = true;       // Use previous week high/low
input double  InpLevelProximityPoints = 100.0;      // Price must be within X points of PD level
input bool    InpRequirePDProximity   = true;       // Require proximity, else skip

// Trading Sessions (server time HH:MM)
input bool    InpUseSessions          = true;       // Restrict to sessions
input string  InpSess1Start           = "02:00";    // Session 1 start
input string  InpSess1End             = "05:00";    // Session 1 end
input string  InpSess2Start           = "07:00";    // Session 2 start
input string  InpSess2End             = "10:00";    // Session 2 end
input string  InpSess3Start           = "10:00";    // Session 3 start
input string  InpSess3End             = "12:00";    // Session 3 end

// Risk Controls & Filters
input double  InpMaxSpreadPoints      = 200.0;      // Max spread (points) allowed
input int     InpMaxSlippagePoints    = 20;         // Max slippage (points)
input double  InpDailyLossLimitPct    = 3.0;        // Daily loss limit (% of equity)
input int     InpMaxOpenPositions     = 2;          // Max open positions (incl. scale-ins)
input bool    InpDisableFridaysLate   = true;       // Avoid last hours on Friday
input string  InpFridayCutoff         = "20:00";    // Friday cutoff HH:MM server time

// News manual blocks (optional: semicolon-separated "HH:MM-HH:MM")
input string  InpManualNewsBlocks     = "";         // e.g. "12:25-13:15;14:55-15:10"

// Journal
input bool    InpWriteCSVJournal      = true;       // Write CSV trade log to MQL5/Files
input string  InpJournalFilePrefix    = "NBB_MMM_OTE"; // CSV filename prefix

// Notifications
input bool    InpEnablePush           = false;      // Push notifications on key events

//=========================== GLOBALS / STATE ===========================//
CTrade     Trade;
MqlTick    g_tick;

struct FibLeg
{
   bool     valid;
   bool     isShort;
   double   A;
   double   B;
   datetime tA;
   datetime tB;
   double   entryMin;
   double   entryMax;
   double   fib0;
   double   fib1;
};

FibLeg     g_leg;
int        g_lastBarCF = -1;
int        g_scaleIns   = 0;
double     g_startEquity = 0.0;
datetime   g_dayStamp = 0;
double     g_dayStartEquity = 0.0;
double     g_dayEquityMin = 0.0;

// Performance Tracking
int        g_tradesTotal = 0;
int        g_tradesWins  = 0;
int        g_tradesLoss  = 0;
double     g_grossProfit = 0.0;
double     g_grossLoss   = 0.0;

// Runtime-adjustable copies of inputs
double     g_FibEntryMin = 0.50;
double     g_FibEntryMax = 0.79;
double     g_SecondaryFib= 0.705;

//=========================== UTILITY PROTOTYPES ========================//
string    Trim(const string s);
bool      IsNewBar(const string sym, ENUM_TIMEFRAMES tf, int &last_index_ref);
bool      InTradingSession();
bool      IsFridayLate();
bool      InManualNewsBlock();
bool      CheckSpreadOK();
double    PointsToPrice(double pts);
double    PriceToPoints(double price_diff);
bool      GetPrevDayHL(double &pdHigh, double &pdLow);
bool      GetPrevWeekHL(double &pwHigh, double &pwLow);
bool      NearPDArray();
int       TFtoSeconds(ENUM_TIMEFRAMES tf);
bool      ParseHHMM(const string s, int &hh, int &mm);
datetime  TodayAt(int hh, int mm);
double    iATRv(const string sym, ENUM_TIMEFRAMES tf, int period, int shift);
double    BodySize(const string sym, ENUM_TIMEFRAMES tf, int shift);
double    CandleHigh(const string sym, ENUM_TIMEFRAMES tf, int shift);
double    CandleLow(const string sym, ENUM_TIMEFRAMES tf, int shift);
double    CandleOpen(const string sym, ENUM_TIMEFRAMES tf, int shift);
double    CandleClose(const string sym, ENUM_TIMEFRAMES tf, int shift);
bool      GetBias(bool &sellOnly, bool &buyOnly);
bool      FindBreakerAndDisplacement(FibLeg &leg);
void      BuildFibLegPrices(FibLeg &leg);
bool      OpenOTEOrders(const FibLeg &leg);
double    CalculateLotSize(double stopPoints);
bool      CheckRiskLimits();
double    CurrentDayLossPct();
void      UpdateDayEquity();
void      UpdatePerformanceFromHistory();
void      ManageOpenPositions();
void      ApplyBreakevenAndTrail(const FibLeg &leg);
void      LogCSV(const string action, const string note);
string    LastErrText();
void      Notify(const string msg);

//============================== HELPERS ================================//
string Trim(const string s)
{
   string t = s;
   StringTrimLeft(t);
   StringTrimRight(t);
   return t;
}

void Notify(const string msg)
{
   if(InpEnablePush) SendNotification("[NBB_MMM_OTE] " + msg);
}

//=============================== INIT =================================//
int OnInit()
{
   Trade.SetExpertMagicNumber((int)InpMagicNumber);
   if(!SymbolInfoTick(_Symbol, g_tick))
   {
      Print("Failed to get initial tick");
      return(INIT_FAILED);
   }

   // Initialize FibLeg structure
   g_leg.valid = false;
   g_leg.isShort = false;
   g_leg.A = 0;
   g_leg.B = 0;
   g_leg.tA = 0;
   g_leg.tB = 0;
   g_leg.entryMin = 0;
   g_leg.entryMax = 0;
   g_leg.fib0 = 0;
   g_leg.fib1 = 0;

   // Record starting equity & day stats
   g_startEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStamp = (datetime) (TimeCurrent()/86400)*86400;
   g_dayStartEquity = g_startEquity;
   g_dayEquityMin   = g_startEquity;

   // Copy/validate fib inputs into mutable globals (don't assign to input vars)
   g_FibEntryMin = InpFibEntryMin;
   g_FibEntryMax = InpFibEntryMax;
   g_SecondaryFib= InpSecondaryFib;
   if(g_FibEntryMin < 0.30 || g_FibEntryMin > 0.79) { Print("FibEntryMin adjusted to 0.50"); g_FibEntryMin = 0.50; }
   if(g_FibEntryMax <= g_FibEntryMin || g_FibEntryMax > 0.90) { Print("FibEntryMax adjusted to 0.79"); g_FibEntryMax = 0.79; }
   if(g_SecondaryFib <= g_FibEntryMin || g_SecondaryFib >= g_FibEntryMax) g_SecondaryFib = 0.705;

   UpdatePerformanceFromHistory();
   LogCSV("INIT","EA started");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   UpdatePerformanceFromHistory();
   double pf = (g_grossLoss<0 ? (g_grossProfit/MathAbs(g_grossLoss)) : 0.0);
   PrintFormat("Stats: total=%d wins=%d loss=%d PF=%.2f", g_tradesTotal, g_tradesWins, g_tradesLoss, pf);
   LogCSV("DEINIT","EA stopped. reason="+(string)reason);
}

//=============================== TICK =================================//
void OnTick()
{
   if(!SymbolInfoTick(_Symbol, g_tick)) return;

   UpdateDayEquity();
   if(CurrentDayLossPct() >= InpDailyLossLimitPct) return;
   if(InpDisableFridaysLate && IsFridayLate()) return;
   if(InpUseSessions && !InTradingSession()) return;
   if(StringLen(InpManualNewsBlocks) > 0 && InManualNewsBlock()) return;
   if(!CheckSpreadOK()) return;

   if(!IsNewBar(_Symbol, InpConfirmTF, g_lastBarCF)) 
   {
      ManageOpenPositions();
      return;
   }

   if(InpRequirePDProximity && !NearPDArray()) return;

   bool sellOnly=false, buyOnly=false;
   if(!GetBias(sellOnly,buyOnly)) return;

   FibLeg newLeg;
   newLeg.valid=false; newLeg.isShort=false; newLeg.A=0; newLeg.B=0;
   newLeg.tA=0; newLeg.tB=0; newLeg.entryMin=0; newLeg.entryMax=0; newLeg.fib0=0; newLeg.fib1=0;

   if(!FindBreakerAndDisplacement(newLeg)) return;

   if( (newLeg.isShort && buyOnly) || (!newLeg.isShort && sellOnly) ) return;

   BuildFibLegPrices(newLeg);
   g_leg = newLeg;
   g_scaleIns = 0;

   if(CheckRiskLimits()) OpenOTEOrders(g_leg);

   ManageOpenPositions();
}

//=========================== CORE FUNCTIONS ===========================//
bool IsNewBar(const string sym, ENUM_TIMEFRAMES tf, int &last_index_ref)
{
   int curr = iBarShift(sym, tf, TimeCurrent(), true);
   if(curr<0) return false;
   if(curr != last_index_ref)
   {
      last_index_ref = curr;
      return true;
   }
   return false;
}

bool CheckSpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread <= 0) return true;
   return ((double)spread <= InpMaxSpreadPoints);
}

double PointsToPrice(double pts){ return pts * _Point; }
double PriceToPoints(double price_diff){ return price_diff / _Point; }

bool GetPrevDayHL(double &pdHigh, double &pdLow)
{
   int shift = iBarShift(_Symbol, PERIOD_D1, TimeCurrent() - 86400, false);
   if(shift < 0) return false;
   pdHigh = iHigh(_Symbol, PERIOD_D1, shift);
   pdLow  = iLow(_Symbol, PERIOD_D1, shift);
   return (pdHigh>0 && pdLow>0);
}

bool GetPrevWeekHL(double &pwHigh, double &pwLow)
{
   double hi = iHigh(_Symbol, PERIOD_W1, 1);
   double lo = iLow(_Symbol, PERIOD_W1, 1);
   if(hi==0 || lo==0) return false;
   pwHigh = hi; pwLow = lo;
   return true;
}

bool NearPDArray()
{
   double pdH=0, pdL=0, pwH=0, pwL=0;
   bool near=false;
   if(InpUsePrevDayLevels && GetPrevDayHL(pdH, pdL))
   {
      if(PriceToPoints(MathAbs(g_tick.bid - pdH)) <= InpLevelProximityPoints) near=true;
      if(PriceToPoints(MathAbs(g_tick.bid - pdL)) <= InpLevelProximityPoints) near=true;
   }
   if(InpUsePrevWeekLevels && GetPrevWeekHL(pwH, pwL))
   {
      if(PriceToPoints(MathAbs(g_tick.bid - pwH)) <= InpLevelProximityPoints) near=true;
      if(PriceToPoints(MathAbs(g_tick.bid - pwL)) <= InpLevelProximityPoints) near=true;
   }
   return near;
}

int TFtoSeconds(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1: return 60;
      case PERIOD_M5: return 300;
      case PERIOD_M15: return 900;
      case PERIOD_M30: return 1800;
      case PERIOD_H1: return 3600;
      case PERIOD_H4: return 14400;
      case PERIOD_D1: return 86400;
      default: return 60;
   }
}

bool ParseHHMM(const string s, int &hh, int &mm)
{
   string parts[];
   int n = StringSplit(s, ':', parts);
   if(n != 2) return false;
   hh = (int)StringToInteger(parts[0]);
   mm = (int)StringToInteger(parts[1]);
   if(hh<0 || hh>23 || mm<0 || mm>59) return false;
   return true;
}

datetime TodayAt(int hh, int mm)
{
   datetime now = TimeCurrent();
   MqlDateTime mt; TimeToStruct(now, mt);
   mt.hour = hh; mt.min = mm; mt.sec = 0;
   return StructToTime(mt);
}

bool InTradingSession()
{
   int h1=0,m1=0,h2=0,m2=0,h3=0,m3=0,h4=0,m4=0,h5=0,m5=0,h6=0,m6=0;
   bool ok1 = ParseHHMM(InpSess1Start, h1,m1) && ParseHHMM(InpSess1End, h2,m2);
   bool ok2 = ParseHHMM(InpSess2Start, h3,m3) && ParseHHMM(InpSess2End, h4,m4);
   bool ok3 = ParseHHMM(InpSess3Start, h5,m5) && ParseHHMM(InpSess3End, h6,m6);
   datetime t = TimeCurrent();
   bool in1=false,in2=false,in3=false;
   if(ok1) { datetime a=TodayAt(h1,m1), b=TodayAt(h2,m2); if(t>=a && t<=b) in1=true; }
   if(ok2) { datetime a=TodayAt(h3,m3), b=TodayAt(h4,m4); if(t>=a && t<=b) in2=true; }
   if(ok3) { datetime a=TodayAt(h5,m5), b=TodayAt(h6,m6); if(t>=a && t<=b) in3=true; }
   return (in1||in2||in3);
}

bool IsFridayLate()
{
   MqlDateTime mt; TimeToStruct(TimeCurrent(), mt);
   if(mt.day_of_week!=5) return false;
   int hh=0,mm=0; if(!ParseHHMM(InpFridayCutoff, hh,mm)) return false;
   datetime cutoff = TodayAt(hh,mm);
   return (TimeCurrent() >= cutoff);
}

bool InManualNewsBlock()
{
   if(StringLen(InpManualNewsBlocks)==0) return false;
   string blocks[]; int n=StringSplit(InpManualNewsBlocks, ';', blocks);
   if(n<=0) return false;
   datetime now = TimeCurrent();
   for(int i=0;i<n;i++)
   {
      string s = Trim(blocks[i]);
      if(StringLen(s)==0) continue;
      string p[]; if(StringSplit(s,'-',p)!=2) continue;
      int h1=0,m1=0,h2=0,m2=0; if(!ParseHHMM(p[0],h1,m1) || !ParseHHMM(p[1],h2,m2)) continue;
      datetime a=TodayAt(h1,m1), b=TodayAt(h2,m2);
      if(now>=a && now<=b) return true;
   }
   return false;
}

double iATRv(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   return iATR(sym, tf, period, shift);
}

double BodySize(const string sym, ENUM_TIMEFRAMES tf, int shift)
{
   double o = iOpen(sym, tf, shift);
   double c = iClose(sym, tf, shift);
   return MathAbs(c - o);
}

double CandleHigh(const string sym, ENUM_TIMEFRAMES tf, int shift){ return iHigh(sym, tf, shift); }
double CandleLow (const string sym, ENUM_TIMEFRAMES tf, int shift){ return iLow(sym,  tf, shift); }
double CandleOpen(const string sym, ENUM_TIMEFRAMES tf, int shift){ return iOpen(sym, tf, shift); }
double CandleClose(const string sym, ENUM_TIMEFRAMES tf, int shift){ return iClose(sym,tf, shift); }

bool GetBias(bool &sellOnly, bool &buyOnly)
{
   sellOnly=false; buyOnly=false;
   if(InpBiasMode==BIAS_LONG){ buyOnly=true; return true; }
   if(InpBiasMode==BIAS_SHORT){ sellOnly=true; return true; }
   // AUTO: EMA20<EMA50 -> sell; EMA20>EMA50 -> buy
   double emaF = iMA(_Symbol, PERIOD_D1, InpBiasFastEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
   double emaS = iMA(_Symbol, PERIOD_D1, InpBiasSlowEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
   if(emaF==0 || emaS==0) return false;
   if(emaF < emaS) sellOnly=true; else if(emaF > emaS) buyOnly=true;
   return true;
}

// Breaker + displacement detection simplified heuristic
bool FindBreakerAndDisplacement(FibLeg &leg)
{
   leg.valid=false; leg.isShort=false;
   leg.A=0; leg.B=0; leg.tA=0; leg.tB=0; leg.entryMin=0; leg.entryMax=0; leg.fib0=0; leg.fib1=0;
   int LB = MathMax(6, InpSwingLookback);
   int last = 1; // last closed bar on confirm TF

   // Shorts: H0, L1, HH2, LL3 + displacement close below LL3
   for(int i=last+3; i<=last+LB; i++)
   {
      double H0 = CandleHigh(_Symbol, InpConfirmTF, i);
      double L1 = CandleLow (_Symbol, InpConfirmTF, i-1);
      double H2 = CandleHigh(_Symbol, InpConfirmTF, i-2);
      double L3 = CandleLow (_Symbol, InpConfirmTF, i-3);
      if(!(H2>H0 && L3<L1)) continue;

      double body = BodySize(_Symbol, InpConfirmTF, last);
      double atr  = iATRv(_Symbol, InpConfirmTF, InpATRPeriod, last);
      double close= CandleClose(_Symbol, InpConfirmTF, last);
      if(atr<=0) continue;
      if(body < atr*InpMinDispATR) continue;
      if(close >= L3) continue;

      leg.isShort = true;
      leg.A = H2;
      leg.B = CandleLow(_Symbol, InpConfirmTF, last);
      leg.tA = iTime(_Symbol, InpConfirmTF, i-2);
      leg.tB = iTime(_Symbol, InpConfirmTF, last);
      leg.valid = (leg.A>0 && leg.B>0 && leg.A>leg.B);
      if(leg.valid) return true;
   }

   // Longs: L0, H1, LL2, HH3 + displacement close above HH3
   for(int i=last+3; i<=last+LB; i++)
   {
      double L0 = CandleLow (_Symbol, InpConfirmTF, i);
      double H1 = CandleHigh(_Symbol, InpConfirmTF, i-1);
      double L2 = CandleLow (_Symbol, InpConfirmTF, i-2);
      double H3 = CandleHigh(_Symbol, InpConfirmTF, i-3);
      if(!(L2<L0 && H3>H1)) continue;

      double body = BodySize(_Symbol, InpConfirmTF, last);
      double atr  = iATRv(_Symbol, InpConfirmTF, InpATRPeriod, last);
      double close= CandleClose(_Symbol, InpConfirmTF, last);
      if(atr<=0) continue;
      if(body < atr*InpMinDispATR) continue;
      if(close <= H3) continue;

      leg.isShort = false;
      leg.A = L2;
      leg.B = CandleHigh(_Symbol, InpConfirmTF, last);
      leg.tA = iTime(_Symbol, InpConfirmTF, i-2);
      leg.tB = iTime(_Symbol, InpConfirmTF, last);
      leg.valid = (leg.A>0 && leg.B>0 && leg.B>leg.A);
      if(leg.valid) return true;
   }
   return false;
}

void BuildFibLegPrices(FibLeg &leg)
{
   if(!leg.valid) return;
   if(leg.isShort)
   {
      double range = leg.A - leg.B;
      double pMin = leg.B + range*g_FibEntryMin;
      double pMax = leg.B + range*g_FibEntryMax;
      leg.entryMin = pMin;
      leg.entryMax = pMax;
      leg.fib0 = leg.B;
      leg.fib1 = (InpStopMode==STOP_AT_100 ? leg.A : (leg.B + range*0.90));
   }
   else
   {
      double range = leg.B - leg.A;
      double pMin = leg.A + range*g_FibEntryMin;
      double pMax = leg.A + range*g_FibEntryMax;
      leg.entryMin = pMin;
      leg.entryMax = pMax;
      leg.fib0 = leg.B;
      leg.fib1 = (InpStopMode==STOP_AT_100 ? leg.A : (leg.A + range*0.10));
   }
}

bool OpenOTEOrders(const FibLeg &leg)
{
   if(!leg.valid) return false;

   double entry1=0.0, entry2=0.0;
   if(leg.isShort)
   {
      entry1 = leg.A - (leg.A - leg.B)*0.62;
      if(InpUseDualLimits) entry2 = leg.A - (leg.A - leg.B)*g_SecondaryFib;
   }
   else
   {
      entry1 = leg.A + (leg.B - leg.A)*0.62;
      if(InpUseDualLimits) entry2 = leg.A + (leg.B - leg.A)*g_SecondaryFib;
   }

   if(!(entry1>=leg.entryMin-1e-10 && entry1<=leg.entryMax+1e-10)) entry1=0.0;
   if(InpUseDualLimits && !(entry2>=leg.entryMin-1e-10 && entry2<=leg.entryMax+1e-10)) entry2=0.0;

   int placed=0;
   if(entry1>0.0)
   {
      double sl = leg.fib1;
      double tp = leg.fib0;
      if(InpUseATRStopPad)
      {
         double atr = iATRv(_Symbol, InpRefineTF, InpATRPeriod, 0);
         if(atr>0)
         {
            if(leg.isShort) sl += atr*InpATRPadMult;
            else            sl -= atr*InpATRPadMult;
         }
      }
      double stopPts = PriceToPoints(MathAbs(sl - entry2));
      double lot = CalculateLotSize(stopPts);
      if(lot>0)
      {
         bool ok=false;
         Trade.SetDeviationInPoints(InpMaxSlippagePoints);
         if(leg.isShort) ok = Trade.SellLimit(lot, entry2, _Symbol, sl, tp);
         else            ok = Trade.BuyLimit (lot, entry2, _Symbol, sl, tp);
         if(ok){ placed++; Notify("Placed pending order"); LogCSV("PLACE", StringFormat("limit2 %.5f SL=%.5f TP=%.5f lot=%.2f", entry2,sl,tp,lot)); }
         else  { LogCSV("ERR",   "place limit2: "+LastErrText()); }
      }
   }
   return (placed>0);
}

double CalculateLotSize(double stopPoints)
{
   if(stopPoints<=0) return 0.0;
   if(!InpUseRiskPercent) return InpFixedLot;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt = equity * (InpRiskPercent/100.0);

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point    = _Point;
   if(tickSize<=0 || tickValue<=0 || point<=0) return 0.0;

   double moneyPerPointPerLot = tickValue * (point / tickSize);
   double moneyRiskPerLot = moneyPerPointPerLot * stopPoints;
   if(moneyRiskPerLot<=0) return 0.0;

   double lots = riskAmt / moneyRiskPerLot;

   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(volStep<=0) volStep=0.01;
   lots = MathFloor(lots/volStep)*volStep;
   if(lots < volMin) lots = volMin;
   if(lots > volMax) lots = volMax;
   return lots;
}

bool CheckRiskLimits()
{
   int total=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      total++;
   }
   if(total >= InpMaxOpenPositions) return false;
   return true;
}

void ManageOpenPositions()
{
   ApplyBreakevenAndTrail(g_leg);

   if(g_scaleIns < InpMaxScaleIns && g_leg.valid)
   {
      double entry_price=0, sl=0; 
      bool have=false; 
      bool safe=false; 
      ENUM_POSITION_TYPE pt=POSITION_TYPE_BUY;
      
      for(int i=0;i<PositionsTotal();i++)
      {
         if(!PositionSelectByIndex(i)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;
         pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
         sl          = PositionGetDouble(POSITION_SL);
         have=true;
         if(pt==POSITION_TYPE_BUY)  { if(sl>=entry_price-1e-10) safe=true; }
         if(pt==POSITION_TYPE_SELL) { if(sl<=entry_price+1e-10) safe=true; }
         break;
      }
      if(have && safe)
      {
         double mid = (g_leg.entryMin + g_leg.entryMax)/2.0;
         double stop = g_leg.fib1;
         double tp   = g_leg.fib0;
         double stopPts = PriceToPoints(MathAbs(stop - mid));
         double lot = CalculateLotSize(stopPts);
         bool ok=false;
         Trade.SetDeviationInPoints(InpMaxSlippagePoints);
         if(g_leg.isShort) ok = Trade.SellLimit(lot, mid, _Symbol, stop, tp);
         else              ok = Trade.BuyLimit (lot, mid, _Symbol, stop, tp);
         if(ok){ g_scaleIns++; Notify("Scale-in placed"); LogCSV("SCALE_IN", StringFormat("mid %.5f lot %.2f", mid, lot)); }
      }
   }
}

void ApplyBreakevenAndTrail(const FibLeg &leg)
{
   if(!leg.valid) return;

   for(int i=0;i<PositionsTotal();i++)
   {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      bool doBE=false;
      double bePrice=entry;
      if(type==POSITION_TYPE_SELL)
      {
         double trigger = leg.B + (leg.A - leg.B)*InpBEFibLevel;
         if(g_tick.bid <= trigger - 1e-10) doBE=true;
      }
      else if(type==POSITION_TYPE_BUY)
      {
         double trigger = leg.A + (leg.B - leg.A)*(1.0 - InpBEFibLevel);
         if(g_tick.ask >= trigger + 1e-10) doBE=true;
      }
      if(doBE)
      {
         double newSL = bePrice;
         if(type==POSITION_TYPE_BUY && sl < newSL-1e-10)
         { 
            if(Trade.PositionModify(ticket, newSL, tp))
            {
               Notify("Moved SL to BE"); 
               LogCSV("BE","Moved SL to BE");
            }
         }
         if(type==POSITION_TYPE_SELL && sl > newSL+1e-10)
         { 
            if(Trade.PositionModify(ticket, newSL, tp))
            {
               Notify("Moved SL to BE"); 
               LogCSV("BE","Moved SL to BE");
            }
         }
      }

      if(InpTrailAfterTPBreak)
      {
         double atr = iATRv(_Symbol, InpRefineTF, InpTrailATRPeriod, 0);
         if(atr<=0) atr = iATRv(_Symbol, InpConfirmTF, InpTrailATRPeriod, 0);
         if(atr<=0) continue;

         if(type==POSITION_TYPE_SELL)
         {
            if(g_tick.bid < tp - 1e-10)
            {
               double newSL = tp;
               if(sl > newSL+1e-10)
               {
                  if(Trade.PositionModify(ticket, newSL, 0.0))
                  {
                     Notify("Short TP breached; trailing");
                     LogCSV("TRAIL","Short: TP breached; set SL=old TP");
                  }
               }
            }
         }
         else if(type==POSITION_TYPE_BUY)
         {
            if(g_tick.ask > tp + 1e-10)
            {
               double newSL = tp;
               if(sl < newSL-1e-10)
               {
                  if(Trade.PositionModify(ticket, newSL, 0.0))
                  {
                     Notify("Long TP breached; trailing");
                     LogCSV("TRAIL","Long: TP breached; set SL=old TP");
                  }
               }
            }
         }
      }
   }
}

void UpdateDayEquity()
{
   datetime now = TimeCurrent();
   datetime d = (datetime) (now/86400)*86400;
   if(d != g_dayStamp)
   {
      g_dayStamp = d;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dayEquityMin   = g_dayStartEquity;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq < g_dayEquityMin) g_dayEquityMin = eq;
}

double CurrentDayLossPct()
{
   if(g_dayStartEquity<=0) return 0.0;
   double loss = (g_dayStartEquity - g_dayEquityMin);
   if(loss<=0) return 0.0;
   return (loss / g_dayStartEquity) * 100.0;
}

void UpdatePerformanceFromHistory()
{
   g_tradesTotal=g_tradesWins=g_tradesLoss=0;
   g_grossProfit=g_grossLoss=0.0;

   HistorySelect(0, TimeCurrent());
   int deals = HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong dTicket = HistoryDealGetTicket(i);
      if(dTicket == 0) continue;
      if(HistoryDealGetString(dTicket, DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(dTicket, DEAL_MAGIC)!=(long)InpMagicNumber) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dTicket, DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(dTicket, DEAL_PROFIT) + 
                      HistoryDealGetDouble(dTicket, DEAL_SWAP) + 
                      HistoryDealGetDouble(dTicket, DEAL_COMMISSION);
      g_tradesTotal++;
      if(profit>=0) { g_tradesWins++; g_grossProfit+=profit; } 
      else { g_tradesLoss++; g_grossLoss+=profit; }
   }
}

void LogCSV(const string action, const string note)
{
   if(!InpWriteCSVJournal) return;
   string fname = InpJournalFilePrefix + "_" + _Symbol + ".csv";
   int fh = FileOpen(fname, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ';');
   if(fh==INVALID_HANDLE)
   {
      Print("CSV open failed: ", GetLastError());
      return;
   }
   FileSeek(fh, 0, SEEK_END);
   string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   FileWrite(fh, timeStr, action, note, (string)AccountInfoInteger(ACCOUNT_LOGIN), (string)InpMagicNumber);
   FileClose(fh);
}

string LastErrText()
{
   int err=GetLastError();
   ResetLastError();
   return StringFormat("#%d", err);
}
//+------------------------------------------------------------------+, InpRefineTF, InpATRPeriod, 0);
         if(atr>0)
         {
            if(leg.isShort) sl += atr*InpATRPadMult;
            else            sl -= atr*InpATRPadMult;
         }
      }
      double stopPts = PriceToPoints(MathAbs(sl - entry1));
      double lot = CalculateLotSize(stopPts);
      if(lot>0)
      {
         bool ok=false;
         Trade.SetDeviationInPoints(InpMaxSlippagePoints);
         if(leg.isShort) ok = Trade.SellLimit(lot, entry1, _Symbol, sl, tp);
         else            ok = Trade.BuyLimit (lot, entry1, _Symbol, sl, tp);
         if(ok){ placed++; Notify("Placed pending order"); LogCSV("PLACE", StringFormat("limit1 %.5f SL=%.5f TP=%.5f lot=%.2f", entry1,sl,tp,lot)); }
         else  { LogCSV("ERR",   "place limit1: "+LastErrText()); }
      }
   }
   if(entry2>0.0)
   {
      double sl = leg.fib1;
      double tp = leg.fib0;
      if(InpUseATRStopPad)
      {
         double atr = iATRv(_Symbol