//+------------------------------------------------------------------+
//|                                                    FTMO Challenge|
//|                          Institutional Momentum Trap (Skeleton)  |
//|                                     © 2025 GH Wealth Makers Elite|
//+------------------------------------------------------------------+
#property copyright   "© 2025 GH Wealth Makers Elite"
#property version     "1.0"
#property strict

#include <Trade/Trade.mqh>

//============================== Inputs ==============================
input string InpSymbols              = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD";
input double InpRiskPercentBase      = 1.0;      // Base risk % per trade
input double InpRiskMinPercent       = 0.5;      // Min dynamic risk %
input double InpRiskMaxPercent       = 1.5;      // Max dynamic risk %
input bool   InpUseDynamicRisk       = true;
input int    InpMagic                = 602031;   // Magic number
input int    InpMaxDailyTrades       = 3;
input double InpMaxDailyDrawdownPct  = 5.0;      // Daily equity DD cap (%)
input double InpMaxTotalDrawdownPct  = 10.0;     // Overall equity DD cap (%)
input bool   InpTradeMonday          = true;
input bool   InpTradeFriday          = false;
input string InpSessionsGMT          = "08:00-12:00,13:00-17:00"; // London & NY (GMT)
input int    InpMaxSpreadPoints      = 35;       // Max allowed spread (points)
input bool   InpUseNewsFilter        = false;    // Requires MT5 Economic Calendar
input int    InpNewsBlackoutMin      = 30;       // Minutes before/after news
// Strategy parameters
input int    InpEMA_H4_Fast          = 50;
input int    InpEMA_H4_Slow          = 200;
input int    InpEMA_H1_Fast          = 20;
input int    InpEMA_H1_Slow          = 50;
input int    InpRSI_Period           = 14;
input int    InpRSI_Low              = 40;
input int    InpRSI_High             = 60;
input int    InpMACD_FastEMA         = 12;
input int    InpMACD_SlowEMA         = 26;
input int    InpMACD_Signal          = 9;
input int    InpVolAvgPeriod         = 20;
input int    InpATR_Period           = 14;
input double InpTP1_ATR_Mult         = 1.5;
input double InpTP2_ATR_Mult         = 2.5;
input double InpTrail_ATR_Mult       = 1.0;
// Stop-hunt / pattern
input int    InpSwingLookback        = 10;       // Bars for recent swing high/low
input int    InpPinBarBodyMaxPct     = 30;       // Body size <= % of range
input int    InpEngulfLookbackBars   = 1;        // Compare to previous bar
// Safety
input bool   InpEnableTimeExit       = true;
input int    InpMaxBarsInTrade       = 80;       // Close trade if exceeds
input bool   InpPrintDebug           = true;

//---------------------- Dashboard / HUD ----------------------
input bool   InpShowDashboard       = true;
input int    InpDashCorner          = 0;     // 0=LeftTop,1=RightTop,2=LeftBottom,3=RightBottom
input int    InpDashX               = 10;
input int    InpDashY               = 20;
input int    InpDashWidth           = 360;
input int    InpDashLineHeight      = 16;
input int    InpDashFontSize        = 10;
input color  InpDashBG              = clrBlack;
input color  InpDashText            = clrWhite;
input color  InpDashAccent          = clrLime;


//=========================== Global / Types =========================
CTrade Trade;

enum LOG_LEVEL { LOG_DEBUG, LOG_INFO, LOG_WARN, LOG_ERROR };
void Log(LOG_LEVEL lvl, string msg)
{
   if(!InpPrintDebug && lvl==LOG_DEBUG) return;
   string pfx = (lvl==LOG_DEBUG?"[DEBUG]":lvl==LOG_INFO?"[INFO]":lvl==LOG_WARN?"[WARN]":"[ERROR]");
   Print(pfx+" "+msg);
}

struct TradeStats {
   datetime dayStampGMT;      // Start-of-day (GMT)
   int      dailyTradeCount;
   double   dayStartEquity;
   int      consecWins;
   int      consecLosses;
   double   maxEquityPeak;
   double   minEquityTrough;
};

TradeStats Stats;


// Dashboard globals
string gHudPrefix;
double gStartingBalance=0.0;


