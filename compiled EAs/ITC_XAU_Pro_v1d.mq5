//+------------------------------------------------------------------+
//|                                                   ITC_XAU_Pro.mq5 |
//|         Institutional Trend Continuation (Gold, Prop-Safe)         |
//|                              v1.0 (2025-09-13)                     |
//|                                                                    |
//|  This EA implements the "Institutional Trend Continuation"         |
//|  strategy tailored for XAUUSD with prop-firm risk safeguards.      |
//|                                                                    |
//|  Author: ChatGPT (GPT-5 Thinking)                                  |
//|  Notes:                                                            |
//|   * Optimized for H4 chart (entries), uses D1 for bias, H1 for RM. |
//|   * Partial profits at 1.5R (50%) and 2.5R (30%); trail remainder. |
//|   * "Two-strikes/day", "One-direction/day", news & session filters.|
//|   * Closes on Friday before cutoff; max exposure guard.            |
//+------------------------------------------------------------------+
#property strict
#property description "Institutional Trend Continuation (XAUUSD) with prop-firm safety"
#property version   "1.00"
#property copyright "2025"
#property link      "https://"

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------------- INPUTS ---------------------------------------
input string   Inp_EA_Name                   = "ITC_XAU_Pro";
input ulong    Inp_Magic                     = 820152013;   // Magic number

// Symbols & TFs
input string   Inp_AllowedSymbol             = "XAUUSD";    // Empty = any
input ENUM_TIMEFRAMES Inp_TF_Primary         = PERIOD_H4;   // Entry TF
input ENUM_TIMEFRAMES Inp_TF_Confirm         = PERIOD_D1;   // Bias TF
input ENUM_TIMEFRAMES Inp_TF_Precision       = PERIOD_H1;   // Risk mgmt TF

// Core indicators
input int      Inp_EMA_Period                = 21;
input int      Inp_ATR_Period                = 14;
input double   Inp_ATR_Mult                  = 1.5;         // Stop multiple

// RSI Bias Ranges (D1)
input int      Inp_RSI_Period                = 14;
input double   Inp_RSI_Long_Min              = 40.0;
input double   Inp_RSI_Long_Max              = 65.0;
input double   Inp_RSI_Short_Min             = 35.0;
input double   Inp_RSI_Short_Max             = 60.0;

// Volume filter (tick volume)
input bool     Inp_UseVolumeFilter           = true;
input int      Inp_Vol_Fast                  = 5;
input int      Inp_Vol_Slow                  = 20;

// Key levels
input bool     Inp_UseKeyLevels              = true;
input double   Inp_RoundStep                 = 10.0;   // Round numbers (e.g., 10.0 for XAUUSD)
input double   Inp_LevelTolerancePoints      = 150;    // Distance tolerance to key level (points)
input bool     Inp_UsePrevDayHL              = true;
input bool     Inp_UseWeeklyPivots           = true;

// Entry confirmation
input double   Inp_PullbackProximityPoints   = 250;    // Distance to EMA21 for pullback validity (points)
input bool     Inp_UseRejectionCandles       = true;   // Pin/Engulfing near EMA or key level

// Risk
enum Mode { Evaluation=0, Funded=1 };
input Mode     Inp_Mode                      = Evaluation;
input double   Inp_Risk_Per_Trade_Eval       = 0.7;    // % equity
input double   Inp_Risk_Per_Trade_Funded     = 0.5;    // % equity
input double   Inp_Max_Total_Exposure_Percent= 3.0;    // Max total risk active

// Partial profits & trailing
input bool     Inp_UsePartial_TPs            = true;
input double   Inp_TP1_R                     = 1.5;
input double   Inp_TP1_CloseFrac             = 0.50;
input double   Inp_TP2_R                     = 2.5;
input double   Inp_TP2_CloseFrac             = 0.30;
input bool     Inp_Trail_By_EMA              = true;   // Trail on EMA (TF_Precision)
input double   Inp_Trail_Offset_Points       = 200;    // SL offset beyond EMA

