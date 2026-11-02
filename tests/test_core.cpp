// Exercises the actual pure MQL5 decision helpers using two platform shims.
// This does not compile the EA or test MT5 indicators, orders or persistence.
#include <cmath>
#include <iostream>
#include <limits>
#include <string>

bool MathIsValidNumber(const double value) { return std::isfinite(value); }
const double EMPTY_VALUE=std::numeric_limits<double>::max();
#include "../SmartForexBotCore.mqh"

int checks=0;
int failures=0;

void Check(const bool condition,const std::string &name)
{
   ++checks;
   if(!condition)
   {
      ++failures;
      std::cerr<<"FAIL: "<<name<<'\n';
   }
}

int main()
{
   const double nan=std::numeric_limits<double>::quiet_NaN();
   const double inf=std::numeric_limits<double>::infinity();

   Check(SFBValidIndicator(1.1),"finite indicator");
   Check(SFBValidIndicator(0.0),"zero indicator can be valid ADX");
   Check(!SFBValidIndicator(EMPTY_VALUE),"empty indicator");
   Check(!SFBValidIndicator(nan),"NaN indicator");
   Check(!SFBValidIndicator(inf),"infinite indicator");
   Check(!SFBValidIndicator(-inf),"negative infinite indicator");

   Check(SFBCrossover(1.0,1.1,1.2,1.1)==1,"upward crossover");
   Check(SFBCrossover(1.2,1.1,1.0,1.1)==-1,"downward crossover");
   Check(SFBCrossover(1.1,1.1,1.2,1.1)==1,"previous equality permits BUY");
   Check(SFBCrossover(1.1,1.1,1.0,1.1)==-1,"previous equality permits SELL");
   Check(SFBCrossover(1.0,1.1,1.1,1.1)==0,"closed equality does not buy");
   Check(SFBCrossover(1.2,1.1,1.1,1.1)==0,"closed equality does not sell");
   Check(SFBCrossover(1.2,1.1,1.3,1.1)==0,"already above does not buy again");
   Check(SFBCrossover(1.0,1.1,0.9,1.1)==0,"already below does not sell again");
   Check(SFBCrossover(1.1,1.1,1.1,1.1)==0,"equal EMAs have no signal");
   for(const double invalid : {nan,inf,-inf,EMPTY_VALUE})
   {
      Check(SFBCrossover(invalid,1.1,1.2,1.1)==0,"invalid previous fast");
      Check(SFBCrossover(1.0,invalid,1.2,1.1)==0,"invalid previous slow");
      Check(SFBCrossover(1.0,1.1,invalid,1.1)==0,"invalid closed fast");
      Check(SFBCrossover(1.0,1.1,1.2,invalid)==0,"invalid closed slow");
   }

   Check(!SFBPassADX(true,19.99,20.0),"ADX below threshold");
   Check(!SFBPassADX(true,20.0,20.0),"ADX equal threshold is rejected");
   Check(SFBPassADX(true,20.01,20.0),"ADX above threshold");
   Check(SFBPassADX(true,100.0,20.0),"ADX upper bound");
   Check(!SFBPassADX(true,0.0,0.0),"ADX zero does not exceed zero");
   Check(SFBPassADX(true,0.01,0.0),"positive ADX exceeds zero threshold");
   Check(!SFBPassADX(true,100.01,20.0),"ADX outside upper range");
   Check(!SFBPassADX(true,-0.01,20.0),"negative ADX");
   Check(!SFBPassADX(true,25.0,-1.0),"negative threshold");
   Check(!SFBPassADX(true,25.0,101.0),"threshold above 100");
   Check(!SFBPassADX(true,100.0,100.0),"100 threshold cannot pass");
   Check(!SFBPassADX(true,nan,20.0),"enabled filter rejects unavailable ADX");
   Check(!SFBPassADX(true,EMPTY_VALUE,20.0),"enabled filter rejects EMPTY_VALUE");
   Check(!SFBPassADX(true,25.0,nan),"enabled filter rejects invalid threshold");
   Check(SFBPassADX(false,nan,20.0),"disabled filter ignores unavailable ADX");
   Check(SFBPassADX(false,EMPTY_VALUE,20.0),"disabled filter ignores EMPTY_VALUE");
   Check(SFBPassADX(false,nan,nan),"disabled filter has no ADX dependency");

   Check(!SFBDailyLossReached(10000.0,10000.0,2.0),"unchanged daily equity");
   Check(!SFBDailyLossReached(10000.0,10200.0,2.0),"daily gain");
   Check(!SFBDailyLossReached(10000.0,9800.01,2.0),"just above daily loss boundary");
   Check(SFBDailyLossReached(10000.0,9800.0,2.0),"exact daily loss boundary locks");
   Check(SFBDailyLossReached(10000.0,9799.99,2.0),"below daily loss boundary locks");
   Check(SFBDailyLossReached(10000.0,-1.0,2.0),"negative equity locks");
   Check(SFBDailyLossReached(0.0,10000.0,2.0),"zero daily baseline fails closed");
   Check(SFBDailyLossReached(-1.0,10000.0,2.0),"negative daily baseline fails closed");
   Check(SFBDailyLossReached(nan,10000.0,2.0),"NaN baseline fails closed");
   Check(SFBDailyLossReached(10000.0,nan,2.0),"NaN equity fails closed");
   Check(SFBDailyLossReached(10000.0,10000.0,nan),"NaN daily threshold fails closed");
   Check(SFBDailyLossReached(10000.0,10000.0,0.0),"zero daily threshold fails closed");
   Check(SFBDailyLossReached(10000.0,10000.0,100.0),"invalid daily threshold fails closed");
   Check(SFBDailyLossReached(EMPTY_VALUE,10000.0,2.0),"sentinel baseline fails closed");

   std::cout<<checks<<" checks; "<<failures<<" failures\n";
   return failures==0?0:1;
}
