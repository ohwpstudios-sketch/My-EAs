//+------------------------------------------------------------------+
//|                                        ORION_AllWeather_Engine_v3 |
//|                                   Author: GH Wealth Makers Elite   |
//|                                         (c) 2025, GH Wealth Makers |
//+------------------------------------------------------------------+
//| A multi-regime "all-weather" trading engine for any liquid symbol |
//| Combines:                                                         |
//|  1) Trend breakout (Donchian + ATR trail)                         |
//|  2) Range mean-reversion (RSI(2) + Bollinger)                     |
//|  3) Shock continuation (inside-bar break after daily shock)       |
//| With volatility targeting, spread/slippage guards, session filter,|
//| order expiry cleanup, and conservative risk caps.                 |
//+------------------------------------------------------------------+
#property copyright   "2025 GH Wealth Makers Elite"
#property link        "https://ghwealthmakerselite.xyz/"
#property version     "1.001"
#property strict

#include <Trade/Trade.mqh>

//============================= USER INPUTS ============================//
// General
input ulong   InpMagicNumber           = 90231418;   // Magic Number
input bool    InpEnablePush            = false;      // Push notifications
input double  InpMaxSpreadPoints       = 150.0;      // Max spread (points)
input int     InpMaxSlippagePoints     = 20;         // Max slippage (points)
input int     InpMaxOpenPositions      = 2;          // Max open positions (this symbol)
input bool    InpUseSessions           = true;       // Restrict to sessions
input int     InpLondonOpenHour        = 7;          // London open (broker time)
input int     InpNewYorkOpenHour       = 12;         // New York open (broker time)
input int     InpLondonCloseHour       = 16;         // London close (broker time)
input int     InpPendingExpiryMin      = 90;         // Cancel pendings after N minutes
input int     InpCooldownMin           = 30;         // Cooldown minutes after expiry

// Volatility targeting & risk
input double  InpBaseRiskPct           = 0.35;       // Base risk % per trade
input double  InpTargetVolAnnualPct    = 24.0;       // Target ann. vol % (drives scaler k)
input double  InpKMin                  = 0.50;       // Min risk scaler
input double  InpKMax                  = 2.00;       // Max risk scaler
input double  InpMaxOpenRiskPct        = 1.50;       // Cap total % open risk (this symbol)
input double  InpDailyLossStopPct      = 1.50;       // Daily loss stop %

// Regime detection (D1)
input int     InpEMAfast               = 20;         // EMA fast (D1)
input int     InpEMAslow               = 50;         // EMA slow (D1)
input int     InpADXperiod             = 14;         // ADX (D1)
input double  InpADXTrendThresh        = 25.0;       // ADX threshold for trend
input int     InpSlopeLookback         = 5;          // Slope lookback bars for EMA
input int     InpATRperiod_D1          = 20;         // ATR for realized vol & shock
input int     InpATRShockMedianLookback= 60;         // Median window for ATR shock test
input double  InpShockATRMult          = 1.75;       // Shock if ATR > X * median
input double  InpShockRetSigma         = 2.0;        // Shock if |ret| > X * stdev20

// Trend system (H1/H4)
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_H1;  // Execution TF for trend
input int     InpDonchian              = 55;         // Donchian length
input double  InpTrendSL_ATR_mult      = 2.5;        // Initial SL = mult * ATR14(TrendTF)
input int     InpATRperiod_Exec        = 14;         // ATR on execution TF
input int     InpTrailATR_mult         = 2;          // Chandelier trail multiple

// Range system (H1)
input ENUM_TIMEFRAMES InpRangeTF       = PERIOD_H1;  // Execution TF for range
input int     InpRSIPeriod             = 2;          // RSI length
input double  InpRSILow                = 5.0;        // RSI buy threshold
input double  InpRSIHigh               = 95.0;       // RSI sell threshold
input int     InpBBPeriod              = 20;         // Bollinger period
input double  InpBBDev                 = 2.0;        // Bollinger deviation
input double  InpBBExtraSigmas         = 0.5;        // Extra sigma buffer beyond bands
input double  InpRangeSL_ATR_mult      = 1.5;        // SL multiple of ATR14(RangeTF)

// Shock continuation (M30/H1)
input ENUM_TIMEFRAMES InpShockTF       = PERIOD_H1;  // Execution TF for shock
input int     InpInsideBarMaxLookback  = 3;          // Look back for inside bar after shock
input double  InpShockTP_RR            = 2.0;        // Fixed RR for shock trades