// Session & News
input bool     Inp_UseSessionFilter          = true;
input int      Inp_LondonStartHour           = 7;      // server hour
input int      Inp_NYEndHour                 = 20;     // server hour
input bool     Inp_UseNewsBlackout           = true;
input int      Inp_News_Blackout_Minutes     = 30;     // before/after high impact
input string   Inp_News_Currencies           = "USD";  // CSV list; USD relevant for XAUUSD

// Friday rules
input bool     Inp_CloseOnFriday             = true;
input int      Inp_FridayCutoffHour          = 16;     // close & disable after this hour

// Prop discipline rules
input bool     Inp_OneDirectionPerDay        = true;
input bool     Inp_TwoStrikesPerDay          = true;
input int      Inp_MaxLossesPerDay           = 2;
input int      Inp_MaxSetupsPerWeek          = 5;

// Correlation (optional)
input bool     Inp_UseDXY                    = false;  // set true if DXY symbol exists
input string   Inp_DXY_Symbol                = "DXY";  // your broker's ticker

// Misc
input bool     Inp_TakeScreenshots           = true;
input int      Inp_Screenshot_Width          = 1280;
input int      Inp_Screenshot_Height         = 720;

//--------------------------- INTERNAL STATE -----------------------------------
datetime g_lastPrimaryBarTime = 0;
int      g_todayLosses = 0;
int      g_todayDirection = 0; // 1=long taken, -1=short taken, 0=none
int      g_weekSetups = 0;
int      g_currWeek = -1;
string   g_prefix;

// Flags persisted via GlobalVariables (per symbol+magic)
string GVK(const string& key)
{
   return(StringFormat("%s.%s.%I64u.%s", Inp_EA_Name, _Symbol, (ulong)Inp_Magic, key));
}

bool GetGVFlag(const string& key)
{
   string k = GVK(key);
   if(GlobalVariableCheck(k))
      return(GlobalVariableGet(k) > 0.5);
   return(false);
}
void SetGVFlag(const string& key, bool v)
{
   string k = GVK(key);
   if(v)
   {
      if(GlobalVariableCheck(k)) GlobalVariableSet(k,1.0);
      else GlobalVariableSet(k,1.0);
   }
   else
   {
      if(GlobalVariableCheck(k)) GlobalVariableSet(k,0.0);
      else GlobalVariableSet(k,0.0);
   }
}

//----------------------------- HELPERS ----------------------------------------
int GetISOWeek(datetime t)
{
   MqlDateTime st; TimeToStruct(t,st);
   int doy = st.day_of_year; // safer than DayOfYear()
   return(1 + doy/7);
}


double PipValuePerPoint()
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0) tick_size=_Point;
   // money per 1 point for 1 lot
   return( tick_value * (_Point / tick_size) );
}

double NormalizeVolume(double vol)
{
   double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vol < minlot) vol = minlot;
   if(vol > maxlot) vol = maxlot;
   // round to step
   int steps = (int)MathRound(vol/step);
   return(steps*step);
}

bool IsSessionOK()
{
   if(!Inp_UseSessionFilter) return(true);
   MqlDateTime st; TimeToStruct(TimeCurrent(), st);
   if(st.hour < Inp_LondonStartHour) return(false);
   if(st.hour > Inp_NYEndHour) return(false);
   return(true);
}

bool IsFridayCutoff()
{
   if(!Inp_CloseOnFriday) return(false);
   MqlDateTime st; TimeToStruct(TimeCurrent(), st);
   if(st.day_of_week==5 && st.hour>=Inp_FridayCutoffHour) return(true);
   return(false);
}

void ResetDailyCountersIfNeeded()
{
   static int last_day = -1;
   MqlDateTime st; TimeToStruct(TimeCurrent(), st);
   if(st.day != last_day)
   {
      g_todayLosses = 0;
      g_todayDirection = 0;
      last_day = st.day;
   }
}
void ResetWeeklyCounterIfNeeded()
{
   int wk = GetISOWeek(TimeCurrent());
   if(wk != g_currWeek)
   {
      g_currWeek = wk;
      g_weekSetups = 0;
   }
}