struct Signal {
   int      direction; // 1=buy, -1=sell, 0=none
   double   sl_price;
   double   tp1_price;
   double   tp2_price;
   double   trail_atr_points;
   double   stop_atr_points;
   string   symbol;
   ulong    ticket_hint;
};

//============================= Helpers ==============================
string Trim(string s)
{
   int b=0, e=StringLen(s)-1;
   while(b<=e && StringGetCharacter(s,b)<=32) b++;
   while(e>=b && StringGetCharacter(s,e)<=32) e--;
   if(e<b) return "";
   return StringSubstr(s,b,e-b+1);
}

void Split(const string src, const string delim, string &arr[])
{
   StringSplit(src, StringGetCharacter(delim,0), arr);
   for(int i=0;i<ArraySize(arr);++i) arr[i]=Trim(arr[i]);
}

bool InAllowedSessionGMT(datetime t_gmt)
{
   string ranges[]; Split(InpSessionsGMT,",",ranges);
   MqlDateTime dt; TimeToStruct(t_gmt,dt);
   int now_minutes = dt.hour*60 + dt.min;
   for(int i=0;i<ArraySize(ranges);++i)
   {
      string seg = Trim(ranges[i]);
      if(seg=="") continue;
      string parts[]; Split(seg,"-",parts);
      if(ArraySize(parts)!=2) continue;
      int sh,sm,eh,em; sh=sm=eh=em=0;
      if(StringLen(parts[0])>=4 && StringLen(parts[1])>=4)
      {
         sh = (int)StringToInteger(StringSubstr(parts[0],0,2));
         sm = (int)StringToInteger(StringSubstr(parts[0],3,2));
         eh = (int)StringToInteger(StringSubstr(parts[1],0,2));
         em = (int)StringToInteger(StringSubstr(parts[1],3,2));
         int startM = sh*60+sm;
         int endM   = eh*60+em;
         if(now_minutes>=startM && now_minutes<=endM) return true;
      }
   }
   return false;
}

bool IsTradingDay()
{
   MqlDateTime g; TimeToStruct(TimeGMT(), g);
   int wday = g.day_of_week; // 0=Sun .. 6=Sat
   if(wday==0 || wday==6) return false;
   if(wday==1 && !InpTradeMonday) return false;
   if(wday==5 && !InpTradeFriday) return false;
   return true;
}

bool SpreadOK(const string sym)
{
   MqlTick tk;
   if(!SymbolInfoTick(sym, tk)) return false;
   double pnt=0.0; if(!SymbolInfoDouble(sym, SYMBOL_POINT, pnt)) return false;
long digits=0; SymbolInfoInteger(sym, SYMBOL_DIGITS, digits);
   double spread_points = (tk.ask - tk.bid)/pnt;
   return (spread_points <= InpMaxSpreadPoints);
}

double ATRPoints(const string sym, ENUM_TIMEFRAMES tf, int period)
{
   int h = iATR(sym, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,0,2,buf)<2) return 0.0;
   // convert ATR price units to points:
   double pnt; SymbolInfoDouble(sym, SYMBOL_POINT, pnt);
   return buf[0]/pnt;
}

