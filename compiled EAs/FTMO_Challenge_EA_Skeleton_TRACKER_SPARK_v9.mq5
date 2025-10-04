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
input int    InpDashFontSize        = 12;
input color  InpDashBG              = clrBlack;
input color  InpDashText            = clrWhite;
input color  InpDashAccent          = clrLime;
//====================== Sessions & News ======================
input bool   InpShowSessions        = true;
input string InpLondonOpen          = "08:00";
input string InpLondonClose         = "12:00";
input string InpNYOpen              = "13:00";
input string InpNYClose             = "17:00";

input bool   InpUseNewsFile         = false;          // read news from Files\ftmo_news.csv
input string InpNewsFileName        = "ftmo_news.csv";
input string InpNewsImpactFilter    = "High,Medium";  // comma-separated
input int    InpNewsWindowMin       = 30;             // blackout +/- minutes
input int    InpNewsReloadMin       = 60;             // reload cadence (minutes)

//====================== Alerts & Journaling ==================
input bool   InpAlertPopup          = true;
input bool   InpAlertEmail          = false;
input bool   InpAlertPush           = false;
input string InpAlertPrefix         = "[FTMO]";
input bool   InpJournalEnable       = true;
input string InpJournalFile         = "ftmo_journal.csv";

// Target / Sparkline
input double InpPhaseTargetPct      = 10.0;   // Profit target % (10 = Phase 1, 5 = Phase 2)
input int    InpSparkPoints         = 120;    // samples kept for sparkline (seconds)
input int    InpSparkWidth          = 180;    // reserved width (layout)
input int    InpSparkHeight         = 16;     // reserved height (layout)



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
// Sessions & News globals
datetime gLastNewsLoad=0;

struct NewsItem {
   datetime t;
   string   ccy;
   string   impact;
   string   title;
   bool     alerted;
};
NewsItem gNews[];

double gEquityBuf[];   // rolling equity samples for sparkline
int    gDaysTraded=0;  // increments on days that had >=1 trade



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
            if(Stats.dailyTradeCount>0) gDaysTraded++;
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
   int total = ObjectsTotal(0, -1, -1);
   for(int i=total-1;i>=0;i--)
   {
      string name = ObjectName(0, i, -1);
      if(StringFind(name, gHudPrefix, 0)==0)
         ObjectDelete(0, name);
   }
}

void HudEnsureRect(const string name, int x, int y, int w, int h, color bg)
{
   string id = gHudPrefix + name;
   if(ObjectFind(0, id) == -1)
      ObjectCreate(0, id, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, id, OBJPROP_CORNER, InpDashCorner);
   ObjectSetInteger(0, id, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, id, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, id, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, id, OBJPROP_YSIZE,     h);
   ObjectSetInteger(0, id, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, id, OBJPROP_COLOR,     InpDashAccent);
ObjectSetInteger(0, id, OBJPROP_BACK,      false);
   ObjectSetInteger(0, id, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, id, OBJPROP_SELECTED,  false);
}

void HudEnsureLabel(const string name, int x, int y, string text, color clr)
{
   string id = gHudPrefix + name;
   if(ObjectFind(0, id) == -1)
      ObjectCreate(0, id, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, id, OBJPROP_CORNER, InpDashCorner);
   ObjectSetInteger(0, id, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, id, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, id, OBJPROP_COLOR, clr);
ObjectSetInteger(0, id, OBJPROP_FONTSIZE, InpDashFontSize);
ObjectSetInteger(0, id, OBJPROP_BACK, false);
ObjectSetString(0, id, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, id, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, id, OBJPROP_SELECTED, false);
   ObjectSetString(0, id, OBJPROP_TEXT, text);
}



//---------------------- Sparkline Helpers ----------------------
void SparkPush(double v)
{
   int n = ArraySize(gEquityBuf);
   if(n>=InpSparkPoints)
   {
      for(int i=1;i<n;i++) gEquityBuf[i-1]=gEquityBuf[i];
      gEquityBuf[n-1]=v;
   }
   else
   {
      ArrayResize(gEquityBuf, n+1);
      gEquityBuf[n]=v;
   }
}

string SparkString()
{
   int n = ArraySize(gEquityBuf);
   if(n<=1) return "";
   double mn=gEquityBuf[0], mx=gEquityBuf[0];
   for(int i=1;i<n;i++){ if(gEquityBuf[i]<mn) mn=gEquityBuf[i]; if(gEquityBuf[i]>mx) mx=gEquityBuf[i]; }
   double rg = mx-mn; if(rg<=0.0) rg=1.0;
   string levels[8] = {"▁","▂","▃","▄","▅","▆","▇","█"};
   string s="";
   for(int i=0;i<n;i++){
      int idx = (int)MathFloor( (gEquityBuf[i]-mn)/rg * 7.0 + 0.0001 );
      if(idx<0) idx=0; if(idx>7) idx=7;
      s += levels[idx];
   }
   return s;
}
//---------------------- Dashboard Update ----------------------

