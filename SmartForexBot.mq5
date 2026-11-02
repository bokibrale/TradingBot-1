#property strict
#property version "1.10"
#property description "EURUSD H1 EMA + optional closed-bar ADX filter; demo/tester only."

#include "SmartForexBotCore.mqh"

input string InpSymbol             = "EURUSD"; // Broker suffix supported, e.g. EURUSD.a
input ENUM_TIMEFRAMES InpTimeframe  = PERIOD_H1;
input int    InpFastEMA             = 20;
input int    InpSlowEMA             = 50;
input int    InpATRPeriod           = 14;
input bool   InpUseADXFilter        = true;
input int    InpADXPeriod           = 14;
input double InpMinADX              = 20.0; // Require ADX strictly above this value
input double InpSLATR               = 1.5;
input double InpTPATR               = 2.0;
input double InpRiskPercent         = 0.25; // Hard maximum 0.5%
input double InpCostReservePercent  = 10.0; // Portion of risk budget reserved for costs
input double InpDailyLossPercent    = 2.0; // Hard maximum 2%
input int    InpMaxSpreadPoints     = 20;  // 20 points = 2 pips on a 5-digit symbol
input int    InpDeviationPoints     = 10;
input ulong  InpMagic               = 205014;
input bool   InpCloseOnDailyLimit   = true;
input bool   InpLogSignals          = true;

int fast_handle=INVALID_HANDLE, slow_handle=INVALID_HANDLE, atr_handle=INVALID_HANDLE;
int adx_handle=INVALID_HANDLE;
datetime last_bar=0;
datetime data_warning_bar=0;
int day_id=0;
double day_equity=0;
bool daily_locked=false;
string day_key="";

struct SignalContext
{
   datetime bar;
   int direction;
   double fast_previous;
   double slow_previous;
   double fast_closed;
   double slow_closed;
   double atr;
   double adx;
   bool atr_ready;
   bool adx_ready;
};

