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
input long    MagicNumber                 = 7700772525;

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



// --- Multi-Asset Execution (stocks/indices/CFDs compatibility)
input bool    AllowSLTPInRequest          = true;   // if false, send market order without SL/TP then modify
input bool    FallbackSendWithoutSLTP     = true;   // fallback on broker rejections
input double  StopBufferPointsFactor      = 1.2;    // multiply broker stops level by this buffer

// --- Portfolio Risk Budget & Exposure Caps (A)
input double  DailyRiskBudget_Percent     = 0.80;   // risk to "spend" per day; pause when consumed
input double  MaxPortfolioOpenRisk_Pct    = 1.50;   // cap on total open risk (% of equity)
input double  MaxSymbolOpenRisk_Pct       = 0.80;   // cap per symbol open risk (% of equity)

// --- Multi-Symbol Scheduler & Resolver (B)
input bool    EnableMultiSymbolScan       = false;
input string  SymbolsCSV                  = "EURUSD,GBPUSD,US100,US500,DE30,XAUUSD,XTIUSD";
input string  PreferredSuffix             = "m";    // e.g., Exness
input ENUM_TIMEFRAMES ScanTF              = PERIOD_H1;
input int     ScanEverySeconds            = 10;

// --- Partial TP / BreakEven / Trailing (C)
input bool    EnablePartialTP             = false;
input double  TP1_R                       = 1.00;   // take partial at 1R
input double  TP1_ClosePct                = 0.50;   // close 50% at TP1
input bool    EnableBreakEven             = false;
input int     BE_BufferPoints             = 10;     // add a tiny buffer beyond entry
input bool    EnableHybridTrail           = false;  // max(ATR*k , EMA(period))
input double  Trail_ATR_Mult              = 2.0;
input int     Trail_EMA_Period            = 50;
// --- Execution Safety Upgrades
input int     MinBarsForIndicators        = 150;    // bars required before using indicators
input int     MaxSpreadPoints             = 50;     // skip if spread above this
input double  DailyProfitLock_Percent     = 4.0;    // pause trading for the day after +X% gain

// --- News Filter (stub by default)
input bool    UseNewsFilter                = false;  // set true when you implement calendar/file-based filter
input int     PreNewsBlock_Min             = 30;
input int     PostNewsBlock_Min            = 30;

//=========================== INTERNALS ==============================

//=========================== PORTFOLIO STATE ========================
double   g_dayRiskBudgetSpentPct = 0.0;       // consumed risk today
string   g_symbols[];                         // resolved symbols universe
datetime g_lastBarTimes[];                    // per-symbol last bar time for ScanTF

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


//------------------- Portfolio Risk Helpers ------------------------
double PipValuePerLot(const string sym){
   double tickValue=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   double tickSize=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0 || tickSize<=0 || tickValue<=0) return 0.0;
   return tickValue * (point / tickSize);
}
double ComputePositionRiskPct(const string sym, long magic){
   if(!PositionSelect(sym)) return 0.0;
   if((long)PositionGetInteger(POSITION_MAGIC)!=magic) return 0.0;
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   =PositionGetDouble(POSITION_SL);
   if(sl<=0) return 0.0; // unknown; treat as 0 to avoid blocking—SL is always set/modified by this EA
   double lots =PositionGetDouble(POSITION_VOLUME);
   long   type =(long)PositionGetInteger(POSITION_TYPE);
   double risk_points = (type==POSITION_TYPE_BUY)? (entry - sl) : (sl - entry);
   double risk_cash = MathMax(0.0, risk_points) * PipValuePerLot(sym) * lots;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0) return 0.0;
   return 100.0 * (risk_cash / eq);
}
double ComputeOpenRiskPercentTotal(long magic){
   double sum=0.0;
   for(int i=0;i<PositionsTotal();i++){
      ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=magic) continue;
      string s=PositionGetString(POSITION_SYMBOL);
      sum += ComputePositionRiskPct(s, magic);
   }
   return sum;
}
double ComputeOpenRiskPercentForSymbol(const string sym, long magic){
   double sum=0.0;
   for(int i=0;i<PositionsTotal();i++){
      ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
      sum += ComputePositionRiskPct(sym, magic);
   }
   return sum;
}
bool BudgetAndExposureAllow(const string sym, double incomingRiskPct, string &reason_out){
   // Daily risk budget gate
   if(g_dayRiskBudgetSpentPct + incomingRiskPct > DailyRiskBudget_Percent){
      reason_out="DailyRiskBudgetSpent"; return false;
   }
   // Exposure caps
   double totOpen = ComputeOpenRiskPercentTotal(MagicNumber);
   if(totOpen + incomingRiskPct > MaxPortfolioOpenRisk_Pct){ reason_out="PortfolioOpenRiskCap"; return false; }
   double symOpen = ComputeOpenRiskPercentForSymbol(sym, MagicNumber);
   if(symOpen + incomingRiskPct > MaxSymbolOpenRisk_Pct){ reason_out="SymbolOpenRiskCap"; return false; }
   reason_out=""; return true;
}
void BudgetConsume(double incomingRiskPct){ g_dayRiskBudgetSpentPct += incomingRiskPct; }

