//+------------------------------------------------------------------+
//|                                           TrendGuard Pro v7      |
//|                                     "Prop-Master" (2025 & beyond)|
//|  Regime-adaptive (Trend + MeanReversion) with Prop Guardrails    |
//|  Works across FX, Metals, Indices, Crypto (symbol-agnostic)      |
//+------------------------------------------------------------------+
#property strict
#property version   "7.0"
#property description "Regime-adaptive EA (Trend + MR). FTMO/Swing friendly guardrails."

#include <Trade/Trade.mqh>
CTrade Trade;

//============================= INPUTS ===============================
// --- Identification
input long    MagicNumber                 = 7700772025;

// --- Risk Core (Prop-friendly)
input double  BaseRisk_Percent            = 0.30;   // % equity risk per trade (0.2-0.5 typical)
input double  MaxDailyLoss_Percent        = 4.5;    // Hard daily max loss (stop trading when breached)
input double  MaxTotalDrawdown_Percent    = 9.0;    // Hard total DD from peak equity
input int     MaxConsecutiveLosses        = 5;      // Pause after N losses
input int     CooldownMinutesAfterLoss    = 30;     // Pause trading for N minutes after loss
input int     MaxOpenPositionsPerSymbol   = 1;
input bool    CloseAllIfDailyLossHit      = true;

// --- Sessions (GMT-based)
enum BrokerGMTOffsetEnum {
   GMT_Minus_12 = -12, GMT_Minus_11 = -11, GMT_Minus_10 = -10, GMT_Minus_9 = -9,
   GMT_Minus_8 = -8, GMT_Minus_7 = -7, GMT_Minus_6 = -6, GMT_Minus_5 = -5,
   GMT_Minus_4 = -4, GMT_Minus_3 = -3, GMT_Minus_2 = -2, GMT_Minus_1 = -1,
   GMT_0 = 0, GMT_Plus_1 = 1, GMT_Plus_2 = 2, GMT_Plus_3 = 3, GMT_Plus_4 = 4,
   GMT_Plus_5 = 5, GMT_Plus_6 = 6, GMT_Plus_7 = 7, GMT_Plus_8 = 8, GMT_Plus_9 = 9,
   GMT_Plus_10 = 10, GMT_Plus_11 = 11, GMT_Plus_12 = 12
};
input BrokerGMTOffsetEnum BrokerGMTOffsetHours = GMT_0;
input bool    UseSessionFilter             = true;
input bool    UseTokyoSession              = false;
input string  TokyoStartHHMM               = "00:00";
input string  TokyoEndHHMM                 = "08:00";
input bool    UseLondonSession             = true;
input string  LondonStartHHMM              = "07:00";
input string  LondonEndHHMM                = "16:00";
input bool    UseNewYorkSession            = true;
input string  NewYorkStartHHMM             = "12:30";
input string  NewYorkEndHHMM               = "21:00";
input bool    AllowLondonNYOverlapBoost    = true;
input double  Overlap_SizeMultiplier       = 1.25;

// --- Day of Week multipliers (Mon..Fri)
input bool    UseDayOfWeekOptimizer        = true;
input double  Monday_SizeMult              = 0.85;
input double  Tuesday_SizeMult             = 1.05;
input double  Wednesday_SizeMult           = 1.00;
input double  Thursday_SizeMult            = 0.95;
input double  Friday_SizeMult              = 0.85;

// --- Regime Detection
input int     ADX_Period                   = 14;
input int     ADX_TrendThreshold           = 25;    // ADX > this => trending
input int     ADX_RangeThreshold           = 20;    // ADX < this => ranging
input int     ATR_Period                   = 14;

// --- Trend-following params
input int     TF_EMA_Fast                  = 50;
input int     TF_EMA_Slow                  = 200;
input int     TF_EntryTF_MinPullbackBars   = 2;     // min bars since last EMA touch
input double  TF_StopATR_Mult              = 2.0;
input double  TF_TakeProfit_RR             = 1.8;

// --- Mean-reversion params
input int     MR_RSI_Period                = 14;
input int     MR_RSI_BuyLevel              = 30;
input int     MR_RSI_SellLevel             = 70;
input int     MR_BB_Period                 = 20;
input double  MR_BB_Dev                    = 2.0;
input double  MR_StopATR_Mult              = 1.8;
input double  MR_TakeProfit_RR             = 1.2;