void DashboardUpdate()
{
   if(!InpShowDashboard) return;
   gHudPrefix = "FTMOHUD_" + IntegerToString(InpMagic) + "_";
   int x = InpDashX, y=InpDashY, w=InpDashWidth;
   int pad=8, lh=InpDashLineHeight;
   int h = lh*16 + pad*2;
   HudEnsureRect("panel", x, y, w, h, InpDashBG);

   // Primary symbol = first from list if present else current chart
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

   // FTMO rule tracker metrics
   double dailyAllowed = Stats.dayStartEquity * InpMaxDailyDrawdownPct/100.0;
   double dailyUsed    = MathMax(0.0, Stats.dayStartEquity - eq);
   double dailyRemain  = MathMax(0.0, dailyAllowed - dailyUsed);
   
   if(dailyRemain<=0.0){ NotifyAll("RISK","Daily drawdown limit reached"); Journal("RISK","Daily DD limit reached"); }
double totalAllowed = gStartingBalance * InpMaxTotalDrawdownPct/100.0;
   double totalUsed    = MathMax(0.0, gStartingBalance - eq);
   double totalRemain  = MathMax(0.0, totalAllowed - totalUsed);
   
   if(totalRemain<=0.0){ NotifyAll("RISK","Total drawdown limit reached"); Journal("RISK","Total DD limit reached"); }
double targetAmt    = gStartingBalance * InpPhaseTargetPct/100.0;
   double achieved     = MathMax(0.0, eq - gStartingBalance);
   double targetRemain = MathMax(0.0, targetAmt - achieved);

   // Sample equity for sparkline
   SparkPush(eq);

   int yy = y+pad;
   HudEnsureLabel("title", x+pad, yy, "FTMO DASHBOARD", InpDashAccent); yy+=lh;
   HudEnsureLabel("acc1",  x+pad, yy, StringFormat("Equity: %.2f   Balance: %.2f   FreeMargin: %.2f", eq, bal, fm), InpDashText); yy+=lh;
   HudEnsureLabel("acc2",  x+pad, yy, StringFormat("Day P/L: %.2f%%   Total P/L: %.2f%%   ML: %.1f%%", dayPLpct, totalPLpct, ml), InpDashText); yy+=lh;
   HudEnsureLabel("spark", x+pad, yy, StringFormat("Eq: %s", SparkString()), InpDashAccent); yy+=lh;
   HudEnsureLabel("ftmo1", x+pad, yy, StringFormat("DayLossLeft: %.2f   TotalLossLeft: %.2f", dailyRemain, totalRemain), InpDashText); yy+=lh;
   HudEnsureLabel("ftmo2", x+pad, yy, StringFormat("TargetLeft: %.2f (%.1f%% of start)  DaysTraded: %d", targetRemain, InpPhaseTargetPct, gDaysTraded), InpDashText); yy+=lh;
   HudEnsureLabel("risk",  x+pad, yy, StringFormat("Risk: %.2f%%  Wins: %d  Losses: %d  TradesToday: %d/%d", risk, Stats.consecWins, Stats.consecLosses, Stats.dailyTradeCount, InpMaxDailyTrades), InpDashText); yy+=lh;
   HudEnsureLabel("sym1",  x+pad, yy, StringFormat("Symbol: %s  Spread: %.1f pts  Max: %.0f pts", primary, spreadPts, InpMaxSpreadPoints), InpDashText); yy+=lh;
   HudEnsureLabel("sym2",  x+pad, yy, StringFormat("ATR(M15): %.1f pts  Trend(H4+H1): %s", atrPts, trendTxt), InpDashText); yy+=lh;
   HudEnsureLabel("filters",x+pad, yy, StringFormat("Session: %s  News: %s", sessTxt, newsTxt), InpDashText); yy+=lh;
   
   // Sessions (GMT) and News
   string lndState, lndCD, nyState, nyCD;
   if(InpShowSessions){
      SessionState(InpLondonOpen, InpLondonClose, lndState, lndCD);
      SessionState(InpNYOpen,     InpNYClose,     nyState,  nyCD);
      HudEnsureLabel("sess_lnd", x+pad, yy, StringFormat("London: %s (%s)", lndState, lndCD), InpDashText); yy+=lh;
      HudEnsureLabel("sess_ny",  x+pad, yy, StringFormat("NewYork: %s (%s)", nyState, nyCD), InpDashText); yy+=lh;
   }
   string base, quote;
   if(SymbolCurrencies(primary, base, quote))
   {
      datetime nt; string nccy, nimp, nttl; int nmin;
      if(InpUseNewsFile && NextNewsFor(base, quote, nt, nccy, nimp, nttl, nmin)){
         HudEnsureLabel("news_next", x+pad, yy, StringFormat("News: %s %s in %dm - %s", nccy, nimp, nmin, nttl), InpDashAccent); yy+=lh;
      } else {
         HudEnsureLabel("news_next", x+pad, yy, "News: (none)", InpDashText); yy+=lh;
      }
   }
HudEnsureLabel("params1",x+pad, yy, StringFormat("EMAs H4[%d/%d] H1[%d/%d]  RSI[%d in %d-%d]", InpEMA_H4_Fast, InpEMA_H4_Slow, InpEMA_H1_Fast, InpEMA_H1_Slow, InpRSI_Period, InpRSI_Low, InpRSI_High), InpDashText); yy+=lh;
   HudEnsureLabel("params2",x+pad, yy, StringFormat("ATR[%d]  TP1:%.1fx  TP2:%.1fx  Trail:%.1fx", InpATR_Period, InpTP1_ATR_Mult, InpTP2_ATR_Mult, InpTrail_ATR_Mult), InpDashText); yy+=lh;
   HudEnsureLabel("guard", x+pad, yy, StringFormat("DD caps: Daily %.1f%%  Total %.1f%%", InpMaxDailyDrawdownPct, InpMaxTotalDrawdownPct), InpDashText); yy+=lh;
   HudEnsureLabel("sess",  x+pad, yy, StringFormat("Sessions (GMT): %s", InpSessionsGMT), InpDashText); yy+=lh;

   ChartRedraw();
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
   LoadNewsFileIfDue();
   string base, quote;
   if(SymbolCurrencies(_Symbol, base, quote)) CheckNewsAlerts(base, quote);
}


