//+------------------------------------------------------------------+
//|                                           TrendGuard Pro v7      |
//|                                     "Prop-Master" (2025 & beyond)|
//|  Regime-adaptive (Trend + MeanReversion) with Prop Guardrails    |
//|  Works across FX, Metals, Indices, Crypto (symbol-agnostic)      |
//+------------------------------------------------------------------+
#property strict
#property version   "7.2"
#property description "Regime-adaptive EA (Trend + MR). FTMO/MFF-friendly guardrails."
// Compile: 0 error(s), 0 warning(s)  (target with current MetaEditor)

/*
   Licensing Toggle:
   -----------------
   If you have a working LicenseManager.mqh that exposes:
     - bool InitializeLicense();
     - bool CheckLicenseStatus();
     - void DeinitializeLicense();
   then uncomment the next line (#define USE_TG7_LICENSE) and ensure the include path is correct.
*/
// #define USE_TG7_LICENSE

#ifdef USE_TG7_LICENSE
  #include <LicenseManager.mqh>
  #define License_Init()    InitializeLicense()
  #define License_Check()   CheckLicenseStatus()
  #define License_Deinit()  DeinitializeLicense()
#else
  bool License_Init(){ return true; }
  bool License_Check(){ return true; }
  void License_Deinit(){}
#endif

#include <Trade/Trade.mqh>
CTrade Trade;

//============================= INPUTS ===============================
// --- Identification
input long    MagicNumber                 = 77007700;

// --- Risk Core (Prop-friendly)  (Keep these as the ORIGINAL names)
input double  BaseRisk_Percent            = 0.30;   // % equity risk per trade (0.2-0.5 typical)
input double  MaxDailyLoss_Percent        = 5.0;    // Daily loss threshold (% of start-of-day equity)
input double  MaxTotalDrawdown_Percent    = 10.0;   // Max peak-to-trough drawdown (% of peak equity)
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
input double  TF_StopATR_Mult              = 2.0;
input double  TF_TakeProfit_RR             = 1.5;

// --- Mean-Reversion params
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

// --- News Filter (stub by default)
input bool    UseNewsFilter                = false;  // set true when you implement calendar/file-based filter
input int     PreNewsBlock_Min             = 30;
input int     PostNewsBlock_Min            = 30;

// --- Account Modes (new)
enum AccountModeEnum { Mode_Custom, Mode_Normal, Mode_Prop_Challenge, Mode_Prop_Funded };
input AccountModeEnum AccountMode = Mode_Custom;   // OFF → original behavior

enum PropRulePreset { Prop_Custom, Prop_FTMO_2025, Prop_MFF_2025, Prop_FundedNext_2025 };
input PropRulePreset PropPreset = Prop_Custom;     // OFF → original behavior

input double DailyLossBufferPct = 0.0; // Optional pre-stop buffer (e.g., 0.5 → stop at 4.5% if rule is 5%)

// --- Execution Guards (new)
input bool   UseSpreadGuard  = false; // Block trades when spread too high
input int    MaxSpreadPoints = 25;    // In *points*

input bool   UseSignalCooldown = false; // Prevent rapid duplicate entries
input int    CooldownMinutes   = 15;    // Per symbol+direction

// --- Management (new)
input bool   UseBreakEven     = false;
input double BE_TriggerATR    = 1.0;     // Move SL to BE after price moves 1.0x ATR favorably
input int    BE_LockPoints    = 5;       // Lock +5 points beyond BE

input bool   UsePartialTP     = false;   // Two partial targets by ATR multiples
input double Partial1Pct      = 50.0;    // Close 50% at TP1
input double Partial1_TPxATR  = 1.0;     // TP1 at 1.0x ATR
input double Partial2Pct      = 25.0;    // Close 25% at TP2 (remaining runs)
input double Partial2_TPxATR  = 2.0;     // TP2 at 2.0x ATR

enum TrailModeEnum { Trail_None, Trail_ATR, Trail_Chandelier };
input TrailModeEnum TrailMode = Trail_None;
input int    TrailATRPeriod   = 14;
input double TrailATRMult     = 2.0;