// Trailing controls
input bool    InpUseATRChandelierTrail = true;       // Apply ATR trailing stop
input int     InpTrailMinPoints        = 1;          // Min points improvement to modify SL

// CSV logging
input bool    InpWriteCSVJournal       = false;      // Write CSV journal

//============================= GLOBALS ================================//
CTrade     Trade;
MqlTick    g_tick;
datetime   g_cooldownUntil = 0;

//============================= UTILITIES ==============================//
void Notify(const string msg){ if(InpEnablePush) SendNotification("[ORION] "+msg); }

double PointsToPrice(double pts){ return pts * _Point; }
double PriceToPoints(double d){ return d / _Point; }

bool SpreadOK()
{
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints || spread<=0);
}

bool InSession()
{
   if(!InpUseSessions) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool lo  = (h>=InpLondonOpenHour && h<InpLondonCloseHour);
   bool nyo = (h>=InpNewYorkOpenHour && h<InpLondonCloseHour);
   return (lo || nyo);
}

void LogCSV(const string action, const string note)
{
   if(!InpWriteCSVJournal) return;
   string name = StringFormat("ORION_%s.csv", _Symbol);
   int fh = FileOpen(name, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ';');
   if(fh==INVALID_HANDLE){ Print("CSV open failed"); return; }
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS), action, note, (string)AccountInfoInteger(ACCOUNT_LOGIN), (string)InpMagicNumber);
   FileClose(fh);
}