bool GetEMA(const string sym, ENUM_TIMEFRAMES tf, int period, double &outEMA)
{
   int h = iMA(sym, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return false;
   double b[]; if(CopyBuffer(h,0,0,2,b)<2) return false;
   outEMA=b[0]; return true;
}

bool GetRSI(const string sym, ENUM_TIMEFRAMES tf, int period, double &outRSI)
{
   int h=iRSI(sym, tf, period, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return false;
   double b[]; if(CopyBuffer(h,0,0,2,b)<2) return false;
   outRSI=b[0]; return true;
}

bool GetMACDHist(const string sym, ENUM_TIMEFRAMES tf, int fastEma, int slowEma, int signal, double &outHist)
{
   int h=iMACD(sym, tf, fastEma, slowEma, signal, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return false;
   double main[], sig[];
   if(CopyBuffer(h,0,0,2,main)<2) return false;
   if(CopyBuffer(h,1,0,2,sig)<2)  return false;
   outHist = main[0]-sig[0];
   return true;
}

bool VolumeAboveAverage(const string sym, ENUM_TIMEFRAMES tf, int period)
{
   long vols[];
   if(CopyTickVolume(sym, tf, 0, period+1, vols) < period+1) return false;
   double sum=0; for(int i=1;i<=period;i++) sum += (double)vols[i];
   double avg=sum/period;
   return ((double)vols[0] > avg);
}

double PointValueInMoney(const string sym)
{
   double tick_val; SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE, tick_val);
   double tick_size; SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE, tick_size);
   double pnt; SymbolInfoDouble(sym, SYMBOL_POINT, pnt);
   if(tick_size==0.0) return 0.0;
   return tick_val*(pnt/tick_size);
}

// Candle helpers (on M15)
struct Candle { double open, high, low, close; };
bool GetCandle(const string sym, ENUM_TIMEFRAMES tf, int shift, Candle &c)
{
   double O[],H[],L[],C[];
   if(CopyOpen(sym,tf,shift,1,O)<1) return false;
   if(CopyHigh(sym,tf,shift,1,H)<1) return false;
   if(CopyLow(sym,tf,shift,1,L)<1) return false;
   if(CopyClose(sym,tf,shift,1,C)<1) return false;
   c.open=O[0]; c.high=H[0]; c.low=L[0]; c.close=C[0]; return true;
}

bool IsEngulfing(const string sym, ENUM_TIMEFRAMES tf, int lookback, int dir)
{
   // dir 1=bulllish engulf, -1=bearish engulf
   Candle cur, prev;
   if(!GetCandle(sym, tf, 0, cur)) return false;
   if(!GetCandle(sym, tf, lookback, prev)) return false;
   bool bullEngulf = (cur.close>cur.open) && (prev.close<prev.open) &&
                     (cur.close>=prev.open) && (cur.open<=prev.close);
   bool bearEngulf = (cur.close<cur.open) && (prev.close>prev.open) &&
                     (cur.close<=prev.open) && (cur.open>=prev.close);
   if(dir==1)  return bullEngulf;
   if(dir==-1) return bearEngulf;
   return (bullEngulf||bearEngulf);
}

bool IsPinBar(const string sym, ENUM_TIMEFRAMES tf, int maxBodyPct, int dir)
{
   Candle c; if(!GetCandle(sym, tf, 0, c)) return false;
   double range = c.high - c.low; if(range<=0) return false;
   double body  = MathAbs(c.close - c.open);
   if(body > (maxBodyPct/100.0)*range) return false;
   // dir 1=buy pin (long lower wick), -1=sell pin (long upper wick)
   double upperWick = c.high - MathMax(c.open,c.close);
   double lowerWick = MathMin(c.open,c.close) - c.low;
   if(dir==1)  return (lowerWick > upperWick*1.5);
   if(dir==-1) return (upperWick > lowerWick*1.5);
   return (upperWick>lowerWick*1.5 || lowerWick>upperWick*1.5);
}

bool StopHuntDetected(const string sym, ENUM_TIMEFRAMES tf, int lookback, int dir)
{
   // Simple model: previous bar makes stop run beyond recent swing and closes back in
   Candle cur, prev; if(!GetCandle(sym, tf, 0, cur) || !GetCandle(sym, tf, 1, prev)) return false;
   double highs[]; if(CopyHigh(sym, tf, 1, lookback, highs)<lookback) return false;
   double lows[];  if(CopyLow(sym, tf, 1, lookback, lows)<lookback) return false;
   double maxH=highs[0]; for(int i=1;i<lookback;i++) if(highs[i]>maxH) maxH=highs[i];
   double minL=lows[0];  for(int i=1;i<lookback;i++) if(lows[i]<minL) minL=lows[i];
   bool ranHigh = (prev.high>maxH) && (prev.close<prev.high);
   bool ranLow  = (prev.low<minL)  && (prev.close>prev.low);
   if(dir==1)  return ranLow;
   if(dir==-1) return ranHigh;
   return (ranHigh || ranLow);
}

// Multi-timeframe trend alignment
int TrendAlignment(const string sym)
{
   // return 1 for uptrend, -1 for downtrend, 0 none
   double emaH4Fast, emaH4Slow, emaH1Fast, emaH1Slow;
   if(!GetEMA(sym, PERIOD_H4, InpEMA_H4_Fast, emaH4Fast)) return 0;
   if(!GetEMA(sym, PERIOD_H4, InpEMA_H4_Slow, emaH4Slow)) return 0;
   if(!GetEMA(sym, PERIOD_H1, InpEMA_H1_Fast, emaH1Fast)) return 0;
   if(!GetEMA(sym, PERIOD_H1, InpEMA_H1_Slow, emaH1Slow)) return 0;
   MqlTick tk; if(!SymbolInfoTick(sym, tk)) return 0;
   bool up  = (emaH4Fast>emaH4Slow) && (emaH1Fast>emaH1Slow) && (tk.bid>emaH1Fast && tk.bid>emaH1Slow);
   bool dn  = (emaH4Fast<emaH4Slow) && (emaH1Fast<emaH1Slow) && (tk.bid<emaH1Fast && tk.bid<emaH1Slow);
   if(up) return 1;
   if(dn) return -1;
   return 0;
}

// Momentum confirmation on H1
int MomentumOK(const string sym, int dir)
{
   double rsi; if(!GetRSI(sym, PERIOD_H1, InpRSI_Period, rsi)) return 0;
   double macdH; if(!GetMACDHist(sym, PERIOD_H1, InpMACD_FastEMA, InpMACD_SlowEMA, InpMACD_Signal, macdH)) return 0;
   bool volOK = VolumeAboveAverage(sym, PERIOD_H1, InpVolAvgPeriod);
   bool rsiOK = (rsi>=InpRSI_Low && rsi<=InpRSI_High);
   bool macdOK= (dir==1 ? macdH>0 : macdH<0);
   return (rsiOK && macdOK && volOK) ? 1 : 0;
}

// Retrace to H1 20 EMA, pattern & stop-hunt trigger on M15
bool EntryTrigger(const string sym, int dir, double &sl_price, double &tp1, double &tp2, double &trailAtrPts, double &stopAtrPts)
{
   double emaH1Fast;
   if(!GetEMA(sym, PERIOD_H1, InpEMA_H1_Fast, emaH1Fast)) return false;
   Candle m15; if(!GetCandle(sym, PERIOD_M15, 0, m15)) return false;
   // Price retrace to H1 20 EMA (within 0.25*ATR on M15)
   double pnt; SymbolInfoDouble(sym, SYMBOL_POINT, pnt);
   double atrPts = ATRPoints(sym, PERIOD_M15, InpATR_Period);
   if(atrPts<=0) return false;
   double px = m15.close;
   if(MathAbs(px - emaH1Fast) > 0.25*atrPts*pnt) return false;
   // Patterns
   bool pattern = IsEngulfing(sym, PERIOD_M15, InpEngulfLookbackBars, dir) || IsPinBar(sym, PERIOD_M15, InpPinBarBodyMaxPct, dir);
   if(!pattern) return false;
   // Stop hunt
   if(!StopHuntDetected(sym, PERIOD_M15, InpSwingLookback, dir)) return false;
   // Build SL/TP using ATR
   trailAtrPts = InpTrail_ATR_Mult * atrPts;
   stopAtrPts  = 1.0 * atrPts;
   double tp1Pts = InpTP1_ATR_Mult * atrPts;
   double tp2Pts = InpTP2_ATR_Mult * atrPts;
   MqlTick tk; SymbolInfoTick(sym, tk);
   if(dir==1)
   {
      sl_price = tk.bid - stopAtrPts*pnt;
      tp1      = tk.bid + tp1Pts*pnt;
      tp2      = tk.bid + tp2Pts*pnt;
   }
   else
   {
      sl_price = tk.ask + stopAtrPts*pnt;
      tp1      = tk.ask - tp1Pts*pnt;
      tp2      = tk.ask - tp2Pts*pnt;
   }
   return true;
}

//=========================== Risk / Limits ==========================
double DynamicRiskPercent()
{
   if(!InpUseDynamicRisk) return InpRiskPercentBase;
   // Simple adaptive model: decrease after 2+ losses, increase after 2+ wins (bounded)
   double r = InpRiskPercentBase;
   if(Stats.consecLosses>=2) r = MathMax(InpRiskMinPercent, r - 0.25);
   if(Stats.consecWins  >=2) r = MathMin(InpRiskMaxPercent, r + 0.25);
   return r;
}

bool DrawdownGuardActive()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal= AccountInfoDouble(ACCOUNT_BALANCE);
   // Total DD
   double peak = (Stats.maxEquityPeak>0? Stats.maxEquityPeak : bal);
   if(eq>peak) Stats.maxEquityPeak=eq;
   double totalDDPct = (peak>0? (peak-eq)/peak*100.0 : 0.0);
   if(totalDDPct >= InpMaxTotalDrawdownPct) { Log(LOG_WARN,"Total DD cap reached"); return true; }
   // Daily DD
   if(TimeCurrent() - Stats.dayStampGMT > 24*60*60) { // safety rotate if broker time drift
      Stats.dayStampGMT = TimeGMT() - (TimeGMT()%86400); // midnight GMT
      Stats.dayStartEquity = eq;
      Stats.dailyTradeCount=0;
   }
   double dailyDDPct = (Stats.dayStartEquity>0? (Stats.dayStartEquity-eq)/Stats.dayStartEquity*100.0 : 0.0);
   if(dailyDDPct >= InpMaxDailyDrawdownPct) { Log(LOG_WARN,"Daily DD cap reached"); return true; }
   return false;
}