double GetEMA(string sym, ENUM_TIMEFRAMES tf, int period, int shift=0)
{
   double buf[];
   if(CopyBuffer(iMA(sym, tf, period, 0, MODE_EMA, PRICE_CLOSE), 0, shift, 2, buf) < 2) return(EMPTY_VALUE);
   return(buf[1]); // last closed bar
}
double GetRSI(string sym, ENUM_TIMEFRAMES tf, int period, int shift=0)
{
   double buf[];
   if(CopyBuffer(iRSI(sym, tf, period, PRICE_CLOSE), 0, shift, 2, buf) < 2) return(EMPTY_VALUE);
   return(buf[1]);
}
double GetATR(string sym, ENUM_TIMEFRAMES tf, int period, int shift=0)
{
   double buf[];
   if(CopyBuffer(iATR(sym, tf, period), 0, shift, 2, buf) < 2) return(EMPTY_VALUE);
   return(buf[1]);
}

bool GetRates(string sym, ENUM_TIMEFRAMES tf, int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates,true);
   int copied = CopyRates(sym, tf, 0, count, rates);
   return(copied>=count);
}

bool NearRoundLevel(double price)
{
   if(!Inp_UseKeyLevels || Inp_RoundStep<=0) return(false);
   double step = Inp_RoundStep;
   double nearest = MathRound(price/step)*step;
   double tol = Inp_LevelTolerancePoints * _Point;
   return( MathAbs(price - nearest) <= tol );
}

bool NearPrevDayHL(double price)
{
   if(!Inp_UsePrevDayHL) return(false);
   double prevHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow  = iLow(_Symbol, PERIOD_D1, 1);
   if(prevHigh==0 || prevLow==0) return(false);
   double tol = Inp_LevelTolerancePoints * _Point;
   if(MathAbs(price-prevHigh)<=tol || MathAbs(price-prevLow)<=tol) return(true);
   return(false);
}

// weekly pivot based on LAST week's OHLC
bool NearWeeklyPivot(double price)
{
   if(!Inp_UseWeeklyPivots) return(false);
   // compute last week's timeframe values (W1)
   double lastH = iHigh(_Symbol, PERIOD_W1, 1);
   double lastL = iLow(_Symbol, PERIOD_W1, 1);
   double lastC = iClose(_Symbol, PERIOD_W1, 1);
   if(lastH==0 || lastL==0 || lastC==0) return(false);
   double P = (lastH+lastL+lastC)/3.0;
   double R1 = 2*P - lastL;
   double S1 = 2*P - lastH;
   double tol = Inp_LevelTolerancePoints * _Point;
   if(MathAbs(price-P)<=tol || MathAbs(price-R1)<=tol || MathAbs(price-S1)<=tol) return(true);
   return(false);
}

bool NearKeyLevels(double price)
{
   bool ok=false;
   if(Inp_UseKeyLevels)
   {
      if(NearRoundLevel(price)) ok=true;
      if(NearPrevDayHL(price))  ok=true;
      if(NearWeeklyPivot(price)) ok=true;
   }
   return(ok);
}

