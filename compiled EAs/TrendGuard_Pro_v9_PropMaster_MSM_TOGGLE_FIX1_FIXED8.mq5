//+------------------------------------------------------------------+
//|                  TrendGuard Pro v9 - PropMaster MSM              |
//|        Single-chart Multi-Symbol Manager + Prop/Retail toggle    |
//|        EURUSD, GBPUSD, XAUUSD, NAS100, BTCUSD (configurable)     |
//|        2025-09 - Warning-Free Build (MT5)                        |
//+------------------------------------------------------------------+
#property copyright   "TrendGuard"
#property link        "https://example.com"
#property version     "9.0"
#property strict
#property description "Single EA instance manages multiple symbols with portfolio-level guardrails."

#include <Trade/Trade.mqh>
CTrade Trade;

//============================= INPUTS ===============================
input long    MagicNumber                       = 990001;

// --- Symbols & engine
input string  SymbolsCSV                        = "EURUSD,GBPUSD,XAUUSD,NAS100,BTCUSD";
input ENUM_TIMEFRAMES WorkingTF                 = PERIOD_H1;
input int     PollSeconds                       = 5;          // OnTimer cadence (sec)

// --- Risk & guardrails (prop friendly)
input double  BaseRisk_Percent                  = 0.30;       // % equity risk per trade
input double  MaxDailyLoss_Percent              = 4.5;        // from day's start equity
input double  MaxTotalDrawdown_Percent          = 9.0;        // from peak equity
input int     MaxConsecutiveLosses              = 6;          // pause after N losses
input int     CooldownMinutesAfterLoss          = 30;         // pause after loss
input int     MaxOpenPositionsPerSymbol         = 1;          // cap stacking per symbol
input int     MaxOpenPositionsTotal             = 5;          // cap across portfolio
input double  MaxPortfolioRisk_Percent          = 1.20;       // cap total active % risk
input bool    CloseAllIfDailyLossHit            = true;       // auto-close when day loss hit

// --- Sessions (GMT-based windowing)
enum BrokerGMTOffsetEnum {
   GMT_Minus_12=-12,GMT_Minus_11=-11,GMT_Minus_10=-10,GMT_Minus_9=-9,
   GMT_Minus_8=-8,  GMT_Minus_7=-7,  GMT_Minus_6=-6,  GMT_Minus_5=-5,
   GMT_Minus_4=-4,  GMT_Minus_3=-3,  GMT_Minus_2=-2,  GMT_Minus_1=-1,
   GMT_0=0,         GMT_Plus_1=1,    GMT_Plus_2=2,    GMT_Plus_3=3,
   GMT_Plus_4=4,    GMT_Plus_5=5,    GMT_Plus_6=6,    GMT_Plus_7=7,
   GMT_Plus_8=8,    GMT_Plus_9=9,    GMT_Plus_10=10,  GMT_Plus_11=11,
   GMT_Plus_12=12
};
input BrokerGMTOffsetEnum BrokerGMTOffsetHours   = GMT_0;
input bool    UseSessionFilter                   = true;
input bool    UseTokyoSession                    = false;
input string  TokyoStartHHMM                     = "00:00";
input string  TokyoEndHHMM                       = "08:00";
input bool    UseLondonSession                   = true;
input string  LondonStartHHMM                    = "07:00";
input string  LondonEndHHMM                      = "16:00";
input bool    UseNewYorkSession                  = true;
input string  NewYorkStartHHMM                   = "12:30";
input string  NewYorkEndHHMM                     = "21:00";
input bool    AllowLondonNYOverlapBoost          = true;
input double  Overlap_SizeMultiplier             = 1.25;

// --- Day-of-week size modulation
input bool    UseDayOfWeekOptimizer              = true;
input double  Monday_SizeMult                    = 0.85;
input double  Tuesday_SizeMult                   = 1.05;
input double  Wednesday_SizeMult                 = 1.00;
input double  Thursday_SizeMult                  = 0.95;
input double  Friday_SizeMult                    = 0.85;

// --- Regime & indicators
input int     ADX_Period                         = 14;
input int     ADX_TrendThreshold                 = 25;        // >= trend
input int     ADX_RangeThreshold                 = 20;        // <= range
input int     ATR_Period                         = 14;

