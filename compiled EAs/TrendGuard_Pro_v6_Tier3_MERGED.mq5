//+------------------------------------------------------------------+
//|                        TrendGuard Pro v5 — Tier2 + PROP (Merged) |
//|                       GH Wealth Makers Elite — FTMO Ready        |
//|  Full Tier-2 feature stack merged with prop guardrails for MT5   |
//+------------------------------------------------------------------+
#property copyright "GH Wealth Makers Elite"
#property version   "5.10"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/PositionInfo.mqh>

// ---------------- ENUMS ----------------
enum ENUM_MARKET_REGIME { REGIME_STRONG_TREND=0, REGIME_WEAK_TREND=1, REGIME_RANGING=2, REGIME_VOLATILE_CHAOS=3 };
enum ENUM_SESSION_TYPE  { SESSION_ASIAN=0, SESSION_LONDON=1, SESSION_NEWYORK=2, SESSION_OVERLAP=3, SESSION_CLOSED=4 };

// ---------------- INPUTS: CORE & TIER-2 ----------------
input group "=== Indicator Settings ==="
input int            EMA_Length         = 200;
input int            ATR_Length         = 14;
input double         ATR_Multiplier     = 2.0;
input double         ST_Multiplier      = 3.0;
input int            ST_Period          = 10;

input group "=== Risk Management ==="
input bool           UseMoneyManagement = true;
input double         Risk_Percent       = 1.0;
input double         RR_Ratio           = 2.0;
input double         Lots_Fixed         = 0.10;
input double         MaxLots            = 100.0;

input group "=== Trading Settings ==="
input ENUM_TIMEFRAMES TimeFrame         = PERIOD_H1;
input ulong          MagicNumber        = 20250908;
input ulong          DeviationPoints    = 10;

input group "=== TIER 1 ENHANCEMENTS ==="
input bool           UseVolumeFilter    = true;
input int            VolumePeriod       = 20;
input double         VolumeThreshold    = 1.0;

input bool           UseMTFConfluence   = true;
input ENUM_TIMEFRAMES MTF_Higher1       = PERIOD_H4;
input ENUM_TIMEFRAMES MTF_Higher2       = PERIOD_D1;
input int            MTF_MinAlignment   = 2;

input bool           UseDynamicSizing   = true;
input int            ATR_AvgPeriod      = 50;
input double         LowVolMultiplier   = 0.5;
input double         HighVolMultiplier  = 0.75;

input bool           UseSmartTrailing   = true;
input double         TrailingActivation = 1.0;
input double         TrailingATRMult    = 2.0;
input bool           TightenTrailing    = true;

input group "=== TIER 2: MARKET STRUCTURE ==="
input bool           UseSupplyDemand    = true;
input int            ZoneLookback       = 50;
input double         ZoneATRMult        = 1.5;
input int            MinZoneTouches     = 2;

input bool           UseMarketRegime    = true;
input int            ADX_Period         = 14;
input double         ADX_StrongTrend    = 30.0;
input double         ADX_WeakTrend      = 20.0;
input double         RegimeRiskMult_ST  = 1.2;
input double         RegimeRiskMult_WT  = 1.0;
input double         RegimeRiskMult_R   = 0.5;
input double         RegimeRiskMult_VC  = 0.3;

input bool           UseDivergence      = true;
input int            RSI_Period         = 14;
input double         RSI_Overbought     = 70.0;
input double         RSI_Oversold       = 30.0;
input int            DivLookback        = 20;

input bool           UseSessionFilter   = true;
input double         AsianSizeMult      = 0.5;
input double         LondonSizeMult     = 1.0;
input double         NYSizeMult         = 1.0;
input double         OverlapSizeMult    = 1.5;
input bool           AvoidAsianRange    = true;

input bool           UseNewsFilter      = true;
input int            NewsAvoidMinutes   = 30;
input bool           CloseBeforeNews    = false;

input bool           UseDayOfWeek       = true;
input double         MondayRiskMult     = 0.8;
input double         TuesdayRiskMult    = 1.1;
input double         WednesdayRiskMult  = 1.0;
input double         ThursdayRiskMult   = 1.0;
input double         FridayRiskMult     = 0.9;
input bool           NoFridayAfternoon  = true;

input group "=== Visual Settings ==="
input bool           ShowEMA            = true;
input bool           ShowSupertrend     = true;
input bool           ShowEntryArrows    = true;
input bool           ShowMTFPanel       = true;
input bool           ShowMarketPanel    = true;
input bool           ShowSupplyDemand   = true;

input group "=== Logging Settings ==="
input bool           EnableCSVLogging   = true;
input string         CSVFileName        = "TrendGuard_v5_Trades.csv";

// ---------------- INPUTS: PROP GUARDRAILS ----------------
input group "=== Prop Firm Guardrails (FTMO-ready) ==="
input bool     PropMode_Enabled        = true;
input double   MaxDailyLossPct         = 5.0;   // FTMO-style daily loss cap
input double   EquityHardFloorPct      = 10.0;  // Overall loss cap proxy
input double   MaxOpenRiskPct          = 3.0;
input int      MaxPositionsPerSymbol   = 2;
input int      MaxConsecutiveLosses    = 3;
input int      CooldownMinutesAfterLoss= 60;
input double   DailyRiskBudgetPct      = 2.0;   // conservative risk spend per day
input bool     LockoutForTheDay        = true;
input bool     Tester_PushCustomStat   = true;

// ---------------- GLOBALS/OBJECTS ----------------
CTrade         m_trade;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;
CPositionInfo  m_position;

