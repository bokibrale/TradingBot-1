#property strict
#property version "1.00"
#property description "EURUSD H1 EMA crossover; demo/tester only. No profitability guarantee."

input string InpSymbol             = "EURUSD"; // Broker suffix supported, e.g. EURUSD.a
input ENUM_TIMEFRAMES InpTimeframe  = PERIOD_H1;
input int    InpFastEMA             = 20;
input int    InpSlowEMA             = 50;
input int    InpATRPeriod           = 14;
input double InpSLATR               = 1.5;
input double InpTPATR               = 2.0;
input double InpRiskPercent         = 0.5; // Hard maximum 0.5%
input double InpCostReservePercent  = 10.0; // Portion of risk budget reserved for costs
input double InpDailyLossPercent    = 2.0; // Hard maximum 2%
input int    InpMaxSpreadPoints     = 20;  // 20 points = 2 pips on a 5-digit symbol
input int    InpDeviationPoints     = 10;
input ulong  InpMagic               = 205014;
input bool   InpCloseOnDailyLimit   = true;

int fast_handle=INVALID_HANDLE, slow_handle=INVALID_HANDLE, atr_handle=INVALID_HANDLE;
datetime last_bar=0;
int day_id=0;
double day_equity=0;
bool daily_locked=false;
string day_key="";