// --- Filters (new)
input bool   UseMTFFilter        = false;              // MTF EMA(50/200) alignment filter
input ENUM_TIMEFRAMES MTFTimeframe= PERIOD_H4;         // Higher timeframe for filter
input int    MTF_EMA_Fast        = 50;
input int    MTF_EMA_Slow        = 200;

// --- Session Edges (new)
input int BlockFridayClose_Minutes = 60; // Block last N minutes before Friday close
input int BlockWeekendGap_Minutes  = 30; // Block first N minutes after week open

// --- News/Blackout Windows (new)
input string BlackoutWindows = ""; // e.g. "2025-09-21 12:00-14:00; 2025-09-23 08:25-09:10"

//=========================== INTERNALS ==============================
#define INTMAX 2147483647

datetime  g_dayStart=0;
double    g_dayStartEquity=0.0;
double    g_peakEquity=0.0;
int       g_consecLosses=0;
datetime  g_lastLossTime=0;

// --- Effective risk limits for presets (new) – internal shadows
double eff_MaxDailyLossPct_internal = 0.0;
double eff_MaxTotalDDPct_internal   = 0.0;
bool   eff_CloseAllIfDailyLossHit_internal = false;

// --- Cooldown timestamps (per direction)
datetime g_lastSignalTimeBuy  = 0;
datetime g_lastSignalTimeSell = 0;

