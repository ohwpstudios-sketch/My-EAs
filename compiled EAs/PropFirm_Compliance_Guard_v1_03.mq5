//+------------------------------------------------------------------+
//|                                    PropFirm_Compliance_Guard.mq5 |
//|                                      v1.03 (robust compile-safe) |
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      "https://example.com"
#property version   "1.030"
#property strict

#include <Trade/Trade.mqh>

// ============================================================================
// PURPOSE
// Stand-alone EA enforcing prop-firm style risk/compliance rules: daily loss,
// relative DD, exposure caps, sessions, Friday/weekend, optional news blackout.
// All code uses conservative, widely-supported MQL5 APIs.
// ============================================================================

// ----------------------- Inputs: Identity & Mode -----------------------------
input string InpSuiteTag                  = "PFG";   // Tag prefix for comments/files
input bool   InpEnableHardLock            = true;    // On breach: close positions & delete pendings
input bool   InpEnableSoftLock            = true;    // On breach: block new entries via GlobalVariable

// ----------------------- Inputs: Drawdown Rules ------------------------------
input double InpMaxDailyLossPct           = 2.50;    // Max DAILY loss % from daily anchor equity
input double InpMaxDailyLossAmt           = 0.00;    // Max DAILY loss absolute (deposit currency). 0=disabled
input bool   InpUseTrailingDailyAnchor    = true;    // Trailing intraday high as anchor
input double InpMaxRelativeDDPct          = 8.00;    // Max RELATIVE drawdown % from ALL-TIME equity peak
input bool   InpCloseAllOnDailyBreach     = true;    // Close all positions on daily breach
input int    InpCooldownMinutes           = 1440;    // Cooldown minutes after breach

// ----------------------- Inputs: Exposure Caps -------------------------------
input double InpMaxLotsTotal              = 2.00;    // Cap total open lots across all symbols
input int    InpMaxPositionsTotal         = 20;      // Cap total open positions
input double InpMaxLotsPerSymbol          = 1.00;    // Cap open lots per symbol
input int    InpMaxPositionsPerSymbol     = 10;      // Cap open positions per symbol
input int    InpMaxEntriesPerMinute       = 10;      // Max positions opened in last 60 seconds

// ----------------------- Inputs: Trade Windows -------------------------------
input bool   InpUseSessionWindows         = true;    // Only trade within time windows
input string InpSession1                  = "00:00-23:59"; // HH:MM-HH:MM
input string InpSession2                  = "";            // Optional second window
input bool   InpDisableFriday             = false;         // Block on Fridays
input bool   InpCloseBeforeWeekend        = true;          // Auto-close before market close (Fri)
input int    InpMinutesBeforeWeekendClose = 10;            // Minutes before close to flatten

// ----------------------- Inputs: News Guard ----------------------------------
input bool   InpUseNewsGuard              = false;   // Use MT5 economic calendar
input string InpCurrenciesWatchlist       = "USD,EUR,GBP,JPY,CAD,AUD,NZD,CHF,XAU"; // CSV
input int    InpNewsBlackoutBeforeMin     = 30;      // Minutes before high/medium impact
input int    InpNewsBlackoutAfterMin      = 30;      // Minutes after high/medium impact
input int    InpMinNewsImportance         = 2;       // 2=High, 1=Medium, 0=Low

// ----------------------- Inputs: Notifications -------------------------------
input bool   InpPushNotifications         = true;    // Mobile push (set MetaQuotes ID)
input bool   InpPopupAlerts               = true;    // Popup alerts
input int    InpTimerSeconds              = 2;       // Evaluation interval in seconds

// ----------------------- Runtime & State -------------------------------------
CTrade        trade;
datetime      g_day=0;                 // Current anchor day (00:00 server)
double        g_equity_anchor = 0.0;   // Daily anchor equity
double        g_equity_peak   = 0.0;   // All-time equity peak
double        g_equity_low    = 0.0;   // Intraday low equity
bool          g_soft_locked   = false;
datetime      g_soft_lock_until = 0;   // When soft lock expires (server time)
string        g_lock_gv_name  = "";    // GlobalVariable name for soft lock

// ----------------------------- Helpers ---------------------------------------
string Join(string a, string b, string sep="-")
{
   if(a=="") return b;
   if(b=="") return a;
   return a+sep+b;
}