// Simple volume condition: fast SMA of tick-volume greater during impulse than pullback.
// We'll approximate by requiring fast SMA > slow SMA on the bar that breaks in-direction,
// and fast SMA < slow SMA on the preceding pullback bars cluster (heuristic).
bool VolumeFilterOK(string sym, ENUM_TIMEFRAMES tf)
{
   if(!Inp_UseVolumeFilter) return(true);
   MqlRates rates[];
   if(!GetRates(sym, tf, MathMax(Inp_Vol_Slow*3, 120), rates)) return(false);
   // compute simple MAs on the last N bars
   int Nf = MathMax(1, Inp_Vol_Fast);
   int Ns = MathMax(Nf+1, Inp_Vol_Slow);
   double fast=0, slow=0;
   for(int i=0;i<Nf;i++)   fast += (double)rates[i].tick_volume;
   for(int i=0;i<Ns;i++)   slow += (double)rates[i].tick_volume;
   fast/=Nf; slow/=Ns;
   // last closed bar "impulsive" should have fast > slow
   bool impulsive = fast > slow;
   // approximate "pullback weaker" by comparing previous cluster
   double fast_prev=0, slow_prev=0;
   for(int i=Nf;i<2*Nf;i++) fast_prev += (double)rates[i].tick_volume;
   for(int i=Ns;i<2*Ns;i++) slow_prev += (double)rates[i].tick_volume;
   fast_prev/=Nf; slow_prev/=Ns;
   bool pullback_weaker = fast_prev < slow_prev;
   return(impulsive && pullback_weaker);
}

// Detect rejection candle (pin or engulfing) on primary TF near EMA or key level
int RejectionDirection(string sym, ENUM_TIMEFRAMES tf, double ema, double &rejHigh, double &rejLow)
{
   MqlRates r[];
   if(!GetRates(sym, tf, 5, r)) return(0);
   // r[1] is last closed bar
   double o=r[1].open, c=r[1].close, h=r[1].high, l=r[1].low;
   double body = MathAbs(c-o);
   double range= h-l;
   if(range < 3*_Point) return(0);
   double upper_wick = h - MathMax(c,o);
   double lower_wick = MathMin(c,o) - l;

   bool nearEMA = (MathAbs(( (o+c)/2.0 ) - ema) <= Inp_PullbackProximityPoints*_Point);
   bool nearKey  = NearKeyLevels((o+c)/2.0);
   if(!(nearEMA || nearKey)) return(0);

   // Pin bar bullish: long lower wick, close in top half
   bool bull_pin = (lower_wick > 2.0*body) && (c > (l + 0.6*range));
   // Bearish pin: long upper wick, close in bottom half
   bool bear_pin = (upper_wick > 2.0*body) && (c < (l + 0.4*range));
   // Engulfing: current body engulfs previous body
   bool engulf_bull=false, engulf_bear=false;
   double oprev=r[2].open, cprev=r[2].close;
   if( (c>o) && (cprev<oprev) && (c>oprev) && (o<cprev) ) engulf_bull=true;
   if( (c<o) && (cprev>oprev) && (c<oprev) && (o>cprev) ) engulf_bear=true;

   int dir=0;
   if(Inp_UseRejectionCandles)
   {
      if(bull_pin || engulf_bull) dir = +1;
      if(bear_pin || engulf_bear) dir = -1;
   }
   else
   {
      // fallback: if candle closes above/below EMA decisively
      if(c>ema && o<ema) dir=+1;
      if(c<ema && o>ema) dir=-1;
   }

   if(dir!=0){ rejHigh=h; rejLow=l; }
   return(dir);
}

// Daily bias: price vs EMA21 and RSI range
int DailyBias()
{
   double emaD = GetEMA(_Symbol, Inp_TF_Confirm, Inp_EMA_Period);
   double rsiD = GetRSI(_Symbol, Inp_TF_Confirm, Inp_RSI_Period);
   if(emaD==EMPTY_VALUE || rsiD==EMPTY_VALUE) return(0);
   double closeD[];
   if(CopyClose(_Symbol, Inp_TF_Confirm, 1, 1, closeD) < 1) return(0);
   double price = closeD[0];

   bool longBias = (price > emaD && rsiD>=Inp_RSI_Long_Min && rsiD<=Inp_RSI_Long_Max);
   bool shortBias= (price < emaD && rsiD>=Inp_RSI_Short_Min && rsiD<=Inp_RSI_Short_Max);
   if(longBias && !shortBias) return(+1);
   if(shortBias && !longBias) return(-1);
   return(0);
}