// Indicator wrappers
double Indi_ATR(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iATR(sym, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double b[]; if(CopyBuffer(h, 0, shift, 1, b)<1) return 0.0;
   return b[0];
}
double Indi_EMA(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iMA(sym, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double b[]; if(CopyBuffer(h, 0, shift, 1, b)<1) return 0.0;
   return b[0];
}
double Indi_ADX(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iADX(sym, tf, period);
   if(h==INVALID_HANDLE) return 0.0;
   double b[]; if(CopyBuffer(h, 0, shift, 1, b)<1) return 0.0;
   return b[0];
}
double Indi_RSI(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iRSI(sym, tf, period, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 50.0;
   double b[]; if(CopyBuffer(h, 0, shift, 1, b)<1) return 50.0;
   return b[0];
}
bool Indi_BBands(const string sym, ENUM_TIMEFRAMES tf, int period, double dev, int shift, double &upper, double &mid, double &lower)
{
   int h = iBands(sym, tf, period, dev, 0, PRICE_CLOSE);
   if(h==INVALID_HANDLE) return false;
   double up[1], md[1], lo[1];
   if(CopyBuffer(h, 0, shift, 1, up)<1) return false;
   if(CopyBuffer(h, 1, shift, 1, md)<1) return false;
   if(CopyBuffer(h, 2, shift, 1, lo)<1) return false;
   upper=up[0]; mid=md[0]; lower=lo[0]; return true;
}

//============================= REGIME ================================//
enum Regime { REG_NONE=0, REG_TREND=1, REG_RANGE=2, REG_SHOCK=3 };

double DailyClose(int shift){ return iClose(_Symbol, PERIOD_D1, shift); }

double DailyReturnAbs(int shift)
{
   double c0=iClose(_Symbol, PERIOD_D1, shift);
   double c1=iClose(_Symbol, PERIOD_D1, shift+1);
   if(c1<=0) return 0.0;
   return MathAbs((c0-c1)/c1);
}

double StdDevDailyRet20()
{
   double sum=0, sum2=0; int n=0;
   for(int i=1;i<=20;i++)
   {
      double r = DailyReturnAbs(i);
      sum += r; sum2 += r*r; n++;
   }
   if(n<2) return 0.0;
   double mu = sum/n;
   return MathSqrt(MathMax(0.0, (sum2/n) - mu*mu));
}

double ATRMedian(const string sym, int period, int lookback)
{
   int h = iATR(sym, PERIOD_D1, period);
   if(h==INVALID_HANDLE) return 0.0;
   int cnt = MathMin(lookback, Bars(sym, PERIOD_D1)-period-2);
   if(cnt<=5) return 0.0;
   double buf[]; if(CopyBuffer(h, 0, 1, cnt, buf)<cnt) return 0.0; // skip current forming bar
   ArraySort(buf); // ascending
   int mid = cnt/2;
   double med = ( (cnt%2==1) ? buf[mid] : (0.5*(buf[mid-1]+buf[mid])) );
   return med;
}

int EMASlopeSign(const string sym, ENUM_TIMEFRAMES tf, int period, int lookback)
{
   double a = Indi_EMA(sym, tf, period, 1);
   double b = Indi_EMA(sym, tf, period, 1+lookback);
   double s = a-b;
   if(s>0) return +1;
   if(s<0) return -1;
   return 0;
}

Regime DetectRegime()
{
   // Daily signals
   double emaF = Indi_EMA(_Symbol, PERIOD_D1, InpEMAfast, 1);
   double emaS = Indi_EMA(_Symbol, PERIOD_D1, InpEMAslow, 1);
   double adx  = Indi_ADX(_Symbol, PERIOD_D1, InpADXperiod, 1);
   if(emaF==0 || emaS==0) return REG_NONE;

   int slope = EMASlopeSign(_Symbol, PERIOD_D1, InpEMAfast, InpSlopeLookback);
   int bias  = (emaF>emaS) ? +1 : (emaF<emaS ? -1 : 0);

   // Shock test
   double atr_curr = Indi_ATR(_Symbol, PERIOD_D1, InpATRperiod_D1, 1);
   double atr_med  = ATRMedian(_Symbol, InpATRperiod_D1, InpATRShockMedianLookback);
   double sd20     = StdDevDailyRet20();
   double ret1     = DailyReturnAbs(1);

   bool shock = false;
   if(atr_med>0 && atr_curr > InpShockATRMult * atr_med) shock = true;
   if(sd20>0 && ret1 > InpShockRetSigma * sd20) shock = true;
   if(shock) return REG_SHOCK;

   // Trend vs Range
   if(adx >= InpADXTrendThresh && slope*bias>0) return REG_TREND;
   if(adx <  InpADXTrendThresh) return REG_RANGE;
   return REG_NONE;
}

//============================ VOL TARGET =============================//
double RealizedVolAnnualPct()
{
   double atr = Indi_ATR(_Symbol, PERIOD_D1, InpATRperiod_D1, 1);
   double c   = DailyClose(1);
   if(atr<=0 || c<=0) return 0.0;
   double vol = (atr/c) * MathSqrt(252.0) * 100.0;
   return vol;
}

double RiskScalerK()
{
   double rv = RealizedVolAnnualPct();
   if(rv<=0) return 1.0;
   double k = InpTargetVolAnnualPct / rv;
   if(k<InpKMin) k=InpKMin;
   if(k>InpKMax) k=InpKMax;
   return k;
}

//=========================== RISK & SIZING ===========================//
double MoneyPerPointPerLot()
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point    = _Point;
   if(tickSize<=0 || tickValue<=0 || point<=0) return 0.0;
   return tickValue * (point / tickSize);
}

double CalcLotsByRisk(double stopPoints, double riskPct)
{
   if(stopPoints<=0) return 0.0;
   double mpp = MoneyPerPointPerLot();
   if(mpp<=0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt = equity * (riskPct/100.0);
   double moneyRiskPerLot = mpp * stopPoints;
   if(moneyRiskPerLot<=0) return 0.0;
   double lots = riskAmt / moneyRiskPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step>0) lots = MathFloor(lots/step)*step;
   if(minL>0) lots = MathMax(lots, minL);
   if(maxL>0) lots = MathMin(lots, maxL);
   return lots;
}

double CurrentOpenRiskPct()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double mpp = MoneyPerPointPerLot();
   if(equity<=0 || mpp<=0) return 0.0;
   double sumRisk=0.0;

   int total=(int)PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string sym; PositionGetString(POSITION_SYMBOL, sym);
      if(sym!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;

      double vol   = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      if(sl<=0) continue;

      double distPts = PriceToPoints(MathAbs(entry - sl));
      double moneyRisk = vol * mpp * distPts;
      sumRisk += (moneyRisk / equity) * 100.0;
   }
   return sumRisk;
}

//=========================== SIGNALS =================================//
// Donchian breakout
bool DonchianBreakout(bool up, ENUM_TIMEFRAMES tf, int len, double &stopPtsOut)
{
   int bars = Bars(_Symbol, tf);
   if(bars < len+5) return false;
   int shift=1;
   double hi = iHigh(_Symbol, tf, iHighest(_Symbol, tf, MODE_HIGH, len, shift));
   double lo = iLow (_Symbol, tf, iLowest (_Symbol, tf, MODE_LOW,  len, shift));
   stopPtsOut = PriceToPoints(Indi_ATR(_Symbol, tf, InpATRperiod_Exec, shift)) * InpTrendSL_ATR_mult;
   if(up)
   {
      return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) > hi+1e-10);
   }
   else
   {
      return (SymbolInfoDouble(_Symbol, SYMBOL_BID) < lo-1e-10);
   }
}

