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


//--- trading session inputs (HHMM-HHMM)
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

//--- market bias inputs
input int    InpHAPeriod   = 100; // HA Period
input int    InpOscPeriod  = 7;   // Oscillator Period
input bool   InpUseMarketBias = true;

//--- ADX filter inputs
input bool   InpEnableADXFilter = true;
input int    InpADXPeriod  = 14;
input bool   InpUseDynamicADX = true;
input double InpStaticADXThreshold = 25.0;
input int    InpADXLookback = 20;
input double InpADXMultiplier = 0.8;
input double InpADXMin = 15.0;

//--- synergy score inputs
input bool   InpUseSynergyScore = true;
input double InpRSIWeight       = 1.0;
input double InpTrendWeight     = 1.0;
input double InpMacdvWeight     = 1.0;
input bool   InpUseTF5m         = true;
input double InpWeight5m        = 1.0;
input bool   InpUseTF15m        = true;
input double InpWeight15m       = 1.0;
input bool   InpUseTF1h         = true;
input double InpWeight1h        = 1.0;

//--- global variables derived from symbol info
double   PipSize;
double   ContractSize;
double   PipValuePerLot;
double   LotStep;

int      TZOffset=0;
bool     InSession=false;
bool     BiasChangedToBullish=false;
bool     BiasChangedToBearish=false;
double   SynergyScore=0.0;

//+------------------------------------------------------------------+
//| Convert timezone string to hour offset                           |
//+------------------------------------------------------------------+
int ParseTZOffset(string tz)
  {
   if(tz=="UTC+1") return 1;
   if(tz=="UTC+2") return 2;
   if(tz=="UTC-1") return -1;
   if(tz=="UTC-2") return -2;
   return 0;
  }

//+------------------------------------------------------------------+
//| Check if time is within HHMM-HHMM session                         |
//+------------------------------------------------------------------+
bool TimeInSession(string sess,datetime now)
  {
   if(sess=="" || StringLen(sess)<9) return(false);
   int sh=(int)StringToInteger(StringSubstr(sess,0,2));
   int sm=(int)StringToInteger(StringSubstr(sess,2,2));
   int eh=(int)StringToInteger(StringSubstr(sess,5,2));
   int em=(int)StringToInteger(StringSubstr(sess,7,2));
   MqlDateTime dt; TimeToStruct(now,dt);
   int cur=dt.hour*60+dt.min;
   int st=sh*60+sm; int en=eh*60+em;
   if(en<st) return(cur>=st || cur<=en);
   return(cur>=st && cur<=en);
  }

//+------------------------------------------------------------------+
//| Check if within any of two sessions                               |
//+------------------------------------------------------------------+
bool InAnySession(string s1,string s2,datetime now)
  {
   return(TimeInSession(s1,now) || TimeInSession(s2,now));
  }

//+------------------------------------------------------------------+
//| Update session flag                                              |
//+------------------------------------------------------------------+
void UpdateSession(datetime now)
  {
   MqlDateTime dt; TimeToStruct(now,dt);
   switch(dt.day_of_week)
     {
      case 1: InSession=InAnySession(MonSession1,MonSession2,now); break; // Monday
      case 2: InSession=InAnySession(TueSession1,TueSession2,now); break;
      case 3: InSession=InAnySession(WedSession1,WedSession2,now); break;
      case 4: InSession=InAnySession(ThuSession1,ThuSession2,now); break;
      case 5: InSession=InAnySession(FriSession1,FriSession2,now); break;
      case 6: InSession=InAnySession(SatSession1,SatSession2,now); break;
      case 0: InSession=InAnySession(SunSession1,SunSession2,now); break; // Sunday
      default: InSession=false; break;
     }
  }

//+------------------------------------------------------------------+
//| Update market bias calculation                                   |
//+------------------------------------------------------------------+
void UpdateMarketBias()
  {
   static double prev_xha=EMPTY_VALUE;
   static double prev_close=EMPTY_VALUE;
   static double o2=0,c2=0;
   double emaOpen=iMA(NULL,0,InpHAPeriod,0,MODE_EMA,PRICE_OPEN,0);
   double emaHigh=iMA(NULL,0,InpHAPeriod,0,MODE_EMA,PRICE_HIGH,0);
   double emaLow =iMA(NULL,0,InpHAPeriod,0,MODE_EMA,PRICE_LOW,0);
   double emaClose=iMA(NULL,0,InpHAPeriod,0,MODE_EMA,PRICE_CLOSE,0);
   double haclose=(emaOpen+emaHigh+emaLow+emaClose)/4.0;
   double xhaopen=(emaOpen+emaClose)/2.0;
   double haopen=(prev_xha==EMPTY_VALUE)?xhaopen:(prev_xha+prev_close)/2.0;
   prev_xha=xhaopen; prev_close=haclose;
   o2=(o2*(InpHAPeriod-1)+haopen)/InpHAPeriod;
   c2=(c2*(InpHAPeriod-1)+haclose)/InpHAPeriod;
   static double osc_smooth=0; 
   double osc_bias=100*(c2-o2);
   osc_smooth=(osc_smooth*(InpOscPeriod-1)+osc_bias)/InpOscPeriod;
   static bool prevPos=false;
   bool currPos=(osc_bias>0);
   BiasChangedToBullish=!prevPos && currPos;
   BiasChangedToBearish=prevPos && !currPos;
   prevPos=currPos;
  }