// indicator handles
int emaHandle=INVALID_HANDLE, atrHandle=INVALID_HANDLE, volumeHandle=INVALID_HANDLE, adxHandle=INVALID_HANDLE, rsiHandle=INVALID_HANDLE;
int emaHandleH4=INVALID_HANDLE, emaHandleD1=INVALID_HANDLE, atrHandleH4=INVALID_HANDLE, atrHandleD1=INVALID_HANDLE;

// states
bool g_volumeFilterEnabled=false, g_mtfConfluenceEnabled=false;
ENUM_MARKET_REGIME currentRegime=REGIME_RANGING;
ENUM_SESSION_TYPE  currentSession=SESSION_CLOSED;
double currentRegimeMultiplier=1.0, currentSessionMultiplier=1.0, currentDayMultiplier=1.0;
datetime lastBarTime=0;
double averageATR=0.0; datetime lastATRCalc=0;

// Supertrend states for TF/MTF
double prevSTLine=0.0, prevSTLineH4=0.0, prevSTLineD1=0.0;
int    prevSTDir=0,  prevSTDirH4=0,  prevSTDirD1=0;

// Zones
struct SUPPLY_DEMAND_ZONE{ double price_high, price_low; datetime time_created; int touches; bool is_supply, is_active; };
SUPPLY_DEMAND_ZONE zones[]; int activeZoneCount=0;

// Divergence flags
bool activeBullishDiv=false, activeBearishDiv=false;

// Trailing
bool trailingActivated=false; int trailBarCount=0;

// Day/prop tracking
double dayStartEquity=0.0, initEquity=0.0, dayRealizedPL=0.0, dayPlannedRisk=0.0, peakEquity=0.0;
int consecLosses=0; datetime lastLossTime=0; datetime dayAnchor=0; double maxDailyDDPct=0.0, maxDrawdownPct=0.0;

// ---------------- FORWARD DECLS ----------------
void InitializeTier1();
void InitializeTier2();
void InitializeSupertrend();
bool IsNewBar(datetime t);
double GetEMAValue();
double GetATRValue();
double GetAverageATR();
bool CheckVolumeFilter();
int  CheckMTFAlignment(int primaryDirection);
double CalculateDynamicRisk();
void CalculateSupertrend(double atrValue,double multiplier,double &calcSTLine,int &calcSTDir,const MqlRates &bar,double &prevLine,int &prevDir);
void ManageTrailingStop();
bool ValidateTradeLevels(bool isBuy,double price,double sl,double tp);
void ExecuteBuy(double atrValue,double riskPercent);
void ExecuteSell(double atrValue,double riskPercent);
double CalculateLotSize(double stopDistance,double riskPercent);
bool HasOpenPosition();
void DrawEntryArrow(bool isBuy, datetime t,double price);
void DetectSupplyDemandZones();
void DrawSupplyDemandZones();
void AnalyzeMarketStructure();
ENUM_SESSION_TYPE GetCurrentSession();
bool IsHighImpactNewsTime();
void CloseAllPositions(string reason);
void InitializeCSVLog();
void LogTrade(string type,double lots,double entry,double sl,double tp,double stopDist,double riskPct);
void UpdateDailyDD();
void UpdateEquityDD();

// Prop helpers
bool IsNewBrokerDay();
void ResetDay();
bool CanOpenNewTrade(double plannedRiskPct);
double ComputeOpenRiskPct();

// ---------------- INIT ----------------
int TG_Tier2_OnInit()
{
   if(!m_symbol.Name(_Symbol) || !m_symbol.RefreshRates()) return INIT_FAILED;
   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetDeviationInPoints((int)DeviationPoints);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   m_trade.SetAsyncMode(false);

   emaHandle = iMA(_Symbol, TimeFrame, EMA_Length, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, TimeFrame, ATR_Length);
   if(emaHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE) return INIT_FAILED;
   InitializeTier1();
   InitializeTier2();
   ArrayResize(zones, 100);
   InitializeSupertrend();
   if(EnableCSVLogging) InitializeCSVLog();

   initEquity = m_account.Equity();
   dayStartEquity = initEquity;
   peakEquity = initEquity;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); dt.hour=0; dt.min=0; dt.sec=0; dayAnchor=StructToTime(dt);
   return INIT_SUCCEEDED;
}