//------------------- Symbol Resolver (Broker-agnostic) --------------
void PushUnique(string &arr[], const string v)
  { for(int i=0;i<ArraySize(arr);i++) if(StringCompare(arr[i], v, true)==0) return; int n=ArraySize(arr); ArrayResize(arr, n+1); arr[n]=v; }
bool EndsWith(string s, string tail){ int ls=StringLen(s), lt=StringLen(tail); if(lt>ls) return false; return StringCompare(StringSubstr(s, ls-lt), tail, true)==0; }
bool StartsWith(string s, string head){ int ls=StringLen(s), lh=StringLen(head); if(lh>ls) return false; return StringCompare(StringSubstr(s, 0, lh), head, true)==0; }
string Normalize(string s){ string up=StringToUpper(s); StringReplace(up,".",""); StringReplace(up,"_",""); StringReplace(up,"-",""); StringReplace(up,"/",""); return up; }

string TrimBoth(string s){ StringTrimLeft(s); StringTrimRight(s); return s; }


void GetAliasesForBase(string base_in, string &aliases[])
  {
   string base = StringToUpper(base_in); PushUnique(aliases, base);
   if(base=="NAS100"||base=="USTEC"||base=="US100"||base=="NDX"){ string a[]={"NAS100","US100","USTEC","NDX","US100m","NAS100m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="US500"||base=="SPX500"||base=="SP500"||base=="SPX"){ string a[]={"US500","SPX500","SP500","SPX","US500m","SPX500m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="US30"||base=="DJ30"||base=="DOW"||base=="DJI"){ string a[]={"US30","DJ30","DOW","DJI","US30m","DJ30m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="GER40"||base=="DE40"||base=="DAX40"||base=="GER30"||base=="DE30"||base=="DAX"){ string a[]={"GER40","DE40","DAX40","GER30","DE30","DAX","GER40m","DE40m","GER30m","DE30m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="UK100"||base=="FTSE100"||base=="FTSE"){ string a[]={"UK100","FTSE100","FTSE","UK100m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="JP225"||base=="JPN225"||base=="NIKKEI"||base=="N225"){ string a[]={"JP225","JPN225","NIKKEI","N225","JP225m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="HK50"||base=="HSI"){ string a[]={"HK50","HSI","HK50m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="FRA40"||base=="CAC40"||base=="CAC"){ string a[]={"FRA40","CAC40","CAC","FRA40m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="ESP35"||base=="IBEX35"||base=="IBEX"){ string a[]={"ESP35","IBEX35","IBEX","ESP35m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="AUS200"||base=="ASX200"){ string a[]={"AUS200","ASX200","AUS200m"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="XAUUSD"||base=="GOLD"||base=="XAU"){ string a[]={"XAUUSD","GOLD","XAUUSDm"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="XAGUSD"||base=="SILVER"||base=="XAG"){ string a[]={"XAGUSD","SILVER","XAGUSDm"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="XTIUSD"||base=="USOIL"||base=="WTI"){ string a[]={"XTIUSD","USOIL","WTI","XTIUSDm"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
   if(base=="XBRUSD"||base=="UKOIL"||base=="BRENT"){ string a[]={"XBRUSD","UKOIL","BRENT","XBRUSDm"}; for(int i=0;i<ArraySize(a);i++) PushUnique(aliases,a[i]); }
  }

string ResolveSymbol(const string base_in)
  {
   string aliases[]; GetAliasesForBase(base_in, aliases);
   if(StringLen(PreferredSuffix)>0){
      int total=(int)SymbolsTotal(false);
      for(int i=0;i<total;i++){ string s=SymbolName(i,false);
         for(int k=0;k<ArraySize(aliases);k++){ string expect=aliases[k]+PreferredSuffix;
            if(StringCompare(s,expect,true)==0){ SymbolSelect(s,true); Print("[Resolver] ",base_in," -> ",s," (exact+suffix)"); return s; } } }
   }
   int total2=(int)SymbolsTotal(false);
   for(int i=0;i<total2;i++){ string s=SymbolName(i,false);
      for(int k=0;k<ArraySize(aliases);k++){ if(StringCompare(s,aliases[k],true)==0){ SymbolSelect(s,true); Print("[Resolver] ",base_in," -> ",s," (exact)"); return s; } } }
   // fuzzy
   string nb=Normalize(base_in);
   string best="";
   for(int i=0;i<total2;i++){ string s=SymbolName(i,false); string ns=Normalize(s);
      bool hit=(StringFind(ns,nb)>=0);
      if(!hit){ for(int k=0;k<ArraySize(aliases);k++){ string na=Normalize(aliases[k]); if(StringFind(ns,na)>=0||EndsWith(ns,na)||StartsWith(ns,na)){ hit=true; break; } } }
      if(hit){ if(StringLen(PreferredSuffix)>0 && EndsWith(s,PreferredSuffix)){ SymbolSelect(s,true); Print("[Resolver] ",base_in," -> ",s," (fuzzy+suffix)"); return s; }
               if(best=="") best=s; }
   }
   if(best!=""){ SymbolSelect(best,true); Print("[Resolver] ",base_in," -> ",best," (fuzzy)"); return best; }
   // visible fallback
   int selected=(int)SymbolsTotal(true); best="";
   for(int i=0;i<selected;i++){ string s=SymbolName(i,true); string ns=Normalize(s);
      if(StringFind(ns,nb)>=0){ if(StringLen(PreferredSuffix)>0 && EndsWith(s,PreferredSuffix)){ Print("[Resolver] ",base_in," -> ",s," (visible+suffix)"); return s; }
         if(best=="") best=s; } }
   if(best!=""){ Print("[Resolver] ",base_in," -> ",best," (visible)"); return best; }
   Print("[Resolver] Could not resolve base symbol: ", base_in); return "";
  }

int ResolveListCSV(const string csv, string &resolved_out[])
  {
   string parts[]; int n=StringSplit(csv, ',', parts);
   ArrayResize(resolved_out, 0);
   for(int i=0;i<n;i++){ string base=TrimBoth(parts[i]); if(base=="") continue;
      string s=ResolveSymbol(base); if(s!=""){ int sz=ArraySize(resolved_out); ArrayResize(resolved_out, sz+1); resolved_out[sz]=s; } }
   return ArraySize(resolved_out);
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



//------------------- Multi-Symbol Signals ---------------------------
double GetATR_S(string sym, int period, ENUM_TIMEFRAMES tf, int shift){
   int h = iATR(sym, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}
double GetEMA_S(string sym, int period, ENUM_TIMEFRAMES tf, int shift){
   int h = iMA(sym, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}
double GetRSI_S(string sym, int period, ENUM_TIMEFRAMES tf, int shift){
   int h = iRSI(sym, tf, period, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v = buf[0]; IndicatorRelease(h); return v;
}
void GetBBands_S(string sym, int period, double dev, ENUM_TIMEFRAMES tf, int shift, double &upper, double &middle, double &lower){
   if(!SeriesReady(sym, tf, MinBarsForIndicators)){ upper=middle=lower=0.0; return; }
   int h = iBands(sym, tf, period, dev, 0, PRICE_CLOSE);
   if(h==INVALID_HANDLE){ upper=middle=lower=0.0; return; }
   double u[1], m[1], l[1];
   if(CopyBuffer(h,0,shift,1,u)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   if(CopyBuffer(h,1,shift,1,m)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   if(CopyBuffer(h,2,shift,1,l)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   upper=u[0]; middle=m[0]; lower=l[0]; IndicatorRelease(h);
}

bool TrendSignal_S(string sym, ENUM_TIMEFRAMES tf, int &dir, double &stop_pips){
   dir=0; stop_pips=0.0;
   if(!SeriesReady(sym, tf, MinBarsForIndicators)) return false;
   double emaFast0 = GetEMA_S(sym, TF_EMA_Fast, tf, 0);
   double emaSlow0 = GetEMA_S(sym, TF_EMA_Slow, tf, 0);
   if(emaFast0==0 || emaSlow0==0) return false;
   double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);
   double point= SymbolInfoDouble(sym, SYMBOL_POINT);
   double atr  = GetATR_S(sym, ATR_Period, tf, 0);
   if(emaFast0>emaSlow0 && bid>emaFast0) dir=1;
   if(emaFast0<emaSlow0 && ask<emaFast0) dir=-1;
   if(dir==0) return false;
   double stop_dist = TF_StopATR_Mult * atr;
   stop_pips = stop_dist/point;
   return true;
}

bool MRSignal_S(string sym, ENUM_TIMEFRAMES tf, int &dir, double &stop_pips){
   dir=0; stop_pips=0.0;
   if(!SeriesReady(sym, tf, MinBarsForIndicators)) return false;
   double rsi0 = GetRSI_S(sym, MR_RSI_Period, tf, 0);
   double up, mid, lo; GetBBands_S(sym, MR_BB_Period, MR_BB_Dev, tf, 0, up, mid, lo);
   if(rsi0==0 || up==0 || lo==0) return false;
   double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);
   double point= SymbolInfoDouble(sym, SYMBOL_POINT);
   double atr  = GetATR_S(sym, ATR_Period, tf, 0);
   if(rsi0<=MR_RSI_BuyLevel && bid<=lo) dir=1;
   if(rsi0>=MR_RSI_SellLevel && ask>=up) dir=-1;
   if(dir==0) return false;
   double stop_dist = MR_StopATR_Mult * atr;
   stop_pips = stop_dist/point;
   return true;
}


bool WithinMaxPositionsSym(const string sym){
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++){
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetString(POSITION_SYMBOL)==sym) cnt++;
   }
   return (cnt<MaxOpenPositionsPerSymbol);
}

bool PlaceTradeSym(const string sym, int dir, double stop_pips, double rr_tp){
   if(!WithinMaxPositionsSym(sym)) return false;

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double price = (dir>0)? SymbolInfoDouble(sym,SYMBOL_ASK) : SymbolInfoDouble(sym,SYMBOL_BID);
   double sl=0.0, tp=0.0;
   double stop_dist_points = stop_pips * point;
   if(dir>0){ sl = price - stop_dist_points; tp = price + (rr_tp * stop_dist_points); }
   else     { sl = price + stop_dist_points; tp = price - (rr_tp * stop_dist_points); }

   // Enforce broker stops + spread gate
   long stopsLvl = (long)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopPoints = (double)stopsLvl;
   if(minStopPoints>0 && stop_dist_points < minStopPoints*point) stop_dist_points = minStopPoints*point;
   double spreadPts = (SymbolInfoDouble(sym,SYMBOL_ASK) - SymbolInfoDouble(sym,SYMBOL_BID)) / point;
   if(spreadPts > MaxSpreadPoints){ if(VerboseLog) Print("TG7: Spread too high @", sym, " sp=", spreadPts); return false; }

   // Effective risk
   double sessMult=1.0; if(!SessionOkayAndSizeMult(sessMult)) return false;
   if(IsBlockedByNewsStub()) return false;
   if(!CheckDailyAndTotalDD()) return false;
   double dowMult = GetDoWSizeMult();
   double effRisk = BaseRisk_Percent * sessMult * dowMult;

   // Portfolio gates
   string reason;
   if(!BudgetAndExposureAllow(sym, effRisk, reason)){ if(VerboseLog) Print("TG7: Portfolio gate blocked: ", reason); return false; }

   double lots = CalcLotByRisk_S(sym, stop_pips, effRisk);
   if(lots<=0){ if(VerboseLog) Print("TG7: Lots<=0 @", sym); return false; }

   // Build comment with initial risk points (RPTS)
   int rpts = (int)MathRound(stop_dist_points/point);
   string cmt = "TG7 RPTS="+IntegerToString(rpts);

   // Normalize lots & ensure stop distance
   sl = EnsureStopDistance(sym, price, sl, (dir>0));

   bool ok = TryPlaceMarket(sym, dir, lots, sl, tp, cmt);
   if(!ok){ if(VerboseLog) Print("TG7: Send fail @", sym, " ret=", Trade.ResultRetcode()); return false; }

   // Consume risk budget on successful send
   BudgetConsume(effRisk);

   if(VerboseLog) Print("TG7: Sent ", (dir>0?"BUY":"SELL"), " ", sym, " lots=", DoubleToString(lots,2),
                        " stop_pips=", DoubleToString(stop_pips,1), " RR=", rr_tp, " effRisk%=", DoubleToString(effRisk,2));
   return true;
}

//------------------- Risk & Execution -------------------------------

double CalcLotByRisk_S(const string sym, double stop_pips, double risk_percent){
   if(stop_pips<=0) return 0.0;
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * (risk_percent/100.0);
   double tickValue= SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double point    = SymbolInfoDouble(sym,SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0 || tickSize<=0 || tickValue<=0) return 0.0;
   double pipValuePerLot = tickValue * (point / tickSize);
   double lots = riskCash / (stop_pips * pipValuePerLot);
   double minLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   if(step>0) lots = MathFloor(lots/step)*step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}
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



//------------------- Multi-Asset Helpers ---------------------------
double NormalizeLots(string sym, double lots){
   double minLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   if(step>0) lots = MathFloor(lots/step)*step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}
double EnsureStopDistance(string sym, double price, double sl, bool isBuy){
   // Enforce minimum stop distance using broker's stops level (+ buffer)
   long stopsLvlPts = (long)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minDist = (double)stopsLvlPts * point * StopBufferPointsFactor;
   if(minDist<=0) return sl;
   if(isBuy){
      if((price - sl) < minDist) sl = price - minDist;
   }else{
      if((sl - price) < minDist) sl = price + minDist;
   }
   return sl;
}
bool ModifySLTPAfterFill(string sym, double sl, double tp){
   if(!PositionSelect(sym)) return false;
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   if(MathIsValidNumber(sl) && sl>0 && MathAbs(sl-curSL) > SymbolInfoDouble(sym,SYMBOL_POINT)/2.0)
      if(!Trade.PositionModify(sym, sl, curTP)) return false;
   if(MathIsValidNumber(tp) && tp>0 && MathAbs(tp-curTP) > SymbolInfoDouble(sym,SYMBOL_POINT)/2.0)
      if(!Trade.PositionModify(sym, PositionGetDouble(POSITION_SL), tp)) return false;
   return true;
}
bool TryPlaceMarket(const string sym, int dir, double lots, double sl, double tp, const string cmt){
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(SlippagePoints);
   bool wantSLTP = AllowSLTPInRequest;
   bool ok=false;

   double price_buy = SymbolInfoDouble(sym,SYMBOL_ASK);
   double price_sell= SymbolInfoDouble(sym,SYMBOL_BID);
   if(dir>0){
      if(wantSLTP) ok = Trade.Buy(lots, sym, 0.0, sl, tp, cmt);
      else         ok = Trade.Buy(lots, sym, 0.0, 0.0, 0.0, cmt);
   }else{
      if(wantSLTP) ok = Trade.Sell(lots, sym, 0.0, sl, tp, cmt);
      else         ok = Trade.Sell(lots, sym, 0.0, 0.0, 0.0, cmt);
   }
   if(ok) return true;

   // Fallback on typical rejections (stocks/CFDs may forbid SL/TP in request)
   long rc = (long)Trade.ResultRetcode();
   if(FallbackSendWithoutSLTP && (rc==TRADE_RETCODE_INVALID_STOPS || rc==TRADE_RETCODE_REQUOTE || rc==TRADE_RETCODE_PRICE_OFF || rc==TRADE_RETCODE_MARKET_CLOSED || rc==TRADE_RETCODE_INVALID_PRICE)){
      if(VerboseLog) Print("TG7: Fallback send without SL/TP due to retcode=", rc);
      if(dir>0) ok = Trade.Buy(lots, sym, 0.0, 0.0, 0.0, "TG7");
      else      ok = Trade.Sell(lots, sym, 0.0, 0.0, 0.0, "TG7");
      if(!ok) return false;
      // attempt to set SL/TP after fill
      Sleep(50);
      ModifySLTPAfterFill(sym, sl, tp);
      return true;
   }
   return false;
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
   // Multi-symbol resolver & timer
   if(EnableMultiSymbolScan){
      int n=ResolveListCSV(SymbolsCSV, g_symbols);
      ArrayResize(g_lastBarTimes, n); for(int i=0;i<n;i++){ g_lastBarTimes[i]=0; PrimeHistory(g_symbols[i], ScanTF, 200); }
      EventSetTimer(ScanEverySeconds);
      Print("TG7 Init: Multi-symbol scan ENABLED. Resolved ", n, " symbols.");
   }else{
      EventKillTimer();
   }


   if(VerboseLog) Print("TG7 Init: Symbol=",_Symbol," TF=",EnumToString((ENUM_TIMEFRAMES)_Period),
                        " BaseRisk%=",DoubleToString(BaseRisk_Percent,2),
                        " MaxDD(day/total)=",DoubleToString(MaxDailyLoss_Percent,1),"/",DoubleToString(MaxTotalDrawdown_Percent,1));
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason){}

datetime last_bar_time=0;
void OnTick(){
   if(EnableMultiSymbolScan) return; // scanning handled by OnTimer
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

void OnTimer(){
   if(!EnableMultiSymbolScan) return;
   // Portfolio check: reset daily anchor/budget when day rolls
   datetime curDay = iTime(_Symbol,PERIOD_D1,0);
   if(curDay!=g_dayStart){ ResetDailyEquityAnchor(); g_dayRiskBudgetSpentPct=0.0; }

   for(int i=0;i<ArraySize(g_symbols);i++){
      string s = g_symbols[i];
      if(!SeriesReady(s, ScanTF, MinBarsForIndicators)) continue;
      datetime bar = iTime(s, ScanTF, 0);
      if(bar==g_lastBarTimes[i]){ continue; }
      g_lastBarTimes[i]=bar;

      // Determine regime on scan TF (reuse your DetectRegime logic approximated for s)
      int dir=0; double stop_pips=0.0; bool got=false; double rr=1.5;
      double adx = GetADX(ADX_Period, ScanTF, 0); // using chart _Symbol version might mismatch; safe fallback is to use S variants where available
      // Choose signals based on your inputs (trend or MR)
      Regime regime = DetectRegime(); // uses chart symbol/timeframe; for brevity, we pick signals directly for s:
      if(TrendSignal_S(s, ScanTF, dir, stop_pips)){ rr = TF_TakeProfit_RR; got=true; }
      else if(MRSignal_S(s, ScanTF, dir, stop_pips)){ rr = MR_TakeProfit_RR; got=true; }
      if(got){ PlaceTradeSym(s, dir, stop_pips, rr); }

      // Manage open positions (partial TP/BE/trailing)
      ManagePositionsSym(s, ScanTF);
   }
}



void ManagePositionsSym(const string sym, ENUM_TIMEFRAMES tf){
   if(!(EnablePartialTP||EnableBreakEven||EnableHybridTrail)) return;
   if(!PositionSelect(sym)) return;
   if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) return;

   long   type  = (long)PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   double lots  = PositionGetDouble(POSITION_VOLUME);
   string cmt   = PositionGetString(POSITION_COMMENT);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   // Parse RPTS from comment
   int rpos = StringFind(cmt, "RPTS=");
   int rpts = 0;
   if(rpos>=0){ string sub = StringSubstr(cmt, rpos+5); rpts = (int)StringToInteger(sub); }
   if(rpts<=0){ // fall back: estimate from current SL
      if(sl>0){ double risk_points = (type==POSITION_TYPE_BUY)? (entry-sl):(sl-entry); rpts = (int)MathRound(risk_points/point); }
   }
   if(rpts<=0) return;

   double price = (type==POSITION_TYPE_BUY)? SymbolInfoDouble(sym,SYMBOL_BID):SymbolInfoDouble(sym,SYMBOL_ASK);
   double move_points = (type==POSITION_TYPE_BUY)? (price-entry):(entry-price);

   // A) Partial TP & BreakEven
   if(EnablePartialTP && move_points >= TP1_R * rpts){
      // partial close once (idempotent guard: check lot reduction vs initial; we can't know initial, so check >= 1.1*minLot difference)
      double minLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
      double closeLots = MathMax(minLot, lots*TP1_ClosePct);
      // close a chunk
      Trade.PositionClosePartial(sym, closeLots);
      // move to BE+buffer if enabled
      if(EnableBreakEven){
         double be = (type==POSITION_TYPE_BUY)? (entry + BE_BufferPoints*point):(entry - BE_BufferPoints*point);
         Trade.PositionModify(sym, be, tp);
      }
   }else if(EnableBreakEven && move_points >= (1.0 * rpts)){ // BE without partial
      double be = (type==POSITION_TYPE_BUY)? (entry + BE_BufferPoints*point):(entry - BE_BufferPoints*point);
      // Only bump if improves stop in right direction
      if((type==POSITION_TYPE_BUY && (sl==0 || be>sl)) || (type==POSITION_TYPE_SELL && (sl==0 || be<sl)))
         Trade.PositionModify(sym, be, tp);
   }

   // B) Hybrid Trailing: max(ATR*k, EMA(period)) as stop reference
   if(EnableHybridTrail){
      double atr = GetATR_S(sym, ATR_Period, tf, 0);
      double ema = GetEMA_S(sym, Trail_EMA_Period, tf, 0);
      if(atr>0 && ema>0){
         double trail_dist = Trail_ATR_Mult * atr;
         double newSL = sl;
         if(type==POSITION_TYPE_BUY){
            double cand = MathMax(ema, price - trail_dist);
            newSL = MathMax(sl, cand);
            if(newSL>sl && newSL<price) Trade.PositionModify(sym, newSL, tp);
         }else{
            double cand = MathMin(ema, price + trail_dist);
            newSL = MathMin(sl==0? 1e9:sl, cand);
            if((sl==0 || newSL<sl) && newSL>0 && newSL>price) Trade.PositionModify(sym, newSL, tp);
         }
      }
   }
}