//+------------------------------------------------------------------+
//| Update ADX filter                                                 |
//+------------------------------------------------------------------+
void UpdateADX()
  {
   static double adxHist[50];
   static int    idx=0;
   double adx=iADX(NULL,0,InpADXPeriod,PRICE_CLOSE,MODE_MAIN,0);
   adxHist[idx%InpADXLookback]=adx; idx++;
   int count=MathMin(idx,InpADXLookback);
   double sum=0; for(int i=0;i<count;i++) sum+=adxHist[i];
   double avg=sum/count;
   double dyn=MathMax(InpADXMin,avg*InpADXMultiplier);
   double thr=InpUseDynamicADX?dyn:InpStaticADXThreshold;
   // store condition in global variable for later trading logic
   if(InpEnableADXFilter)
      SynergyScore=adx>thr ? SynergyScore : SynergyScore; // placeholder
  }

//+------------------------------------------------------------------+
//| Update synergy score                                             |
//+------------------------------------------------------------------+
void UpdateSynergyScore()
  {
   double score=0;
   if(InpUseTF5m)
     {
      double rsi=iRSI(NULL,PERIOD_M5,14,PRICE_CLOSE,0);
      double ma1=iMA(NULL,PERIOD_M5,10,0,MODE_EMA,PRICE_CLOSE,0);
      double ma2=iMA(NULL,PERIOD_M5,100,0,MODE_EMA,PRICE_CLOSE,0);
      double macd=iMA(NULL,PERIOD_M5,12,0,MODE_EMA,PRICE_CLOSE,0)-
                 iMA(NULL,PERIOD_M5,26,0,MODE_EMA,PRICE_CLOSE,0);
      double macd_prev=iMA(NULL,PERIOD_M5,12,0,MODE_EMA,PRICE_CLOSE,1)-
                       iMA(NULL,PERIOD_M5,26,0,MODE_EMA,PRICE_CLOSE,1);
      score+= (rsi>50?InpRSIWeight:-InpRSIWeight)*InpWeight5m;
      score+= (ma1>ma2?InpTrendWeight:-InpTrendWeight)*InpWeight5m;
      score+= (macd>macd_prev?InpMacdvWeight:-InpMacdvWeight)*InpWeight5m;
     }
   if(InpUseTF15m)
     {
      double rsi=iRSI(NULL,PERIOD_M15,14,PRICE_CLOSE,0);
      double ma1=iMA(NULL,PERIOD_M15,50,0,MODE_EMA,PRICE_CLOSE,0);
      double ma2=iMA(NULL,PERIOD_M15,200,0,MODE_EMA,PRICE_CLOSE,0);
      double macd=iMA(NULL,PERIOD_M15,12,0,MODE_EMA,PRICE_CLOSE,0)-
                 iMA(NULL,PERIOD_M15,26,0,MODE_EMA,PRICE_CLOSE,0);
      double macd_prev=iMA(NULL,PERIOD_M15,12,0,MODE_EMA,PRICE_CLOSE,1)-
                       iMA(NULL,PERIOD_M15,26,0,MODE_EMA,PRICE_CLOSE,1);
      score+= (rsi>50?InpRSIWeight:-InpRSIWeight)*InpWeight15m;
      score+= (ma1>ma2?InpTrendWeight:-InpTrendWeight)*InpWeight15m;
      score+= (macd>macd_prev?InpMacdvWeight:-InpMacdvWeight)*InpWeight15m;
     }
   if(InpUseTF1h)
     {
      double rsi=iRSI(NULL,PERIOD_H1,14,PRICE_CLOSE,0);
      double ma1=iMA(NULL,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE,0);
      double ma2=iMA(NULL,PERIOD_H1,200,0,MODE_EMA,PRICE_CLOSE,0);
      double macd=iMA(NULL,PERIOD_H1,12,0,MODE_EMA,PRICE_CLOSE,0)-
                 iMA(NULL,PERIOD_H1,26,0,MODE_EMA,PRICE_CLOSE,0);
      double macd_prev=iMA(NULL,PERIOD_H1,12,0,MODE_EMA,PRICE_CLOSE,1)-
                       iMA(NULL,PERIOD_H1,26,0,MODE_EMA,PRICE_CLOSE,1);
      score+= (rsi>50?InpRSIWeight:-InpRSIWeight)*InpWeight1h;
      score+= (ma1>ma2?InpTrendWeight:-InpTrendWeight)*InpWeight1h;
      score+= (macd>macd_prev?InpMacdvWeight:-InpMacdvWeight)*InpWeight1h;
     }
   SynergyScore=score;
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

   TZOffset     = ParseTZOffset(InpTimeZone);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {

   datetime now=TimeCurrent()+TZOffset*3600;
   UpdateSession(now);
   if(InpUseMarketBias) UpdateMarketBias();
   if(InpEnableADXFilter) UpdateADX();
   if(InpUseSynergyScore) UpdateSynergyScore();
=======

   // trading logic will be implemented here
  }
//+------------------------------------------------------------------+