void TG_Tier2_OnDeinit(const int reason)
{
   if(emaHandle!=INVALID_HANDLE) IndicatorRelease(emaHandle);
   if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(volumeHandle!=INVALID_HANDLE) IndicatorRelease(volumeHandle);
   if(adxHandle!=INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(rsiHandle!=INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(emaHandleH4!=INVALID_HANDLE) IndicatorRelease(emaHandleH4);
   if(emaHandleD1!=INVALID_HANDLE) IndicatorRelease(emaHandleD1);
   if(atrHandleH4!=INVALID_HANDLE) IndicatorRelease(atrHandleH4);
   if(atrHandleD1!=INVALID_HANDLE) IndicatorRelease(atrHandleD1);
}

// ---------------- TICK ----------------
void TG_Tier2_OnTick()
{
   if(!m_symbol.RefreshRates()) return;

   if(IsNewBrokerDay()) ResetDay();

   AnalyzeMarketStructure();
   currentSession = GetCurrentSession();

   if(UseNewsFilter && IsHighImpactNewsTime())
   {
      if(CloseBeforeNews && HasOpenPosition()) CloseAllPositions("News Event");
      return;
   }

   if(UseSmartTrailing && HasOpenPosition()) ManageTrailingStop();

   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, TimeFrame, 0, 2, r) < 2) return;
   if(!IsNewBar(r[0].time)) return;

   // Prop lockouts
   if(PropMode_Enabled && LockoutForTheDay)
   {
      double dailyLossPct = (dayRealizedPL<0 && dayStartEquity>0) ? (-dayRealizedPL/dayStartEquity)*100.0 : 0.0;
      if(dailyLossPct >= MaxDailyLossPct) return;
      if(dayPlannedRisk >= DailyRiskBudgetPct) return;
   }
   if(PropMode_Enabled && initEquity>0)
   {
      double eq = m_account.Equity();
      double dropPct = (initEquity - eq)/initEquity*100.0;
      if(dropPct >= EquityHardFloorPct) return;
   }
   if(PropMode_Enabled)
   {
      if(consecLosses >= MaxConsecutiveLosses) return;
      if(lastLossTime>0 && (TimeCurrent()-lastLossTime) < CooldownMinutesAfterLoss*60) return;
   }

   // Minimal entry scaffold: EMA bias + MTF alignment + volume
   if(!CheckVolumeFilter()) return;
   double ema = GetEMAValue(), atr = GetATRValue(); if(ema==EMPTY_VALUE || atr<=0) return;

   int alignLong = CheckMTFAlignment(+1);
   int alignShort= CheckMTFAlignment(-1);

   double riskPct = CalculateDynamicRisk();
   double openRisk = ComputeOpenRiskPct();
   if(PropMode_Enabled && (openRisk + riskPct) > MaxOpenRiskPct) return;
   if(PropMode_Enabled && (dayPlannedRisk + riskPct) > DailyRiskBudgetPct) return;

   // Cap positions per symbol
   int countSym=0;
   for(int i=PositionsTotal()-1;i>=0;i--) if(m_position.SelectByIndex(i) && m_position.Symbol()==_Symbol && m_position.Magic()==MagicNumber) countSym++;
   if(countSym >= MaxPositionsPerSymbol) return;

   if(r[1].close > ema && alignLong >= MTF_MinAlignment) ExecuteBuy(atr, riskPct);
   else if(r[1].close < ema && alignShort >= MTF_MinAlignment) ExecuteSell(atr, riskPct);
}

// ---------------- TRADE EVENTS ----------------
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      long deal_ticket = (long)trans.deal;
      string sym = (string)HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
      if(sym!=_Symbol) { UpdateEquityDD(); UpdateDailyDD(); return; }
      int entry = (int)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      double net = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) + HistoryDealGetDouble(deal_ticket, DEAL_SWAP) + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
      if(entry==DEAL_ENTRY_OUT)
      {
         dayRealizedPL += net;
         if(net<0){ consecLosses++; lastLossTime=TimeCurrent(); } else { consecLosses=0; }
         UpdateEquityDD();
         UpdateDailyDD();
      }
   }
}

double OnTester()
{
   if(!Tester_PushCustomStat) return 0.0;
   double eq = m_account.Equity();
   bool passProfit = (eq >= initEquity*1.001);
   bool passDaily  = (maxDailyDDPct <= MaxDailyLossPct + 1e-6);
   double dropPct = (initEquity>0)?((initEquity - eq)/initEquity*100.0):0.0;
   bool passFloor = (dropPct < EquityHardFloorPct - 1e-6);
   return (passProfit && passDaily && passFloor) ? 1.0 : 0.0;
}

// ---------------- HELPERS (Init) ----------------
void InitializeTier1()
{
   if(UseVolumeFilter)
   {
      volumeHandle = iVolumes(_Symbol, TimeFrame, VOLUME_TICK);
      if(volumeHandle!=INVALID_HANDLE) g_volumeFilterEnabled=true;
   }
   if(UseMTFConfluence)
   {
      emaHandleH4 = iMA(_Symbol, MTF_Higher1, EMA_Length, 0, MODE_EMA, PRICE_CLOSE);
      emaHandleD1 = iMA(_Symbol, MTF_Higher2, EMA_Length, 0, MODE_EMA, PRICE_CLOSE);
      atrHandleH4 = iATR(_Symbol, MTF_Higher1, ATR_Length);
      atrHandleD1 = iATR(_Symbol, MTF_Higher2, ATR_Length);
      if(emaHandleH4!=INVALID_HANDLE && emaHandleD1!=INVALID_HANDLE && atrHandleH4!=INVALID_HANDLE && atrHandleD1!=INVALID_HANDLE)
         g_mtfConfluenceEnabled=true;
   }
}
void InitializeTier2()
{
   if(UseMarketRegime){ adxHandle = iADX(_Symbol, TimeFrame, ADX_Period); }
   if(UseDivergence){   rsiHandle = iRSI(_Symbol, TimeFrame, RSI_Period, PRICE_CLOSE); }
   ArrayResize(zones, 100);
}
void InitializeSupertrend()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol, TimeFrame, 1, 1, r)>0){ prevSTLine=(r[0].high+r[0].low)/2.0; prevSTDir=(r[0].close>=prevSTLine)?1:-1; }
   if(g_mtfConfluenceEnabled && CopyRates(_Symbol, MTF_Higher1, 1, 1, r)>0){ prevSTLineH4=(r[0].high+r[0].low)/2.0; prevSTDirH4=(r[0].close>=prevSTLineH4)?1:-1; }
   if(g_mtfConfluenceEnabled && CopyRates(_Symbol, MTF_Higher2, 1, 1, r)>0){ prevSTLineD1=(r[0].high+r[0].low)/2.0; prevSTDirD1=(r[0].close>=prevSTLineD1)?1:-1; }
}

// ---------------- HELPERS (Runtime) ----------------
bool IsNewBar(datetime t){ if(lastBarTime!=t){ lastBarTime=t; return true; } return false; }