// Trend-following
input int     TF_EMA_Fast                        = 50;
input int     TF_EMA_Slow                        = 200;
input double  TF_StopATR_Mult                    = 2.0;
input double  TF_TakeProfit_RR                   = 1.8;

// Mean-reversion
input int     MR_RSI_Period                      = 14;
input int     MR_RSI_BuyLevel                    = 30;
input int     MR_RSI_SellLevel                   = 70;
input int     MR_BB_Period                       = 20;
input double  MR_BB_Dev                          = 2.0;
input double  MR_StopATR_Mult                    = 1.8;
input double  MR_TakeProfit_RR                   = 1.2;

// Execution & slippage
input int     SlippagePoints_FX                  = 8;
input int     SlippagePoints_Metals              = 20;
input int     SlippagePoints_Indices             = 50;
input int     SlippagePoints_Crypto              = 100;

// Correlation
input bool    UseCorrelationBlock                = true;
input bool    CorrelateUSDQuotes                 = true;

// UI / logging
input bool    VerboseLog                         = true;
input bool    DebugMode                          = false;
input bool    ShowDashboard                      = true;
input int     EquityCurveLookback                = 20;

// --- Trading mode toggle
enum ModeType { PROP_MODE=0, RETAIL_MODE=1 };
input ModeType TradingMode = PROP_MODE;

//=========================== INTERNALS ==============================
datetime  g_dayStart=0;
double    g_dayStartEquity=0.0;
double    g_peakEquity=0.0;
int       g_consecLosses=0;
datetime  g_lastLossTime=0;

string    g_symbols[];
datetime  g_lastBarTime[];

double    g_equityHistory[];
int       g_eqIndex=0;
double    g_equityMA=0.0;

//------------------- Utilities -------------------------------------
int ParseHHMM(const string hhmm){
   int h=(int)StringToInteger(StringSubstr(hhmm,0,2));
   int m=(int)StringToInteger(StringSubstr(hhmm,3,2));
   return h*60+m;
}
// Warning-free: int-only arithmetic
int ServerTimeToGMTMinutes(datetime t){
   MqlDateTime st; 
   TimeToStruct(t,st);
   int minutes = ((int)st.hour - (int)BrokerGMTOffsetHours) * 60 + (int)st.min;
   while(minutes<0) minutes+=1440;
   while(minutes>=1440) minutes-=1440;
   return minutes;
}
bool InWindow(int nowMin,int startMin,int endMin){
   if(startMin<=endMin) return (nowMin>=startMin && nowMin<endMin);
   return (nowMin>=startMin || nowMin<endMin);
}
void ResetDailyEquityAnchor(){
   g_dayStart = iTime(_Symbol, PERIOD_D1, 0);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity = g_dayStartEquity;
}
double GetDoWSizeMult(){
   if(!UseDayOfWeekOptimizer) return 1.0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int dow = dt.day_of_week;
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
   int nowGMT=ServerTimeToGMTMinutes(TimeCurrent());
   int tks=ParseHHMM(TokyoStartHHMM);
   int tke=ParseHHMM(TokyoEndHHMM);
   int lns=ParseHHMM(LondonStartHHMM);
   int lne=ParseHHMM(LondonEndHHMM);
   int nys=ParseHHMM(NewYorkStartHHMM);
   int nye=ParseHHMM(NewYorkEndHHMM);
   bool tok=UseTokyoSession && InWindow(nowGMT,tks,tke);
   bool lon=UseLondonSession&& InWindow(nowGMT,lns,lne);
   bool ny =UseNewYorkSession&&InWindow(nowGMT,nys,nye);
   if(!(tok||lon||ny)){
      if(VerboseLog) Print("TG9: Outside sessions");
      return false;
   }
   if(tok) mult_out*=0.60;
   if(lon) mult_out*=1.00;
   if(ny)  mult_out*=1.00;
   if(AllowLondonNYOverlapBoost && lon && ny) mult_out*=Overlap_SizeMultiplier;

   if(DebugMode){
      string dbg = StringFormat("TG9 Debug Session: tok=%d lon=%d ny=%d mult=%.2f",
                                (int)tok,(int)lon,(int)ny,mult_out);
      Print(dbg);
   }
   return true;
}
void UpdateEquityCurve(){
   int N=MathMax(1,EquityCurveLookback);
   if(ArraySize(g_equityHistory)!=N){
      ArrayResize(g_equityHistory,N);
      for(int i=0;i<N;i++) g_equityHistory[i]=AccountInfoDouble(ACCOUNT_EQUITY);
      g_eqIndex=0;
   }
   g_equityHistory[g_eqIndex]=AccountInfoDouble(ACCOUNT_EQUITY);
   g_eqIndex=(g_eqIndex+1)%N;
   double sum=0.0;
   for(int i=0;i<N;i++) sum+=g_equityHistory[i];
   g_equityMA=sum/N;
}


