//+------------------------------------------------------------------+
//|                             PropFirm_Compliance_Guard_v1_07.mq5  |
//|     Compile-safe: no Calendar, while-loops, safe order enums     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.070"
#property description "Prop-firm compliance guard: daily loss, rel DD, exposure caps, sessions, Friday/weekend lock, soft/hard lock."

#include <Trade/Trade.mqh>

// ========================== Inputs ===========================================
input string InpSuiteTag                  = "PFG";
input bool   InpEnableHardLock            = true;
input bool   InpEnableSoftLock            = true;

input double InpMaxDailyLossPct           = 2.50;
input double InpMaxDailyLossAmt           = 0.00;
input bool   InpUseTrailingDailyAnchor    = true;
input double InpMaxRelativeDDPct          = 8.00;
input bool   InpCloseAllOnDailyBreach     = true;
input int    InpCooldownMinutes           = 1440;

input double InpMaxLotsTotal              = 2.00;
input int    InpMaxPositionsTotal         = 20;
input double InpMaxLotsPerSymbol          = 1.00;
input int    InpMaxPositionsPerSymbol     = 10;
input int    InpMaxEntriesPerMinute       = 10;

input bool   InpUseSessionWindows         = true;
input string InpSession1                  = "00:00-23:59";
input string InpSession2                  = "";
input bool   InpDisableFriday             = false;
input bool   InpCloseBeforeWeekend        = true;
input int    InpMinutesBeforeWeekendClose = 10;

input bool   InpUseNewsGuard              = false;   // (stubbed; always false)

input bool   InpPushNotifications         = true;
input bool   InpPopupAlerts               = true;
input int    InpTimerSeconds              = 2;

// ========================== State ============================================
CTrade   trade;
datetime g_day=0;
double   g_equity_anchor=0.0;
double   g_equity_peak=0.0;
double   g_equity_low=0.0;
bool     g_soft_locked=false;
datetime g_soft_lock_until=0;
string   g_lock_gv_name;

// ========================== Helpers ==========================================
string Join(const string a, const string b, const string sep="-")
{
   if(a=="") return b;
   if(b=="") return a;
   return a+sep+b;
}

string TodayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

string AccountKey() { return (string)AccountInfoInteger(ACCOUNT_LOGIN); }

string GVName_Lock()        { return Join(InpSuiteTag, Join("LOCK_UNTIL", AccountKey(), "_"), "_"); }
string GVName_EquityPeak()  { return Join(InpSuiteTag, Join("EQUITY_PEAK", AccountKey(), "_"), "_"); }
string GVName_DailyAnchor() { return Join(InpSuiteTag, Join("DAILY_ANCHOR_"+TodayKey(), AccountKey(), "_"), "_"); }

void Push(const string msg)
{
   if(InpPushNotifications) SendNotification(msg);
   if(InpPopupAlerts) Alert(msg);
   Print(msg);
}

bool ParseSession(const string sess, int &startMin, int &endMin)
{
   startMin=-1; endMin=-1;
   if(sess=="") return false;

   string parts[]; int n=StringSplit(sess,'-',parts);
   if(n!=2) return false;

   string t1[]; string t2[];
   if(StringSplit(parts[0],':',t1)!=2) return false;
   if(StringSplit(parts[1],':',t2)!=2) return false;

   int h1=(int)StringToInteger(t1[0]); int m1=(int)StringToInteger(t1[1]);
   int h2=(int)StringToInteger(t2[0]); int m2=(int)StringToInteger(t2[1]);
   if(h1<0||h1>23||h2<0||h2>23||m1<0||m1>59||m2<0||m2>59) return false;

   startMin=h1*60+m1; endMin=h2*60+m2;
   return true;
}