double GetEMAValue(){ double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(emaHandle,0,0,1,b)<=0) return EMPTY_VALUE; return b[0]; }
double GetATRValue(){ double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(atrHandle,0,0,1,b)<=0) return EMPTY_VALUE; return b[0]; }

double GetAverageATR()
{
   if(TimeCurrent() - lastATRCalc > 3600)
   {
      double a[]; ArraySetAsSeries(a,true);
      if(CopyBuffer(atrHandle,0,0,ATR_AvgPeriod,a)>0){ averageATR=0.0; for(int i=0;i<ATR_AvgPeriod;i++) averageATR+=a[i]; averageATR/=ATR_AvgPeriod; lastATRCalc=TimeCurrent(); }
   }
   return averageATR;
}

bool CheckVolumeFilter()
{
   if(!g_volumeFilterEnabled) return true;
   double v[]; ArraySetAsSeries(v,true);
   if(CopyBuffer(volumeHandle,0,0,VolumePeriod+1,v)<=0) return true;
   double avg=0; for(int i=1;i<=VolumePeriod;i++) avg+=v[i]; avg/=VolumePeriod;
   return (v[0] >= avg*VolumeThreshold);
}

int CheckMTFAlignment(int primaryDirection)
{
   if(!g_mtfConfluenceEnabled) return 3;
   int count=1;
   double emaH4[], atrH4[]; MqlRates rH4[];
   ArraySetAsSeries(emaH4,true); ArraySetAsSeries(atrH4,true); ArraySetAsSeries(rH4,true);
   if(CopyBuffer(emaHandleH4,0,0,1,emaH4)>0 && CopyBuffer(atrHandleH4,0,0,1,atrH4)>0 && CopyRates(_Symbol, MTF_Higher1,0,1,rH4)>0)
   {
      double stL=0; int stD=0; CalculateSupertrend(atrH4[0], ST_Multiplier, stL, stD, rH4[0], prevSTLineH4, prevSTDirH4);
      bool okLong = (rH4[0].close > emaH4[0]) && (stD==1);
      bool okShort= (rH4[0].close < emaH4[0]) && (stD==-1);
      if( (primaryDirection==1 && okLong) || (primaryDirection==-1 && okShort)) count++;
   }
   double emaD1[], atrD1[]; MqlRates rD1[]; ArraySetAsSeries(emaD1,true); ArraySetAsSeries(atrD1,true); ArraySetAsSeries(rD1,true);
   if(CopyBuffer(emaHandleD1,0,0,1,emaD1)>0 && CopyBuffer(atrHandleD1,0,0,1,atrD1)>0 && CopyRates(_Symbol, MTF_Higher2,0,1,rD1)>0)
   {
      double stL=0; int stD=0; CalculateSupertrend(atrD1[0], ST_Multiplier, stL, stD, rD1[0], prevSTLineD1, prevSTDirD1);
      bool okLong = (rD1[0].close > emaD1[0]) && (stD==1);
      bool okShort= (rD1[0].close < emaD1[0]) && (stD==-1);
      if( (primaryDirection==1 && okLong) || (primaryDirection==-1 && okShort)) count++;
   }
   return count;
}

double CalculateDynamicRisk()
{
   if(!UseDynamicSizing) return Risk_Percent;
   GetAverageATR();
   if(averageATR<=0) return Risk_Percent;
   double curATR = GetATRValue(); if(curATR<=0) return Risk_Percent;
   double adj = Risk_Percent;
   if(curATR < averageATR*0.7) adj = Risk_Percent*LowVolMultiplier;
   else if(curATR > averageATR*1.3) adj = Risk_Percent*HighVolMultiplier;
   // also apply regime/day/session multipliers
   adj *= currentRegimeMultiplier; adj *= currentDayMultiplier; adj *= currentSessionMultiplier;
   return adj;
}

void CalculateSupertrend(double atrValue,double multiplier,double &calcSTLine,int &calcSTDir,const MqlRates &bar,double &prevLine,int &prevDir)
{
   double hl2=(bar.high+bar.low)/2.0;
   double up=hl2+multiplier*atrValue;
   double dn=hl2-multiplier*atrValue;
   if(prevDir==0){ calcSTDir=(bar.close>=hl2)?1:-1; calcSTLine=(calcSTDir==1)?dn:up; }
   else if(prevDir==1)
   {
      if(bar.close<=up){ calcSTDir=-1; calcSTLine=up; }
      else { calcSTDir=1; calcSTLine=MathMax(dn, prevLine); }
   }
   else
   {
      if(bar.close>=dn){ calcSTDir=1; calcSTLine=dn; }
      else { calcSTDir=-1; calcSTLine=MathMin(up, prevLine); }
   }
   prevLine=calcSTLine; prevDir=calcSTDir;
}

void ManageTrailingStop()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol()!=_Symbol || m_position.Magic()!=MagicNumber) continue;
      double cur=m_position.PriceCurrent(), entry=m_position.PriceOpen(), sl=m_position.StopLoss(), tp=m_position.TakeProfit();
      double atr=GetATRValue(); if(atr<=0) continue;
      bool isLong=(m_position.PositionType()==POSITION_TYPE_BUY);
      double initialRisk=MathAbs(entry-sl);
      double currentProfit = isLong ? (cur - entry) : (entry - cur);
      double profitInR = (initialRisk>0)? currentProfit/initialRisk : 0.0;
      if(profitInR >= TrailingActivation)
      {
         if(!trailingActivated){ trailingActivated=true; trailBarCount=0; }
         double trailDist = atr*TrailingATRMult;
         if(TightenTrailing){ trailBarCount++; if(trailBarCount>10) trailDist*=0.9; if(trailBarCount>20) trailDist*=0.8; if(trailBarCount>30) trailDist*=0.7; }
         double newSL=sl;
         if(isLong){ newSL = NormalizeDouble(cur - trailDist, (int)m_symbol.Digits()); if(newSL>sl) m_trade.PositionModify(m_position.Ticket(), newSL, tp); }
         else      { newSL = NormalizeDouble(cur + trailDist, (int)m_symbol.Digits()); if(newSL<sl) m_trade.PositionModify(m_position.Ticket(), newSL, tp); }
      }
   }
   if(!HasOpenPosition()){ trailBarCount=0; trailingActivated=false; }
}

