//+------------------------------------------------------------------+
//|                                                     MarketCrasherProp.mq5 |
//|                        Ported from TradingView strategy         |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

//--- input groups
input string InpTimeZone = "UTC"; // Timezone offset string like UTC, UTC+1, UTC-1
input double InpLotStep = 0.01;   // Lot step (min increment)
input double InpFixedLot = 1.0;   // Fixed lot
input bool   InpUseRiskPct = true; // Risk % mode
input double InpRiskPct  = 0.3;   // Risk %

// Market bias inputs
input int    InpBiasPeriod = 100;
input int    InpBiasOscPeriod = 7;
input bool   InpUseMarketBias = true;

// ADX filter inputs
input bool   InpEnableADXFilter = true;
input int    InpADXPeriod = 14;
input bool   InpUseDynamicADX = true;
input double InpStaticADXThreshold = 25;
input int    InpADXLookback = 20;
input double InpADXMultiplier = 0.8;
input double InpADXMin = 15;

// Synergy score inputs (simplified)
input bool   InpUseSynergy = true;

//--- global variables derived from symbol info
double   PipSize;
double   ContractSize;
double   PipValuePerLot;
double   LotStep;

// helper --------------------------------------------------------------
int TZOffset()
{
   if(StringLen(InpTimeZone)<=3) return 0;
   string sign = StringSubstr(InpTimeZone,3,1);
   int val = (int)StringToInteger(StringSubstr(InpTimeZone,4));
   if(sign=="-") val = -val;
   return val;
}

// return current time adjusted for timezone
datetime NowTz()
{
   return(TimeCurrent() + TZOffset()*3600);
}

// format lot
string fmtLot(double lots)
{
   return(DoubleToString(lots, _Digits));
}

double roundLot(double lots)
{
   double step = LotStep>0 ? LotStep : InpLotStep;
   return(MathMax(MathRound(lots/step)*step, step));
}

// indicator helper : returns last value of MA
double GetMA(ENUM_TIMEFRAMES tf,int period)
{
   int handle=iMA(_Symbol,tf,period,0,MODE_EMA,PRICE_CLOSE);
   if(handle==INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,0,0,1,buf)<=0)
     {
      IndicatorRelease(handle);
      return 0.0;
     }
   IndicatorRelease(handle);
   return buf[0];
}

// indicator helper : RSI
double GetRSI(ENUM_TIMEFRAMES tf,int period)
{
   int handle=iRSI(_Symbol,tf,period,PRICE_CLOSE);
   if(handle==INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,0,0,1,buf)<=0)
     {
      IndicatorRelease(handle);
      return 0.0;
     }
   IndicatorRelease(handle);
   return buf[0];
}

// indicator helper : MACD difference (EMA12-EMA26)
double GetMACDVar(ENUM_TIMEFRAMES tf)
{
   double ema12 = GetMA(tf,12);
   double ema26 = GetMA(tf,26);
   return (ema12-ema26);
}

// indicator helper : ADX value
double GetADX(ENUM_TIMEFRAMES tf,int period)
{
   int handle=iADX(_Symbol,tf,period);
   if(handle==INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(handle,0,0,1,buf)<=0)
     {
      IndicatorRelease(handle);
      return 0.0;
     }
   IndicatorRelease(handle);
   return buf[0];
}

// session strings (HH:MM-HH:MM)
input string MonSess1="00:00-23:59";
input string MonSess2="";
input string TueSess1="00:00-23:59";
input string TueSess2="";
input string WedSess1="00:00-23:59";
input string WedSess2="";
input string ThuSess1="00:00-23:59";
input string ThuSess2="";
input string FriSess1="00:00-23:59";
input string FriSess2="";
input string SatSess1="";
input string SatSess2="";
input string SunSess1="";
input string SunSess2="";

bool SessionActive(string sess,datetime t)
{
   if(StringLen(sess)<9) return false;
   int pos=StringFind(sess,"-");
   if(pos<0) return false;
   string st=StringSubstr(sess,0,pos);
   string en=StringSubstr(sess,pos+1);
   int sh=(int)StringToInteger(StringSubstr(st,0,2));
   int sm=(int)StringToInteger(StringSubstr(st,3,2));
   int eh=(int)StringToInteger(StringSubstr(en,0,2));
   int em=(int)StringToInteger(StringSubstr(en,3,2));
   datetime day=StructToTime(TimeToStruct(t));
   datetime start=day + sh*3600 + sm*60;
   datetime end=day + eh*3600 + em*60;
   return(t>=start && t<=end);
}