// Trim spaces both sides (compat-friendly)
string TrimBoth(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

string TodayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

string AccountKey()
{
   long login=(long)AccountInfoInteger(ACCOUNT_LOGIN);
   return (string)login;
}

string GVName_Lock()        { return Join(InpSuiteTag, Join("LOCK_UNTIL", AccountKey(), "_"), "_"); }
string GVName_EquityPeak()  { return Join(InpSuiteTag, Join("EQUITY_PEAK", AccountKey(), "_"), "_"); }
string GVName_DailyAnchor() { return Join(InpSuiteTag, Join("DAILY_ANCHOR_"+TodayKey(), AccountKey(), "_"), "_"); }

void Push(string msg)
{
   if(InpPushNotifications) SendNotification(msg);
   if(InpPopupAlerts) Alert(msg);
   Print(msg);
}

bool ParseSession(string sess, int &startMin, int &endMin)
{
   startMin=-1; endMin=-1;
   if(sess=="") return false;
   string parts[]; int n=StringSplit(sess, '-', parts);
   if(n!=2) return false;
   string a=parts[0], b=parts[1];
   string t1[]; string t2[];
   if(StringSplit(a, ':', t1)!=2) return false;
   if(StringSplit(b, ':', t2)!=2) return false;
   int h1=(int)StringToInteger(t1[0]); int m1=(int)StringToInteger(t1[1]);
   int h2=(int)StringToInteger(t2[0]); int m2=(int)StringToInteger(t2[1]);
   if(h1<0||h1>23||h2<0||h2>23||m1<0||m1>59||m2<0||m2>59) return false;
   startMin=h1*60+m1;
   endMin=h2*60+m2;
   return true;
}

bool InSessionNow()
{
   if(!InpUseSessionWindows) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour*60+dt.min;
   int s1=0,e1=0,s2=0,e2=0;
   bool ok1=ParseSession(InpSession1, s1,e1);
   bool ok2=ParseSession(InpSession2, s2,e2);
   bool pass=false;
   if(ok1)
   {
      if(s1<=e1) pass = pass || (nowMin>=s1 && nowMin<=e1);
      else       pass = pass || (nowMin>=s1 || nowMin<=e1); // overnight
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
   if(dt.day_of_week==5 /* Friday */)
   {
      int assumedCloseHour = 22;
      int assumedCloseMin  = 0;
      int nowMin = dt.hour*60+dt.min;
      int closeMin = assumedCloseHour*60+assumedCloseMin;
      int diff = closeMin - nowMin;
      return (diff <= InpMinutesBeforeWeekendClose && diff >= 0);
   }
   return false;
}

// ---- News guard (compile-safe) ----------------------------------------------
// Uses Calendar* APIs if available. If not available / disabled, returns false.
bool IsNewsBlackout()
{
   if(!InpUseNewsGuard) return false;

   // Prepare watchlist
   string currs[]; int n=StringSplit(InpCurrenciesWatchlist, ',', currs);
   for(int i=0;i<n;i++) currs[i]=TrimBoth(currs[i]);

   datetime now=TimeCurrent();
   datetime t_from = now - 3600; // look back 1h to catch ongoing
   datetime t_to   = now + (InpNewsBlackoutBeforeMin+InpNewsBlackoutAfterMin)*60;

   if(!CalendarSelect(t_from, t_to)) return false;

   int ev_total = (int)CalendarEventsTotal();
   MqlCalendarEvent ev;
   MqlCalendarValue val;

   for(int i=0;i<ev_total;i++)
   {
      ulong evid = CalendarEventByIndex(i);
      if(!CalendarEventById(evid, ev)) continue;

      if(ev.importance < InpMinNewsImportance) continue;

      // currency filter
      bool watch=false;
      for(int k=0;k<n;k++)
      {
         if(ev.currency==currs[k]) { watch=true; break; }
      }
      if(!watch) continue;

      // Last value/time for this event
      if(!CalendarValueLast(evid, val)) continue;
      datetime t = val.time;

      if((t - now) <= InpNewsBlackoutBeforeMin*60 && (now - t) <= InpNewsBlackoutAfterMin*60)
         return true;
   }
   return false;
}

// ------------------------- Exposure & stats ----------------------------------
double TotalOpenLots()
{
   double lots=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double LotsPerSymbol(string sym)
{
   double lots=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string s=PositionGetString(POSITION_SYMBOL);
      if(s==sym) lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

int PositionsPerSymbol(string sym)
{
   int cnt=0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string s=PositionGetString(POSITION_SYMBOL);
      if(s==sym) cnt++;
   }
   return cnt;
}

int EntriesInLastMinute()
{
   datetime now=TimeCurrent();
   int count=0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      datetime t=(datetime)PositionGetInteger(POSITION_TIME);
      if(now - t <= 60) count++;
   }
   return count;
}

// ------------------------- Flatten & cancel ----------------------------------
bool CloseAllPositions()
{
   bool ok=true;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string sym=PositionGetString(POSITION_SYMBOL);
      if(!trade.PositionClose(sym))
      {
         ok=false;
         Print("CloseAllPositions: failed to close ", sym, " err=", GetLastError());
         ResetLastError();
      }
   }
   return ok;
}

void DeleteAllPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      ulong ticket=(ulong)OrderGetInteger(ORDER_TICKET);
      if(ticket==0) continue;
      if(!trade.OrderDelete(ticket))
      {
         Print("DeleteAllPending: failed to delete #", ticket, " err=", GetLastError());
         ResetLastError();
      }
   }
}