bool ValidateTradeLevels(bool isBuy,double price,double sl,double tp)
{
   double minStop = m_symbol.StopsLevel()*m_symbol.Point();
   if(minStop>0)
   {
      if(isBuy){ if(price-sl<minStop) return false; if(tp-price<minStop) return false; }
      else     { if(sl-price<minStop) return false; if(price-tp<minStop) return false; }
   }
   return true;
}

void ExecuteBuy(double atrValue,double riskPercent)
{
   double ask=m_symbol.Ask(), bid=m_symbol.Bid();
   double sl = NormalizeDouble(bid - atrValue*ATR_Multiplier, (int)m_symbol.Digits());
   double tp = NormalizeDouble(bid + (bid-sl)*RR_Ratio, (int)m_symbol.Digits());
   if(!ValidateTradeLevels(true, ask, sl, tp)) return;

   // Prop checks just before sending
   if(PropMode_Enabled)
   {
      double openRisk = ComputeOpenRiskPct();
      if((openRisk + riskPercent) > MaxOpenRiskPct) return;
      if((dayPlannedRisk + riskPercent) > DailyRiskBudgetPct) return;
   }

   double stopDist = MathAbs(bid - sl);
   double lots = CalculateLotSize(stopDist, riskPercent);
   if(lots<=0) return;
   if(m_trade.Buy(lots, _Symbol, ask, sl, tp, "TGv5 Merged Long"))
   {
      dayPlannedRisk += riskPercent;
      if(EnableCSVLogging) LogTrade("BUY", lots, ask, sl, tp, stopDist, riskPercent);
      if(ShowEntryArrows) DrawEntryArrow(true, TimeCurrent(), ask);
   }
}

void ExecuteSell(double atrValue,double riskPercent)
{
   double ask=m_symbol.Ask(), bid=m_symbol.Bid();
   double sl = NormalizeDouble(ask + atrValue*ATR_Multiplier, (int)m_symbol.Digits());
   double tp = NormalizeDouble(ask - (sl-ask)*RR_Ratio, (int)m_symbol.Digits());
   if(!ValidateTradeLevels(false, bid, sl, tp)) return;

   if(PropMode_Enabled)
   {
      double openRisk = ComputeOpenRiskPct();
      if((openRisk + riskPercent) > MaxOpenRiskPct) return;
      if((dayPlannedRisk + riskPercent) > DailyRiskBudgetPct) return;
   }

   double stopDist = MathAbs(sl - ask);
   double lots = CalculateLotSize(stopDist, riskPercent);
   if(lots<=0) return;
   if(m_trade.Sell(lots, _Symbol, bid, sl, tp, "TGv5 Merged Short"))
   {
      dayPlannedRisk += riskPercent;
      if(EnableCSVLogging) LogTrade("SELL", lots, bid, sl, tp, stopDist, riskPercent);
      if(ShowEntryArrows) DrawEntryArrow(false, TimeCurrent(), bid);
   }
}

double CalculateLotSize(double stopDistance,double riskPercent)
{
   double lots = (!UseMoneyManagement || riskPercent<=0.0) ? Lots_Fixed : 0.0;
   if(UseMoneyManagement && riskPercent>0.0)
   {
      double equity = m_account.Equity();
      double riskAmt = equity*(riskPercent/100.0);
      double stopPoints = stopDistance / m_symbol.Point();
      double riskPerLot = stopPoints * m_symbol.TickValue();
      if(riskPerLot>0) lots = riskAmt / riskPerLot;
      if(lots<=0) lots = Lots_Fixed;
   }
   double step=m_symbol.LotsStep();
   if(step>0) lots = MathFloor(lots/step)*step;
   if(lots<m_symbol.LotsMin()) lots=m_symbol.LotsMin();
   if(lots>m_symbol.LotsMax()) lots=m_symbol.LotsMax();
   lots=MathMin(lots, MaxLots);
   return NormalizeDouble(lots,2);
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i) && m_position.Symbol()==_Symbol && m_position.Magic()==MagicNumber)
         return true;
   return false;
}