// --- Execution
input int     SlippagePoints               = 10;

// --- Logging
input bool    VerboseLog                   = true;
input bool    DebugMode                    = false;  // extra prints


// --- Execution Safety Upgrades
input int     MinBarsForIndicators        = 150;    // bars required before using indicators
input int     MaxSpreadPoints             = 50;     // skip if spread above this
input double  DailyProfitLock_Percent     = 4.0;    // pause trading for the day after +X% gain

// --- News Filter (stub by default)
input bool    UseNewsFilter                = false;  // set true when you implement calendar/file-based filter
input int     PreNewsBlock_Min             = 30;
input int     PostNewsBlock_Min            = 30;

//=========================== INTERNALS ==============================
datetime  g_dayStart=0;
double    g_dayStartEquity=0.0;
double    g_peakEquity=0.0;
int       g_consecLosses=0;
datetime  g_lastLossTime=0;

//------------------- Utilities -------------------------------------
int ParseHHMM(const string hhmm){
   int h=(int)StringToInteger(StringSubstr(hhmm,0,2));
   int m=(int)StringToInteger(StringSubstr(hhmm,3,2));
   return h*60+m;
}
int ServerTimeToGMTMinutes(datetime t){
   MqlDateTime st; TimeToStruct(t,st);
   int minutes = (st.hour - (int)BrokerGMTOffsetHours)*60 + st.min;
   while(minutes<0) minutes+=1440;
   while(minutes>=1440) minutes-=1440;
   return minutes;
}
bool InWindow(int nowMin, int startMin, int endMin){
   if(startMin<=endMin) return (nowMin>=startMin && nowMin<endMin);
   return (nowMin>=startMin || nowMin<endMin); // wrap
}
void ResetDailyEquityAnchor(){
   g_dayStart       = iTime(_Symbol,PERIOD_D1,0);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
}
double GetDoWSizeMult(){
   if(!UseDayOfWeekOptimizer) return 1.0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int dow = dt.day_of_week; // 0=Sun
   if(dow==1) return Monday_SizeMult;
   if(dow==2) return Tuesday_SizeMult;
   if(dow==3) return Wednesday_SizeMult;
   if(dow==4) return Thursday_SizeMult;
   if(dow==5) return Friday_SizeMult;
   return 1.0;
}
bool SessionOkayAndSizeMult(double &mult_out){
   mult_out=1.0;
   if(!UseSessionFilter) return true;

   int nowGMT = ServerTimeToGMTMinutes(TimeCurrent());
   int tks = ParseHHMM(TokyoStartHHMM);
   int tke = ParseHHMM(TokyoEndHHMM);
   int lns = ParseHHMM(LondonStartHHMM);
   int lne = ParseHHMM(LondonEndHHMM);
   int nys = ParseHHMM(NewYorkStartHHMM);
   int nye = ParseHHMM(NewYorkEndHHMM);

   bool tok = UseTokyoSession  && InWindow(nowGMT,tks,tke);
   bool lon = UseLondonSession && InWindow(nowGMT,lns,lne);
   bool ny  = UseNewYorkSession&& InWindow(nowGMT,nys,nye);
   if(!(tok||lon||ny)){
      if(VerboseLog) Print("TG7: Outside sessions");
      return false;
   }
   // Base session multipliers
   if(tok) mult_out *= 0.60;
   if(lon) mult_out *= 1.00;
   if(ny)  mult_out *= 1.00;
   if(AllowLondonNYOverlapBoost && lon && ny) mult_out *= Overlap_SizeMultiplier;

   if(DebugMode) Print("TG7 Debug: srv=",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
                       " gmtMin=",nowGMT," tok=",tok," lon=",lon," ny=",ny," sessMult=",DoubleToString(mult_out,2));
   return true;
}

// Series/history safety: ensure data is synced & enough bars
bool SeriesReady(const string sym, ENUM_TIMEFRAMES tf, int min_bars=100){
   if(sym=="") return false;
   long synced=0; if(!SeriesInfoInteger(sym, tf, SERIES_SYNCHRONIZED, synced)) return false;
   if(synced==0) return false;
   int bars = Bars(sym, tf);
   if(bars<min_bars) return false;
   return true;
}
bool PrimeHistory(const string sym, ENUM_TIMEFRAMES tf, int need=200){
   MqlRates rates[]; int tries=0;
   while(tries<15){ int got=CopyRates(sym, tf, 0, need, rates); if(got>=MathMin(need,50)) return true; Sleep(50); tries++; }
   return false;
}

