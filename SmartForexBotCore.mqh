#ifndef SMART_FOREX_BOT_CORE_MQH
#define SMART_FOREX_BOT_CORE_MQH

// Pure decision helpers shared by the EA and the portable boundary tests.
// No trading, indicator reads or terminal state belong in this file.
bool SFBValidIndicator(const double value)
{
   return MathIsValidNumber(value) && value!=EMPTY_VALUE;
}

// Arguments represent bar 2 (previous) and bar 1 (last closed), never bar 0.
// +1 = BUY crossover, -1 = SELL crossover, 0 = no valid crossover.
int SFBCrossover(const double fast_previous,const double slow_previous,
                 const double fast_closed,const double slow_closed)
{
   if(!SFBValidIndicator(fast_previous) || !SFBValidIndicator(slow_previous)
      || !SFBValidIndicator(fast_closed) || !SFBValidIndicator(slow_closed)) return 0;
   if(fast_previous<=slow_previous && fast_closed>slow_closed) return 1;
   if(fast_previous>=slow_previous && fast_closed<slow_closed) return -1;
   return 0;
}

bool SFBPassADX(const bool enabled,const double value,const double threshold)
{
   // Disabling the filter must not introduce an ADX-data dependency.
   if(!enabled) return true;
   if(!SFBValidIndicator(value) || !SFBValidIndicator(threshold)
      || value<0.0 || value>100.0 || threshold<0.0 || threshold>100.0) return false;
   return value>threshold; // Equality is rejected: the rule is strictly above.
}

bool SFBDailyLossReached(const double reference_equity,const double current_equity,
                         const double limit_percent)
{
   // Invalid daily accounting is fail-closed. Negative current equity is valid
   // input and necessarily breaches a positive-equity reference.
   if(!SFBValidIndicator(reference_equity) || reference_equity<=0.0
      || !SFBValidIndicator(current_equity) || !SFBValidIndicator(limit_percent)
      || limit_percent<=0.0 || limit_percent>=100.0) return true;
   return current_equity<=reference_equity*(1.0-limit_percent/100.0);
}

#endif