//------------------- Utilities -------------------------------------
int ParseHHMM(const string hhmm){
   int h=(int)StringToInteger(StringSubstr(hhmm,0,2));
   int m=(int)StringToInteger(StringSubstr(hhmm,3,2));
   return h*60+m;
}
int ServerTimeToGMTMinutes(datetime srv){
   MqlDateTime mt; TimeToStruct(srv, mt);
   int minute = mt.hour*60 + mt.min;
   int gmtShift = (int)BrokerGMTOffsetHours;
   int g = minute - gmtShift*60;
   if(g<0) g += 24*60;
   if(g>=24*60) g -= 24*60;
   return g;
}
bool InWindow(int nowMin, int startMin, int endMin){
   if(startMin<=endMin) return (nowMin>=startMin && nowMin<=endMin);
   // overnight window
   return (nowMin>=startMin || nowMin<=endMin);
}
void ResetDailyEquityAnchor(){
   g_dayStart = iTime(_Symbol,PERIOD_D1,0);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
}
double GetDoWSizeMult(){
   if(!UseDayOfWeekOptimizer) return 1.0;
   MqlDateTime mt; TimeToStruct(TimeCurrent(), mt);
   switch(mt.day_of_week){
      case 1: return Monday_SizeMult;
      case 2: return Tuesday_SizeMult;
      case 3: return Wednesday_SizeMult;
      case 4: return Thursday_SizeMult;
      case 5: return Friday_SizeMult;
   }
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

   // Effective limits (resolve presets to internals; fall back to ORIGINAL inputs)
   double MaxDaily = (eff_MaxDailyLossPct_internal>0.0 ? eff_MaxDailyLossPct_internal : MaxDailyLoss_Percent);
   double MaxTotal = (eff_MaxTotalDDPct_internal>0.0   ? eff_MaxTotalDDPct_internal   : MaxTotalDrawdown_Percent);
   bool   CloseAll = (eff_CloseAllIfDailyLossHit_internal ? true : CloseAllIfDailyLossHit);

   // Daily DD
   if(g_dayStartEquity>0){
      double dayDD = (g_dayStartEquity - eq)/g_dayStartEquity*100.0;
      if(dayDD >= MaxDaily){
         if(VerboseLog) Print("TG7: Daily loss breached. Pausing trading.");
         if(CloseAll){
            for(int i=PositionsTotal()-1;i>=0;i--){
               ulong tk = PositionGetTicket(i);
               if(PositionSelectByTicket(tk) && PositionGetString(POSITION_SYMBOL)==_Symbol){
                  Trade.PositionClose(tk);
               }
            }
         }
         return false;
      }
   }
   // Total DD from peak
   if(g_peakEquity>0){
      double totalDD = (g_peakEquity - eq)/g_peakEquity*100.0;
      if(totalDD >= MaxTotal){
         if(VerboseLog) Print("TG7: Total DD breached. Pausing trading.");
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
   int h = (int)iATR(_Symbol, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}
double GetADX(int period, ENUM_TIMEFRAMES tf, int shift){
   int h = iADX(_Symbol, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}
double GetEMA(int period, ENUM_TIMEFRAMES tf, int shift){
   int h = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}
double GetRSI(int period, ENUM_TIMEFRAMES tf, int shift){
   int h = iRSI(_Symbol, tf, period, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}
void GetBBands(int period, double dev, ENUM_TIMEFRAMES tf, int shift, double &up, double &mid, double &lo){
   int h = iBands(_Symbol, tf, period, (int)dev, 0, PRICE_CLOSE);
   if(h==INVALID_HANDLE){ up=mid=lo=0.0; return; }
   double b0[],b1[],b2[];
   int c0=CopyBuffer(h,0,shift,1,b0);
   int c1=CopyBuffer(h,1,shift,1,b1);
   int c2=CopyBuffer(h,2,shift,1,b2);
   IndicatorRelease(h);
   if(c0<=0||c1<=0||c2<=0){ up=mid=lo=0.0; return; }
   up=b0[0]; mid=b1[0]; lo=b2[0];
}
// Determine regime on current chart timeframe
enum Regime { REGIME_TREND=0, REGIME_RANGE=1, REGIME_CHAOS=2 };
Regime DetectRegime(){
   double adx = GetADX(ADX_Period, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   if(adx>=ADX_TrendThreshold) return REGIME_TREND;
   if(adx<=ADX_RangeThreshold) return REGIME_RANGE;
   return REGIME_CHAOS;
}

//------------------- Signals ---------------------------------------
bool MTF_Aligned(const int dir); // forward decl

bool TrendSignal(int &dir, double &stop_pips){
   dir = 0; stop_pips=0.0;
   double emaFast0 = GetEMA(TF_EMA_Fast, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   double emaSlow0 = GetEMA(TF_EMA_Slow, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   if(emaFast0==0 || emaSlow0==0) return false;

   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point= SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atr  = GetATR(ATR_Period, (ENUM_TIMEFRAMES)PERIOD_CURRENT, 0);
   if(atr<=0 || point<=0) return false;

   if(emaFast0>emaSlow0 && bid>emaFast0){
      dir = 1;
   }
   if(emaFast0<emaSlow0 && ask<emaFast0){
      dir = -1;
   }
   if(dir==0) return false;

   double stop_dist = TF_StopATR_Mult * atr;
   if(!MTF_Aligned(dir)) return false;
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
   if(atr<=0 || point<=0) return false;

   if(rsi0<=MR_RSI_BuyLevel && bid<=lo){
      dir = 1;
   }
   if(rsi0>=MR_RSI_SellLevel && ask>=up){
      dir = -1;
   }
   if(dir==0) return false;

   double stop_dist = MR_StopATR_Mult * atr;
   if(!MTF_Aligned(dir)) return false;
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

// helpers forward decls
int CurrentSpreadPoints();
bool BlockedBySessionEdges();
bool IsInManualBlackout();
bool CooldownAllows(const int dir);
void MarkCooldown(const int dir);

bool PlaceTrade(int dir, double stop_pips, double rr_tp){
   // Spread guard
   if(UseSpreadGuard){
      int sp = CurrentSpreadPoints();
      if(sp==INTMAX || sp>MaxSpreadPoints){ if(VerboseLog) PrintFormat("SpreadGuard: %d>%d → block", sp, MaxSpreadPoints); return false; }
   }
   // Session edges
   if(BlockedBySessionEdges()){
      if(VerboseLog) Print("SessionEdges: blocked");
      return false;
   }
   // Manual blackout windows
   if(IsInManualBlackout()){
      if(VerboseLog) Print("ManualBlackout: blocked");
      return false;
   }

   if(!WithinMaxPositions()) return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double price = (dir>0)? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl    = 0.0, tp=0.0;
   double stop_dist_points = stop_pips * point;
   if(dir>0){
      sl = price - stop_dist_points;
      tp = price + (rr_tp * stop_dist_points);
   }else{
      sl = price + stop_dist_points;
      tp = price - (rr_tp * stop_dist_points);
   }

   // Effective risk = base * sessions * DoW
   double sessMult=1.0;
   if(!SessionOkayAndSizeMult(sessMult)) return false;
   double dowMult = GetDoWSizeMult();
   double effRisk = BaseRisk_Percent * sessMult * dowMult;

   double lots = CalcLotByRisk(stop_pips, effRisk);
   if(lots<=0){
      if(VerboseLog) Print("TG7: Lots <= 0, skip. calc inputs stop_pips=",stop_pips," effRisk=",DoubleToString(effRisk,2));
      return false;
   }

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(SlippagePoints);
   bool ok = (dir>0) ? Trade.Buy(lots,_Symbol,0.0,sl,tp,"TG7-TrendGuard")
                     : Trade.Sell(lots,_Symbol,0.0,sl,tp,"TG7-TrendGuard");
   if(!ok){
      // bounded retry on common transient retcodes
      const int MAX_ATTEMPTS = 2;
      for(int k=1;k<=MAX_ATTEMPTS && !ok;k++){
         uint rc = (uint)Trade.ResultRetcode();
         if(VerboseLog || DebugMode) PrintFormat("OrderSend retry %d ret=%u %s", k, rc, Trade.ResultRetcodeDescription());
         if(rc==TRADE_RETCODE_REQUOTE || rc==TRADE_RETCODE_REJECT || rc==TRADE_RETCODE_PRICE_CHANGED){
            Sleep(200 + 100*k);
            ok = (dir>0) ? Trade.Buy(lots,_Symbol,0.0,sl,tp,"TG7-TrendGuard")
                         : Trade.Sell(lots,_Symbol,0.0,sl,tp,"TG7-TrendGuard");
         }else break;
      }
   }
   if(ok) MarkCooldown(dir);

   if(VerboseLog) Print("TG7: Sent ", (dir>0?"BUY":"SELL"), " lots=", DoubleToString(lots,2),
                        " stop_pips=", DoubleToString(stop_pips,1), " RR=", rr_tp,
                        " effRisk%=", DoubleToString(effRisk,2));

   return ok;
}

// Track PnL to update g_consecLosses and g_lastLossTime
void UpdatePnLStatsOnTradeClose(){
   HistorySelect(0, TimeCurrent());
   uint deals = HistoryDealsTotal();
   datetime latest=0; double lastProfit=0;
   for(uint i=0;i<deals;i++){
      ulong deal_id = HistoryDealGetTicket(i);
      if((long)deal_id<=0) continue;
      string sym = (string)HistoryDealGetString(deal_id, DEAL_SYMBOL);
      if(sym!=_Symbol) continue;
      int entry = (int)HistoryDealGetInteger(deal_id, DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT) continue;
      datetime ctime = (datetime)HistoryDealGetInteger(deal_id, DEAL_TIME);
      if(ctime>latest){
         latest=ctime;
         lastProfit = HistoryDealGetDouble(deal_id, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal_id, DEAL_SWAP)
                    + HistoryDealGetDouble(deal_id, DEAL_COMMISSION);
      }
   }
   if(latest>0){
      if(lastProfit<0){ g_consecLosses++; g_lastLossTime=latest; }
      else if(lastProfit>0){ g_consecLosses=0; }
   }
}

//============================= NEW UTILITIES ===============================

// Trim helpers
string TrimLeft(const string s){ string t=s; while(StringLen(t)>0 && (StringGetCharacter(t,0)==' ' || StringGetCharacter(t,0)=='\t')) t=StringSubstr(t,1); return t; }
string TrimRight(const string s){ string t=s; while(StringLen(t)>0){ int c=StringGetCharacter(t,StringLen(t)-1); if(c==' '||c=='\t'||c=='\r'||c=='\n') t=StringSubstr(t,0,StringLen(t)-1); else break; } return t; }
string Trim(const string s){ return TrimRight(TrimLeft(s)); }

// Get ATR in POINTS for given timeframe/period
double GetATR_Points(ENUM_TIMEFRAMES tf, int period){
   int h = iATR(_Symbol, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double b[]; int copied = CopyBuffer(h,0,1,1,b);
   IndicatorRelease(h);
   if(copied!=1) return 0.0;
   return b[0]/_Point;
}

// Current spread in points
int CurrentSpreadPoints(){
   double ask = 0.0, bid = 0.0;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_ASK, ask)) return INTMAX;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_BID, bid)) return INTMAX;
   return (int)MathRound((ask - bid)/_Point);
}

// Friday close / weekend open edge blocks (server time)
bool BlockedBySessionEdges(){
   if(!UseSessionFilter) return false;
   datetime now = TimeCurrent();
   MqlDateTime mt; TimeToStruct(now, mt);
   int dow = mt.day_of_week; // 0=Sun ... 5=Fri, 6=Sat
   int minuteOfDay = mt.hour*60 + mt.min;
   if(dow==5 && BlockFridayClose_Minutes>0){
      if(minuteOfDay >= (24*60 - BlockFridayClose_Minutes)) return true;
   }
   if(BlockWeekendGap_Minutes>0){
      if((dow==0 && minuteOfDay < BlockWeekendGap_Minutes) || (dow==1 && minuteOfDay < BlockWeekendGap_Minutes)) return true;
   }
   return false;
}

// Manual blackout windows parser: "YYYY-MM-DD HH:MM-HH:MM; ..."
bool IsInManualBlackout(){
   string s = Trim(BlackoutWindows);
   if(StringLen(s)<16) return false;
   string items[]; int n = StringSplit(s,';',items);
   if(n<=0) return false;
   datetime now = TimeCurrent();
   for(int i=0;i<n;i++){
      string rec = Trim(items[i]);
      if(StringLen(rec)<16) continue;
      int sp = StringFind(rec, " "); if(sp<0) continue;
      int dash = StringFind(rec, "-", sp+1); if(dash<0) continue;
      string datePart = StringSubstr(rec,0,sp);
      // Normalize date to YYYY.MM.DD for StringToTime
      for(int j=0;j<StringLen(datePart);j++){
         if(StringGetCharacter(datePart,j)=='-'){
            StringSetCharacter(datePart,j,'.');
         }
      }
      string t1 = StringSubstr(rec, sp+1, dash-sp-1);
      string t2 = StringSubstr(rec, dash+1);
      string s1 = datePart+" "+Trim(t1);
      string s2 = datePart+" "+Trim(t2);
      datetime d1 = StringToTime(s1);
      datetime d2 = StringToTime(s2);
      if(d1==0 || d2==0) continue;
      if(now>=d1 && now<=d2) return true;
   }
   return false;
}

// Account presets loader: sets effective limits only (does NOT overwrite user inputs)
void ApplyAccountPresets(){
   // Start from ORIGINAL inputs
   eff_MaxDailyLossPct_internal = MaxDailyLoss_Percent;
   eff_MaxTotalDDPct_internal   = MaxTotalDrawdown_Percent;
   eff_CloseAllIfDailyLossHit_internal = CloseAllIfDailyLossHit;

   if(AccountMode==Mode_Custom && PropPreset==Prop_Custom) return;

   double dDaily = eff_MaxDailyLossPct_internal;
   double dTotal = eff_MaxTotalDDPct_internal;
   bool   closeAll = eff_CloseAllIfDailyLossHit_internal;

   switch(AccountMode){
      case Mode_Normal:         dDaily=DBL_MAX; dTotal=DBL_MAX; closeAll=false; break;
      case Mode_Prop_Challenge: dDaily=5.0;     dTotal=10.0;    closeAll=true;  break;
      case Mode_Prop_Funded:    dDaily=5.0;     dTotal=10.0;    closeAll=true;  break;
      default: break;
   }
   switch(PropPreset){
      case Prop_FTMO_2025:       dDaily=5.0;  dTotal=10.0; closeAll=true;  break;
      case Prop_MFF_2025:        dDaily=5.0;  dTotal=12.0; closeAll=true;  break;
      case Prop_FundedNext_2025: dDaily=4.0;  dTotal=8.0;  closeAll=true;  break;
      default: break;
   }
   if(DailyLossBufferPct>0.0 && dDaily<DBL_MAX){
      dDaily = MathMax(0.0, dDaily - DailyLossBufferPct);
   }
   eff_MaxDailyLossPct_internal = dDaily;
   eff_MaxTotalDDPct_internal   = dTotal;
   eff_CloseAllIfDailyLossHit_internal = closeAll;

   if(VerboseLog){
      PrintFormat("[Presets] eff_MaxDailyLossPct=%.2f eff_MaxTotalDDPct=%.2f CloseAll=%s",
                  eff_MaxDailyLossPct_internal, eff_MaxTotalDDPct_internal, (eff_CloseAllIfDailyLossHit_internal?"true":"false"));
   }
}

// Cooldown helpers
bool CooldownAllows(const int dir){
   if(!UseSignalCooldown) return true;
   datetime now = TimeCurrent();
   if(dir>0){ if(g_lastSignalTimeBuy!=0 && (now - g_lastSignalTimeBuy) < (CooldownMinutes*60)) return false; }
   else      { if(g_lastSignalTimeSell!=0 && (now - g_lastSignalTimeSell)< (CooldownMinutes*60)) return false; }
   return true;
}
void MarkCooldown(const int dir){
   if(!UseSignalCooldown) return;
   datetime now = TimeCurrent();
   if(dir>0) g_lastSignalTimeBuy = now; else g_lastSignalTimeSell = now;
}

// Management: Break-Even
void ManageBreakEven(){
   if(!UseBreakEven) return;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket = PositionGetTicket(i); if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double price= PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);

      double atrPts = GetATR_Points(PERIOD_CURRENT, 14);
      if(atrPts<=0) continue;
      double beMovePts = BE_TriggerATR * atrPts;

      if(type==POSITION_TYPE_BUY){
         double bid; SymbolInfoDouble(_Symbol, SYMBOL_BID, bid);
         double favPts = (bid - price)/_Point;
         if(favPts >= beMovePts){
            double newSL = price + BE_LockPoints*_Point;
            if(sl < newSL){ Trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)); }
         }
      }else if(type==POSITION_TYPE_SELL){
         double ask; SymbolInfoDouble(_Symbol, SYMBOL_ASK, ask);
         double favPts = (price - ask)/_Point;
         if(favPts >= beMovePts){
            double newSL = price - BE_LockPoints*_Point;
            if(sl==0 || sl > newSL){ Trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)); }
         }
      }
   }
}