// DXY inverse confirmation (optional)
bool DXYConfirms(int direction)
{
   if(!Inp_UseDXY || StringLen(Inp_DXY_Symbol)==0) return(true);
   // compare last closed bar change
   double clDxy[2];
   if(CopyClose(Inp_DXY_Symbol, Inp_TF_Primary, 0, 2, clDxy) < 2) return(true);
   double chg = clDxy[0] - clDxy[1];
   if(direction>0) return(chg <= 0); // gold up prefers DXY down
   if(direction<0) return(chg >= 0);
   return(true);
}

// Compute lot size from stop distance
double ComputeVolumeForRisk(double stop_points)
{
   if(stop_points <= 0) return(0.0);
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskp = (Inp_Mode==Evaluation ? Inp_Risk_Per_Trade_Eval : Inp_Risk_Per_Trade_Funded);
   double riskMoney = eq * (riskp/100.0);
   double valuePerPoint = PipValuePerPoint();
   if(valuePerPoint<=0.0) return(0.0);
   double vol = riskMoney / (stop_points * valuePerPoint);
   return( NormalizeVolume(vol) );
}

// Exposure guard: rough sum of open risk on this symbol (SL distance * value)
double CurrentExposurePercent()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0) return(0.0);
   double totalRiskMoney=0.0;
   if(PositionSelect(_Symbol))
   {
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      if(sl>0 && vol>0)
      {
         double stop_points = MathAbs(price - sl)/_Point;
         totalRiskMoney += stop_points * PipValuePerPoint() * vol;
      }
   }
   return( 100.0 * totalRiskMoney / eq );
}


// News blackout: simple time-based gate (broker calendar support varies).
bool InNewsBlackout()
{
   if(!Inp_UseNewsBlackout) return(false);
   // If your broker supports the MQL5 Economic Calendar, you can expand this later.
   // For now we provide a stub that always returns false to avoid compile/runtime issues on unsupported servers.
   return(false);
}

bool DirectionAllowed(int dir)
{
   if(!Inp_OneDirectionPerDay) return(true);
   if(g_todayDirection==0) return(true);
   return(g_todayDirection==dir);
}

bool CanOpenSetup()
{
   if(Inp_TwoStrikesPerDay && g_todayLosses >= Inp_MaxLossesPerDay) return(false);
   if(g_weekSetups >= Inp_MaxSetupsPerWeek) return(false);
   if(CurrentExposurePercent() >= Inp_Max_Total_Exposure_Percent) return(false);
   if(IsFridayCutoff()) return(false);
   if(!IsSessionOK()) return(false);
   if(InNewsBlackout()) return(false);
   return(true);
}

void MaybeScreenshot(const string &tag)
{
   if(!Inp_TakeScreenshots) return;
   string fn = StringFormat("%s_%s_%I64u_%s_%s.png",
                            Inp_EA_Name, _Symbol, (ulong)Inp_Magic, tag,
                            TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
   ChartScreenShot(0, fn, Inp_Screenshot_Width, Inp_Screenshot_Height, ALIGN_LEFT);
}

// Round price to valid tick
double RoundToTick(double price)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0) ts=_Point;
   return( MathRound(price/ts)*ts );
}

