//+------------------------------------------------------------------+
//|                                                     MarketCrasherProp.mq5 |
//|                        Ported from TradingView strategy         |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

//--- input groups
input string InpTimeZone = "UTC"; // Timezone
input double InpLotStep = 0.01;   // Lot step (min increment)
input double InpFixedLot = 1.0;   // Fixed lot
input bool   InpUseRiskPct = true; // Risk % mode
input double InpRiskPct  = 0.3;   // Risk %

//--- session inputs (HHMM-HHMM format)
input string MonSession1 = "0000-2359";
input string MonSession2 = "0000-2359";
input string TueSession1 = "0000-2359";
input string TueSession2 = "0000-2359";
input string WedSession1 = "0000-2359";
input string WedSession2 = "0000-2359";
input string ThuSession1 = "0000-2359";
input string ThuSession2 = "0000-2359";
input string FriSession1 = "0000-2359";
input string FriSession2 = "0000-2359";
input string SatSession1 = "0000-2359";
input string SatSession2 = "0000-2359";
input string SunSession1 = "0000-2359";
input string SunSession2 = "0000-2359";

//--- ADX filter inputs
input bool   InpEnableADX   = true;
input int    InpADXPeriod   = 14;
input bool   InpUseDynamicADX = true;
input double InpStaticADX   = 25;
input int    InpADXLookback = 20;
input double InpADXMult     = 0.8;
input double InpADXMin      = 15;

//--- global variables derived from symbol info
double   PipSize;
double   ContractSize;
double   PipValuePerLot;
double   LotStep;
int      TZOffset=0;      // timezone offset in seconds
bool     InSessionFlag=false;
int      adxHandle=INVALID_HANDLE;
double   adxBuffer[];
bool     AdxTrendOK=true;

//+------------------------------------------------------------------+
//| Convert timezone string to hour offset                           |
//+------------------------------------------------------------------+
int parseTZ(string tz)
  {
   if(StringFind(tz,"UTC")!=0) return(0);
   int sign = StringFind(tz,"-")>=0 ? -1 : 1;
   string num = StringSubstr(tz,sign<0?4:3);
   return(sign*StringToInteger(num));
  }

//+------------------------------------------------------------------+
//| Parse HHMM string to minutes                                     |
//+------------------------------------------------------------------+
int hhmmToMin(string str)
  {
   if(StringLen(str)<4) return(0);
   int hh = StringToInteger(StringSubstr(str,0,2));
   int mm = StringToInteger(StringSubstr(str,2,2));
   return(hh*60+mm);
  }

//+------------------------------------------------------------------+
//| Check if given time is within session                             |
//+------------------------------------------------------------------+
bool timeInSession(datetime t,string sess)
  {
   if(StringLen(sess)<9) return(false);
   int from=hhmmToMin(StringSubstr(sess,0,4));
   int to=hhmmToMin(StringSubstr(sess,5,4));
   int cur=TimeHour(t)*60+TimeMinute(t);
   if(from<=to)
      return(cur>=from && cur<=to);
   return(cur>=from || cur<=to);
  }

//+------------------------------------------------------------------+
//| Determine if we are in any session                                |
//+------------------------------------------------------------------+
bool inAnySession(string s1,string s2,datetime t)
  {
   return(timeInSession(t,s1) || timeInSession(t,s2));
  }

//+------------------------------------------------------------------+
//| Update in-session flag                                           |
//+------------------------------------------------------------------+
void updateSession()
  {
   datetime tzTime=TimeCurrent()+TZOffset;
   int dow=TimeDayOfWeek(tzTime);
   switch(dow)
     {
      case 1: InSessionFlag=inAnySession(MonSession1,MonSession2,tzTime); break;
      case 2: InSessionFlag=inAnySession(TueSession1,TueSession2,tzTime); break;
      case 3: InSessionFlag=inAnySession(WedSession1,WedSession2,tzTime); break;
      case 4: InSessionFlag=inAnySession(ThuSession1,ThuSession2,tzTime); break;
      case 5: InSessionFlag=inAnySession(FriSession1,FriSession2,tzTime); break;
      case 6: InSessionFlag=inAnySession(SatSession1,SatSession2,tzTime); break;
      case 0: InSessionFlag=inAnySession(SunSession1,SunSession2,tzTime); break;
      default: InSessionFlag=false; break;
    }
  }

//+------------------------------------------------------------------+
//| Update ADX and trend condition                                   |
//+------------------------------------------------------------------+
void updateADX()
  {
   if(adxHandle==INVALID_HANDLE)
      return;
   int copied=CopyBuffer(adxHandle,0,0,InpADXLookback,adxBuffer);
   if(copied<=0)
     return;
   double adxCurrent=adxBuffer[0];
   double avg=0;
   for(int i=0;i<MathMin(InpADXLookback,copied);i++)
       avg+=adxBuffer[i];
   avg/=MathMin(InpADXLookback,copied);
   double dynamicThr=MathMax(InpADXMin,avg*InpADXMult);
   double thr=InpUseDynamicADX?dynamicThr:InpStaticADX;
   AdxTrendOK = !InpEnableADX || (adxCurrent>thr);
  }

//+------------------------------------------------------------------+
//| Format lot to string                                            |
//+------------------------------------------------------------------+
string fmtLot(double lots)
  {
   return(DoubleToString(lots, _Digits));
  }

//+------------------------------------------------------------------+
//| Round lot to nearest step                                       |
//+------------------------------------------------------------------+
double roundLot(double lots)
  {
   double step = LotStep>0 ? LotStep : InpLotStep;
   return(MathMax(MathRound(lots/step)*step, step));
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   LotStep      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   PipSize      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   ContractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   PipValuePerLot = ContractSize * PipSize;
   TZOffset = parseTZ(InpTimeZone) * 3600;
   InSessionFlag=false;
   adxHandle=iADX(_Symbol,PERIOD_CURRENT,InpADXPeriod);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(adxHandle!=INVALID_HANDLE)
      IndicatorRelease(adxHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   updateSession();
   updateADX();
   // trading logic will be implemented here
  }
//+------------------------------------------------------------------+