//====================== Sessions & News Helpers ======================
int ParseHM(const string hm)
{
   string parts[]; int n=StringSplit(hm, ':', parts);
   if(n<2) return -1;
   int h=(int)StringToInteger(parts[0]);
   int m=(int)StringToInteger(parts[1]);
   if(h<0||h>23||m<0||m>59) return -1;
   return h*60+m;
}

int MinutesSinceGMTMidnight()
{
   datetime g=TimeGMT();
   MqlDateTime dt; TimeToStruct(g, dt);
   return dt.hour*60 + dt.min;
}

string CountdownStr(int minutes_left)
{
   if(minutes_left<0) minutes_left=0;
   int h=minutes_left/60; int m=minutes_left%60;
   return StringFormat("%dh %02dm", h, m);
}

void SessionState(const string openHM, const string closeHM, string &state, string &countdown)
{
   int o=ParseHM(openHM), c=ParseHM(closeHM);
   int now=MinutesSinceGMTMidnight();
   state="CLOSED"; countdown="";
   if(o<0||c<0){ countdown="--"; return; }
   if(now>=o && now<c){ state="OPEN"; countdown=CountdownStr(c-now); }
   else {
      int next = (now<o? o : (o+24*60)); // next open today or tomorrow
      int left = (next - now);
      countdown = CountdownStr(left);
   }
}


string UpperAscii(const string src)
{
   string out = src;
   int len = StringLen(out);
   for(int i=0;i<len;i++)
   {
      int ch = (int)StringGetCharacter(out, i);
      if(ch>=97 && ch<=122) // 'a'..'z'
         StringSetCharacter(out, i, (ushort)(ch-32));
   }
   return out;
}
bool ImpactAllowed(const string impact)
{
   string toks[]; int n=StringSplit(InpNewsImpactFilter, ',', toks);
   if(n<=0) return true;
   string up = UpperAscii(impact);
   for(int i=0;i<n;i++)
   {
      string t=Trim(toks[i]);
      if(UpperAscii(t)==up) return true;
   }
   return false;
}

bool SymbolCurrencies(const string sym, string &base, string &quote)
{
   base=""; quote="";
   string b="", q="";
   if(SymbolInfoString(sym, SYMBOL_CURRENCY_BASE, b) && SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT, q))
   { base=b; quote=q; return true; }
   // fallback: try 6-letter core
   int len=StringLen(sym);
   if(len>=6){
      base=StringSubstr(sym,0,3);
      quote=StringSubstr(sym,3,3);
      return true;
   }
   return false;
}