bool IsBlockedByNewsStub(){
   if(!UseNewsFilter) return false;
   // Placeholder: always false. Implement Calendar or File-based blocking when desired.
   return false;
}

bool CheckDailyAndTotalDD(){
   // Reset daily anchor at new D1 bar
   datetime curDay = iTime(_Symbol,PERIOD_D1,0);
   if(curDay!=g_dayStart) ResetDailyEquityAnchor();

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_peakEquity) g_peakEquity=eq;

   // Daily DD
   double dayDD = (g_dayStartEquity - eq)/g_dayStartEquity*100.0;
   if(dayDD >= MaxDailyLoss_Percent){
      if(VerboseLog) Print("TG7: Daily loss breached. Pausing trading.");
      if(CloseAllIfDailyLossHit){
         for(int i=PositionsTotal()-1;i>=0;i--){
            ulong tk = PositionGetTicket(i);
            if(PositionSelectByTicket(tk) && PositionGetString(POSITION_SYMBOL)==_Symbol){
               Trade.PositionClose(tk);
            }
         }
      }
      return false;
   }
   // Total DD from peak
   if(g_peakEquity>0){
      double totalDD = (g_peakEquity - eq)/g_peakEquity*100.0;
      if(totalDD >= MaxTotalDrawdown_Percent){
         if(VerboseLog) Print("TG7: Total DD breached. Pausing trading.");
         return false;
      }
   // Daily profit lock
   double dayGain = (AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity)/g_dayStartEquity*100.0;
   if(dayGain >= DailyProfitLock_Percent){
      if(VerboseLog) Print("TG7: Daily profit lock reached (", DoubleToString(dayGain,2), "%). Pausing trading.");
      return false;
   }

   }
   // Cooldown after consecutive losses
   if(g_consecLosses>=MaxConsecutiveLosses){
      if(VerboseLog) Print("TG7: Max consecutive losses reached. Cooling down.");
      return false;
   }
   if(g_lastLossTime>0 && (TimeCurrent()-g_lastLossTime) < CooldownMinutesAfterLoss*60){
      if(VerboseLog) Print("TG7: Cooling down after loss.");
      return false;
   }
   return true;
}