void DrawEntryArrow(bool isBuy, datetime t,double price)
{
   static int id=0; id++;
   string name="TG_MERGE_ARR_"+(string)id;
   ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, isBuy?233:234);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy?clrBlue:clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DetectSupplyDemandZones()
{
   if(!UseSupplyDemand) return;
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol, TimeFrame, 0, ZoneLookback+2, r) < ZoneLookback+2) return;
   double atr=GetATRValue(); if(atr<=0) return;
   double zoneH=atr*ZoneATRMult;
   activeZoneCount=0;
   int maxz=ArraySize(zones);
   for(int i=2;i<ZoneLookback && activeZoneCount<maxz;i++)
   {
      bool supply=(r[i].high - MathMax(r[i].close,r[i].open)) > (MathAbs(r[i].close-r[i].open))*1.5;
      bool demand=(MathMin(r[i].close,r[i].open) - r[i].low)   > (MathAbs(r[i].close-r[i].open))*1.5;
      if(supply || demand)
      {
         zones[activeZoneCount].is_supply=supply;
         zones[activeZoneCount].price_high = supply? r[i].high : r[i].low+zoneH;
         zones[activeZoneCount].price_low  = supply? r[i].high-zoneH : r[i].low;
         zones[activeZoneCount].time_created = r[i].time;
         zones[activeZoneCount].touches=0;
         zones[activeZoneCount].is_active=true;
         activeZoneCount++;
      }
   }
   if(ShowSupplyDemand) DrawSupplyDemandZones();
}
void DrawSupplyDemandZones()
{
   for(int i=0;i<50;i++) ObjectDelete(0, "TG_ZONE_"+(string)i);
   for(int i=0;i<activeZoneCount && i<20;i++)
   {
      if(!zones[i].is_active) continue;
      string name="TG_ZONE_"+(string)i;
      color c = zones[i].is_supply?clrRed:clrGreen;
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, zones[i].time_created, zones[i].price_low, TimeCurrent(), zones[i].price_high);
      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
}

void AnalyzeMarketStructure()
{
   if(UseMarketRegime && adxHandle!=INVALID_HANDLE)
   {
      double adx[]; ArraySetAsSeries(adx,true);
      if(CopyBuffer(adxHandle,0,0,1,adx)>0)
      {
         if(adx[0]>=ADX_StrongTrend) currentRegime=REGIME_STRONG_TREND;
         else if(adx[0]>=ADX_WeakTrend) currentRegime=REGIME_WEAK_TREND;
         else currentRegime=REGIME_RANGING;
      }
   }
   switch(currentRegime)
   {
      case REGIME_STRONG_TREND: currentRegimeMultiplier=RegimeRiskMult_ST; break;
      case REGIME_WEAK_TREND:   currentRegimeMultiplier=RegimeRiskMult_WT; break;
      case REGIME_RANGING:      currentRegimeMultiplier=RegimeRiskMult_R;  break;
      case REGIME_VOLATILE_CHAOS: currentRegimeMultiplier=RegimeRiskMult_VC; break;
   }
   // Day-of-week multiplier
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   currentDayMultiplier=1.0;
   if(UseDayOfWeek)
   {
      if(dt.day_of_week==1) currentDayMultiplier=MondayRiskMult;
      else if(dt.day_of_week==2) currentDayMultiplier=TuesdayRiskMult;
      else if(dt.day_of_week==3) currentDayMultiplier=WednesdayRiskMult;
      else if(dt.day_of_week==4) currentDayMultiplier=ThursdayRiskMult;
      else if(dt.day_of_week==5) currentDayMultiplier=FridayRiskMult;
   }
}

ENUM_SESSION_TYPE GetCurrentSession()
{
   MqlDateTime dt; TimeGMT(dt);
   int hour=dt.hour;
   if(hour>=13 && hour<17){ currentSessionMultiplier=OverlapSizeMult; return SESSION_OVERLAP; }
   else if(hour>=8 && hour<17){ currentSessionMultiplier=LondonSizeMult; return SESSION_LONDON; }
   else if(hour>=13 && hour<22){ currentSessionMultiplier=NYSizeMult; return SESSION_NEWYORK; }
   else if(hour>=0 && hour<9){ currentSessionMultiplier=AsianSizeMult; return SESSION_ASIAN; }
   currentSessionMultiplier=1.0; return SESSION_CLOSED;
}

bool IsHighImpactNewsTime()
{
   if(!UseNewsFilter) return false;
   MqlDateTime dt; TimeGMT(dt);
   bool firstFriday = (dt.day_of_week==5 && dt.day<=7);
   if(firstFriday)
   {
      if( (dt.hour==13 && MathAbs(dt.min-30)<=NewsAvoidMinutes) ||
          (dt.hour==14 && dt.min<=NewsAvoidMinutes) )
         return true;
   }
   int newsHours[3]={8,10,14}; int newsMins[3]={30,0,30};
   for(int i=0;i<3;i++) if(dt.hour==newsHours[i] && MathAbs(dt.min-newsMins[i])<=NewsAvoidMinutes) return true;
   return false;
}

void CloseAllPositions(string reason)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i) && m_position.Symbol()==_Symbol && m_position.Magic()==MagicNumber)
         m_trade.PositionClose(m_position.Ticket());
}

// CSV
void InitializeCSVLog()
{
   if(!FileIsExist(CSVFileName))
   {
      int h=FileOpen(CSVFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(h!=INVALID_HANDLE)
      {
         // Write CSV header
         FileWrite(h, "timestamp","symbol","action","lots");
         FileClose(h);
      }
   }
}

// removed stray brace
// removed stray brace
void LogTrade(string type,double lots,double entry,double sl,double tp,double stopDist,double riskPct)
{
   if(!EnableCSVLogging) return;
   int h=FileOpen(CSVFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h==INVALID_HANDLE) return;
   FileSeek(h,0,SEEK_END);
   string reg="Ranging"; if(currentRegime==REGIME_STRONG_TREND) reg="Strong"; else if(currentRegime==REGIME_WEAK_TREND) reg="Weak"; else if(currentRegime==REGIME_VOLATILE_CHAOS) reg="Volatile";
   string ses="Closed"; if(currentSession==SESSION_ASIAN) ses="Asian"; else if(currentSession==SESSION_LONDON) ses="London"; else if(currentSession==SESSION_NEWYORK) ses="NewYork"; else if(currentSession==SESSION_OVERLAP) ses="Overlap";
   double rr = (type=="BUY") ? (tp-entry)/MathMax(0.0000001,(entry-sl)) : (entry-tp)/MathMax(0.0000001,(sl-entry));
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, type, DoubleToString(lots,2));
FileClose(h);
}