// Management: Partial TP (two levels by ATR)
void ManagePartialTP(){
   if(!UsePartialTP) return;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket = PositionGetTicket(i); if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double price= PositionGetDouble(POSITION_PRICE_OPEN);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double minLot, lotStep, maxLot; 
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN,minLot); 
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP,lotStep); 
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX,maxLot);
      double atrPts = GetATR_Points(PERIOD_CURRENT, 14); if(atrPts<=0) continue;

      double tp1Pts = Partial1_TPxATR * atrPts;
      double tp2Pts = Partial2_TPxATR * atrPts;

      double ask,bid; SymbolInfoDouble(_Symbol,SYMBOL_ASK,ask); SymbolInfoDouble(_Symbol,SYMBOL_BID,bid);

      bool needClose1=false, needClose2=false;
      if(type==POSITION_TYPE_BUY){
         double favPts = (bid - price)/_Point;
         needClose1 = (favPts >= tp1Pts && Partial1Pct>0);
         needClose2 = (favPts >= tp2Pts && Partial2Pct>0);
      }else if(type==POSITION_TYPE_SELL){
         double favPts = (price - ask)/_Point;
         needClose1 = (favPts >= tp1Pts && Partial1Pct>0);
         needClose2 = (favPts >= tp2Pts && Partial2Pct>0);
      }

      if(needClose1 && vol>minLot){
         double volClose = MathMax(minLot, MathFloor(vol*(Partial1Pct/100.0)/lotStep)*lotStep);
         if(volClose>0 && volClose<vol){ Trade.PositionClosePartial(ticket, volClose); }
      }
      if(needClose2 && vol>minLot){
         double volClose = MathMax(minLot, MathFloor(vol*(Partial2Pct/100.0)/lotStep)*lotStep);
         if(volClose>0 && volClose<vol){ Trade.PositionClosePartial(ticket, volClose); }
      }
   }
}