// ------------------------- Drawdown checks -----------------------------------
void LoadPersistent()
{
   // All-time peak
   string kpeak=GVName_EquityPeak();
   if(GlobalVariableCheck(kpeak)) g_equity_peak = GlobalVariableGet(kpeak);
   else { g_equity_peak = AccountInfoDouble(ACCOUNT_EQUITY); GlobalVariableSet(kpeak, g_equity_peak); }

   // Daily anchor
   string kday=GVName_DailyAnchor();
   if(GlobalVariableCheck(kday)) g_equity_anchor = GlobalVariableGet(kday);
   else { g_equity_anchor = AccountInfoDouble(ACCOUNT_EQUITY); GlobalVariableSet(kday, g_equity_anchor); }

   // Lock variable
   g_lock_gv_name = GVName_Lock();
   if(GlobalVariableCheck(g_lock_gv_name))
      g_soft_lock_until = (datetime)(long)GlobalVariableGet(g_lock_gv_name);
   else
      g_soft_lock_until = 0;
}

void SavePersistent()
{
   GlobalVariableSet(GVName_EquityPeak(), g_equity_peak);
   GlobalVariableSet(GVName_DailyAnchor(), g_equity_anchor);
   if(g_soft_lock_until>0) GlobalVariableSet(g_lock_gv_name, (double)(long)g_soft_lock_until);
}

void ResetDailyAnchorIfNewDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime daystart=StructToTime(dt) - (dt.hour*3600 + dt.min*60 + dt.sec);
   if(g_day != daystart)
   {
      g_day = daystart;
      g_equity_anchor = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(GVName_DailyAnchor(), g_equity_anchor);
      g_soft_locked=false;
      g_soft_lock_until=0;
      GlobalVariableDel(g_lock_gv_name);
      Push(StringFormat("%s: New trading day. Anchor equity=%.2f", InpSuiteTag, g_equity_anchor));
   }
}

void UpdateEquityPeaks()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_equity_peak) g_equity_peak = eq;
   if(InpUseTrailingDailyAnchor && eq > g_equity_anchor)
      g_equity_anchor = eq;
   if(g_equity_low==0.0 || eq<g_equity_low)
      g_equity_low = eq;
}

bool DailyLossBreached(double &pct_out, double &amt_out)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double anchor = g_equity_anchor;
   if(anchor<=0.0) { pct_out=0.0; amt_out=0.0; return false; }
   amt_out = anchor - eq;
   pct_out = (amt_out/anchor)*100.0;
   bool pctBreach = (InpMaxDailyLossPct>0.0 && pct_out >= InpMaxDailyLossPct);
   bool amtBreach = (InpMaxDailyLossAmt>0.0 && amt_out >= InpMaxDailyLossAmt);
   return (pctBreach || amtBreach);
}

bool RelativeDDBreached(double &pct_out)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_equity_peak<=0.0) { pct_out=0.0; return false; }
   pct_out = (g_equity_peak - eq)/g_equity_peak*100.0;
   return (InpMaxRelativeDDPct>0.0 && pct_out >= InpMaxRelativeDDPct);
}