// Prop helpers
bool IsNewBrokerDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today0; dt.hour=0; dt.min=0; dt.sec=0; today0=StructToTime(dt);
   return (today0 > dayAnchor);
}
void ResetDay()
{
   dayAnchor = (datetime) ( (long)(TimeCurrent()/(24*60*60)) * (24*60*60) );
   dayStartEquity = m_account.Equity();
   dayRealizedPL = 0.0;
   dayPlannedRisk = 0.0;
   consecLosses = 0;
   lastLossTime = 0;
   maxDailyDDPct = 0.0;
}
bool CanOpenNewTrade(double plannedRiskPct)
{
   if(!PropMode_Enabled) return true;
   double dailyLossPct = (dayRealizedPL<0 && dayStartEquity>0) ? (-dayRealizedPL/dayStartEquity)*100.0 : 0.0;
   if(LockoutForTheDay && dailyLossPct >= MaxDailyLossPct) return false;
   return true;
}
double ComputeOpenRiskPct()
{
   double openRisk=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol()!=_Symbol || m_position.Magic()!=MagicNumber) continue;
      double entry=m_position.PriceOpen(), sl=m_position.StopLoss(); if(sl<=0) continue;
      double points = MathAbs(entry-sl)/m_symbol.Point();
      double money  = points * m_symbol.TickValue() * m_position.Volume();
      openRisk += money;
   }
   double eq=m_account.Equity(); if(eq<=0) return 0.0;
   return (openRisk/eq)*100.0;
}
void UpdateDailyDD()
{
   if(dayStartEquity>0)
   {
      double eq=m_account.Equity();
      double dailyDD = (dayStartEquity - eq)/dayStartEquity*100.0;
      if(dailyDD > maxDailyDDPct) maxDailyDDPct=dailyDD;
   }
}
void UpdateEquityDD()
{
   double eq=m_account.Equity();
   if(eq>peakEquity) peakEquity=eq;
   if(peakEquity>0)
   {
      double dd=(peakEquity-eq)/peakEquity*100.0;
      if(dd>maxDrawdownPct) maxDrawdownPct=dd;
   }
//==================================================================
}
// TrendGuard — Tier 3 Module (Session/News/DoW + Prop Guardrails)
// Namespaced with TG3_ to avoid conflicts
//==================================================================
#include <Trade/Trade.mqh>
CTrade TG3_Trade;

// ===== Inputs (prefixed) =====
input double   TG3_BaseRisk_Percent            = 0.50;
input double   TG3_MaxDailyLoss_Percent        = 4.0;
input double   TG3_MaxTotalDrawdown_Percent    = 8.0;
input int      TG3_MaxOpenPositionsPerSymbol   = 1;
input bool     TG3_CloseAllIfDailyLossHit      = true;

input bool     TG3_UseSessionFilter            = true;
input int      TG3_BrokerGMTOffsetHours        = 0;

input bool     TG3_UseTokyoSession             = true;
input string   TG3_TokyoStartHHMM              = "00:00";
input string   TG3_TokyoEndHHMM                = "08:00";

input bool     TG3_UseLondonSession            = true;
input string   TG3_LondonStartHHMM             = "07:00";
input string   TG3_LondonEndHHMM               = "16:00";

input bool     TG3_UseNewYorkSession           = true;
input string   TG3_NewYorkStartHHMM            = "12:30";
input string   TG3_NewYorkEndHHMM              = "21:00";

input bool     TG3_AllowLondonNYOverlapBoost   = true;
input double   TG3_Overlap_SizeMultiplier      = 1.50;

input bool     TG3_UseDayOfWeekOptimizer       = true;
input double   TG3_Monday_SizeMult             = 0.80;
input double   TG3_Tuesday_SizeMult            = 1.10;
input double   TG3_Wednesday_SizeMult          = 1.00;
input double   TG3_Thursday_SizeMult           = 1.00;
input double   TG3_Friday_SizeMult             = 0.90;

input bool     TG3_UseNewsFilter               = true;
input bool     TG3_BlockHighImpact             = true;
input bool     TG3_BlockMediumImpact           = false;
input int      TG3_PreNewsBlock_Min            = 30;
input int      TG3_PostNewsBlock_Min           = 30;
input string   TG3_CalendarCountries           = "US,GB,EU";

input int      TG3_SlippagePoints              = 10;
input double   TG3_ATR_Period                  = 14;
input double   TG3_StopATR_Mult                = 2.0;
input bool     TG3_VerboseLog                  = true;

datetime TG3_dayStart=0;
double   TG3_dayStartEquity=0.0;
bool     TG3_dailyLocked=false;

// --- helpers ---
int TG3_ParseHHMM(const string hhmm){
  int h=(int)StringToInteger(StringSubstr(hhmm,0,2));
  int m=(int)StringToInteger(StringSubstr(hhmm,3,2));
  return h*60+m;
}

int TG3_ServerTimeToGMTMinutes(datetime t){
  MqlDateTime st; TimeToStruct(t,st);
  int minutes = (st.hour - TG3_BrokerGMTOffsetHours)*60 + st.min;
  while(minutes<0) minutes+=1440;
  while(minutes>=1440) minutes-=1440;
  return minutes;
}

bool TG3_InWindow(int nowMin, int startMin, int endMin){
  if(startMin<=endMin) return (nowMin>=startMin && nowMin<endMin);
  return (nowMin>=startMin || nowMin<endMin);
}