// Management: Trailing
void ManageTrailing(){
   if(TrailMode==Trail_None) return;
   double atrPts = GetATR_Points(PERIOD_CURRENT, TrailATRPeriod); if(atrPts<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket = PositionGetTicket(i); if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY){
         double bid; SymbolInfoDouble(_Symbol,SYMBOL_BID,bid);
         double trailPrice = 0.0;
         if(TrailMode==Trail_ATR){
            trailPrice = bid - TrailATRMult*atrPts*_Point;
         }else if(TrailMode==Trail_Chandelier){
            int bars = MathMax(14, TrailATRPeriod);
            int hi = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, bars, 1);
            double hh = (hi>=0? iHigh(_Symbol, PERIOD_CURRENT, hi):0.0);
            if(hh>0.0) trailPrice = hh - TrailATRMult*atrPts*_Point;
         }
         if(trailPrice>0.0 && (sl==0.0 || sl<trailPrice)) Trade.PositionModify(ticket, trailPrice, tp);
      }else if(type==POSITION_TYPE_SELL){
         double ask; SymbolInfoDouble(_Symbol,SYMBOL_ASK,ask);
         double trailPrice = 0.0;
         if(TrailMode==Trail_ATR){
            trailPrice = ask + TrailATRMult*atrPts*_Point;
         }else if(TrailMode==Trail_Chandelier){
            int bars = MathMax(14, TrailATRPeriod);
            int lo = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, bars, 1);
            double ll = (lo>=0? iLow(_Symbol, PERIOD_CURRENT, lo):0.0);
            if(ll>0.0) trailPrice = ll + TrailATRMult*atrPts*_Point;
         }
         if(trailPrice>0.0 && (sl==0.0 || sl>trailPrice)) Trade.PositionModify(ticket, trailPrice, tp);
      }
   }
}