bool ExposureBreached(string &reason)
{
   // Total lots
   double lotTot = TotalOpenLots();
   if(InpMaxLotsTotal>0.0 && lotTot > InpMaxLotsTotal)
   {
      reason = StringFormat("Total lots %.2f > cap %.2f", lotTot, InpMaxLotsTotal);
      return true;
   }
   // Total positions
   int posTot = PositionsTotal();
   if(InpMaxPositionsTotal>0 && posTot > InpMaxPositionsTotal)
   {
      reason = StringFormat("Positions %d > cap %d", posTot, InpMaxPositionsTotal);
      return true;
   }
   // Rate limiting
   int recent = EntriesInLastMinute();
   if(InpMaxEntriesPerMinute>0 && recent > InpMaxEntriesPerMinute)
   {
      reason = StringFormat("Entries last 60s %d > cap %d", recent, InpMaxEntriesPerMinute);
      return true;
   }
   // Per-symbol checks
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string sym=PositionGetString(POSITION_SYMBOL);
      double lots=LotsPerSymbol(sym);
      int    cnt =PositionsPerSymbol(sym);

      if(InpMaxLotsPerSymbol>0.0 && lots>InpMaxLotsPerSymbol)
      {
         reason = StringFormat("%s lots %.2f > cap %.2f", sym, lots, InpMaxLotsPerSymbol);
         return true;
      }
      if(InpMaxPositionsPerSymbol>0 && cnt>InpMaxPositionsPerSymbol)
      {
         reason = StringFormat("%s positions %d > cap %d", sym, cnt, InpMaxPositionsPerSymbol);
         return true;
      }
   }
   return false;
}

void ApplyLock(string why, bool hardClose)
{
   g_soft_locked = true;
   g_soft_lock_until = TimeCurrent() + InpCooldownMinutes*60;
   GlobalVariableSet(g_lock_gv_name, (double)(long)g_soft_lock_until);

   string msg = StringFormat("%s LOCKED: %s. Cooldown %d min%s",
                              InpSuiteTag, why, InpCooldownMinutes, hardClose?" (hard)":" (soft)");
   Push(msg);

   if(hardClose && InpEnableHardLock)
   {
      DeleteAllPending();
      CloseAllPositions();
   }
}

bool SoftLockActive()
{
   if(g_soft_locked && TimeCurrent()<=g_soft_lock_until) return true;
   if(GlobalVariableCheck(g_lock_gv_name))
   {
      datetime until=(datetime)(long)GlobalVariableGet(g_lock_gv_name);
      if(TimeCurrent()<=until) { g_soft_locked=true; g_soft_lock_until=until; return true; }
   }
   // Clear stale
   g_soft_locked=false; g_soft_lock_until=0; GlobalVariableDel(g_lock_gv_name);
   return false;
}

// ------------------------------- UI ------------------------------------------
void DrawDashboard()
{
   string name = InpSuiteTag+"_HUD";
   if(ObjectFind(0,name) < 0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,10);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,10);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,name,OBJPROP_COLOR,SoftLockActive()?clrRed:clrLimeGreen);
   }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   string txt = StringFormat("%s | Eq: %.2f  Peak: %.2f  Anchor: %.2f  SoftLock:%s",
                             InpSuiteTag, eq, g_equity_peak, g_equity_anchor, SoftLockActive()?"ON":"OFF");
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_COLOR,SoftLockActive()?clrRed:clrLimeGreen);
}

// ------------------------------- Core ----------------------------------------
void Evaluate()
{
   ResetDailyAnchorIfNewDay();
   UpdateEquityPeaks();

   // Friday close
   if(InpCloseBeforeWeekend && IsFridayCloseWindow())
      ApplyLock("Weekend close window", true);

   // Session window
   if(InpUseSessionWindows && !InSessionNow())
      ApplyLock("Outside trading session", InpEnableHardLock);

   // Friday disable
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpDisableFriday && dt.day_of_week==5)
      ApplyLock("Friday disabled", InpEnableHardLock);

   // News
   if(IsNewsBlackout())
      ApplyLock("News blackout", false);

   // Drawdown
   double ddPct=0.0, ddAmt=0.0;
   if(DailyLossBreached(ddPct, ddAmt))
   {
      string why=StringFormat("Daily loss breached: %.2f%% / %.2f", ddPct, ddAmt);
      ApplyLock(why, InpCloseAllOnDailyBreach);
   }

   double relPct=0.0;
   if(RelativeDDBreached(relPct))
   {
      string why=StringFormat("Relative DD breached: %.2f%%", relPct);
      ApplyLock(why, true);
   }

   // Exposure
   string reason="";
   if(ExposureBreached(reason))
      ApplyLock("Exposure cap: "+reason, true);

   DrawDashboard();
}

// ------------------------ MT5 standard handlers ------------------------------
int OnInit()
{
   trade.SetAsyncMode(false);
   g_day = 0;
   LoadPersistent();
   EventSetTimer(InpTimerSeconds);
   Print(InpSuiteTag,": Prop-Firm Compliance Guard started.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SavePersistent();
   Print(InpSuiteTag,": stopped. Reason=",reason);
}

void OnTimer()
{
   Evaluate();
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&      request,
                        const MqlTradeResult&       result)
{
   // Reserved for immediate reactions to new orders if needed.
}