double CalcLotByRisk(const string sym, double riskPct, double sl_price, int direction)
{
   // riskPct% of equity
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = eq * (riskPct/100.0);
   double pnt; SymbolInfoDouble(sym, SYMBOL_POINT, pnt);
   MqlTick tk; SymbolInfoTick(sym, tk);
   double entry = (direction==1? tk.ask : tk.bid);
   double stopDist = MathAbs(entry - sl_price);
   if(stopDist<=0) return 0.0;
   double pv = PointValueInMoney(sym);
   if(pv<=0.0) return 0.0;
   double lots = riskMoney / (stopDist/pnt * pv);
   // Normalize to min lot step
   double minLot, lotStep, maxLot;
   SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN,  minLot);
   SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP, lotStep);
   SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX,  maxLot);
   lots = MathMax(minLot, MathMin(maxLot, MathFloor(lots/lotStep)*lotStep));
   return lots;
}

//========================== News (Optional) =========================
bool IsNewsBlackout(const string sym)
{
   // Portable stub: disable blocking unless broker calendar integration is added.
   if(!InpUseNewsFilter) return false;
   return false;
}

//=========================== Trade Control ==========================
bool HasOpenForSymbol(const string sym)
{
   if(!PositionSelect(sym)) return false;
   if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) return false;
   return true;
}