bool InSessionNow()
{
   if(!InpUseSessionWindows) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int nowMin=dt.hour*60+dt.min;

   int s1=0,e1=0,s2=0,e2=0;
   bool ok1=ParseSession(InpSession1,s1,e1);
   bool ok2=ParseSession(InpSession2,s2,e2);

   bool pass=false;
   if(ok1)
   {
      if(s1<=e1) pass = pass || (nowMin>=s1 && nowMin<=e1);
      else       pass = pass || (nowMin>=s1 || nowMin<=e1);
   }
   if(ok2)
   {
      if(s2<=e2) pass = pass || (nowMin>=s2 && nowMin<=e2);
      else       pass = pass || (nowMin>=s2 || nowMin<=e2);
   }
   return pass;
}

bool IsFridayCloseWindow()
{
   if(!InpCloseBeforeWeekend) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week!=5) return false;

   int nowMin = dt.hour*60+dt.min;
   int closeMin = 22*60; // assumed 22:00 server
   int diff = closeMin - nowMin;
   return (diff<=InpMinutesBeforeWeekendClose && diff>=0);
}

// Stubbed (always false)
bool IsNewsBlackout(){ return false; }

// ========================== Stats / Exposure =================================
double TotalOpenLots()
{
   double lots=0.0;
   int total=PositionsTotal();
   int i=0;
   while(i<total)
   {
      if(PositionSelectByIndex(i))
         lots += PositionGetDouble(POSITION_VOLUME);
      i++;
   }
   return lots;
}

double LotsPerSymbol(const string sym)
{
   double lots=0.0;
   int total=PositionsTotal();
   int i=0;
   while(i<total)
   {
      if(PositionSelectByIndex(i))
      {
         if(PositionGetString(POSITION_SYMBOL)==sym)
            lots += PositionGetDouble(POSITION_VOLUME);
      }
      i++;
   }
   return lots;
}

int PositionsPerSymbol(const string sym)
{
   int cnt=0;
   int total=PositionsTotal();
   int i=0;
   while(i<total)
   {
      if(PositionSelectByIndex(i))
      {
         if(PositionGetString(POSITION_SYMBOL)==sym) cnt++;
      }
      i++;
   }
   return cnt;
}

int EntriesInLastMinute()
{
   datetime now=TimeCurrent();
   int count=0;
   int total=PositionsTotal();
   int i=0;
   while(i<total)
   {
      if(PositionSelectByIndex(i))
      {
         datetime t=(datetime)PositionGetInteger(POSITION_TIME);
         if(now - t <= 60) count++;
      }
      i++;
   }
   return count;
}

// ========================== Flatten & Cancel =================================
bool CloseAllPositions()
{
   bool ok=true;
   int i=PositionsTotal()-1;
   while(i>=0)
   {
      if(PositionSelectByIndex(i))
      {
         string sym=PositionGetString(POSITION_SYMBOL);
         if(!trade.PositionClose(sym))
         {
            ok=false;
            int err=GetLastError();
            Print("CloseAllPositions: failed sym=",sym," err=",err);
            ResetLastError();
         }
      }
      i--;
   }
   return ok;
}

void DeleteAllPending()
{
   int i=OrdersTotal()-1;
   while(i>=0)
   {
      // Use MQL5 enums SELECT_BY_INDEX + ORDER_POOL_TRADES
      if(OrderSelect(i, SELECT_BY_INDEX, ORDER_POOL_TRADES))
      {
         ulong ticket=(ulong)OrderGetInteger(ORDER_TICKET);
         if(ticket>0 && !trade.OrderDelete(ticket))
         {
            int err=GetLastError();
            Print("DeleteAllPending: failed #",ticket," err=",err);
            ResetLastError();
         }
      }
      i--;
   }
}

