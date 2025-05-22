#ifndef CORE_MQH
#define CORE_MQH

double CalculateSynergyScore();
bool InitSynergyIndicators();
void ReleaseSynergyIndicators();
bool InitMarketBias();
bool CalculateMarketBias();
double CalculateEMAValue(double &array[], int period);
void ReleaseMarketBias();
bool InitADXFilter();
bool CalculateADXFilter();
void ReleaseADXFilter();
double FindDeepestPivotLowBelowClose(int lookbackBars);
double FindHighestPivotHighAboveClose(int lookbackBars);
void WarmupIndicatorHistory();
ENUM_TIMEFRAMES GetTimeframeFromString(string tfString);
void OpenTrade(bool isLong,const double sl,const double tp);
void ManageOpenPositions();

#endif // CORE_MQH