// MTF EMA alignment filter; returns true if allowed
bool MTF_Aligned(const int dir){
   if(!UseMTFFilter) return true;
   int fH = iMA(_Symbol, MTFTimeframe, MTF_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   int sH = iMA(_Symbol, MTFTimeframe, MTF_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   if(fH==INVALID_HANDLE || sH==INVALID_HANDLE) return true; // fail-open
   double f[2], s[2];
   int cf = CopyBuffer(fH,0,1,1,f); int cs = CopyBuffer(sH,0,1,1,s);
   IndicatorRelease(fH); IndicatorRelease(sH);
   if(cf!=1 || cs!=1) return true;
   if(dir>0) return (f[0]>s[0]);
   if(dir<0) return (f[0]<s[0]);
   return true;
}

//=========================== LIFECYCLE ==============================
int OnInit(){
   if(!License_Init()) return(INIT_FAILED);

   ResetDailyEquityAnchor();
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   ApplyAccountPresets(); // sets effective internal limits based on mode/preset

   if(VerboseLog) Print("TG7 Init: Symbol=",_Symbol," TF=",EnumToString((ENUM_TIMEFRAMES)_Period),
                        " BaseRisk%=",DoubleToString(BaseRisk_Percent,2),
                        " MaxDD(day/total)=",DoubleToString(eff_MaxDailyLossPct_internal,1),"/",DoubleToString(eff_MaxTotalDDPct_internal,1));
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason){
  License_Deinit();
}

datetime last_bar_time=0;
void OnTick(){
   if(!License_Check()) return;

   // Only run once per bar for signal logic
   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur_bar == last_bar_time) return;
   last_bar_time = cur_bar;

   if(!CheckDailyAndTotalDD()) return;

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
      gotSignal = false;
   }

   if(gotSignal){
      if(CooldownAllows(dir)){
         PlaceTrade(dir, stop_pips, rr);
      }else if(VerboseLog){ Print("Cooldown active → skip entry"); }
   }

   ManageBreakEven();
   ManagePartialTP();
   ManageTrailing();

   UpdatePnLStatsOnTradeClose();
}
//+------------------------------------------------------------------+