void Journal(const string evt, const string details)
{
   if(!InpJournalEnable) return;
   int h = FileOpen(InpJournalFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      h = FileOpen(InpJournalFile, FILE_WRITE|FILE_CSV|FILE_ANSI);
      if(h==INVALID_HANDLE) return;
      FileWrite(h, "timestamp", "symbol", "event", "details", "equity", "balance");
   }
   FileSeek(h, 0, SEEK_END);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), _Symbol, evt, details, DoubleToString(eq,2), DoubleToString(bal,2));
   FileClose(h);
}

void NotifyAll(const string tag, const string msg)
{
   string m = InpAlertPrefix + " " + tag + " " + msg;
   if(InpAlertPopup) Alert(m);
   if(InpAlertEmail) SendMail(InpAlertPrefix+" "+tag, msg);
   if(InpAlertPush)  SendNotification(m);
}

void LoadNewsFileIfDue()
{
   if(!InpUseNewsFile) return;
   datetime now = TimeCurrent();
   if(gLastNewsLoad!=0 && (now - gLastNewsLoad) < InpNewsReloadMin*60) return;
   gLastNewsLoad = now;
   ArrayResize(gNews, 0);
   int h = FileOpen(InpNewsFileName, FILE_READ|FILE_CSV|FILE_ANSI);
   if(h==INVALID_HANDLE) return;
   while(!FileIsEnding(h))
   {
      string ts = FileReadString(h);
      if(StringLen(ts)==0){ FileReadString(h); FileReadString(h); FileReadString(h); continue; }
      string ccy = FileReadString(h);
      string imp = FileReadString(h);
      string ttl = FileReadString(h);
      // parse datetime "YYYY.MM.DD HH:MM"
      datetime t=0;
      if(StringLen(ts)>=16)
      {
         int Y=(int)StringToInteger(StringSubstr(ts,0,4));
         int M=(int)StringToInteger(StringSubstr(ts,5,2));
         int D=(int)StringToInteger(StringSubstr(ts,8,2));
         int hH=(int)StringToInteger(StringSubstr(ts,11,2));
         int mM=(int)StringToInteger(StringSubstr(ts,14,2));
         MqlDateTime dt; dt.year=Y; dt.mon=M; dt.day=D; dt.hour=hH; dt.min=mM; dt.sec=0;
         t = StructToTime(dt);
      }
      if(t>0)
      {
         int n = ArraySize(gNews);
         ArrayResize(gNews, n+1);
         gNews[n].t = t;
         gNews[n].ccy = ccy;
         gNews[n].impact = imp;
         gNews[n].title = ttl;
         gNews[n].alerted = false;
      }
   }
   FileClose(h);
}

bool NextNewsFor(const string base, const string quote, datetime &t, string &ccy, string &impact, string &title, int &minsTo)
{
   t=0; ccy=""; impact=""; title=""; minsTo=0;
   if(ArraySize(gNews)==0) return false;
   datetime now = TimeCurrent();
   datetime bestT=0; int bestIdx=-1;
   for(int i=0;i<ArraySize(gNews);i++)
   {
      string c = UpperAscii(gNews[i].ccy);
      if(!(c==UpperAscii(base) || c==UpperAscii(quote))) continue;
      if(!ImpactAllowed(gNews[i].impact)) continue;
      if(gNews[i].t < now) continue;
      if(bestIdx==-1 || gNews[i].t < bestT){ bestIdx=i; bestT=gNews[i].t; }
   }
   if(bestIdx==-1) return false;
   t = gNews[bestIdx].t; ccy=gNews[bestIdx].ccy; impact=gNews[bestIdx].impact; title=gNews[bestIdx].title;
   minsTo = (int)MathFloor((t - now)/60);
   if(minsTo<0) minsTo=0;
   return true;
}

void CheckNewsAlerts(const string base, const string quote)
{
   if(!InpUseNewsFile) return;
   datetime now=TimeCurrent();
   for(int i=0;i<ArraySize(gNews);i++)
   {
      if(gNews[i].alerted) continue;
      string c = UpperAscii(gNews[i].ccy);
      if(!(c==UpperAscii(base) || c==UpperAscii(quote))) continue;
      if(!ImpactAllowed(gNews[i].impact)) continue;
      int diff = (int)MathAbs((int)(gNews[i].t - now))/60;
      if(diff <= InpNewsWindowMin)
      {
         string msg = StringFormat("%s %s in %d min: %s", gNews[i].ccy, gNews[i].impact, (int)((gNews[i].t-now)/60), gNews[i].title);
         NotifyAll("NEWS", msg);
         Journal("NEWS_ALERT", msg);
         gNews[i].alerted = true;
      }
   }
}