// ========================== DD / Persistence =================================
void LoadPersistent()
{
   string kpeak=GVName_EquityPeak();
   if(GlobalVariableCheck(kpeak)) g_equity_peak=GlobalVariableGet(kpeak);
   else { g_equity_peak=AccountInfoDouble(ACCOUNT_EQUITY); GlobalVariableSet(kpeak,g_equity_peak); }

   string kday=GVName_DailyAnchor();
   if(GlobalVariableCheck(kday)) g_equity_anchor=GlobalVariableGet(kday);
   else { g_equity_anchor=AccountInfoDouble(ACCOUNT_EQUITY); GlobalVariableSet(kday,g_equity_anchor); }

   g_lock_gv_name = GVName_Lock();
   if(GlobalVariableCheck(g_lock_gv_name))
      g_soft_lock_until=(datetime)(long)GlobalVariableGet(g_lock_gv_name);
   else g_soft_lock_until=0;
}

void SavePersistent()
{
   GlobalVariableSet(GVName_EquityPeak(), g_equity_peak);
   GlobalVariableSet(GVName_DailyAnchor(), g_equity_anchor);
   if(g_soft_lock_until>0) GlobalVariableSet(g_lock_gv_name,(double)(long)g_soft_lock_until);
}

void ResetDailyAnchorIfNewDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime daystart=StructToTime(dt) - (dt.hour*3600 + dt.min*60 + dt.sec);
   if(g_day!=daystart)
   {
      g_day=daystart;
      g_equity_anchor=AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(GVName_DailyAnchor(), g_equity_anchor);
      g_soft_locked=false;
      g_soft_lock_until=0;
      GlobalVariableDel(g_lock_gv_name);
      Push(StringFormat("%s: New trading day. Anchor equity=%.2f", InpSuiteTag, g_equity_anchor));
   }
}

void UpdateEquityPeaks()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_equity_peak) g_equity_peak=eq;
   if(InpUseTrailingDailyAnchor && eq>g_equity_anchor) g_equity_anchor=eq;
   if(g_equity_low==0.0 || eq<g_equity_low) g_equity_low=eq;
}

bool DailyLossBreached(double &pct_out, double &amt_out)
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double anchor=g_equity_anchor;
   if(anchor<=0.0){ pct_out=0.0; amt_out=0.0; return false; }
   amt_out = anchor - eq;
   pct_out = (amt_out/anchor)*100.0;
   bool pctBreach=(InpMaxDailyLossPct>0.0 && pct_out>=InpMaxDailyLossPct);
   bool amtBreach=(InpMaxDailyLossAmt>0.0 && amt_out>=InpMaxDailyLossAmt);
   return (pctBreach || amtBreach);
}

bool RelativeDDBreached(double &pct_out)
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_equity_peak<=0.0){ pct_out=0.0; return false; }
   pct_out=(g_equity_peak-eq)/g_equity_peak*100.0;
   return (InpMaxRelativeDDPct>0.0 && pct_out>=InpMaxRelativeDDPct);
}

bool ExposureBreached(string &reason)
{
   double lotTot=TotalOpenLots();
   if(InpMaxLotsTotal>0.0 && lotTot>InpMaxLotsTotal)
   { reason=StringFormat("Total lots %.2f > cap %.2f",lotTot,InpMaxLotsTotal); return true; }

   int posTot=PositionsTotal();
   if(InpMaxPositionsTotal>0 && posTot>InpMaxPositionsTotal)
   { reason=StringFormat("Positions %d > cap %d",posTot,InpMaxPositionsTotal); return true; }

   int recent=EntriesInLastMinute();
   if(InpMaxEntriesPerMinute>0 && recent>InpMaxEntriesPerMinute)
   { reason=StringFormat("Entries last 60s %d > cap %d",recent,InpMaxEntriesPerMinute); return true; }

   int total=PositionsTotal();
   int i=0;
   while(i<total)
   {
      if(PositionSelectByIndex(i))
      {
         string sym=PositionGetString(POSITION_SYMBOL);
         double lots=LotsPerSymbol(sym);
         int cnt=PositionsPerSymbol(sym);
         if(InpMaxLotsPerSymbol>0.0 && lots>InpMaxLotsPerSymbol)
         { reason=StringFormat("%s lots %.2f > cap %.2f",sym,lots,InpMaxLotsPerSymbol); return true; }
         if(InpMaxPositionsPerSymbol>0 && cnt>InpMaxPositionsPerSymbol)
         { reason=StringFormat("%s positions %d > cap %d",sym,cnt,InpMaxPositionsPerSymbol); return true; }
      }
      i++;
   }
   return false;
}