void Log(const string message) { Print("SmartForexBot | ",message); }
bool IsTester() { return (bool)MQLInfoInteger(MQL_TESTER); }
bool SafeAccount()
{
   return IsTester() || AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO;
}
int DateID(const datetime when)
{
   MqlDateTime d;
   TimeToStruct(when,d);
   return d.year*10000+d.mon*100+d.day;
}
string DailyKey(const int date)
{
   // Account-wide within this terminal, shared across EA instances/magic numbers.
   string server=AccountInfoString(ACCOUNT_SERVER);
   uint hash=0;
   for(int i=0;i<StringLen(server);i++) hash=hash*31+(uint)StringGetCharacter(server,i);
   return StringFormat("SFB.%I64d.%u.%d",AccountInfoInteger(ACCOUNT_LOGIN),hash,date);
}
bool UpdateDailyState()
{
   int today=DateID(TimeCurrent());
   if(today!=day_id)
   {
      day_id=today;
      day_key=DailyKey(today);
      day_equity=AccountInfoDouble(ACCOUNT_EQUITY);
      daily_locked=false;
      if(!IsTester())
      {
         if(GlobalVariableCheck(day_key+".equity"))
            day_equity=GlobalVariableGet(day_key+".equity");
         else if(GlobalVariableSet(day_key+".equity",day_equity)==0)
         {
            Log("Cannot persist daily equity; entries disabled.");
            day_id=0;
            return false;
         }
         daily_locked=GlobalVariableCheck(day_key+".locked");
         GlobalVariablesFlush();
      }
      Log(StringFormat("Daily baseline equity %.2f; locked=%s",day_equity,daily_locked?"true":"false"));
   }
   if(!MathIsValidNumber(day_equity) || day_equity<=0) return false;
   if(!IsTester() && GlobalVariableCheck(day_key+".locked")) daily_locked=true;
   if(!daily_locked && AccountInfoDouble(ACCOUNT_EQUITY)<=day_equity*(1.0-InpDailyLossPercent/100.0))
   {
      daily_locked=true;
      Log("Daily equity loss limit reached; entries locked until next broker day.");
   }
   if(daily_locked && !IsTester())
   {
      if(!GlobalVariableCheck(day_key+".locked"))
      {
         if(GlobalVariableSet(day_key+".locked",1.0)==0) Log("ERROR: cannot persist daily lock.");
         GlobalVariablesFlush();
      }
   }
   return true;
}
bool TradingAllowed()
{
   return SafeAccount() && (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)
       && (bool)MQLInfoInteger(MQL_TRADE_ALLOWED)
       && (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)
       && (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
}
bool FillingMode(ENUM_ORDER_TYPE_FILLING &mode)
{
   long flags=SymbolInfoInteger(InpSymbol,SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK)!=0) { mode=ORDER_FILLING_FOK; return true; }
   if((flags & SYMBOL_FILLING_IOC)!=0) { mode=ORDER_FILLING_IOC; return true; }
   if(SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_EXEMODE)!=SYMBOL_TRADE_EXECUTION_MARKET)
   { mode=ORDER_FILLING_RETURN; return true; }
   return false;
}
bool SendChecked(MqlTradeRequest &request)
{
   MqlTradeCheckResult check={};
   ResetLastError();
   if(!OrderCheck(request,check))
   {
      Log(StringFormat("OrderCheck rejected: error=%d retcode=%u %s",GetLastError(),check.retcode,check.comment));
      return false;
   }
   MqlTradeResult result={};
   ResetLastError();
   bool sent=OrderSend(request,result);
   Log(StringFormat("OrderSend ok=%s error=%d retcode=%u order=%I64u deal=%I64u %s",
       sent?"true":"false",GetLastError(),result.retcode,result.order,result.deal,result.comment));
   // No automatic retry: a timeout or accepted/partial order may already have executed.
   return sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL
                   || result.retcode==TRADE_RETCODE_PLACED);
}
bool SymbolOccupied()
{
   // Include manual/other-EA positions and pending orders to avoid overlap.
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==InpSymbol) return true;
   for(int i=OrdersTotal()-1;i>=0;i--)
      if(OrderGetTicket(i)>0 && OrderGetString(ORDER_SYMBOL)==InpSymbol) return true;
   return false;
}
void CloseOwnPositions()
{
   if(!TradingAllowed()) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=InpSymbol
         || (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      MqlTick tick;
      if(!SymbolInfoTick(InpSymbol,tick)) continue;
      MqlTradeRequest request={};
      request.action=TRADE_ACTION_DEAL;
      request.symbol=InpSymbol;
      request.position=ticket;
      request.magic=InpMagic;
      request.volume=PositionGetDouble(POSITION_VOLUME);
      request.type=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
      request.price=request.type==ORDER_TYPE_BUY?tick.ask:tick.bid;
      request.deviation=(ulong)InpDeviationPoints;
      request.comment="SFB daily loss exit";
      if(!FillingMode(request.type_filling)) continue;
      SendChecked(request);
   }
}
double PriceRound(const double price,const double step,const bool up)
{
   double rounded=(up?MathCeil(price/step):MathFloor(price/step))*step;
   return NormalizeDouble(rounded,(int)SymbolInfoInteger(InpSymbol,SYMBOL_DIGITS));
}
double VolumeDown(const double volume,const double step)
{
   return NormalizeDouble(MathFloor(volume/step)*step,8);
}
void Enter(const ENUM_ORDER_TYPE side,const double atr)
{
   if(!TradingAllowed() || SymbolOccupied()) return;
   long trade_mode=SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_MODE);
   if(trade_mode==SYMBOL_TRADE_MODE_DISABLED || trade_mode==SYMBOL_TRADE_MODE_CLOSEONLY
      || (side==ORDER_TYPE_BUY && trade_mode==SYMBOL_TRADE_MODE_SHORTONLY)
      || (side==ORDER_TYPE_SELL && trade_mode==SYMBOL_TRADE_MODE_LONGONLY)) return;
   long order_mode=SymbolInfoInteger(InpSymbol,SYMBOL_ORDER_MODE);
   if((order_mode & SYMBOL_ORDER_MARKET)==0 || (order_mode & SYMBOL_ORDER_SL)==0
      || (order_mode & SYMBOL_ORDER_TP)==0) { Log("Broker does not support required market/SL/TP orders."); return; }
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol,tick) || tick.ask<=tick.bid || tick.bid<=0) return;
   double point=SymbolInfoDouble(InpSymbol,SYMBOL_POINT);
   double step=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0 || step<=0 || !MathIsValidNumber(atr) || atr<=0) return;
   if((tick.ask-tick.bid)/point>InpMaxSpreadPoints) { Log("Signal skipped: spread too high."); return; }
   bool buy=side==ORDER_TYPE_BUY;
   double entry=buy?tick.ask:tick.bid;
   double distance=(double)MathMax(SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_STOPS_LEVEL),
                                  SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_FREEZE_LEVEL))*point+step;
   // Stop distances are checked against the closing quote (Bid for BUY, Ask for SELL).
   double sl=buy?MathMin(entry-InpSLATR*atr,tick.bid-distance):MathMax(entry+InpSLATR*atr,tick.ask+distance);
   double tp=buy?MathMax(entry+InpTPATR*atr,tick.bid+distance):MathMin(entry-InpTPATR*atr,tick.ask-distance);
   sl=PriceRound(sl,step,!buy);
   tp=PriceRound(tp,step,buy);
   if(sl<=0 || tp<=0) return;
   double worst_entry=entry+(buy?1.0:-1.0)*InpDeviationPoints*point;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_base=MathMin(equity,AccountInfoDouble(ACCOUNT_BALANCE));
   double budget=risk_base*InpRiskPercent/100.0;
   // Do not allocate more than the remaining daily loss allowance.
   budget=MathMin(budget,equity-day_equity*(1.0-InpDailyLossPercent/100.0));
   budget*=1.0-InpCostReservePercent/100.0;
   double minvol=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
   double maxvol=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
   double volstep=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
   if(budget<=0 || minvol<=0 || maxvol<minvol || volstep<=0 || worst_entry<=0) return;
   double loss=0;
   ResetLastError();
   if(!OrderCalcProfit(side,InpSymbol,minvol,worst_entry,sl,loss) || loss>=0)
   { Log(StringFormat("OrderCalcProfit failed or invalid loss: %d",GetLastError())); return; }
   double volume=VolumeDown(MathMin(maxvol,budget/(-loss/minvol)),volstep);
   if(volume<minvol) { Log("Signal skipped: broker minimum volume exceeds risk budget."); return; }
   double margin=0;
   if(!OrderCalcMargin(side,InpSymbol,volume,worst_entry,margin))
   { Log(StringFormat("OrderCalcMargin failed: %d",GetLastError())); return; }
   double available=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95;
   if(available<=0) return;
   if(margin>available) volume=VolumeDown(volume*available/margin,volstep);
   if(volume<minvol) { Log("Signal skipped: insufficient margin for minimum volume."); return; }
   // Recheck final rounded size and margin before the broker-side OrderCheck.
   if(!OrderCalcProfit(side,InpSymbol,volume,worst_entry,sl,loss) || loss>=0 || -loss>budget
      || !OrderCalcMargin(side,InpSymbol,volume,worst_entry,margin) || margin>available)
   { Log("Signal skipped: final risk/margin validation failed."); return; }
   if(SymbolOccupied()) return;
   MqlTradeRequest request={};
   request.action=TRADE_ACTION_DEAL;
   request.symbol=InpSymbol;
   request.magic=InpMagic;
   request.type=side;
   request.volume=volume;
   request.price=entry;
   request.sl=sl;
   request.tp=tp;
   request.deviation=(ulong)InpDeviationPoints;
   request.comment="SmartForexBot EMA";
   if(!FillingMode(request.type_filling)) { Log("No supported filling policy."); return; }
   Log(StringFormat("Signal %s volume=%.8f SL=%.*f TP=%.*f modeled SL loss=%.2f budget=%.2f",
       buy?"BUY":"SELL",volume,_Digits,sl,_Digits,tp,-loss,budget));
   SendChecked(request);
}
int OnInit()
{
   if(!SafeAccount()) { Log("REFUSED: only demo accounts or Strategy Tester are allowed."); return INIT_FAILED; }
   if(InpSymbol!=_Symbol || InpTimeframe!=PERIOD_H1 || _Period!=PERIOD_H1
      || SymbolInfoString(InpSymbol,SYMBOL_CURRENCY_BASE)!="EUR"
      || SymbolInfoString(InpSymbol,SYMBOL_CURRENCY_PROFIT)!="USD")
   { Log("Attach to EURUSD H1; set InpSymbol to the exact broker symbol."); return INIT_PARAMETERS_INCORRECT; }
   if(InpFastEMA<1 || InpSlowEMA<=InpFastEMA || InpSlowEMA>10000 || InpATRPeriod<1 || InpATRPeriod>10000
      || !MathIsValidNumber(InpSLATR) || InpSLATR<=0 || !MathIsValidNumber(InpTPATR) || InpTPATR<=0
      || !MathIsValidNumber(InpRiskPercent) || InpRiskPercent<=0 || InpRiskPercent>0.5
      || !MathIsValidNumber(InpCostReservePercent) || InpCostReservePercent<0 || InpCostReservePercent>=100
      || !MathIsValidNumber(InpDailyLossPercent) || InpDailyLossPercent<=0 || InpDailyLossPercent>2.0
      || InpMaxSpreadPoints<1 || InpDeviationPoints<0 || InpMagic==0)
   { Log("Invalid input parameters or safety limits exceeded."); return INIT_PARAMETERS_INCORRECT; }
   fast_handle=iMA(InpSymbol,InpTimeframe,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   slow_handle=iMA(InpSymbol,InpTimeframe,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   atr_handle=iATR(InpSymbol,InpTimeframe,InpATRPeriod);
   if(fast_handle==INVALID_HANDLE || slow_handle==INVALID_HANDLE || atr_handle==INVALID_HANDLE)
   { Log(StringFormat("Indicator initialization failed: %d",GetLastError())); return INIT_FAILED; }
   if(!UpdateDailyState()) return INIT_FAILED;
   last_bar=iTime(InpSymbol,InpTimeframe,0); // No stale signal immediately after attachment.
   Log("Initialized: demo/tester only, closed-bar signals, EURUSD H1.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(fast_handle!=INVALID_HANDLE) IndicatorRelease(fast_handle);
   if(slow_handle!=INVALID_HANDLE) IndicatorRelease(slow_handle);
   if(atr_handle!=INVALID_HANDLE) IndicatorRelease(atr_handle);
   Log(StringFormat("Stopped; reason=%d",reason));
}
void OnTick()
{
   if(!SafeAccount() || !UpdateDailyState()) return;
   if(daily_locked) { if(InpCloseOnDailyLimit) CloseOwnPositions(); return; }
   datetime bar=iTime(InpSymbol,InpTimeframe,0);
   if(bar<=0 || bar==last_bar) return;
   int required=MathMax(InpSlowEMA,InpATRPeriod)+3;
   if(BarsCalculated(fast_handle)<required || BarsCalculated(slow_handle)<required
      || BarsCalculated(atr_handle)<required) return;
   double fast[2],slow[2],atr[1];
   // CopyBuffer writes oldest first: [0]=bar 2, [1]=bar 1. Never read bar 0.
   if(CopyBuffer(fast_handle,0,1,2,fast)!=2 || CopyBuffer(slow_handle,0,1,2,slow)!=2
      || CopyBuffer(atr_handle,0,1,1,atr)!=1) return;
   for(int i=0;i<2;i++)
      if(!MathIsValidNumber(fast[i]) || !MathIsValidNumber(slow[i])
         || fast[i]==EMPTY_VALUE || slow[i]==EMPTY_VALUE) return;
   if(!MathIsValidNumber(atr[0]) || atr[0]<=0 || atr[0]==EMPTY_VALUE) return;
   last_bar=bar; // One attempt per bar, including skipped/rejected orders.
   if(fast[0]<=slow[0] && fast[1]>slow[1]) Enter(ORDER_TYPE_BUY,atr[0]);
   else if(fast[0]>=slow[0] && fast[1]<slow[1]) Enter(ORDER_TYPE_SELL,atr[0]);
}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) { Log("Cannot select transaction deal history."); return; }
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=InpSymbol
      || (ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic) return;
   Log(StringFormat("Deal=%I64u entry=%d type=%d volume=%.8f price=%.*f profit=%.2f commission=%.2f swap=%.2f fee=%.2f",
       trans.deal,(int)HistoryDealGetInteger(trans.deal,DEAL_ENTRY),(int)HistoryDealGetInteger(trans.deal,DEAL_TYPE),
       HistoryDealGetDouble(trans.deal,DEAL_VOLUME),_Digits,HistoryDealGetDouble(trans.deal,DEAL_PRICE),
       HistoryDealGetDouble(trans.deal,DEAL_PROFIT),HistoryDealGetDouble(trans.deal,DEAL_COMMISSION),
       HistoryDealGetDouble(trans.deal,DEAL_SWAP),HistoryDealGetDouble(trans.deal,DEAL_FEE)));
}