// UpdateStatsOnClose removed
void ManageOpenPositionsSymbol(const string sym)
{
   if(!PositionSelect(sym)) return;
   if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) return;

   double volume   = PositionGetDouble(POSITION_VOLUME);
   double price    = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl       = PositionGetDouble(POSITION_SL);
   double tp       = PositionGetDouble(POSITION_TP);
   long   type     = PositionGetInteger(POSITION_TYPE);
   datetime tOpen  = (datetime)PositionGetInteger(POSITION_TIME);
   int dir = (type==POSITION_TYPE_BUY? 1 : -1);

   // ATR-based trailing
   double atrPts = ATRPoints(sym, PERIOD_M15, InpATR_Period);
   double pnt; SymbolInfoDouble(sym, SYMBOL_POINT, pnt);
   MqlTick tk; SymbolInfoTick(sym, tk);
   double trailDist = InpTrail_ATR_Mult * atrPts * pnt;

   if(dir==1)
   {
      double newSL = tk.bid - trailDist;
      if(newSL>sl && tk.bid>price) Trade.PositionModify(sym, newSL, tp);
   }
   else
   {
      double newSL = tk.ask + trailDist;
      if((sl==0.0 || newSL<sl) && tk.ask<price) Trade.PositionModify(sym, newSL, tp);
   }

   // Partial exits at TP1/TP2
   double tp1Dist = InpTP1_ATR_Mult * atrPts * pnt;
   double tp2Dist = InpTP2_ATR_Mult * atrPts * pnt;
   double move    = (dir==1? (tk.bid - price) : (price - tk.ask));
   // Close 50% at TP1
   if(move>=tp1Dist && volume>0.01)
   {
      double closeVol = MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), volume*0.5);
      Trade.PositionClosePartial(sym, closeVol);
      // Move SL to BE
      if(dir==1) Trade.PositionModify(sym, price, 0.0);
      else       Trade.PositionModify(sym, price, 0.0);
   }
   // Close 30% at TP2
   if(move>=tp2Dist && volume>0.01)
   {
      double closeVol = MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), volume*0.3);
      Trade.PositionClosePartial(sym, closeVol);
   }

   // Time-based exit
   if(InpEnableTimeExit)
   {
      int barsOpen=Bars(sym, PERIOD_M15, tOpen, TimeCurrent());
      if(barsOpen>=InpMaxBarsInTrade) Trade.PositionClose(sym);
   }
}