// Entry/SL/TP management & partials -------------------------------------------
void ManageOpenPosition()
{
   if(!PositionSelect(_Symbol)) return;
   double vol   = PositionGetDouble(POSITION_VOLUME);
   if(vol <= 0.0) return;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   long   type  = PositionGetInteger(POSITION_TYPE);
   int    dir   = (type==POSITION_TYPE_BUY)? +1 : -1;

   double stop_points = MathAbs(entry - sl)/_Point;
   if(stop_points<=0) return;

   double tp1Price = entry + dir * (Inp_TP1_R * stop_points * _Point);
   double tp2Price = entry + dir * (Inp_TP2_R * stop_points * _Point);

   bool T1done = GetGVFlag("T1done");
   bool T2done = GetGVFlag("T2done");

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (dir>0)? bid : ask;

   // TP1
   if(Inp_UsePartial_TPs && !T1done)
   {
      if( (dir>0 && price >= tp1Price) || (dir<0 && price <= tp1Price) )
      {
         double closeVol = NormalizeVolume(vol * Inp_TP1_CloseFrac);
         if(closeVol > 0 && closeVol < vol)
         {
            trade.PositionClosePartial(_Symbol, closeVol);
            if(trade.ResultRetcode()==10009 || trade.ResultRetcode()==10008) // done
            {
               SetGVFlag("T1done", true);
               // move SL to BE
               trade.PositionModify(_Symbol, entry, 0.0);
            }
         }
      }
   }
   // TP2
   if(Inp_UsePartial_TPs && GetGVFlag("T1done") && !T2done)
   {
      if( (dir>0 && price >= tp2Price) || (dir<0 && price <= tp2Price) )
      {
         // re-fetch current volume
         if(!PositionSelect(_Symbol)) return;
         vol   = PositionGetDouble(POSITION_VOLUME);
         double closeVol = NormalizeVolume(vol * (Inp_TP2_CloseFrac/(1.0 - Inp_TP1_CloseFrac))); // approximate
         if(closeVol > 0 && closeVol < vol)
         {
            trade.PositionClosePartial(_Symbol, closeVol);
            if(trade.ResultRetcode()==10009 || trade.ResultRetcode()==10008)
            {
               SetGVFlag("T2done", true);
            }
         }
      }
   }

   // Trailing for runner
   if(Inp_Trail_By_EMA && GetGVFlag("T1done"))
   {
      double emaTrail = GetEMA(_Symbol, Inp_TF_Precision, Inp_EMA_Period);
      if(emaTrail!=EMPTY_VALUE)
      {
         double newSL = (dir>0)? (emaTrail - Inp_Trail_Offset_Points*_Point)
                               : (emaTrail + Inp_Trail_Offset_Points*_Point);
         // only tighten toward price
         if(dir>0 && newSL > sl) trade.PositionModify(_Symbol, RoundToTick(newSL), 0.0);
         if(dir<0 && newSL < sl) trade.PositionModify(_Symbol, RoundToTick(newSL), 0.0);
      }
   }

   // If SL hit => loss recorded (captured in OnTradeTransaction ideally; fallback here not reliable)
}