void ApplyLock(string why, const bool hardClose)
{
   g_soft_locked=true;
   g_soft_lock_until=TimeCurrent()+InpCooldownMinutes*60;
   GlobalVariableSet(g_lock_gv_name,(double)(long)g_soft_lock_until);

   Push(StringFormat("%s LOCKED: %s. Cooldown %d min%s",
        InpSuiteTag, why, InpCooldownMinutes, hardClose?" (hard)":" (soft)"));

   if(hardClose && InpEnableHardLock)
   { DeleteAllPending(); CloseAllPositions(); }
}

bool SoftLockActive()
{
   if(g_soft_locked && TimeCurrent()<=g_soft_lock_until) return true;
   if(GlobalVariableCheck(g_lock_gv_name))
   {
      datetime until=(datetime)(long)GlobalVariableGet(g_lock_gv_name);
      if(TimeCurrent()<=until){ g_soft_locked=true; g_soft_lock_until=until; return true; }
   }
   g_soft_locked=false; g_soft_lock_until=0; GlobalVariableDel(g_lock_gv_name);
   return false;
}

// ========================== UI ===============================================
void DrawDashboard()
{
   string name=InpSuiteTag+"_HUD";
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,10);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,10);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,name,OBJPROP_COLOR,SoftLockActive()?clrRed:clrLime);
   }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   string txt=StringFormat("%s | Eq: %.2f  Peak: %.2f  Anchor: %.2f  SoftLock:%s",
                           InpSuiteTag,eq,g_equity_peak,g_equity_anchor,SoftLockActive()?"ON":"OFF");
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_COLOR,SoftLockActive()?clrRed:clrLime);
}

// ========================== Core =============================================
bool CanOpenNow()
{
   if(SoftLockActive()) return false;
   if(InpUseSessionWindows && !InSessionNow()) return false;
   if(IsFridayCloseWindow()) return false;
   if(InpDisableFriday)
   {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
      if(dt.day_of_week==5) return false;
   }
   if(InpUseNewsGuard && IsNewsBlackout()) return false; // stubbed false
   return true;
}

void Evaluate()
{
   ResetDailyAnchorIfNewDay();
   UpdateEquityPeaks();

   if(InpCloseBeforeWeekend && IsFridayCloseWindow())
      ApplyLock("Weekend close window", true);

   if(InpUseSessionWindows && !InSessionNow())
      ApplyLock("Outside trading session", InpEnableHardLock);

   double ddPct=0.0, ddAmt=0.0;
   if(DailyLossBreached(ddPct,ddAmt))
      ApplyLock(StringFormat("Daily loss breached: %.2f%% / %.2f",ddPct,ddAmt), InpCloseAllOnDailyBreach);

   double relPct=0.0;
   if(RelativeDDBreached(relPct))
      ApplyLock(StringFormat("Relative DD breached: %.2f%%",relPct), true);

   string reason="";
   if(ExposureBreached(reason))
      ApplyLock("Exposure cap: "+reason, true);

   DrawDashboard();
}

// ========================== Handlers =========================================
int OnInit()
{
   trade.SetAsyncMode(false);
   LoadPersistent();
   EventSetTimer(InpTimerSeconds);
   Print(InpSuiteTag,": Compliance Guard started.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SavePersistent();
   Print(InpSuiteTag,": stopped. Reason=",reason);
}

void OnTimer() { Evaluate(); }

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&      request,
                        const MqlTradeResult&       result)
{
   // Optional: hook for instant reactions
}