//============================= Signals ==============================
bool BuildSignal(const string sym, Signal &sig)
{
   if(!SpreadOK(sym)) return false;
   if(IsNewsBlackout(sym)) { Log(LOG_INFO, sym+": News blackout"); return false; }
   if(HasOpenForSymbol(sym)) return false;

   // Trend alignment
   int dir = TrendAlignment(sym);
   if(dir==0) return false;

   // Momentum
   if(!MomentumOK(sym, dir)) return false;

   // Entry trigger
   double sl,tp1,tp2, trailPts, stopPts;
   if(!EntryTrigger(sym, dir, sl, tp1, tp2, trailPts, stopPts)) return false;

   sig.direction = dir;
   sig.sl_price  = sl;
   sig.tp1_price = tp1;
   sig.tp2_price = tp2;
   sig.trail_atr_points = trailPts;
   sig.stop_atr_points  = stopPts;
   sig.symbol   = sym;
   sig.ticket_hint = 0;
   return true;
}

bool ExecuteTrade(const Signal &sig)
{
   if(DrawdownGuardActive()) return false;
   if(Stats.dailyTradeCount>=InpMaxDailyTrades) { Log(LOG_INFO,"Max daily trades reached"); return false; }

   double riskPct = DynamicRiskPercent();
   int dir = sig.direction;
   double lots = CalcLotByRisk(sig.symbol, riskPct, sig.sl_price, dir);
   if(lots<=0.0) { Log(LOG_WARN, sig.symbol+": Lot calc returned 0"); return false; }

   MqlTick tk; SymbolInfoTick(sig.symbol, tk);
   double price  = (dir==1? tk.ask : tk.bid);
   double pnt; SymbolInfoDouble(sig.symbol, SYMBOL_POINT, pnt);

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(20);
   bool ok=false;
   if(dir==1) ok = Trade.Buy(lots, sig.symbol, price, sig.sl_price, 0.0);
   else       ok = Trade.Sell(lots, sig.symbol, price, sig.sl_price, 0.0);

   if(ok)
   {
      Stats.dailyTradeCount++;
      Log(LOG_INFO, StringFormat("%s: Opened %s %.2f lots @ %.5f SL=%.5f",
                                 sig.symbol, (dir==1?"BUY":"SELL"), lots, price, sig.sl_price));
      return true;
   }
   else
   {
      Log(LOG_ERROR, sig.symbol+": OrderSend failed. err="+IntegerToString(_LastError));
      return false;
   }
}

//============================= EA Core ==============================
int OnInit()
{
// Initialize day stamp at GMT midnight
   Stats.dayStampGMT    = TimeGMT() - (TimeGMT()%86400);
   Stats.dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   Stats.dailyTradeCount= 0;
   Stats.consecWins     = 0;
   Stats.consecLosses   = 0;
   Stats.maxEquityPeak  = AccountInfoDouble(ACCOUNT_EQUITY);
   Stats.minEquityTrough= AccountInfoDouble(ACCOUNT_EQUITY);
   Log(LOG_INFO,"FTMO Challenge EA initialized");
      gStartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(InpShowDashboard){ DashboardInit(); EventSetTimer(1); }
   return(INIT_SUCCEEDED);
}


void OnDeinit(const int reason)
{
Log(LOG_INFO,"EA deinitialized. Reason="+IntegerToString(reason));
   if(InpShowDashboard){ EventKillTimer(); DashboardDeinit(); }
}