enum SFB_SEND_STATUS
{
   SFB_SEND_REJECTED,
   SFB_SEND_ACCEPTED,
   SFB_SEND_UNCERTAIN
};

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
   if(!daily_locked && SFBDailyLossReached(day_equity,AccountInfoDouble(ACCOUNT_EQUITY),InpDailyLossPercent))
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
string TradingBlockReason()
{
   if(!SafeAccount()) return "account_is_not_demo_or_tester";
   if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return "terminal_algo_trading_disabled";
   if(!(bool)MQLInfoInteger(MQL_TRADE_ALLOWED)) return "EA_algo_trading_disabled";
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return "account_trading_disabled";
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return "account_expert_trading_disabled";
   return "";
}
bool TradingAllowed() { return TradingBlockReason()==""; }
bool FillingMode(ENUM_ORDER_TYPE_FILLING &mode)
{
   long flags=SymbolInfoInteger(InpSymbol,SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK)!=0) { mode=ORDER_FILLING_FOK; return true; }
   if((flags & SYMBOL_FILLING_IOC)!=0) { mode=ORDER_FILLING_IOC; return true; }
   if(SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_EXEMODE)!=SYMBOL_TRADE_EXECUTION_MARKET)
   { mode=ORDER_FILLING_RETURN; return true; }
   return false;
}
SFB_SEND_STATUS SendChecked(MqlTradeRequest &request,string &reason)
{
   MqlTradeCheckResult check={};
   ResetLastError();
   if(!OrderCheck(request,check))
   {
      reason=StringFormat("OrderCheck_rejected error=%d retcode=%u comment=%s",GetLastError(),check.retcode,check.comment);
      Log(reason);
      return SFB_SEND_REJECTED;
   }
   MqlTradeResult result={};
   ResetLastError();
   bool sent=OrderSend(request,result);
   reason=StringFormat("OrderSend ok=%s error=%d retcode=%u order=%I64u deal=%I64u comment=%s",
       sent?"true":"false",GetLastError(),result.retcode,result.order,result.deal,result.comment);
   Log(reason);
   // No automatic retry: a timeout or accepted/partial order may already have executed.
   if(sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL
               || result.retcode==TRADE_RETCODE_PLACED)) return SFB_SEND_ACCEPTED;
   if(result.retcode==TRADE_RETCODE_TIMEOUT || result.retcode==TRADE_RETCODE_CONNECTION
      || result.retcode==0) return SFB_SEND_UNCERTAIN;
   return SFB_SEND_REJECTED;
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
      string reason;
      SendChecked(request,reason);
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
void SignalDecision(const string context,const string decision,const string reason)
{
   if(InpLogSignals) Log(context+" decision="+decision+" reason="+reason);
}
string SignalDescription(const SignalContext &signal)
{
   string description=StringFormat("Signal candle=%s evaluated=%s side=%s EMA_fast[2]=%.*f EMA_slow[2]=%.*f EMA_fast[1]=%.*f EMA_slow[1]=%.*f",
      TimeToString(signal.bar,TIME_DATE|TIME_MINUTES),TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
      signal.direction>0?"BUY":"SELL",_Digits,signal.fast_previous,_Digits,signal.slow_previous,
      _Digits,signal.fast_closed,_Digits,signal.slow_closed);
   description+=" ATR[1]="+(signal.atr_ready?DoubleToString(signal.atr,_Digits):"unavailable");
   description+=" ADX[1]="+(signal.adx_ready?DoubleToString(signal.adx,4):"unavailable");
   description+=" ADX_filter="+(InpUseADXFilter?"on":"off")+" ADX_threshold="+DoubleToString(InpMinADX,4);
   return description;
}
void Enter(const SignalContext &signal)
{
   ENUM_ORDER_TYPE side=signal.direction>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double atr=signal.atr;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_base=MathMin(equity,AccountInfoDouble(ACCOUNT_BALANCE));
   double budget=risk_base*InpRiskPercent/100.0;
   // Include the remaining daily allowance and cost reserve in every signal log.
   budget=MathMin(budget,equity-day_equity*(1.0-InpDailyLossPercent/100.0));
   budget*=1.0-InpCostReservePercent/100.0;
   MqlTick tick={};
   double point=SymbolInfoDouble(InpSymbol,SYMBOL_POINT);
   double step=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
   bool quote_ready=SymbolInfoTick(InpSymbol,tick) && SFBValidIndicator(tick.bid)
                    && SFBValidIndicator(tick.ask) && tick.bid>0 && tick.ask>tick.bid;
   string context=SignalDescription(signal);
   context+=" spread_points="+(quote_ready && point>0?DoubleToString((tick.ask-tick.bid)/point,2):"unavailable");
   context+=StringFormat(" equity=%.2f risk_base=%.2f risk_percent=%.4f daily_reference=%.2f budget=%.2f currency=%s",
      equity,risk_base,InpRiskPercent,day_equity,budget,AccountInfoString(ACCOUNT_CURRENCY));
   // Safety applies even when the ADX filter is disabled or ADX is unavailable.
   if(daily_locked) { SignalDecision(context,"SKIPPED","daily_loss_locked"); return; }
   string restriction=TradingBlockReason();
   if(restriction!="") { SignalDecision(context,"SKIPPED",restriction); return; }
   if(SymbolOccupied()) { SignalDecision(context,"SKIPPED","symbol_has_position_or_order"); return; }
   if(!signal.atr_ready) { SignalDecision(context,"SKIPPED","ATR_unavailable_or_invalid"); return; }
   if(InpUseADXFilter && !signal.adx_ready)
   { SignalDecision(context,"SKIPPED","ADX_unavailable_or_invalid"); return; }
   if(!SFBPassADX(InpUseADXFilter,signal.adx,InpMinADX))
   { SignalDecision(context,"SKIPPED","ADX_not_strictly_above_threshold"); return; }
   long trade_mode=SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_MODE);
   if(trade_mode==SYMBOL_TRADE_MODE_DISABLED || trade_mode==SYMBOL_TRADE_MODE_CLOSEONLY
      || (side==ORDER_TYPE_BUY && trade_mode==SYMBOL_TRADE_MODE_SHORTONLY)
      || (side==ORDER_TYPE_SELL && trade_mode==SYMBOL_TRADE_MODE_LONGONLY))
   { SignalDecision(context,"SKIPPED","broker_trade_mode_blocks_direction"); return; }
   long order_mode=SymbolInfoInteger(InpSymbol,SYMBOL_ORDER_MODE);
   if((order_mode & SYMBOL_ORDER_MARKET)==0 || (order_mode & SYMBOL_ORDER_SL)==0
      || (order_mode & SYMBOL_ORDER_TP)==0)
   { SignalDecision(context,"SKIPPED","broker_requires_unsupported_market_SL_TP"); return; }
   if(!quote_ready) { SignalDecision(context,"SKIPPED","quote_unavailable_or_invalid"); return; }
   if(point<=0 || step<=0) { SignalDecision(context,"SKIPPED","invalid_broker_price_step"); return; }
   if((tick.ask-tick.bid)/point>InpMaxSpreadPoints)
   { SignalDecision(context,"SKIPPED","spread_above_limit"); return; }
   bool buy=side==ORDER_TYPE_BUY;
   double entry=buy?tick.ask:tick.bid;
   double distance=(double)MathMax(SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_STOPS_LEVEL),
                                  SymbolInfoInteger(InpSymbol,SYMBOL_TRADE_FREEZE_LEVEL))*point+step;
   // Stop distances are checked against the closing quote (Bid for BUY, Ask for SELL).
   double sl=buy?MathMin(entry-InpSLATR*atr,tick.bid-distance):MathMax(entry+InpSLATR*atr,tick.ask+distance);
   double tp=buy?MathMax(entry+InpTPATR*atr,tick.bid+distance):MathMin(entry-InpTPATR*atr,tick.ask-distance);
   sl=PriceRound(sl,step,!buy);
   tp=PriceRound(tp,step,buy);
   context+=StringFormat(" entry=%.*f SL=%.*f TP=%.*f",_Digits,entry,_Digits,sl,_Digits,tp);
   if(!SFBValidIndicator(sl) || !SFBValidIndicator(tp) || sl<=0 || tp<=0)
   { SignalDecision(context,"SKIPPED","invalid_stop_prices"); return; }
   double worst_entry=entry+(buy?1.0:-1.0)*InpDeviationPoints*point;
   double minvol=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
   double maxvol=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
   double volstep=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
   if(!SFBValidIndicator(budget) || budget<=0 || minvol<=0 || maxvol<minvol || volstep<=0 || worst_entry<=0)
   { SignalDecision(context,"SKIPPED","invalid_risk_budget_or_broker_volume_rules"); return; }
   double loss=0;
   ResetLastError();
   if(!OrderCalcProfit(side,InpSymbol,minvol,worst_entry,sl,loss) || !SFBValidIndicator(loss) || loss>=0)
   {
      string reason=StringFormat("OrderCalcProfit_failed_or_invalid error=%d",GetLastError());
      Log(reason);
      SignalDecision(context,"SKIPPED",reason);
      return;
   }
   double volume=VolumeDown(MathMin(maxvol,budget/(-loss/minvol)),volstep);
   context+=StringFormat(" minimum_lot_loss=%.2f volume_before_margin=%.8f",-loss,volume);
   if(volume<minvol) { SignalDecision(context,"SKIPPED","minimum_volume_exceeds_risk_budget"); return; }
   double margin=0;
   if(!OrderCalcMargin(side,InpSymbol,volume,worst_entry,margin))
   {
      string reason=StringFormat("OrderCalcMargin_failed error=%d",GetLastError());
      Log(reason);
      SignalDecision(context,"SKIPPED",reason);
      return;
   }
   double available=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95;
   context+=StringFormat(" available_margin=%.2f",available);
   if(!SFBValidIndicator(available) || available<=0 || !SFBValidIndicator(margin) || margin<0)
   { SignalDecision(context,"SKIPPED","invalid_or_insufficient_free_margin"); return; }
   if(margin>available) volume=VolumeDown(volume*available/margin,volstep);
   context+=StringFormat(" volume=%.8f",volume);
   if(volume<minvol) { SignalDecision(context,"SKIPPED","insufficient_margin_for_minimum_volume"); return; }
   // Recheck final rounded size and margin before the broker-side OrderCheck.
   ResetLastError();
   if(!OrderCalcProfit(side,InpSymbol,volume,worst_entry,sl,loss))
   {
      string reason=StringFormat("final_OrderCalcProfit_failed error=%d",GetLastError());
      Log(reason);
      SignalDecision(context,"SKIPPED",reason);
      return;
   }
   context+=StringFormat(" modeled_SL_loss=%.2f",-loss);
   if(!SFBValidIndicator(loss) || loss>=0 || -loss>budget)
   { SignalDecision(context,"SKIPPED","final_modeled_loss_invalid_or_above_budget"); return; }
   ResetLastError();
   if(!OrderCalcMargin(side,InpSymbol,volume,worst_entry,margin))
   {
      string reason=StringFormat("final_OrderCalcMargin_failed error=%d",GetLastError());
      Log(reason);
      SignalDecision(context,"SKIPPED",reason);
      return;
   }
   context+=StringFormat(" required_margin=%.2f",margin);
   if(!SFBValidIndicator(margin) || margin<0 || margin>available)
   { SignalDecision(context,"SKIPPED","final_margin_invalid_or_above_available"); return; }
   if(SymbolOccupied()) { SignalDecision(context,"SKIPPED","symbol_became_occupied"); return; }
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
   if(!FillingMode(request.type_filling)) { SignalDecision(context,"SKIPPED","no_supported_filling_policy"); return; }
   string reason;
   SFB_SEND_STATUS status=SendChecked(request,reason);
   string decision=status==SFB_SEND_ACCEPTED?"ORDER_ACCEPTED":(status==SFB_SEND_UNCERTAIN?"ORDER_UNCERTAIN":"ORDER_REJECTED");
   SignalDecision(context,decision,reason);
}
int OnInit()
{
   if(!SafeAccount()) { Log("REFUSED: only demo accounts or Strategy Tester are allowed."); return INIT_FAILED; }
   if(InpSymbol!=_Symbol || InpTimeframe!=PERIOD_H1 || _Period!=PERIOD_H1
      || SymbolInfoString(InpSymbol,SYMBOL_CURRENCY_BASE)!="EUR"
      || SymbolInfoString(InpSymbol,SYMBOL_CURRENCY_PROFIT)!="USD")
   { Log("Attach to EURUSD H1; set InpSymbol to the exact broker symbol."); return INIT_PARAMETERS_INCORRECT; }
   if(InpFastEMA<1 || InpSlowEMA<=InpFastEMA || InpSlowEMA>10000 || InpATRPeriod<1 || InpATRPeriod>10000
      || InpADXPeriod<1 || InpADXPeriod>10000
      || !SFBValidIndicator(InpMinADX) || InpMinADX<0 || InpMinADX>100
      || !MathIsValidNumber(InpSLATR) || InpSLATR<=0 || !MathIsValidNumber(InpTPATR) || InpTPATR<=0
      || !MathIsValidNumber(InpRiskPercent) || InpRiskPercent<=0 || InpRiskPercent>0.5
      || !MathIsValidNumber(InpCostReservePercent) || InpCostReservePercent<0 || InpCostReservePercent>=100
      || !MathIsValidNumber(InpDailyLossPercent) || InpDailyLossPercent<=0 || InpDailyLossPercent>2.0
      || InpMaxSpreadPoints<1 || InpDeviationPoints<0 || InpMagic==0)
   { Log("Invalid input parameters or safety limits exceeded."); return INIT_PARAMETERS_INCORRECT; }
   fast_handle=iMA(InpSymbol,InpTimeframe,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   slow_handle=iMA(InpSymbol,InpTimeframe,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   atr_handle=iATR(InpSymbol,InpTimeframe,InpATRPeriod);
   // Also request ADX for diagnostics when the filter is OFF, without making it mandatory.
   adx_handle=iADX(InpSymbol,InpTimeframe,InpADXPeriod);
   if(fast_handle==INVALID_HANDLE || slow_handle==INVALID_HANDLE || atr_handle==INVALID_HANDLE)
   { Log(StringFormat("Indicator initialization failed: %d",GetLastError())); return INIT_FAILED; }
   if(adx_handle==INVALID_HANDLE)
   {
      Log(StringFormat("ADX initialization failed: %d",GetLastError()));
      if(InpUseADXFilter) return INIT_FAILED;
   }
   if(!UpdateDailyState()) return INIT_FAILED;
   last_bar=iTime(InpSymbol,InpTimeframe,0); // No stale signal immediately after attachment.
   Log(StringFormat("Initialized v1.10: demo/tester only, EURUSD H1; ADX_filter=%s period=%d threshold=%.4f risk=%.4f%% signal_logging=%s",
       InpUseADXFilter?"on":"off",InpADXPeriod,InpMinADX,InpRiskPercent,InpLogSignals?"on":"off"));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(fast_handle!=INVALID_HANDLE) IndicatorRelease(fast_handle);
   if(slow_handle!=INVALID_HANDLE) IndicatorRelease(slow_handle);
   if(atr_handle!=INVALID_HANDLE) IndicatorRelease(atr_handle);
   if(adx_handle!=INVALID_HANDLE) IndicatorRelease(adx_handle);
   Log(StringFormat("Stopped; reason=%d",reason));
}
void LogDataWait(const datetime bar,const string reason)
{
   if(data_warning_bar==bar) return;
   data_warning_bar=bar;
   if(InpLogSignals) Log("Signal evaluation waiting for EMA data: bar="+TimeToString(bar,TIME_DATE|TIME_MINUTES)+" reason="+reason);
}
bool ReadClosedValue(const int handle,const int required,double &value)
{
   value=EMPTY_VALUE;
   if(handle==INVALID_HANDLE || BarsCalculated(handle)<required) return false;
   double buffer[1];
   // Buffer 0 is the main ADX line for iADX and the ATR line for iATR.
   if(CopyBuffer(handle,0,1,1,buffer)!=1 || !SFBValidIndicator(buffer[0])) return false;
   value=buffer[0];
   return true;
}
void OnTick()
{
   if(!SafeAccount() || !UpdateDailyState()) return;
   if(daily_locked && InpCloseOnDailyLimit) CloseOwnPositions();
   // Continue signal diagnostics during a lock. Enter() refuses all new entries.
   datetime bar=iTime(InpSymbol,InpTimeframe,0);
   if(bar<=0 || bar==last_bar) return;
   if(last_bar==0) { last_bar=bar; return; } // Initial history may not have been ready in OnInit.
   int required=InpSlowEMA+3;
   if(BarsCalculated(fast_handle)<required || BarsCalculated(slow_handle)<required)
   { LogDataWait(bar,"EMA_warmup"); return; }
   double fast[2],slow[2];
   // CopyBuffer writes oldest first: [0]=bar 2, [1]=bar 1. Never read bar 0.
   if(CopyBuffer(fast_handle,0,1,2,fast)!=2 || CopyBuffer(slow_handle,0,1,2,slow)!=2)
   { LogDataWait(bar,"EMA_CopyBuffer_failed"); return; }
   for(int i=0;i<2;i++)
      if(!SFBValidIndicator(fast[i]) || !SFBValidIndicator(slow[i]))
      { LogDataWait(bar,"EMA_invalid_value"); return; }
   last_bar=bar; // One attempt per bar, including skipped/rejected orders.
   int direction=SFBCrossover(fast[0],slow[0],fast[1],slow[1]);
   if(direction==0) return;
   SignalContext signal={};
   signal.bar=iTime(InpSymbol,InpTimeframe,1);
   signal.direction=direction;
   signal.fast_previous=fast[0];
   signal.slow_previous=slow[0];
   signal.fast_closed=fast[1];
   signal.slow_closed=slow[1];
   signal.atr_ready=ReadClosedValue(atr_handle,InpATRPeriod+3,signal.atr) && signal.atr>0;
   signal.adx_ready=ReadClosedValue(adx_handle,2*InpADXPeriod+3,signal.adx) && signal.adx>=0 && signal.adx<=100;
   Enter(signal);
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