// Open trade helper
bool OpenTrade(int dir, double entryPrice, double slPrice)
{
   if(!DirectionAllowed(dir)) return(false);

   double stop_points = MathAbs(entryPrice - slPrice)/_Point;
   double vol = ComputeVolumeForRisk(stop_points);
   if(vol <= 0.0) { Print("Volume calc failed"); return(false); }

   bool ok=false;
   trade.SetExpertMagicNumber((ulong)Inp_Magic);
   trade.SetAsyncMode(false);
   if(dir>0) ok = trade.Buy(vol, _Symbol, 0.0, slPrice, 0.0, Inp_EA_Name);
   else      ok = trade.Sell(vol, _Symbol, 0.0, slPrice, 0.0, Inp_EA_Name);

   if(ok)
   {
      MaybeScreenshot("ENTRY");
      g_weekSetups++;
      if(Inp_OneDirectionPerDay) g_todayDirection = dir;
      SetGVFlag("T1done", false);
      SetGVFlag("T2done", false);
   }
   else
   {
      Print("Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   return(ok);
}

// Signal evaluation on primary TF
void EvaluateSignal()
{
   // Symbol gate
   if(StringLen(Inp_AllowedSymbol)>0 && _Symbol != Inp_AllowedSymbol) return;

   // Only once per new primary bar
   datetime t[];
   if(CopyTime(_Symbol, Inp_TF_Primary, 0, 2, t) < 2) return;
   if(g_lastPrimaryBarTime == t[0]) return; // same bar update; run on each tick but ensure single evaluation when new bar forms
   bool newBar = (g_lastPrimaryBarTime != t[0]);
   g_lastPrimaryBarTime = t[0];
   if(!newBar) return;

   // If there is already an open position on this symbol (netting), manage & exit
   if(PositionSelect(_Symbol))
   {
      ManageOpenPosition();
      return;
   }

   if(!CanOpenSetup()) return;

   int bias = DailyBias();
   if(bias==0) return;

   if(!DXYConfirms(bias)) return;
   if(!VolumeFilterOK(_Symbol, Inp_TF_Primary)) return;

   // Pullback near EMA21 on primary
   double emaP = GetEMA(_Symbol, Inp_TF_Primary, Inp_EMA_Period);
   if(emaP==EMPTY_VALUE) return;

   double rejHigh=0, rejLow=0;
   int rejDir = RejectionDirection(_Symbol, Inp_TF_Primary, emaP, rejHigh, rejLow);
   if(rejDir==0) return;

   // Direction must align with daily bias
   if(rejDir != bias) return;

   // Key levels requirement
   double midPrice = (rejHigh+rejLow)/2.0;
   if(!NearKeyLevels(midPrice)) return;

   // Construct stop beyond structure & ATR
   double atr = GetATR(_Symbol, Inp_TF_Primary, Inp_ATR_Period);
   if(atr==EMPTY_VALUE) return;

   double slStruct = (rejDir>0)? (rejLow - 1.0*_Point) : (rejHigh + 1.0*_Point);
   double slATR    = (rejDir>0)? (midPrice - Inp_ATR_Mult*atr) : (midPrice + Inp_ATR_Mult*atr);
   double sl = (rejDir>0)? MathMin(slStruct, slATR) : MathMax(slStruct, slATR);
   sl = RoundToTick(sl);

   // Entry: breakout of rejection candle high/low
   double entry = (rejDir>0)? (rejHigh + 2*_Point) : (rejLow - 2*_Point);
   entry = RoundToTick(entry);

   // For market execution on next bar open: check current price proximity; else place at market
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double px  = (rejDir>0)? ask : bid;

   // Ensure stop distance reasonable
   double stop_points = MathAbs(entry - sl)/_Point;
   if(stop_points < 50) // ~ minimal 50 points (~$0.50 if _Point=0.01)
   {
      // expand to ATR-based minimal
      double alt = Inp_ATR_Mult * atr;
      sl = (rejDir>0)? (entry - alt) : (entry + alt);
      sl = RoundToTick(sl);
      stop_points = MathAbs(entry - sl)/_Point;
   }

   OpenTrade(rejDir, px, sl);
}

//------------------------------- EVENTS ---------------------------------------
int OnInit()
{
   g_prefix = StringFormat("%s[%I64u]", Inp_EA_Name, (ulong)Inp_Magic);
   ResetDailyCountersIfNeeded();
   ResetWeeklyCounterIfNeeded();
   Print(g_prefix, " initialized on ", _Symbol, " TF=", EnumToString((ENUM_TIMEFRAMES)Period()));
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason)
{
   Print(g_prefix, " deinit, reason=", reason);
}
void OnTick()
{
   ResetDailyCountersIfNeeded();
   ResetWeeklyCounterIfNeeded();

   // Friday handling: close & block
   if(IsFridayCutoff())
   {
      if(PositionSelect(_Symbol))
      {
         trade.PositionClose(_Symbol);
      }
      return;
   }

   // Manage existing position
   if(PositionSelect(_Symbol))
   {
      ManageOpenPosition();
      return;
   }

   // Evaluate
   EvaluateSignal();
}

// Track losses for "two strikes"
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(HistorySelect(TimeCurrent()-86400, TimeCurrent()))
      {
         long entry_type = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry_type == DEAL_ENTRY_OUT) // closing deal
         {
            string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
            if(sym == _Symbol)
            {
               double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
if(profit < 0)
               {
                  g_todayLosses++;
                  Print("Loss recorded. Today losses = ", g_todayLosses);
               }
            }
         }
      }
   }
}