// Range mean-reversion
enum RangeSignal { RNG_NONE=0, RNG_BUY=1, RNG_SELL=2 };
RangeSignal RangeReversionSignal(double &stopPtsOut)
{
   int shift=1;
   double rsi = Indi_RSI(_Symbol, InpRangeTF, InpRSIPeriod, shift);
   double up, md, lo;
   if(!Indi_BBands(_Symbol, InpRangeTF, InpBBPeriod, InpBBDev, shift, up, md, lo)) return RNG_NONE;

   double atr = Indi_ATR(_Symbol, InpRangeTF, InpATRperiod_Exec, shift);
   double extraPts = PriceToPoints(atr) * InpBBExtraSigmas; // extra sigma approx via ATR
   stopPtsOut = PriceToPoints(atr) * InpRangeSL_ATR_mult;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(rsi <= InpRSILow && bid < (lo - PointsToPrice(extraPts))) return RNG_BUY;
   if(rsi >= InpRSIHigh && ask > (up + PointsToPrice(extraPts))) return RNG_SELL;
   return RNG_NONE;
}

// Shock continuation: inside-bar after shock (D1)
bool ShockInsideBarSetup(bool &longSetup, double &stopPtsOut)
{
   if(DetectRegime()!=REG_SHOCK) return false;
   int shift=1;
   // inside bar on execution TF
   double h1=iHigh(_Symbol, InpShockTF, shift);
   double l1=iLow (_Symbol, InpShockTF, shift);
   double h2=iHigh(_Symbol, InpShockTF, shift+1);
   double l2=iLow (_Symbol, InpShockTF, shift+1);
   bool inside = (h1<=h2 && l1>=l2);
   if(!inside) return false;

   // Direction = sign of D1 return
   double c0=iClose(_Symbol, PERIOD_D1, 1);
   double c1=iClose(_Symbol, PERIOD_D1, 2);
   longSetup = (c0>c1);
   stopPtsOut = PriceToPoints(Indi_ATR(_Symbol, InpShockTF, InpATRperiod_Exec, shift));
   return true;
}

//=========================== ORDER OPS ================================//
bool OpenMarket(bool buy, double stopPts, double tpPtsRR=0.0)
{
   if(CurrentOpenRiskPct() >= InpMaxOpenRiskPct) return false;
   int total=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      string s; PositionGetString(POSITION_SYMBOL, s);
      if(s!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;
      total++;
   }
   if(total >= InpMaxOpenPositions) return false;

   double riskPct = InpBaseRiskPct * RiskScalerK();
   double lots = CalcLotsByRisk(stopPts, riskPct);
   if(lots<=0) return false;

   double price = 0.0, sl=0.0, tp=0.0;
   SymbolInfoTick(_Symbol, g_tick);
   if(buy)
   {
      price = g_tick.ask;
      sl = price - PointsToPrice(stopPts);
      if(tpPtsRR>0) tp = price + PointsToPrice(stopPts*tpPtsRR);
      if(!Trade.Buy(lots, NULL, price, sl, tp)) { LogCSV("ERR","Buy "+(string)GetLastError()); return false; }
      Notify("BUY opened");
   }
   else
   {
      price = g_tick.bid;
      sl = price + PointsToPrice(stopPts);
      if(tpPtsRR>0) tp = price - PointsToPrice(stopPts*tpPtsRR);
      if(!Trade.Sell(lots, NULL, price, sl, tp)) { LogCSV("ERR","Sell "+(string)GetLastError()); return false; }
      Notify("SELL opened");
   }
   return true;
}

// Cancel expired pendings (if any) and start cooldown
void CleanupExpiredPendings()
{
   if(InpPendingExpiryMin<=0) return;
   datetime now = TimeCurrent();
   bool cancelled=false;

   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=(long)InpMagicNumber) continue;

      ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t!=ORDER_TYPE_BUY_LIMIT && t!=ORDER_TYPE_SELL_LIMIT &&
         t!=ORDER_TYPE_BUY_STOP  && t!=ORDER_TYPE_SELL_STOP) continue;

      datetime setup=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(now - setup >= InpPendingExpiryMin*60)
      {
         Trade.OrderDelete(ticket);
         cancelled=true;
      }
   }
   if(cancelled)
   {
      g_cooldownUntil = now + InpCooldownMin*60;
      Notify("Cooldown after expiry");
   }
}