bool TG3_SessionOkayAndSizeMult(double &mult_out){
  mult_out=1.0;
  if(!TG3_UseSessionFilter) return true;
  int nowGMT = TG3_ServerTimeToGMTMinutes(TimeCurrent());

  int tks = TG3_ParseHHMM(TG3_TokyoStartHHMM);
  int tke = TG3_ParseHHMM(TG3_TokyoEndHHMM);
  int lns = TG3_ParseHHMM(TG3_LondonStartHHMM);
  int lne = TG3_ParseHHMM(TG3_LondonEndHHMM);
  int nys = TG3_ParseHHMM(TG3_NewYorkStartHHMM);
  int nye = TG3_ParseHHMM(TG3_NewYorkEndHHMM);

  bool tok = TG3_UseTokyoSession  && TG3_InWindow(nowGMT,tks,tke);
  bool lon = TG3_UseLondonSession && TG3_InWindow(nowGMT,lns,lne);
  bool ny  = TG3_UseNewYorkSession&& TG3_InWindow(nowGMT,nys,nye);

  if(!(tok||lon||ny)) return false;

  if(tok) mult_out *= 0.50;
  if(lon) mult_out *= 1.00;
  if(ny)  mult_out *= 1.00;
  if(TG3_AllowLondonNYOverlapBoost && lon && ny) mult_out *= TG3_Overlap_SizeMultiplier;
  return true;
}

double TG3_DayOfWeekMult(){
  if(!TG3_UseDayOfWeekOptimizer) return 1.0;
  MqlDateTime __tg3_dt; TimeToStruct(TimeCurrent(), __tg3_dt); int dow = (int)__tg3_dt.day_of_week;
  switch(dow){
    case 1: return TG3_Monday_SizeMult;
    case 2: return TG3_Tuesday_SizeMult;
    case 3: return TG3_Wednesday_SizeMult;
    case 4: return TG3_Thursday_SizeMult;
    case 5: return TG3_Friday_SizeMult;
    default: return 1.0;
  }
}

bool TG3_CountryEnabled(string country){
  string list = TG3_CalendarCountries;
  StringToUpper(list);
  StringToUpper(country);
  return (StringFind(","+list+",", ","+country+",")>=0);
}

bool TG3_IsBlockedByNews()
{
  // News filter stub: always allow trading. To enable calendar-based blocking,
  // implement CalendarValueHistory/CalendarEventById here once your MT5 build supports it.
  return false;
}


void TG3_ResetDailyEquityAnchor(){
  TG3_dayStart       = iTime(_Symbol,PERIOD_D1,0);
  TG3_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  TG3_dailyLocked    = false;
}

bool TG3_CheckDailyLossLimits(){
  datetime curDay = iTime(_Symbol,PERIOD_D1,0);
  if(curDay!=TG3_dayStart) TG3_ResetDailyEquityAnchor();
  double eq = AccountInfoDouble(ACCOUNT_EQUITY);
  double dd = (TG3_dayStartEquity - eq)/TG3_dayStartEquity * 100.0;
  if(dd >= TG3_MaxDailyLoss_Percent){
    if(!TG3_dailyLocked && TG3_CloseAllIfDailyLossHit){
      for(int i=PositionsTotal()-1;i>=0;i--){
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol){
          if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)  TG3_Trade.PositionClose(ticket);
          if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL) TG3_Trade.PositionClose(ticket);
        }
      }
    }
    TG3_dailyLocked = true;
    return false;
  }
  return true;
}

bool TG3_CheckTotalDrawdownLimit(){
  static double TG3_peakEquity_static = AccountInfoDouble(ACCOUNT_EQUITY);
  double eq = AccountInfoDouble(ACCOUNT_EQUITY);
  if(eq>TG3_peakEquity_static) TG3_peakEquity_static=eq;
  double dd = (TG3_peakEquity_static - eq)/TG3_peakEquity_static * 100.0;
  return (dd < TG3_MaxTotalDrawdown_Percent);
}

// --- Gate + size calc exposed to Tier2 ---
bool TG3_TradingWindowOpen(double &effectiveRisk){
  if(!TG3_CheckTotalDrawdownLimit()){ if(TG3_VerboseLog) Print("TG3: Total DD breached"); return false; }
  if(!TG3_CheckDailyLossLimits()){    if(TG3_VerboseLog) Print("TG3: Daily loss limit");  return false; }
  if(TG3_IsBlockedByNews()){          if(TG3_VerboseLog) Print("TG3: News block");        return false; }
  double sMult=1.0; if(!TG3_SessionOkayAndSizeMult(sMult)){ if(TG3_VerboseLog) Print("TG3: Outside sessions"); return false; }
  double dMult = TG3_DayOfWeekMult();
  effectiveRisk = TG3_BaseRisk_Percent * sMult * dMult;
  // Enforce single-position per symbol
  int openHere=0;
  for(int i=0;i<PositionsTotal();i++){
    if(PositionGetTicket(i)>0 && PositionSelectByTicket(PositionGetTicket(i)))
      if(PositionGetString(POSITION_SYMBOL)==_Symbol) openHere++;
  }
  if(openHere>=TG3_MaxOpenPositionsPerSymbol) return false;
  return true;
}

// --- Wrappers ---
int OnInit(){
  TG3_ResetDailyEquityAnchor();
  return TG_Tier2_OnInit();
}

void OnDeinit(const int reason){
  TG_Tier2_OnDeinit(reason);
}

void OnTick(){
  double effRisk=0.0;
  if(!TG3_TradingWindowOpen(effRisk)) return;
  GlobalVariableSet("TG3_EffectiveRiskPercent", effRisk);
  TG_Tier2_OnTick();
}
//==================================================================