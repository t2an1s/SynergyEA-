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

//--- global variables derived from symbol info
double   PipSize;
double   ContractSize;
double   PipValuePerLot;
double   LotStep;

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
   // trading logic will be implemented here
  }
//+------------------------------------------------------------------+