// Chandelier trail helper (rounded & min-delta guarded to avoid no-op modifies)
void ApplyATRChandelierTrail()
{
   if(!InpUseATRChandelierTrail) return;

   int    digits        = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point         = _Point;
   int    stops_level   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_from_price= point * (stops_level>0 ? stops_level : 0);
   double min_delta     = MathMax(point, InpTrailMinPoints * point); // require real improvement

   for(int i=0;i<PositionsTotal();i++)
   {
       ulong ticket=PositionGetTicket(i);
       if(ticket==0) continue;
       if(!PositionSelectByTicket(ticket)) continue;
       string s; PositionGetString(POSITION_SYMBOL, s); if(s!=_Symbol) continue;
       if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagicNumber) continue;

       ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
       double sl    = PositionGetDouble(POSITION_SL);
       double tp    = PositionGetDouble(POSITION_TP);

       // Use execution TF ATR for trailing (trend system)
       double atr = Indi_ATR(_Symbol, InpTrendTF, InpATRperiod_Exec, 1);
       if(atr<=0) continue;
       double trail = atr * InpTrailATR_mult;

       SymbolInfoTick(_Symbol, g_tick);
       if(type==POSITION_TYPE_BUY)
       {
          double newSL = NormalizeDouble(g_tick.bid - trail, digits);

          // require real improvement and respect stops level
          if(newSL <= sl + min_delta) continue;
          if((g_tick.bid - newSL) < (min_from_price + point)) continue; // keep distance from current price

          // avoid sending no-op modifies due to server normalization
          if(MathAbs(newSL - sl) < min_delta) continue;

          Trade.PositionModify(_Symbol, newSL, tp);
       }
       else if(type==POSITION_TYPE_SELL)
       {
          double newSL = NormalizeDouble(g_tick.ask + trail, digits);

          if(newSL >= sl - min_delta) continue;
          if((newSL - g_tick.ask) < (min_from_price + point)) continue;

          if(MathAbs(newSL - sl) < min_delta) continue;

          Trade.PositionModify(_Symbol, newSL, tp);
       }
   }
}

//=============================== INIT ================================//
int OnInit()
{
   Trade.SetExpertMagicNumber((long)InpMagicNumber);
   Trade.SetDeviationInPoints((int)InpMaxSlippagePoints);
   if(!SymbolInfoTick(_Symbol, g_tick)){ Print("No initial tick"); return(INIT_FAILED); }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){}

//=============================== TICK ================================//
void OnTick()
{
   if(!SymbolInfoTick(_Symbol, g_tick)) return;
   if(!SpreadOK()) return;
   if(!InSession()) return;
   if(g_cooldownUntil>0 && TimeCurrent()<g_cooldownUntil) return;

   Regime regime = DetectRegime();
   double stopPts=0.0;

   // Trend
   if(regime==REG_TREND)
   {
      bool upBias = (Indi_EMA(_Symbol, PERIOD_D1, InpEMAfast, 1) > Indi_EMA(_Symbol, PERIOD_D1, InpEMAslow, 1));
      if(DonchianBreakout(upBias, InpTrendTF, InpDonchian, stopPts))
      {
         OpenMarket(upBias, stopPts, 0.0);
      }
   }
   // Range
   else if(regime==REG_RANGE)
   {
      double stp=0.0; RangeSignal sig = RangeReversionSignal(stp);
      if(sig==RNG_BUY)  OpenMarket(true,  stp, 1.0);
      if(sig==RNG_SELL) OpenMarket(false, stp, 1.0);
   }
   // Shock
   else if(regime==REG_SHOCK)
   {
      bool longSetup=false; double stp=0.0;
      if(ShockInsideBarSetup(longSetup, stp))
      {
         double h1=iHigh(_Symbol, InpShockTF, 1);
         double l1=iLow (_Symbol, InpShockTF, 1);
         if(longSetup && g_tick.ask > h1+1e-10)  OpenMarket(true,  stp, InpShockTP_RR);
         if(!longSetup && g_tick.bid < l1-1e-10) OpenMarket(false, stp, InpShockTP_RR);
      }
   }

   CleanupExpiredPendings();
   ApplyATRChandelierTrail();
}
//+------------------------------------------------------------------+