bool InTradingSession()
{
   datetime now=NowTz();
   int dow=TimeDayOfWeek(now); // 0=sunday
   if(dow==1)
      return SessionActive(MonSess1,now) || SessionActive(MonSess2,now);
   if(dow==2)
      return SessionActive(TueSess1,now) || SessionActive(TueSess2,now);
   if(dow==3)
      return SessionActive(WedSess1,now) || SessionActive(WedSess2,now);
   if(dow==4)
      return SessionActive(ThuSess1,now) || SessionActive(ThuSess2,now);
   if(dow==5)
      return SessionActive(FriSess1,now) || SessionActive(FriSess2,now);
   if(dow==6)
      return SessionActive(SatSess1,now) || SessionActive(SatSess2,now);
   if(dow==0)
      return SessionActive(SunSess1,now) || SessionActive(SunSess2,now);
   return false;
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
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
}

// basic state vars for market bias
bool prevBiasPositive=false;

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Current time in selected timezone
   datetime now=NowTz();
   bool inSession=InTradingSession();

   // --- Market Bias ---
   double emaOpen=iMA(_Symbol,_Period,InpBiasPeriod,0,MODE_EMA,PRICE_OPEN);
   double emaClose=iMA(_Symbol,_Period,InpBiasPeriod,0,MODE_EMA,PRICE_CLOSE);
   double oscBias=100*(emaClose-emaOpen);
   double oscSmooth=iMA(_Symbol,_Period,InpBiasOscPeriod,0,MODE_EMA,PRICE_CLOSE); // placeholder smoothing

   bool currentBiasPositive = oscBias>0;
   bool biasChangedToBullish = (!prevBiasPositive && currentBiasPositive);
   bool biasChangedToBearish = (prevBiasPositive && !currentBiasPositive);
   prevBiasPositive=currentBiasPositive;

   // --- ADX Filter ---
   double adxVal=GetADX(_Period,InpADXPeriod);
   double adxAvg=GetMA(_Period,InpADXLookback); // placeholder for SMA
   double dynThr=MathMax(InpADXMin,adxAvg*InpADXMultiplier);
   double thr=InpUseDynamicADX?dynThr:InpStaticADXThreshold;
   bool adxTrend= InpEnableADXFilter ? (adxVal>thr) : true;

   // --- Synergy Score (simplified) ---
   double score=0;
   if(InpUseSynergy)
     {
      double rsi_m5=GetRSI(PERIOD_M5,14);
      double maFast_m5=GetMA(PERIOD_M5,10);
      double maSlow_m5=GetMA(PERIOD_M5,100);
      double macd_m5=GetMACDVar(PERIOD_M5);
      double rsi_m15=GetRSI(PERIOD_M15,14);
      double maFast_m15=GetMA(PERIOD_M15,50);
      double maSlow_m15=GetMA(PERIOD_M15,200);
      double macd_m15=GetMACDVar(PERIOD_M15);
      double rsi_h1=GetRSI(PERIOD_H1,14);
      double maFast_h1=GetMA(PERIOD_H1,50);
      double maSlow_h1=GetMA(PERIOD_H1,200);
      double macd_h1=GetMACDVar(PERIOD_H1);

      score += (rsi_m5>50?1:-1);
      score += (maFast_m5>maSlow_m5?1:-1);
      score += (macd_m5>0?1:-1);
      score += (rsi_m15>50?1:-1);
      score += (maFast_m15>maSlow_m15?1:-1);
      score += (macd_m15>0?1:-1);
      score += (rsi_h1>50?1:-1);
      score += (maFast_h1>maSlow_h1?1:-1);
      score += (macd_h1>0?1:-1);
     }

   // placeholder for trading logic
   PrintFormat("Time=%s Session=%s Bias=%f ADX=%f Score=%f",TimeToString(now,TIME_SECONDS),inSession?"Y":"N",oscBias,adxVal,score);
}

//+------------------------------------------------------------------+