void OnTick()
{
   // Trading day/time checks
   if(!IsTradingDay()) return;
   datetime nowGMT = TimeGMT();
   if(!InAllowedSessionGMT(nowGMT)) return;

   // New GMT day roll-over
   datetime dayStart = TimeGMT() - (TimeGMT()%86400);
   if(dayStart != Stats.dayStampGMT)
   {
      Stats.dayStampGMT    = dayStart;
      Stats.dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      Stats.dailyTradeCount= 0;
   }

   // Manage all open positions for our magic
   string msyms[]; Split(InpSymbols, ",", msyms);
   for(int k=0; k<ArraySize(msyms); ++k)
   {
      string osym = Trim(msyms[k]); if(osym=="") continue;
      if(!PositionSelect(osym)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      ManageOpenPositionsSymbol(osym);
   }

   // Scan symbols for new setups if we have capacity
   if(Stats.dailyTradeCount>=InpMaxDailyTrades) return;
   if(DrawdownGuardActive()) return;

   string syms[]; Split(InpSymbols,",", syms);
   for(int s=0; s<ArraySize(syms); ++s)
   {
      string sym = Trim(syms[s]);
      if(sym=="") continue;
      if(!SymbolSelect(sym,true)) continue;
      Signal sig; sig.direction=0;
      if(BuildSignal(sym, sig))
      {
         if(ExecuteTrade(sig))
            break; // one trade per tick cycle
      }
   }
}

// Optional: update stats on trade closure
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // No-op in this skeleton to ensure broad compiler compatibility.
   // (Can be re-enabled to update win/loss streaks using HistoryDealSelect if desired.)
}



//---------------------- Dashboard Helpers ----------------------
void HudDeleteAll()
{
   if(gHudPrefix=="") return;
   int total = ObjectsTotal(0, 0, -1);
   for(int i=total-1;i>=0;i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, gHudPrefix, 0)==0)
         ObjectDelete(0, name);
   }
}

void HudEnsureRect(const string name, int x, int y, int w, int h, color bg)
{
   string id = gHudPrefix + name;
   if(!ObjectFind(0, id))
      ObjectCreate(0, id, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, id, OBJPROP_CORNER, InpDashCorner);
   ObjectSetInteger(0, id, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, id, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, id, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, id, OBJPROP_YSIZE,     h);
   ObjectSetInteger(0, id, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, id, OBJPROP_COLOR,     bg);
   ObjectSetInteger(0, id, OBJPROP_BACK,      true);
   ObjectSetInteger(0, id, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, id, OBJPROP_SELECTED,  false);
}

void HudEnsureLabel(const string name, int x, int y, string text, color clr)
{
   string id = gHudPrefix + name;
   if(!ObjectFind(0, id))
      ObjectCreate(0, id, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, id, OBJPROP_CORNER, InpDashCorner);
   ObjectSetInteger(0, id, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, id, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, id, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, id, OBJPROP_FONTSIZE, InpDashFontSize);
   ObjectSetInteger(0, id, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, id, OBJPROP_SELECTED, false);
   ObjectSetString(0, id, OBJPROP_TEXT, text);
}