//------------------- Indicators & Regime ----------------------------
double GetATR(int period, ENUM_TIMEFRAMES tf, int shift){
   if(!SeriesReady(_Symbol, tf, MinBarsForIndicators)) return 0.0;
   int h = iATR(_Symbol, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}

double GetADX(int period, ENUM_TIMEFRAMES tf, int shift){
   if(!SeriesReady(_Symbol, tf, MinBarsForIndicators)) return 0.0;
   int h = iADX(_Symbol, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}

double GetEMA(int period, ENUM_TIMEFRAMES tf, int shift){
   if(!SeriesReady(_Symbol, tf, MinBarsForIndicators)) return 0.0;
   int h = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}

double GetRSI(int period, ENUM_TIMEFRAMES tf, int shift){
   if(!SeriesReady(_Symbol, tf, MinBarsForIndicators)) return 0.0;
   int h = iRSI(_Symbol, tf, period, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}

void GetBBands(int period, double dev, ENUM_TIMEFRAMES tf, int shift, double &upper, double &middle, double &lower){
   if(!SeriesReady(_Symbol, tf, MinBarsForIndicators)){ upper=middle=lower=0.0; return; }

   int h = iBands(_Symbol, tf, period, dev, 0, PRICE_CLOSE);
   if(h==INVALID_HANDLE){ upper=middle=lower=0.0; return; }
   double u[1], m[1], l[1];
   if(CopyBuffer(h,0,shift,1,u)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   if(CopyBuffer(h,1,shift,1,m)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   if(CopyBuffer(h,2,shift,1,l)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   upper=u[0]; middle=m[0]; lower=l[0]; IndicatorRelease(h);
}


// Determine regime on current chart timeframe
enum Regime { REGIME_TREND=0, REGIME_RANGE=1, REGIME_CHAOS=2 };
Regime DetectRegime(){
   double adx = GetADX(ADX_Period, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   double atr = GetATR(ATR_Period, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   // Simple heuristic: ADX governs trend/range; ATR spike without ADX rise => chaos
   if(adx>=ADX_TrendThreshold) return REGIME_TREND;
   if(adx<=ADX_RangeThreshold) return REGIME_RANGE;
   // mid zone → treat as trend-light (or chaos). We'll mark as chaos to be safe.
   return REGIME_CHAOS;
}

//------------------- Signals ---------------------------------------
// Trend-following: HTF bias + LTF entry on pullback/breakout
bool TrendSignal(int &dir, double &stop_pips){
   dir = 0; stop_pips=0.0;
   // Bias via EMAs on current TF
   double emaFast0 = GetEMA(TF_EMA_Fast, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   double emaSlow0 = GetEMA(TF_EMA_Slow, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   if(emaFast0==0 || emaSlow0==0) return false;

   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point= SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atr  = GetATR(ATR_Period, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);

   // Long trend: fast > slow and price near/above fast EMA (simple pullback filter)
   if(emaFast0>emaSlow0 && bid>emaFast0){
      dir = 1;
   }
   // Short trend
   if(emaFast0<emaSlow0 && ask<emaFast0){
      dir = -1;
   }
   if(dir==0) return false;

   // Stop distance from ATR
   double stop_dist = TF_StopATR_Mult * atr;
   stop_pips = stop_dist/point;
   return true;
}

// Mean-Reversion: RSI extremes + BB bands touch/penetration
bool MRSignal(int &dir, double &stop_pips){
   dir = 0; stop_pips=0.0;
   double rsi0 = GetRSI(MR_RSI_Period, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   double up, mid, lo; GetBBands(MR_BB_Period, MR_BB_Dev, PERIOD_CURRENT, 0, up, mid, lo);
   if(rsi0==0 || up==0 || lo==0) return false;

   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point= SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atr  = GetATR(ATR_Period, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);

   // Long mean-rev: RSI < 30 and price below lower band
   if(rsi0<=MR_RSI_BuyLevel && bid<=lo){
      dir = 1;
   }
   // Short mean-rev: RSI > 70 and price above upper band
   if(rsi0>=MR_RSI_SellLevel && ask>=up){
      dir = -1;
   }
   if(dir==0) return false;

   double stop_dist = MR_StopATR_Mult * atr;
   stop_pips = stop_dist/point;
   return true;
}

//------------------- Risk & Execution -------------------------------
double CalcLotByRisk(double stop_pips, double risk_percent){
   if(stop_pips<=0) return 0.0;
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * (risk_percent/100.0);

   double tickValue= SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double point    = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0 || tickSize<=0 || tickValue<=0) return 0.0;

   double pipValuePerLot = tickValue * (point / tickSize);
   double lots = riskCash / (stop_pips * pipValuePerLot);

   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   // normalize
   if(step>0) lots = MathFloor(lots/step)*step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}
bool WithinMaxPositions(){
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++){
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetString(POSITION_SYMBOL)==_Symbol) cnt++;
   }
   return (cnt<MaxOpenPositionsPerSymbol);
}

bool PlaceTrade(int dir, double stop_pips, double rr_tp){
   if(!WithinMaxPositions()) return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double price = (dir>0)? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl    = 0.0, tp=0.0;
   double stop_dist_points = stop_pips * point;
   // Enforce broker stops level and spread filter
   long stopsLvl = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); // points
   double minStopPoints = (double)stopsLvl;
   if(minStopPoints>0 && stop_dist_points < minStopPoints*point) stop_dist_points = minStopPoints*point;

   double spreadPts = (SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID)) / point;
   if(spreadPts > MaxSpreadPoints){
      if(VerboseLog) Print("TG7: Spread too high (", DoubleToString(spreadPts,1), ">", MaxSpreadPoints, "). Skip.");
      return false;
   }

   if(dir>0){
      sl = price - stop_dist_points;
      tp = price + (rr_tp * stop_dist_points);
   }else{
      sl = price + stop_dist_points;
      tp = price - (rr_tp * stop_dist_points);
   }

   // Effective risk = base * sessions * DoW
   double sessMult=1.0; if(!SessionOkayAndSizeMult(sessMult)) return false;
   if(IsBlockedByNewsStub()) return false;
   if(!CheckDailyAndTotalDD()) return false;

   double dowMult = GetDoWSizeMult();
   double effRisk = BaseRisk_Percent * sessMult * dowMult;

   double lots = CalcLotByRisk(stop_pips, effRisk);
   if(lots<=0){
      if(VerboseLog) Print("TG7: Lots <= 0, skip. calc inputs stop_pips=",stop_pips," effRisk=",DoubleToString(effRisk,2));
      return false;
   }

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(SlippagePoints);
   bool ok = false;
   if(dir>0) ok = Trade.Buy(lots,_Symbol,0,sl,tp,"TG7-TrendGuard");
   else      ok = Trade.Sell(lots,_Symbol,0,sl,tp,"TG7-TrendGuard");

   if(VerboseLog) Print("TG7: Sent ", (dir>0?"BUY":"SELL"), " lots=", DoubleToString(lots,2),
                        " stop_pips=", DoubleToString(stop_pips,1), " RR=", rr_tp,
                        " effRisk%=", DoubleToString(effRisk,2));

   return ok;
}

// Track PnL to update g_consecLosses and g_lastLossTime
void UpdatePnLStatsOnTradeClose(){
   // Walk history for last closed deal on this symbol
   ulong last_ticket = 0;
   datetime last_close_time = 0;
   HistorySelect(0, TimeCurrent());
   uint deals = HistoryDealsTotal();
   for(uint i=0;i<deals;i++){
      ulong deal_id = HistoryDealGetTicket(i);
      if((long)deal_id<=0) continue;
      string sym = (string)HistoryDealGetString(deal_id, DEAL_SYMBOL);
      if(sym!=_Symbol) continue;
      int entry = (int)HistoryDealGetInteger(deal_id, DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT) continue;
      datetime ctime = (datetime)HistoryDealGetInteger(deal_id, DEAL_TIME);
      if(ctime>last_close_time){ last_close_time=ctime; last_ticket=deal_id; }
   }
   if(last_ticket>0){
      double profit = HistoryDealGetDouble(last_ticket, DEAL_PROFIT) + HistoryDealGetDouble(last_ticket, DEAL_SWAP) + HistoryDealGetDouble(last_ticket, DEAL_COMMISSION);
      if(profit<0){ g_consecLosses++; g_lastLossTime=last_close_time; }
      else if(profit>0){ g_consecLosses=0; }
   }
}

//=========================== LIFECYCLE ==============================
int OnInit(){
   ResetDailyEquityAnchor();
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   // Prime a bit of history to avoid indicator sync delays
   PrimeHistory(_Symbol, (ENUM_TIMEFRAMES)_Period, 200);

   if(VerboseLog) Print("TG7 Init: Symbol=",_Symbol," TF=",EnumToString((ENUM_TIMEFRAMES)_Period),
                        " BaseRisk%=",DoubleToString(BaseRisk_Percent,2),
                        " MaxDD(day/total)=",DoubleToString(MaxDailyLoss_Percent,1),"/",DoubleToString(MaxTotalDrawdown_Percent,1));
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason){}

datetime last_bar_time=0;
void OnTick(){
   // Only run once per bar for signal logic
   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur_bar == last_bar_time) return;
   last_bar_time = cur_bar;

   if(!CheckDailyAndTotalDD()) return;

   // Determine regime
   Regime regime = DetectRegime();
   if(DebugMode) Print("TG7 Debug: Regime=", (regime==REGIME_TREND?"TREND":regime==REGIME_RANGE?"RANGE":"CHAOS") );

   int dir=0; double stop_pips=0.0;
   bool gotSignal=false;
   double rr=1.5;

   if(regime==REGIME_TREND){
      gotSignal = TrendSignal(dir, stop_pips);
      rr = TF_TakeProfit_RR;
   }else if(regime==REGIME_RANGE){
      gotSignal = MRSignal(dir, stop_pips);
      rr = MR_TakeProfit_RR;
   }else{
      // Chaos: stand aside
      gotSignal = false;
   }

   if(gotSignal){
      PlaceTrade(dir, stop_pips, rr);
   }

   // Update PnL stats in case a trade closed on this bar
   UpdatePnLStatsOnTradeClose();
}
//+------------------------------------------------------------------+