//---------------- Symbol resolution & series readiness --------------
// ===================== Robust Symbol Resolver & Aliases =====================
// Expands matching to handle broker prefixes/suffixes (e.g., "m.EURUSD", "EURUSDm")
// and maps common index/metal/energy/crypto aliases (e.g., "NAS100" -> "US100"/"USTEC").
string ArrayJoin(const string &arr[], const string sep)
  {
   string out="";
   for(int i=0;i<ArraySize(arr);i++)
     {
      if(i>0) out+=sep;
      out+=arr[i];
     }
   return out;
  }

void PushUnique(string &arr[], const string v)
  {
   for(int i=0;i<ArraySize(arr);i++) if(StringCompare(arr[i], v, true)==0) return;
   int n=ArraySize(arr);
   ArrayResize(arr, n+1);
   arr[n]=v;
  }

void GetAliasesForBase(string base_in, string &aliases[])
  {
   string base=StringToUpper(base_in);
   // Always include the base itself
   PushUnique(aliases, base);

   // ------ Indices ------
   if(base=="NAS100" || base=="USTEC" || base=="US100" || base=="NDX" || base=="NASDAQ100")
     {
      string a[]={"NAS100","US100","USTEC","NDX","NASDAQ100","NAS100.cash","US100.cash","USTEC.cash","NAS100m","US100m","USTECm","USTECH","USTECH100","TEC100"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
   if(base=="US500" || base=="SPX500" || base=="SP500" || base=="S&P500" || base=="SPX")
     {
      string a[]={"US500","SPX500","SP500","SPX","US500.cash","SPX500.cash","US500m","SPX500m","USA500","US500.i"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
   if(base=="US30" || base=="DJ30" || base=="DOW" || base=="DJI")
     {
      string a[]={"US30","DJ30","DOW","DJI","US30.cash","US30m","DJI30","DJ30m"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
   if(base=="GER40" || base=="DE40" || base=="DAX40" || base=="GER30" || base=="DE30" || base=="DAX")
     {
      string a[]={"GER40","DE40","DAX40","GER30","DE30","DAX","GER40.cash","DE40.cash","GER40m","DE40m"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
   if(base=="UK100" || base=="FTSE100" || base=="FTSE")
     {
      string a[]={"UK100","FTSE100","FTSE","UK100.cash","UK100m"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }

   // ------ Metals ------
   if(base=="XAUUSD" || base=="GOLD" || base=="XAU")
     {
      string a[]={"XAUUSD","GOLD","XAUUSDm","XAUUSD.cash","GOLDm","XAUUSD.i"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
   if(base=="XAGUSD" || base=="SILVER" || base=="XAG")
     {
      string a[]={"XAGUSD","SILVER","XAGUSDm","XAGUSD.cash","SILVERm","XAGUSD.i"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }

   // ------ Energy ------
   if(base=="XTIUSD" || base=="USOIL" || base=="WTI" || base=="OIL")
     {
      string a[]={"XTIUSD","USOIL","WTI","OIL","USOIL.cash","XTIUSDm"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
   if(base=="XBRUSD" || base=="UKOIL" || base=="BRENT")
     {
      string a[]={"XBRUSD","UKOIL","BRENT","UKOIL.cash","XBRUSDm"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }

   // ------ Crypto (common CFD names) ------
   if(base=="BTCUSD" || base=="BTCUSDT" || base=="BTC")
     {
      string a[]={"BTCUSD","BTCUSDT","BTCUSDm","BTCUSD.r","BTCUSD.cash"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
   if(base=="ETHUSD" || base=="ETHUSDT" || base=="ETH")
     {
      string a[]={"ETHUSD","ETHUSDT","ETHUSDm","ETHUSD.r","ETHUSD.cash"};
      for(int i=0;i<ArraySize(a);i++) PushUnique(aliases, a[i]);
     }
  }

bool EndsWith(const string s, const string tail)
  {
   int ls=StringLen(s), lt=StringLen(tail);
   if(lt>ls) return false;
   return StringCompare(StringSubstr(s, ls-lt), tail, true)==0;
  }

bool StartsWith(const string s, const string head)
  {
   int ls=StringLen(s), lh=StringLen(head);
   if(lh>ls) return false;
   return StringCompare(StringSubstr(s, 0, lh), head, true)==0;
  }

string Normalize(string s)
  {
   string up=StringToUpper(s);
   // remove common punctuation used in cash/margin variants
   StringReplace(up,".","");
   StringReplace(up,"_","");
   StringReplace(up,"-","");
   StringReplace(up,"/","");
   return up;
  }

string ResolveSymbol(const string base_in)
  {
   string aliases[]; GetAliasesForBase(base_in, aliases);
   // Also consider raw base without punctuation
   string norm_base = Normalize(base_in);

   // First pass: exact symbol match (case-insensitive) for any alias
   int total_all = (int)SymbolsTotal(false);
   for(int i=0;i<total_all;i++)
     {
      string sym = SymbolName(i,false);
      for(int k=0;k<ArraySize(aliases);k++)
        {
         if(StringCompare(sym, aliases[k], true)==0)
           {
            SymbolSelect(sym,true);
            return sym;
           }
        }
     }

   // Second pass: substring / prefix / suffix match including prefixes like "m." and suffixes like "m" or ".pro"
   for(int i=0;i<total_all;i++)
     {
      string sym = SymbolName(i,false);
      string ns = Normalize(sym);
      // if NS contains norm_base anywhere
      if(StringFind(ns, Normalize(aliases[0]))>=0 || StringFind(ns, norm_base)>=0)
        {
         SymbolSelect(sym,true);
         return sym;
        }
      // match any alias by containment too
      for(int k=0;k<ArraySize(aliases);k++)
        {
         string na = Normalize(aliases[k]);
         if(StringFind(ns, na)>=0 || EndsWith(ns, na) || StartsWith(ns, na))
           {
            SymbolSelect(sym,true);
            return sym;
           }
        }
     }

   // Third pass: prioritize visible symbols (Market Watch) with looser matching
   int total_sel = (int)SymbolsTotal(true);
   for(int i=0;i<total_sel;i++)
     {
      string sym = SymbolName(i,true);
      string ns = Normalize(sym);
      if(StringFind(ns, norm_base)>=0)
        {
         SymbolSelect(sym,true);
         return sym;
        }
     }

   // No match
   return "";
  }

bool PrimeHistory(const string sym, ENUM_TIMEFRAMES tf, int need=300)
  {
   MqlRates rates[];
   int tries=0;
   while(tries<10)
     {
      int got = CopyRates(sym, tf, 0, need, rates);
      if(got>=MathMin(need,50)) return true;
      Sleep(50);
      tries++;
     }
   return false;
  }
// =================== End Robust Symbol Resolver & Aliases ====================


bool SeriesReady(const string sym, ENUM_TIMEFRAMES tf, int min_bars=50){
   if(sym=="") return false;
   long synced=0;
   if(!SeriesInfoInteger(sym, tf, SERIES_SYNCHRONIZED, synced)) return false;
   if(synced==0) return false;
   int bars = Bars(sym, tf);
   if(bars<min_bars) return false;
   return true;
}
//---------------- Indicators ---------------------------------------
double GetATR(const string sym,ENUM_TIMEFRAMES tf,int period,int shift){
   if(!SeriesReady(sym,tf)) return 0.0;
   int h=iATR(sym,tf,period); if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v=buf[0]; IndicatorRelease(h); return v;
}
double GetADX(const string sym,ENUM_TIMEFRAMES tf,int period,int shift){
   if(!SeriesReady(sym,tf)) return 0.0;
   int h=iADX(sym,tf,period); if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v=buf[0]; IndicatorRelease(h); return v;
}
double GetEMA(const string sym,ENUM_TIMEFRAMES tf,int period,int shift){
   if(!SeriesReady(sym,tf)) return 0.0;
   int h=iMA(sym,tf,period,0,MODE_EMA,PRICE_CLOSE); if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v=buf[0]; IndicatorRelease(h); return v;
}
double GetRSI(const string sym,ENUM_TIMEFRAMES tf,int period,int shift){
   if(!SeriesReady(sym,tf)) return 0.0;
   int h=iRSI(sym,tf,period,PRICE_CLOSE); if(h==INVALID_HANDLE) return 0.0;
   double buf[]; if(CopyBuffer(h,0,shift,1,buf)<=0){ IndicatorRelease(h); return 0.0; }
   double v=buf[0]; IndicatorRelease(h); return v;
}
void GetBBands(const string sym,ENUM_TIMEFRAMES tf,int period,double dev,int shift,
               double &upper,double &middle,double &lower){
   if(!SeriesReady(sym,tf)){ upper=middle=lower=0.0; return; }

   int h=iBands(sym,tf,period,dev,0,PRICE_CLOSE); if(h==INVALID_HANDLE){ upper=middle=lower=0.0; return; }
   double u[1],m[1],l[1];
   if(CopyBuffer(h,0,shift,1,u)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   if(CopyBuffer(h,1,shift,1,m)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   if(CopyBuffer(h,2,shift,1,l)<=0){ IndicatorRelease(h); upper=middle=lower=0.0; return; }
   upper=u[0]; middle=m[0]; lower=l[0]; IndicatorRelease(h);
}

//---------------- Signals & Regime ---------------------------------
enum Regime { REGIME_TREND=0,REGIME_RANGE=1,REGIME_CHAOS=2 };
Regime DetectRegime(const string sym){
   double adx=GetADX(sym,WorkingTF,ADX_Period,0);
   if(adx>=ADX_TrendThreshold) return REGIME_TREND;
   if(adx<=ADX_RangeThreshold) return REGIME_RANGE;
   return REGIME_CHAOS;
}
bool TrendSignal(const string sym,int &dir,double &stop_pips){
   dir=0; stop_pips=0.0;
   double emaFast0=GetEMA(sym,WorkingTF,TF_EMA_Fast,0);
   double emaSlow0=GetEMA(sym,WorkingTF,TF_EMA_Slow,0);
   if(emaFast0==0 || emaSlow0==0) return false;
   double bid=SymbolInfoDouble(sym,SYMBOL_BID);
   double ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   double atr=GetATR(sym,WorkingTF,ATR_Period,0);
   if(emaFast0>emaSlow0 && bid>emaFast0) dir=1;
   if(emaFast0<emaSlow0 && ask<emaSlow0) dir=-1;
   if(dir==0) return false;
   double stop_dist=TF_StopATR_Mult*atr;
   stop_pips=stop_dist/point;
   return true;
}
bool MRSignal(const string sym,int &dir,double &stop_pips){
   dir=0; stop_pips=0.0;
   double rsi0=GetRSI(sym,WorkingTF,MR_RSI_Period,0);
   double up,mid,lo; GetBBands(sym,WorkingTF,MR_BB_Period,MR_BB_Dev,0,up,mid,lo);
   if(rsi0==0 || up==0 || lo==0) return false;
   double bid=SymbolInfoDouble(sym,SYMBOL_BID);
   double ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   double atr=GetATR(sym,WorkingTF,ATR_Period,0);
   if(rsi0<=MR_RSI_BuyLevel && bid<=lo) dir=1;
   if(rsi0>=MR_RSI_SellLevel && ask>=up) dir=-1;
   if(dir==0) return false;
   double stop_dist=MR_StopATR_Mult*atr;
   stop_pips=stop_dist/point;
   return true;
}

//---------------- Position iteration helpers (MT5-safe) ------------
bool SelectPositionByIndex(const int index){
   if(index<0 || index>=PositionsTotal()) return false;
   ulong ticket=PositionGetTicket(index);
   if(ticket==0) return false;
   return PositionSelectByTicket(ticket);
}
int CountOpenPositionsForSymbol(const string sym){
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++){
      if(!SelectPositionByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL)==sym) cnt++;
   }
   return cnt;
}
int OpenPositionsTotal(){
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++){
      if(SelectPositionByIndex(i)) cnt++;
   }
   return cnt;
}

//---------------- Portfolio risk & correlation ---------------------
double ActivePortfolioRiskPercentEstimate(){
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0) return 0.0;
   double sumRisk=0.0;
   for(int i=0;i<PositionsTotal();i++){
      if(!SelectPositionByIndex(i)) continue;
      string ps=PositionGetString(POSITION_SYMBOL);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double price=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double point=SymbolInfoDouble(ps,SYMBOL_POINT);
      double tickValue=SymbolInfoDouble(ps,SYMBOL_TRADE_TICK_VALUE);
      double tickSize=SymbolInfoDouble(ps,SYMBOL_TRADE_TICK_SIZE);
      if(sl==0 || tickValue<=0 || tickSize<=0 || point<=0) continue;
      double stop_points=MathAbs(price-sl)/point;
      double pipValuePerLot=tickValue*(point/tickSize);
      double riskCash=stop_points*pipValuePerLot*vol;
      sumRisk+=riskCash/eq*100.0;
   }
   return sumRisk;
}
bool CorrelatedBlock(const string sym,int dir){
   if(!UseCorrelationBlock || !CorrelateUSDQuotes) return false;
   string symU=sym; StringToUpper(symU);
   bool symHasUSD=(StringFind(symU,"USD")>=0);
   if(!symHasUSD) return false;
   for(int i=0;i<PositionsTotal();i++){
      if(!SelectPositionByIndex(i)) continue;
      string ps=PositionGetString(POSITION_SYMBOL); StringToUpper(ps);
      if(StringFind(ps,"USD")<0) continue;
      int ptype=(int)PositionGetInteger(POSITION_TYPE);
      int pdir=(ptype==POSITION_TYPE_BUY)? +1 : -1;
      if(pdir==dir) return true;
   }
   return false;
}
int SlippageForSymbol(const string sym){
   string u=sym; StringToUpper(u);
   if(StringFind(u,"XAU")>=0 || StringFind(u,"XAG")>=0) return SlippagePoints_Metals;
   if(StringFind(u,"NAS")>=0 || StringFind(u,"US100")>=0 || StringFind(u,"US30")>=0 || StringFind(u,"DE40")>=0) return SlippagePoints_Indices;
   if(StringFind(u,"BTC")>=0 || StringFind(u,"ETH")>=0 || StringFind(u,"CRYPTO")>=0) return SlippagePoints_Crypto;
   return SlippagePoints_FX;
}
double CalcLotByRisk(const string sym,double stop_pips,double risk_percent){
   if(stop_pips<=0) return 0.0;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash=equity*(risk_percent/100.0);
   double tickValue=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   double tickSize=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0 || tickSize<=0 || tickValue<=0) return 0.0;
   double pipValuePerLot=tickValue*(point/tickSize);
   double lots=riskCash/(stop_pips*pipValuePerLot);
   double minLot=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   if(step>0) lots=MathFloor(lots/step)*step;
   lots=MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}

//---------------- Guardrails & logging ------------------------------
bool CheckDailyAndTotalDD(){
   if(TradingMode == RETAIL_MODE) return true; // Skip strict guardrails

   datetime curDay=iTime(_Symbol,PERIOD_D1,0);
   if(curDay!=g_dayStart) ResetDailyEquityAnchor();
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_peakEquity) g_peakEquity=eq;

   double dayDD=(g_dayStartEquity>0)? (g_dayStartEquity - eq)/g_dayStartEquity*100.0 : 0.0;
   if(dayDD>=MaxDailyLoss_Percent){
      if(VerboseLog) Print("TG9: Daily loss breached. Pausing.");
      if(CloseAllIfDailyLossHit){
         for(int i=PositionsTotal()-1;i>=0;i--){
            if(!SelectPositionByIndex(i)) continue;
            string sym=PositionGetString(POSITION_SYMBOL);
            Trade.PositionClose(sym);
         }
      }
      return false;
   }

   if(g_peakEquity>0){
      double totalDD=(g_peakEquity - eq)/g_peakEquity*100.0;
      if(totalDD>=MaxTotalDrawdown_Percent){
         if(VerboseLog) Print("TG9: Total DD breached. Pausing.");
         return false;
      }
   }

   if(g_consecLosses>=MaxConsecutiveLosses){
      if(VerboseLog) Print("TG9: Max consecutive losses reached. Cooling down.");
      return false;
   }
   if(g_lastLossTime>0 && (TimeCurrent()-g_lastLossTime)<CooldownMinutesAfterLoss*60){
      if(VerboseLog) Print("TG9: Cooling down after loss.");
      return false;
   }
   return true;
}

//---------------- Execution ----------------------------------------
bool PlaceTrade(const string sym,int dir,double stop_pips,double rr_tp){
   if(CountOpenPositionsForSymbol(sym)>=MaxOpenPositionsPerSymbol) return false;
   if(OpenPositionsTotal()>=MaxOpenPositionsTotal) return false;
   if(CorrelatedBlock(sym, dir)){ if(VerboseLog) Print("TG9: Correlation block on ",sym); return false; }
   if(!CheckDailyAndTotalDD()) return false;

   double sessMult=1.0; if(!SessionOkayAndSizeMult(sessMult)) return false;
   double dowMult=GetDoWSizeMult();
   double effRisk=BaseRisk_Percent*sessMult*dowMult;
   if(g_equityMA>0 && AccountInfoDouble(ACCOUNT_EQUITY) < g_equityMA){
      effRisk*=0.5;
      if(VerboseLog) Print("TG9: Equity < MA, risk reduced for ",sym);
   }
   double activeRisk=ActivePortfolioRiskPercentEstimate();
   if(TradingMode==PROP_MODE && activeRisk + effRisk > MaxPortfolioRisk_Percent){
      string msg=StringFormat("TG9: Portfolio risk cap reached. Active=%.2f%% + New=%.2f%% > Max=%.2f%%",
                              activeRisk, effRisk, MaxPortfolioRisk_Percent);
      if(VerboseLog) Print(msg);
      return false;
   }

   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   double price=(dir>0)? SymbolInfoDouble(sym,SYMBOL_ASK) : SymbolInfoDouble(sym,SYMBOL_BID);
   double sl=0.0, tp=0.0;
   double stop_dist_points=stop_pips*point;
   if(dir>0){ sl=price-stop_dist_points; tp=price+(rr_tp*stop_dist_points); }
   else     { sl=price+stop_dist_points; tp=price-(rr_tp*stop_dist_points); }

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(SlippageForSymbol(sym));
   double lots=CalcLotByRisk(sym,stop_pips,effRisk);
   if(lots<=0) return false;

   bool ok = (dir>0)? Trade.Buy(lots, sym, 0, sl, tp, "TG9-MSM")
                    : Trade.Sell(lots, sym, 0, sl, tp, "TG9-MSM");

   if(VerboseLog){
      string lg=StringFormat("TG9: %s %s risk=%.2f%% stop_pips=%.1f rr=%.2f",
                              (dir>0?"BUY":"SELL"), sym, effRisk, stop_pips, rr_tp);
      Print(lg);
   }
   return ok;
}

//---------------- PnL tracking -------------------------------------
void UpdatePnLStatsOnTradeClose(){
   HistorySelect(0, TimeCurrent());
   datetime last_close_time=0;
   ulong last_deal=0;
   uint deals=HistoryDealsTotal();
   for(uint i=0;i<deals;i++){
      ulong id=HistoryDealGetTicket(i);
      if((long)id<=0) continue;
      if((int)HistoryDealGetInteger(id, DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      datetime ct=(datetime)HistoryDealGetInteger(id, DEAL_TIME);
      if(ct>last_close_time){ last_close_time=ct; last_deal=id; }
   }
   if(last_deal>0){
      double profit=HistoryDealGetDouble(last_deal, DEAL_PROFIT)
                   +HistoryDealGetDouble(last_deal, DEAL_SWAP)
                   +HistoryDealGetDouble(last_deal, DEAL_COMMISSION);
      if(profit<0){ g_consecLosses++; g_lastLossTime=last_close_time; }
      else if(profit>0){ g_consecLosses=0; }
   }
}

//=========================== LIFECYCLE ==============================

int OnInit(){
   int parts = StringSplit(SymbolsCSV, ',', g_symbols);
   if(parts<=0){ Print("TG9: No symbols in SymbolsCSV"); return(INIT_FAILED); }
   // Resolve broker-specific symbol suffixes/prefixes
   string resolved[];
   ArrayResize(resolved, parts);
   int newCount=0;
   for(int i=0;i<parts;i++){
      StringTrimLeft(g_symbols[i]);
      StringTrimRight(g_symbols[i]);
      string rs = ResolveSymbol(g_symbols[i]);
      if(rs!=""){
         resolved[newCount++] = rs;
         // Preload some history
         MqlRates rates[];
         CopyRates(rs, WorkingTF, 0, 10, rates);
      }else{
         PrintFormat("TG9: Skipping unknown symbol '%s'", g_symbols[i]);
      }
   }
   ArrayResize(resolved, newCount);
   ArrayResize(g_symbols, ArraySize(resolved));
   for(int ii=0; ii<ArraySize(resolved); ii++) g_symbols[ii]=resolved[ii];
   // Bookkeeping arrays
   ArrayResize(g_lastBarTime, newCount);
   for(int i=0;i<newCount;i++) g_lastBarTime[i]=0;
   ResetDailyEquityAnchor();
   UpdateEquityCurve();
   EventSetTimer(PollSeconds);
   string initMsg=StringFormat("TG9 Init: TF=%s SymbolsCSV=%s ResolvedCount=%d", EnumToString(WorkingTF), SymbolsCSV, newCount);
   Print(initMsg);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){ EventKillTimer(); }

void EvaluateSymbol(const string sym){
   datetime bar=iTime(sym, WorkingTF, 0);
   // map sym -> index in g_symbols
   int idx=-1; for(int i=0;i<ArraySize(g_symbols);i++){ if(g_symbols[i]==sym){ idx=i; break; } }
   if(idx<0) return;
   if(bar==g_lastBarTime[idx]) return; // run once per new bar per symbol
   g_lastBarTime[idx]=bar;

   if(!CheckDailyAndTotalDD()) return;

   Regime regime=DetectRegime(sym);
   int dir=0; double stop_pips=0.0; bool gotSignal=false; double rr=1.5;
   if(regime==REGIME_TREND){ gotSignal=TrendSignal(sym,dir,stop_pips); rr=TF_TakeProfit_RR; }
   else if(regime==REGIME_RANGE){ gotSignal=MRSignal(sym,dir,stop_pips); rr=MR_TakeProfit_RR; }
   else { gotSignal=false; }
   if(gotSignal) PlaceTrade(sym, dir, stop_pips, rr);
}

void OnTimer(){
   UpdatePnLStatsOnTradeClose();
   UpdateEquityCurve();
   for(int i=0;i<ArraySize(g_symbols);i++) EvaluateSymbol(g_symbols[i]);
   if(ShowDashboard) DrawDashboard();
}
void OnTick(){ /* timer-driven engine - intentional no-op */ }

//------------------- Dashboard -------------------------------------
void DrawDashboard(){
   string name="TG9_MSM_Dashboard";
   if(ObjectFind(0,name)<0){
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,6);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,18);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double dayDD=(g_dayStartEquity>0)? (g_dayStartEquity - eq)/g_dayStartEquity*100.0 : 0.0;
   double totalDD=(g_peakEquity>0)? (g_peakEquity - eq)/g_peakEquity*100.0 : 0.0;

   string line = StringFormat(
      "Equity: %.2f | DD Day: %.2f%%/%.1f%% | DD Total: %.2f%%/%.1f%% | Mode: %s | Risk: %s",
      eq, dayDD, MaxDailyLoss_Percent, totalDD, MaxTotalDrawdown_Percent,
      (TradingMode==PROP_MODE?"PROP":"RETAIL"),
      (g_equityMA>0 && eq<g_equityMA) ? "REDUCED 0.5x" : "NORMAL"
   );

   string hud="TrendGuard v9 MSM\n"+line+"\n";
   for(int i=0;i<ArraySize(g_symbols);i++){
      string s=g_symbols[i];
      Regime r=DetectRegime(s);
      string rs=(r==REGIME_TREND?"TREND":r==REGIME_RANGE?"RANGE":"CHAOS");
      int posCount=CountOpenPositionsForSymbol(s);
      hud += s + " | Regime: " + rs + " | Pos: " + IntegerToString(posCount) + "\n";
   }
   ObjectSetString(0,name,OBJPROP_TEXT,hud);
}
//+------------------------------------------------------------------+