//---------------------- Dashboard Update ----------------------
void DashboardUpdate()
{
   if(!InpShowDashboard) return;
   gHudPrefix = "FTMOHUD_" + IntegerToString(InpMagic) + "_";
   int x = InpDashX, y=InpDashY, w=InpDashWidth;
   int pad=8, lh=InpDashLineHeight;
   int h = lh*12 + pad*2;
   HudEnsureRect("panel", x, y, w, h, InpDashBG);

   // Choose a primary symbol
   string primary = _Symbol;
   string listSyms[]; Split(InpSymbols, ",", listSyms);
   if(ArraySize(listSyms)>0)
   {
      string tmp = Trim(listSyms[0]);
      if(tmp!="") primary = tmp;
   }

   // Stats
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal= AccountInfoDouble(ACCOUNT_BALANCE);
   double fm = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double dayPLpct = (Stats.dayStartEquity>0.0 ? (eq-Stats.dayStartEquity)/Stats.dayStartEquity*100.0 : 0.0);
   double totalPLpct= (gStartingBalance>0.0 ? (eq-gStartingBalance)/gStartingBalance*100.0 : 0.0);
   double pnt=0.0; SymbolInfoDouble(primary, SYMBOL_POINT, pnt);
   MqlTick tk; SymbolInfoTick(primary, tk);
   double spreadPts = (pnt>0.0? (tk.ask - tk.bid)/pnt : 0.0);
   double atrPts = ATRPoints(primary, PERIOD_M15, InpATR_Period);
   int trend = TrendAlignment(primary);
   string trendTxt = (trend>0? "UP": (trend<0? "DOWN":"NONE"));
   string sessTxt = (InAllowedSessionGMT(TimeGMT())? "OPEN":"CLOSED");
   double risk = DynamicRiskPercent();
   string newsTxt = (InpUseNewsFilter? "ON (stub)":"OFF");

   int yy = y+pad;
   HudEnsureLabel("title", x+pad, yy, "FTMO DASHBOARD", InpDashAccent); yy+=lh;
   HudEnsureLabel("acc1",  x+pad, yy, StringFormat("Equity: %.2f   Balance: %.2f   FreeMargin: %.2f", eq, bal, fm), InpDashText); yy+=lh;
   HudEnsureLabel("acc2",  x+pad, yy, StringFormat("Day P/L: %.2f%%   Total P/L: %.2f%%   ML: %.1f%%", dayPLpct, totalPLpct, ml), InpDashText); yy+=lh;
   HudEnsureLabel("risk",  x+pad, yy, StringFormat("Risk: %.2f%%  Wins: %d  Losses: %d  TradesToday: %d/%d", risk, Stats.consecWins, Stats.consecLosses, Stats.dailyTradeCount, InpMaxDailyTrades), InpDashText); yy+=lh;
   HudEnsureLabel("sym1",  x+pad, yy, StringFormat("Symbol: %s  Spread: %.1f pts  Max: %.0f pts", primary, spreadPts, InpMaxSpreadPoints), InpDashText); yy+=lh;
   HudEnsureLabel("sym2",  x+pad, yy, StringFormat("ATR(M15): %.1f pts  Trend(H4+H1): %s", atrPts, trendTxt), InpDashText); yy+=lh;
   HudEnsureLabel("filters",x+pad, yy, StringFormat("Session: %s  News: %s", sessTxt, newsTxt), InpDashText); yy+=lh;
   HudEnsureLabel("params1",x+pad, yy, StringFormat("EMAs H4[%d/%d] H1[%d/%d]  RSI[%d in %d-%d]", InpEMA_H4_Fast, InpEMA_H4_Slow, InpEMA_H1_Fast, InpEMA_H1_Slow, InpRSI_Period, InpRSI_Low, InpRSI_High), InpDashText); yy+=lh;
   HudEnsureLabel("params2",x+pad, yy, StringFormat("ATR[%d]  TP1:%.1fx  TP2:%.1fx  Trail:%.1fx", InpATR_Period, InpTP1_ATR_Mult, InpTP2_ATR_Mult, InpTrail_ATR_Mult), InpDashText); yy+=lh;
   HudEnsureLabel("guard", x+pad, yy, StringFormat("DD caps: Daily %.1f%%  Total %.1f%%", InpMaxDailyDrawdownPct, InpMaxTotalDrawdownPct), InpDashText); yy+=lh;
   HudEnsureLabel("sess",  x+pad, yy, StringFormat("Sessions (GMT): %s", InpSessionsGMT), InpDashText); yy+=lh;
}

void DashboardInit()
{
   gHudPrefix = "FTMOHUD_" + IntegerToString(InpMagic) + "_";
   HudDeleteAll();
   DashboardUpdate();
}

void DashboardDeinit()
{
   HudDeleteAll();
}

//======================= FTMO Compliance Check ======================
bool ValidateFTMOCompliance()
{
   // This function provides placeholders for FTMO-specific checks.
   // In live usage, integrate with your monitoring dashboards/logs.
   // - Min trading days (>=4): can be tracked in Analytics module (not implemented here).
   // - No grid/marti/hedge: this EA places single entries only, no inversely correlated hedges.
   // - News blackout: optional InpUseNewsFilter.
   // - Weekend hold: governed by TradeFriday==false and session window.
   return true;
}

//============================= The End ==============================

void OnTimer()
{
   if(InpShowDashboard) DashboardUpdate();
}
