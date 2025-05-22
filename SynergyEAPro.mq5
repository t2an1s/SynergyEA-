//+------------------------------------------------------------------+
//|                                       Synergy_Strategy_v1.03.mq5 |
//|  Streamlined Synergy Strategy + PropEA‑style Hedge Engine (port) |
//|                                                                  |
//|  CHANGE LOG (v1.05 – 20‑May‑2025)                                |
//|   • Added BARS_REQUIRED constant and warm‑up guard               |
//|   • Warm-up now includes longest indicator periods               |
//|   • Force-load history for Synergy indicators across timeframes  |
//|   • Extra debug output when Synergy Score can't be calculated    |
//|  CHANGE LOG (v1.04 – 20‑May‑2025)                                |
//|   • Added BARS_REQUIRED constant and warm‑up guard               |
//|   • Warm-up now includes longest indicator periods               |
//|   • Robust history copying & buffer guards (no array overflow)   |
//|   • Re‑implemented pivot‑scan functions with bounds checks       |
//|   • Safe CopyBuffer calls with early return on incomplete data   |
//|   • Hardened CalculateEMAValue & CalculateADXFilter              |
//|   • Manual trades trigger hedge via OnTradeTransaction           |
//|   • Replaced external Heiken Ashi indicator with built‑in        |
//|     calculation to avoid load errors                             |
//+------------------------------------------------------------------+
#property copyright "t2an1s"
#property link      "http://www.yourwebsite.com"
#property version   "1.05"
#property version   "1.04"
#property strict

#include <Trade\Trade.mqh>
#include <Arrays\ArrayObj.mqh>
CTrade trade;

//────────────────────────────────────────────────────────────────────
// 1.  GLOBAL VARIABLES & CONSTANTS
//────────────────────────────────────────────────────────────────────
// ► min bars before activation (pivot window + safety)
int  BARS_REQUIRED = 100;

// ─── price & time buffers (user-side copies) ──────────────────────
double   Open[] , High[] , Low[] , Close[];
datetime TimeSeries[];            // ← renamed (was Time[])
// Position‑management state
// (unchanged lines omitted for brevity)
double pivotStopLongEntry  = 0;
double pivotTpLongEntry    = 0;
double pivotStopShortEntry = 0;
double pivotTpShortEntry   = 0;
double lastEntryLots       = 0;
double hedgeLotsLast       = 0;
bool   scaleOut1LongTriggered = false;
bool   scaleOut1ShortTriggered = false;
bool   beAppliedLong = false;
bool   beAppliedShort = false;
bool g_newBarJustDetected = false;

// Master trigger – need at least one filter active
bool   entryTriggersEnabled = false;
bool   inSession            = true;
// ── Hedge-link monitor ─────────────────────────────────────────────
const int    HEARTBEAT_SEC    = 5;          // how often we publish our pulse
const int    LINK_TIMEOUT_SEC = 15;         // grace window before status = NOT OK
ulong        lastPulseSent    = 0;          // when we last pinged the other side
bool         linkWasOK        = false;      // remembers previous state for debug prints
string COMM_FILE_PATH = "MQL5\\Files\\MT5com.txt";
string HEARTBEAT_FILE_PATH = "MQL5\\Files\\MT5com_heartbeat.txt";
string HEDGE_HEARTBEAT_FILE_PATH = "MQL5\\Files\\MT5com_hedge_heartbeat.txt";
const int FILE_WRITE_RETRY = 3;
const int FILE_CHECK_SECONDS = 5;


//--------------------------------------------------------------------
// 2.  UTILITY — indicator buffer guard                               
//--------------------------------------------------------------------
//+------------------------------------------------------------------+
//| Utility – did CopyBuffer() give us *at least* the bars we wanted?|
//+------------------------------------------------------------------+
bool CopyOk(const int want,const int got)
{
   return got >= want;   // old code required got == want   [oai_citation:0‡PropMain EA.txt](file-service://file-QgH1Cr4LXwgNw3tZYStN2o)
}

//+------------------------------------------------------------------+
//| Enumeration for Communication Method                              |
//+------------------------------------------------------------------+
enum ENUM_COMMUNICATION_METHOD { 
   GLOBAL_VARS,   // Global Variables
   FILE_BASED     // File-Based
};

//+------------------------------------------------------------------+
//| Input Parameters - General Settings                              |
//+------------------------------------------------------------------+
input group "General Settings"
input string    EA_Name = "Synergy Strategy 2.0";   // EA Name
input int       Magic_Number = 123456;                 // Magic Number
input bool      EnableTrading = true;                  // Enable Trading
input bool      TestingMode = false;                   // Strategy Tester Mode
input int       SlippagePoints = 10;                   // Max slippage (points)

//+------------------------------------------------------------------+
//| Input Parameters - Visualization Settings                         |
//+------------------------------------------------------------------+
input group "Visualization Settings"
input bool      ShowPivotLines = true;                // Show Pivot Points on Chart
input bool      ShowMarketBias = true;                // Show Market Bias Indicator

//+------------------------------------------------------------------+
//| Input Parameters - Risk Management                               |
//+------------------------------------------------------------------+
input group "Risk Management"
input double    RiskPercent = 0.3;                     // Risk Percent per Trade (% of balance)
input bool      UseFixedLot = false;                   // Use Fixed Lot Size
input double    FixedLotSize = 0.01;                   // Fixed Lot Size
input double    MinLot = 0.01;                         // Minimum Lot Size

//+------------------------------------------------------------------+
//| Input Parameters - PropEA Integration                             |
//+------------------------------------------------------------------+
input group "PropEA Settings"
input double    ChallengeC = 700;                      // Challenge Fee
input double    MaxDD = 4000;                          // Maximum Drawdown
input double    StageTarget = 1000;                    // Stage Target
input double    SlipBufD = 0.10;                       // Slippage Buffer
input double    dailyDD = 1700;                        // Daily Drawdown Limit
input int       HedgeEA_Magic = 789123;                // Hedge EA Magic Number
input bool      InputEnableHedgeCommunication = true; // Enable Hedge Communication (read-only)
bool EnableHedgeCommunication;  // Will be set in OnInit
input ENUM_COMMUNICATION_METHOD CommunicationMethod = GLOBAL_VARS; // Hedge Communication Method

// Shared signal file path (for FILE_BASED mode)
string SignalFilePath;
input int       CurrentPhase = 1;                      // Current Challenge Phase (1 or 2)

//+------------------------------------------------------------------+
//| Input Parameters - Scale-Out & BreakEven                          |
//+------------------------------------------------------------------+
input group "Scale-Out Settings"
input bool      EnableScaleOut = true;                 // Enable Scale-Out Strategy
input bool      ScaleOut1Enabled = true;               // Enable First Scale-Out
input double    ScaleOut1Pct = 50;                     // Scale-Out at % of TP Distance
input double    ScaleOut1Size = 50;                    // % of Position to Close
input bool      ScaleOut1BE = true;                    // Set BE after Scale-Out

input group "BreakEven Settings"
input bool      EnableBreakEven = false;               // Enable BreakEven w/o Scale-Out
input int       BeTriggerPips = 10;                    // BE Trigger (pips)

//+------------------------------------------------------------------+
//| Input Parameters - Pivot Point Settings                          |
//+------------------------------------------------------------------+
input group "Pivot Point Settings"
input int       PivotTPBars = 50;                      // Lookback Bars for Pivot-based SL/TP
input int       PivotLengthLeft = 6;                   // Pivot Length Left
input int       PivotLengthRight = 6;                  // Pivot Length Right

//+------------------------------------------------------------------+
//| Input Parameters - Synergy Score Settings                         |
//+------------------------------------------------------------------+
input group "Synergy Score Settings"
input bool      UseSynergyScore = true;                // Use Synergy Score
input double    RSI_Weight = 1.0;                      // RSI Weight
input double    Trend_Weight = 1.0;                    // MA Trend Weight
input double    MACDV_Slope_Weight = 1.0;              // MACDV Slope Weight

// Timeframe selection
input bool      UseTF5min = true;                      // Use 5 Minute TF
input double    Weight_M5 = 1.0;                       // 5min Weight
input bool      UseTF15min = true;                     // Use 15 Minute TF
input double    Weight_M15 = 1.0;                      // 15min Weight
input bool      UseTF1hour = true;                     // Use 1 Hour TF
input double    Weight_H1 = 1.0;                       // 1hour Weight

//+------------------------------------------------------------------+
//| Input Parameters - Market Bias Settings                           |
//+------------------------------------------------------------------+
input group "Market Bias Settings"
input bool      UseMarketBias = true;                  // Use Market Bias
input string    BiasTimeframe = "current";             // Market Bias Timeframe
input int       HeikinAshiPeriod = 100;                // HA Period
input int       OscillatorPeriod = 7;                  // Oscillator Period
input color     BullishColor = clrLime;                // Bullish Color
input color     BearishColor = clrRed;                 // Bearish Color

//+------------------------------------------------------------------+
//| Input Parameters - ADX Filter Settings                            |
//+------------------------------------------------------------------+
input group "ADX Filter Settings"
input bool      EnableADXFilter = true;                // Enable ADX Filter
input int       ADXPeriod = 14;                        // ADX Period
input bool      UseDynamicADX = true;                  // Dynamic Threshold
input double    StaticADXThreshold = 25;               // Static Threshold
input int       ADXLookbackPeriod = 20;                // Average Lookback
input double    ADXMultiplier = 0.8;                   // Multiplier
input double    ADXMinThreshold = 15;                  // Minimum Threshold

//+------------------------------------------------------------------+
//| Input Parameters - Trading Sessions                               |
//+------------------------------------------------------------------+
input group "Trading Sessions"
input bool      EnableSessionFilter = true;            // Enable Session Filter
input string    MondaySession1 = "0000-2359";          // Monday Session 1
input string    MondaySession2 = "";                   // Monday Session 2
input string    TuesdaySession1 = "0000-2359";         // Tuesday Session 1
input string    TuesdaySession2 = "";                  // Tuesday Session 2
input string    WednesdaySession1 = "0000-2359";       // Wednesday Session 1
input string    WednesdaySession2 = "";                // Wednesday Session 2
input string    ThursdaySession1 = "0000-2359";        // Thursday Session 1
input string    ThursdaySession2 = "";                 // Thursday Session 2
input string    FridaySession1 = "0000-2359";          // Friday Session 1
input string    FridaySession2 = "";                   // Friday Session 2
input string    SaturdaySession1 = "0000-2359";        // Saturday Session 1
input string    SaturdaySession2 = "";                 // Saturday Session 2
input string    SundaySession1 = "0000-2359";          // Sunday Session 1
input string    SundaySession2 = "";                   // Sunday Session 2

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
double initialBalance;                                 // Starting balance
double hedgeFactor;                                    // Hedge factor
bool   bleedDone = false;                              // Hedge bleed flag

// Indicator handles
int rsiHandle_M5, maFastHandle_M5, maSlowHandle_M5, macdHandle_M5;
int rsiHandle_M15, maFastHandle_M15, maSlowHandle_M15, macdHandle_M15;
int rsiHandle_H1, maFastHandle_H1, maSlowHandle_H1, macdHandle_H1;

// Indicator buffers
double rsiBuffer_M5[], maFastBuffer_M5[], maSlowBuffer_M5[], macdBuffer_M5[], macdPrevBuffer_M5[];
double rsiBuffer_M15[], maFastBuffer_M15[], maSlowBuffer_M15[], macdBuffer_M15[], macdPrevBuffer_M15[];
double rsiBuffer_H1[], maFastBuffer_H1[], maSlowBuffer_H1[], macdBuffer_H1[], macdPrevBuffer_H1[];

// Synergy score
double synergyScore;

// Market bias variables
int haHandle = INVALID_HANDLE;
double haOpen[], haHigh[], haLow[], haClose[];
double oscBias, oscSmooth;
bool biasChangedToBullish = false;
bool biasChangedToBearish = false;
bool prevBiasPositive = false;
bool currentBiasPositive = false;

// ADX filter variables
int adxHandle;
double adxMain[], adxPlus[], adxMinus[];
double effectiveADXThreshold;
bool adxTrendCondition;

// Prop EA sends “PROP_HB_{magic}”; hedge EA sends “HEDGE_HB_{magic}”
//────────────────────────────────────────────────────────────────────
// REPLACE THE SendHeartbeat FUNCTION
//────────────────────────────────────────────────────────────────────
void SendHeartbeat(bool isPropSide)
{
   if(!EnableHedgeCommunication) return;
   
   if(CommunicationMethod == GLOBAL_VARS)
   {
      // Original global variable code - fix type conversion
      string name = "PROP_HB_" + IntegerToString(Magic_Number);
      double currentTime = (double)TimeCurrent();
      GlobalVariableSet(name, currentTime);
      lastPulseSent = (ulong)TimeCurrent();
      
      // Periodically print debug info
      static datetime lastPrintTime = 0;
      if(TimeCurrent() - lastPrintTime > 60) {
         Print("Main EA heartbeat sent: ", name, " = ", TimeToString((datetime)currentTime));
         lastPrintTime = TimeCurrent();
      }
   }
   else // FILE_BASED
   {
      string heartbeatData = "MAIN_HEARTBEAT," + IntegerToString(Magic_Number) + "," + 
                            IntegerToString((int)TimeCurrent()); // Fix type conversion
      
      // Force cleanup first
      CleanupFileHandles();
      
      // Reset error state
      ResetLastError();
      
      int fileHandle = FileOpen(HEARTBEAT_FILE_PATH, FILE_WRITE|FILE_TXT|FILE_COMMON);
      if(fileHandle != INVALID_HANDLE)
      {
         FileWriteString(fileHandle, heartbeatData);
         FileFlush(fileHandle);
         FileClose(fileHandle);
         
         // Report success with lower frequency to avoid log spam
         static datetime lastReport = 0;
         if(TimeCurrent() - lastReport > 60) {  // Report once per minute
            Print("✅ Main EA heartbeat sent to file: ", HEARTBEAT_FILE_PATH);
            lastReport = TimeCurrent();
         }
      }
      else
      {
         int error = GetLastError();
         static datetime lastErrorReport = 0;
         if(TimeCurrent() - lastErrorReport > 30) { // Report errors every 30 seconds
            Print("❌ ERROR: Failed to write heartbeat file: ", error, " (", GetErrorDescription(error), ")");
            lastErrorReport = TimeCurrent();
         }
      }
      
      lastPulseSent = (ulong)TimeCurrent();
   }
}


//────────────────────────────────────────────────────────────────────
// REPLACE THE IsLinkAlive FUNCTION
//────────────────────────────────────────────────────────────────────
bool IsLinkAlive(bool isPropSide)
{
   if(!EnableHedgeCommunication) return false;
   
   if(CommunicationMethod == GLOBAL_VARS)
   {
      // Original global variable code
      string peer = "HEDGE_HB_" + IntegerToString(HedgeEA_Magic);
      
      if(!GlobalVariableCheck(peer)) {
         static datetime lastErrorTime = 0;
         if(TimeCurrent() - lastErrorTime > 60) {
            Print("ERROR: Hedge heartbeat not found: ", peer);
            lastErrorTime = TimeCurrent();
         }
         return false;
      }
      
      double ts = GlobalVariableGet(peer);
      bool isAlive = (TimeCurrent() - (datetime)ts) <= LINK_TIMEOUT_SEC;
      
      // Log periodic status
      static datetime lastStatusTime = 0;
      if(TimeCurrent() - lastStatusTime > 60) {
         Print("Hedge link status: ", isAlive ? "ALIVE" : "DEAD", 
               " (Last beat: ", TimeToString((datetime)ts), 
               ", Age: ", TimeCurrent() - (datetime)ts, "s)");
         lastStatusTime = TimeCurrent();
      }
      
      return isAlive;
   }
   else // FILE_BASED
   {
      // Try to read hedge heartbeat file - MUST USE FILE_COMMON FLAG
      if(!FileIsExist(HEDGE_HEARTBEAT_FILE_PATH, FILE_COMMON))
      {
         static datetime lastErrorReport = 0;
         if(TimeCurrent() - lastErrorReport > 30) {  // Report every 30 seconds
            Print("WARNING: Hedge heartbeat file not found: ", HEDGE_HEARTBEAT_FILE_PATH);
            lastErrorReport = TimeCurrent();
         }
         return false;
      }
      
      int fileHandle = FileOpen(HEDGE_HEARTBEAT_FILE_PATH, FILE_READ|FILE_TXT|FILE_COMMON);
      if(fileHandle == INVALID_HANDLE)
      {
         Print("ERROR: Unable to open hedge heartbeat file. Error: ", GetLastError());
         return false;
      }
      
      string content = FileReadString(fileHandle);
      FileClose(fileHandle);
      
      // Parse heartbeat data: format is HEDGE_HEARTBEAT,magicnumber,timestamp
      string parts[];
      int count = StringSplit(content, ',', parts);
      
      // Check format validity (removed frequent debug message)
      if(count < 3 || parts[0] != "HEDGE_HEARTBEAT")
      {
         static datetime lastFormatError = 0;
         if(TimeCurrent() - lastFormatError > 60) {  // Only log format errors once per minute
            Print("ERROR: Invalid hedge heartbeat format: ", content);
            lastFormatError = TimeCurrent();
         }
         return false;
      }
      
      // Check if magic number matches
      if(parts[1] != IntegerToString(HedgeEA_Magic))
      {
         Print("ERROR: Hedge heartbeat has incorrect magic number: ", parts[1], 
               " expected: ", HedgeEA_Magic);
         return false;
      }
      
      // Check timestamp - FIXED CALCULATION
      string timestampString = parts[2];
      if(StringLen(timestampString) > 0)
      {
         datetime heartbeatTime = (datetime)StringToInteger(timestampString);
         
         if(heartbeatTime > 0)
         {
            int ageSeconds = (int)(TimeCurrent() - heartbeatTime);  // Cast to int for proper display
            bool isAlive = ageSeconds <= LINK_TIMEOUT_SEC;
            
            // Log status periodically
            static bool wasAlive = false;
            static datetime lastStatusLog = 0;
            
            if(isAlive != wasAlive || TimeCurrent() - lastStatusLog > 60)
            {
               Print("Hedge link status: ", isAlive ? "ALIVE" : "DEAD", 
                     " (Last heartbeat: ", TimeToString(heartbeatTime), 
                     ", Age: ", ageSeconds, "s)");
               lastStatusLog = TimeCurrent();
               wasAlive = isAlive;
            }
            
            return isAlive;
         }
         else
         {
            Print("ERROR: Invalid timestamp value: ", timestampString, " parsed as ", heartbeatTime);
            return false;
         }
      }
      else
      {
         Print("ERROR: Empty timestamp string in heartbeat");
         return false;
      }
   }
}

void OpenTrade(bool isLong, const double sl, const double tp)
{
   // STRICT PIVOT VALIDATION - NO TRADE IF INVALID
   if(sl <= 0 || tp <= 0)
   {
      Print("❌ OpenTrade ABORTED: Invalid pivot levels - SL:", DoubleToString(sl, 5), " TP:", DoubleToString(tp, 5));
      return;
   }
   
   double currentPrice = Close[0];
   
   // STRICT PIVOT LOGIC VALIDATION
   if(isLong)
   {
      if(sl >= currentPrice || tp <= currentPrice)
      {
         Print("❌ LONG Trade ABORTED: Invalid pivot relationship");
         Print("   Current Price: ", DoubleToString(currentPrice, 5));
         Print("   Pivot SL: ", DoubleToString(sl, 5), " (must be < current)");
         Print("   Pivot TP: ", DoubleToString(tp, 5), " (must be > current)");
         return;
      }
   }
   else
   {
      if(sl <= currentPrice || tp >= currentPrice)
      {
         Print("❌ SHORT Trade ABORTED: Invalid pivot relationship");
         Print("   Current Price: ", DoubleToString(currentPrice, 5));
         Print("   Pivot SL: ", DoubleToString(sl, 5), " (must be > current)");
         Print("   Pivot TP: ", DoubleToString(tp, 5), " (must be < current)");
         return;
      }
   }
   
   // Check minimum stop distances WITHOUT modifying pivot levels
   double stopPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopPts * _Point;
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   Print("=== PIVOT TRADE VALIDATION ===");
   Print("Current Ask: ", DoubleToString(askPrice, 5), " Bid: ", DoubleToString(bidPrice, 5));
   Print("Min Stop Distance: ", DoubleToString(minDist, 5), " (", stopPts, " points)");
   Print("Requested SL: ", DoubleToString(sl, 5));
   Print("Requested TP: ", DoubleToString(tp, 5));
   
   if(isLong)
   {
      double slDist = askPrice - sl;
      double tpDist = tp - askPrice;
      Print("LONG distances - SL: ", DoubleToString(slDist, 5), " TP: ", DoubleToString(tpDist, 5));
      
      if(slDist < minDist || tpDist < minDist)
      {
         Print("❌ LONG Trade ABORTED: Pivot levels don't meet broker minimum stop distance");
         Print("   Required min distance: ", DoubleToString(minDist, 5));
         Print("   SL distance: ", DoubleToString(slDist, 5), " (", slDist >= minDist ? "OK" : "TOO CLOSE", ")");
         Print("   TP distance: ", DoubleToString(tpDist, 5), " (", tpDist >= minDist ? "OK" : "TOO CLOSE", ")");
         return;
      }
   }
   else
   {
      double slDist = sl - bidPrice;
      double tpDist = bidPrice - tp;
      Print("SHORT distances - SL: ", DoubleToString(slDist, 5), " TP: ", DoubleToString(tpDist, 5));
      
      if(slDist < minDist || tpDist < minDist)
      {
         Print("❌ SHORT Trade ABORTED: Pivot levels don't meet broker minimum stop distance");
         Print("   Required min distance: ", DoubleToString(minDist, 5));
         Print("   SL distance: ", DoubleToString(slDist, 5), " (", slDist >= minDist ? "OK" : "TOO CLOSE", ")");
         Print("   TP distance: ", DoubleToString(tpDist, 5), " (", tpDist >= minDist ? "OK" : "TOO CLOSE", ")");
         return;
      }
   }

   // Use EXACT pivot levels - NO MODIFICATION
   double finalSL = NormalizeDouble(sl, _Digits);
   double finalTP = NormalizeDouble(tp, _Digits);
   
   Print("✅ PIVOT LEVELS VALIDATED - Proceeding with trade");
   Print("   Final SL: ", DoubleToString(finalSL, 5));
   Print("   Final TP: ", DoubleToString(finalTP, 5));

   //––– Calculate lot size
   double slPips = MathAbs(currentPrice - finalSL) / GetPipSize();
   
   Print("=== LOT SIZE CALCULATION ===");
   Print("OpenTrade: UseFixedLot=", UseFixedLot, ", FixedLotSize=", FixedLotSize, ", RiskPercent=", RiskPercent);
   
   double rawLots;
   if(UseFixedLot) {
      rawLots = FixedLotSize;
      Print("Using fixed lot size: ", FixedLotSize);
   } else {
      rawLots = CalculatePositionSize(slPips, RiskPercent);
      Print("Using risk-based lot size: ", rawLots, " (SL pips: ", slPips, ", Risk%: ", RiskPercent, ")");
   }
   
   double lots = NormalizeLots(rawLots);
   Print("Final normalized lot size: ", lots);

   //––– Calculate hedge volume
   double lotLive = NormalizeLots(lots * hedgeFactor);

   // Record for later
   lastEntryLots = lots;
   hedgeLotsLast = lotLive;

   //––– Place main order with EXACT pivot levels
   Print("=== EXECUTING TRADE ===");
   Print("Direction: ", isLong ? "LONG" : "SHORT");
   Print("Volume: ", DoubleToString(lots, 2));
   Print("Entry: ~", DoubleToString(isLong ? askPrice : bidPrice, 5));
   Print("Stop Loss: ", DoubleToString(finalSL, 5));
   Print("Take Profit: ", DoubleToString(finalTP, 5));
   
   bool ok = isLong
             ? trade.Buy(lots, _Symbol, 0, finalSL, finalTP, "Long_Pivot")
             : trade.Sell(lots, _Symbol, 0, finalSL, finalTP, "Short_Pivot");

   if(!ok) { 
      int error = trade.ResultRetcode();
      Print("❌ OpenTrade(): order failed – Error: ", error, " (", trade.ResultComment(), ")");
      return;
   }

   Print("✅ TRADE EXECUTED SUCCESSFULLY!");
   Print("   Order ticket: ", trade.ResultOrder());
   Print("   Execution price: ", DoubleToString(trade.ResultPrice(), 5));

   // Reset per-side flags
   if(isLong) { 
      scaleOut1LongTriggered = false; 
      beAppliedLong = false; 
   }
   else { 
      scaleOut1ShortTriggered = false; 
      beAppliedShort = false; 
   }

   //––– Fire hedge order
   if(EnableHedgeCommunication)
   {
      Print("=== SENDING HEDGE SIGNAL ===");
      Print("Hedge Direction: ", isLong ? "SELL" : "BUY");
      Print("Hedge Volume: ", DoubleToString(lotLive, 2));
      Print("Hedge TP: ", DoubleToString(finalTP, 5));
      Print("Hedge SL: ", DoubleToString(finalSL, 5));
      
      SendHedgeSignal("OPEN", isLong? "SELL":"BUY", lotLive, finalTP, finalSL);
   }
}

//+------------------------------------------------------------------+
//| Manage open positions (scale-out, breakeven, trailing)           |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   // Get current position
   if(!PositionSelect(_Symbol)) return;
   
   // Check if the position belongs to this EA
   if(PositionGetInteger(POSITION_MAGIC) != Magic_Number) return;
   
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double positionVolume = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);
   
   // PREVENT IMMEDIATE MANAGEMENT - Wait at least 10 seconds after position opens
   int positionAge = (int)(TimeCurrent() - positionTime);
   if(positionAge < 10)
   {
      static datetime lastWarning = 0;
      if(TimeCurrent() - lastWarning > 5)
      {
         Print("DEBUG: Position management delayed - Position age: ", positionAge, " seconds (waiting for 10s)");
         lastWarning = TimeCurrent();
      }
      return;
   }
   
   // LONG position management
   if(posType == POSITION_TYPE_BUY)
   {
      double distInPips = (Close[0] - entryPrice) / GetPipSize();
      
      // Scale-out logic for long positions
      if(EnableScaleOut && ScaleOut1Enabled && !scaleOut1LongTriggered && pivotTpLongEntry > 0)
      {
         // Calculate scale-out price at specified percentage of the target distance
         double scaleOut1Price = entryPrice + ((pivotTpLongEntry - entryPrice) * ScaleOut1Pct / 100.0);
         
         Print("DEBUG: LONG Scale-out check - Current: ", DoubleToString(Close[0], 5), 
               " Target: ", DoubleToString(scaleOut1Price, 5), 
               " Progress: ", DoubleToString(distInPips, 1), " pips");
         
         // Execute scale-out when price reaches the level
         if(Close[0] >= scaleOut1Price)
         {
            scaleOut1LongTriggered = true;
            double partialQty = positionVolume * (ScaleOut1Size / 100.0);
            
            Print("🎯 EXECUTING LONG SCALE-OUT:");
            Print("   Price reached: ", DoubleToString(Close[0], 5));
            Print("   Target was: ", DoubleToString(scaleOut1Price, 5));
            Print("   Closing volume: ", DoubleToString(partialQty, 2));
            
            if(trade.PositionClosePartial(PositionGetTicket(0), partialQty))
            {
               Print("✅ Long position scaled out successfully!");
               
               // Set breakeven if enabled
               if(ScaleOut1BE && !beAppliedLong && pivotStopLongEntry < entryPrice)
               {
                  beAppliedLong = true;
                  double newSL = entryPrice;
                  
                  Print("🔄 Setting breakeven after scale-out:");
                  Print("   Old SL: ", DoubleToString(pivotStopLongEntry, 5));
                  Print("   New SL: ", DoubleToString(newSL, 5));
                  
                  if(trade.PositionModify(PositionGetTicket(0), newSL, pivotTpLongEntry))
                  {
                     Print("✅ Long position SL moved to breakeven after scale-out");
                     pivotStopLongEntry = newSL;
                     
                     // Signal hedge EA about stop adjustment
                     if(EnableHedgeCommunication)
                     {
                        SendHedgeSignal("MODIFY", "SELL", 0, pivotTpLongEntry, newSL);
                        Print("📤 Hedge modify signal sent: SL adjusted to ", DoubleToString(newSL, 5));
                     }
                  }
                  else
                  {
                     Print("❌ Failed to move SL to breakeven. Error: ", trade.ResultRetcode());
                  }
               }
               
               // Signal hedge EA about scale-out
               if(EnableHedgeCommunication)
               {
                  double hedgeScaleOutLots = NormalizeLots(partialQty * hedgeFactor);
                  SendHedgeSignal("PARTIAL_CLOSE", "SELL", hedgeScaleOutLots, 0, 0);
                  Print("📤 Hedge partial close signal sent: SELL ", DoubleToString(hedgeScaleOutLots, 2));
               }
            }
            else
            {
               Print("❌ Scale-out failed. Error: ", trade.ResultRetcode(), " (", trade.ResultComment(), ")");
            }
         }
      }
      
      // Regular breakeven (separate from scale-out)
      if(EnableBreakEven && !beAppliedLong && distInPips >= BeTriggerPips)
      {
         beAppliedLong = true;
         double newSL = entryPrice;
         
         Print("🔄 Regular breakeven triggered:");
         Print("   Distance: ", DoubleToString(distInPips, 1), " pips (trigger: ", BeTriggerPips, ")");
         Print("   Old SL: ", DoubleToString(pivotStopLongEntry, 5));
         Print("   New SL: ", DoubleToString(newSL, 5));
         
         if(trade.PositionModify(PositionGetTicket(0), newSL, pivotTpLongEntry))
         {
            Print("✅ Long position SL moved to breakeven");
            pivotStopLongEntry = newSL;
            
            // Signal hedge EA about stop adjustment
            if(EnableHedgeCommunication)
            {
               SendHedgeSignal("MODIFY", "SELL", 0, pivotTpLongEntry, newSL);
               Print("📤 Hedge modify signal sent: SL adjusted to ", DoubleToString(newSL, 5));
            }
         }
         else
         {
            Print("❌ Failed to move SL to breakeven. Error: ", trade.ResultRetcode());
         }
      }
   }
   
   // SHORT position management (similar structure)
   if(posType == POSITION_TYPE_SELL)
   {
      double distInPips = (entryPrice - Close[0]) / GetPipSize();
      
      // Scale-out logic for short positions
      if(EnableScaleOut && ScaleOut1Enabled && !scaleOut1ShortTriggered && pivotTpShortEntry > 0)
      {
         double scaleOut1Price = entryPrice - ((entryPrice - pivotTpShortEntry) * ScaleOut1Pct / 100.0);
         
         Print("DEBUG: SHORT Scale-out check - Current: ", DoubleToString(Close[0], 5), 
               " Target: ", DoubleToString(scaleOut1Price, 5), 
               " Progress: ", DoubleToString(distInPips, 1), " pips");
         
         if(Close[0] <= scaleOut1Price)
         {
            scaleOut1ShortTriggered = true;
            double partialQty = positionVolume * (ScaleOut1Size / 100.0);
            
            Print("🎯 EXECUTING SHORT SCALE-OUT:");
            Print("   Price reached: ", DoubleToString(Close[0], 5));
            Print("   Target was: ", DoubleToString(scaleOut1Price, 5));
            Print("   Closing volume: ", DoubleToString(partialQty, 2));
            
            if(trade.PositionClosePartial(PositionGetTicket(0), partialQty))
            {
               Print("✅ Short position scaled out successfully!");
               
               // Set breakeven if enabled
               if(ScaleOut1BE && !beAppliedShort && pivotStopShortEntry > entryPrice)
               {
                  beAppliedShort = true;
                  double newSL = entryPrice;
                  
                  Print("🔄 Setting breakeven after scale-out:");
                  Print("   Old SL: ", DoubleToString(pivotStopShortEntry, 5));
                  Print("   New SL: ", DoubleToString(newSL, 5));
                  
                  if(trade.PositionModify(PositionGetTicket(0), newSL, pivotTpShortEntry))
                  {
                     Print("✅ Short position SL moved to breakeven after scale-out");
                     pivotStopShortEntry = newSL;
                     
                     // Signal hedge EA about stop adjustment
                     if(EnableHedgeCommunication)
                     {
                        SendHedgeSignal("MODIFY", "BUY", 0, pivotTpShortEntry, newSL);
                        Print("📤 Hedge modify signal sent: SL adjusted to ", DoubleToString(newSL, 5));
                     }
                  }
                  else
                  {
                     Print("❌ Failed to move SL to breakeven. Error: ", trade.ResultRetcode());
                  }
               }
               
               // Signal hedge EA about scale-out
               if(EnableHedgeCommunication)
               {
                  double hedgeScaleOutLots = NormalizeLots(partialQty * hedgeFactor);
                  SendHedgeSignal("PARTIAL_CLOSE", "BUY", hedgeScaleOutLots, 0, 0);
                  Print("📤 Hedge partial close signal sent: BUY ", DoubleToString(hedgeScaleOutLots, 2));
               }
            }
            else
            {
               Print("❌ Scale-out failed. Error: ", trade.ResultRetcode(), " (", trade.ResultComment(), ")");
            }
         }
      }
      
      // Regular breakeven (separate from scale-out)
      if(EnableBreakEven && !beAppliedShort && distInPips >= BeTriggerPips)
      {
         beAppliedShort = true;
         double newSL = entryPrice;
         
         Print("🔄 Regular breakeven triggered:");
         Print("   Distance: ", DoubleToString(distInPips, 1), " pips (trigger: ", BeTriggerPips, ")");
         Print("   Old SL: ", DoubleToString(pivotStopShortEntry, 5));
         Print("   New SL: ", DoubleToString(newSL, 5));
         
         if(trade.PositionModify(PositionGetTicket(0), newSL, pivotTpShortEntry))
         {
            Print("✅ Short position SL moved to breakeven");
            pivotStopShortEntry = newSL;
            
            // Signal hedge EA about stop adjustment
            if(EnableHedgeCommunication)
            {
               SendHedgeSignal("MODIFY", "BUY", 0, pivotTpShortEntry, newSL);
               Print("📤 Hedge modify signal sent: SL adjusted to ", DoubleToString(newSL, 5));
            }
         }
         else
         {
            Print("❌ Failed to move SL to breakeven. Error: ", trade.ResultRetcode());
         }
      }
   }
}

////+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set this at the very beginning of OnInit
   EnableHedgeCommunication = InputEnableHedgeCommunication;

   Print("=== INITIALIZATION STARTED ===");
   Print("InputEnableHedgeCommunication: ", InputEnableHedgeCommunication ? "TRUE" : "FALSE");
   Print("CommunicationMethod: ", CommunicationMethod == GLOBAL_VARS ? "GLOBAL_VARS" : "FILE_BASED");
   Print("TestingMode: ", TestingMode ? "TRUE" : "FALSE");
   Print("MQL_TESTER: ", MQLInfoInteger(MQL_TESTER) ? "TRUE" : "FALSE");

   // Clean up any existing file handles first
   CleanupFileHandles();

   // Set trade parameters
   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Strategy Tester Mode
   if(MQLInfoInteger(MQL_TESTER) || TestingMode)
   {
      // Disable hedge communication in tester
      EnableHedgeCommunication = false;  
      Print("Running in Strategy Tester Mode - Hedge communication disabled");
   }

   Print("Final EnableHedgeCommunication: ", EnableHedgeCommunication ? "TRUE" : "FALSE");

   // Initialize file paths for cross-terminal communication
   Print("=== FILE COMMUNICATION SETUP ===");
   if(EnableHedgeCommunication && CommunicationMethod == FILE_BASED)
   {
      Print("Setting up FILE_BASED communication...");
      
      // Use common data folder so both terminals can access the files
      string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
      Print("Common data path: ", commonPath);
      
      // Ensure path ends with backslash
      if(StringLen(commonPath) > 0 && StringGetCharacter(commonPath, StringLen(commonPath)-1) != '\\')
         commonPath += "\\";
      
      HEARTBEAT_FILE_PATH      = commonPath + "MT5com_heartbeat.txt";
      HEDGE_HEARTBEAT_FILE_PATH = commonPath + "MT5com_hedge_heartbeat.txt";
      COMM_FILE_PATH            = commonPath + "MT5com.txt";
      SignalFilePath            = commonPath + "Synergy_Signals.txt";
      
      Print("File paths configured:");
      Print("- HEARTBEAT_FILE_PATH: ", HEARTBEAT_FILE_PATH);
      Print("- HEDGE_HEARTBEAT_FILE_PATH: ", HEDGE_HEARTBEAT_FILE_PATH);
      Print("- COMM_FILE_PATH: ", COMM_FILE_PATH);
      Print("- SignalFilePath: ", SignalFilePath);
      
      // Test file access for heartbeat with FILE_COMMON flag
      Print("Attempting to create heartbeat file...");
      ResetLastError();
      
      int fileHandle = FileOpen(HEARTBEAT_FILE_PATH, FILE_WRITE|FILE_TXT|FILE_COMMON);
      if(fileHandle != INVALID_HANDLE)
      {
         string heartbeatContent = "MAIN_HEARTBEAT," + IntegerToString(Magic_Number) + "," + 
                        IntegerToString(TimeCurrent());
         int writeResult = FileWriteString(fileHandle, heartbeatContent);
         FileFlush(fileHandle);
         FileClose(fileHandle);
         
         Print("✅ SUCCESS: Heartbeat file created successfully!");
         Print("   Content: ", heartbeatContent);
         Print("   Bytes written: ", writeResult);
         Print("   Magic: ", Magic_Number);
         Print("   Path: ", HEARTBEAT_FILE_PATH);
         
         // Verify file was actually created
         if(FileIsExist(HEARTBEAT_FILE_PATH, FILE_COMMON))
         {
            Print("✅ VERIFIED: File exists and is accessible");
         }
         else
         {
            Print("⚠️  WARNING: File created but not accessible via FileIsExist");
         }
      }
      else
      {
         int errorCode = GetLastError();
         Print("❌ ERROR: Failed to create heartbeat file!");
         Print("   Error Code: ", errorCode, " (", GetErrorDescription(errorCode), ")");
         Print("   Path: ", HEARTBEAT_FILE_PATH);
         Print("   Common Path: ", commonPath);
         
         // Try alternative path
         Print("Trying alternative path without FILE_COMMON...");
         string altPath = "MQL5\\Files\\MT5com_heartbeat.txt";
         ResetLastError();
         int altHandle = FileOpen(altPath, FILE_WRITE|FILE_TXT);
         if(altHandle != INVALID_HANDLE)
         {
            FileWriteString(altHandle, "MAIN_HEARTBEAT," + IntegerToString(Magic_Number) + "," + 
                           IntegerToString(TimeCurrent()));
            FileFlush(altHandle);
            FileClose(altHandle);
            Print("✅ Alternative path worked: ", altPath);
            
            // 🔥 CRITICAL FIX: Update ALL paths to use the same directory
            HEARTBEAT_FILE_PATH = altPath;
            HEDGE_HEARTBEAT_FILE_PATH = "MQL5\\Files\\MT5com_hedge_heartbeat.txt";
            COMM_FILE_PATH = "MQL5\\Files\\MT5com.txt";
            SignalFilePath = "MQL5\\Files\\Synergy_Signals.txt";
            
            Print("🔄 UPDATED all file paths to use MQL5\\Files\\ directory:");
            Print("   - HEARTBEAT_FILE_PATH: ", HEARTBEAT_FILE_PATH);
            Print("   - HEDGE_HEARTBEAT_FILE_PATH: ", HEDGE_HEARTBEAT_FILE_PATH);
            Print("   - COMM_FILE_PATH: ", COMM_FILE_PATH);
            Print("   - SignalFilePath: ", SignalFilePath);
         }
         else
         {
            Print("❌ Alternative path also failed. Error: ", GetLastError(), " (", GetErrorDescription(GetLastError()), ")");
         }
      }
      
      // Test signal file creation with potentially updated path
      Print("Testing signal file creation...");
      ResetLastError();
      
      // Use appropriate flags based on which path we're using
      bool useFileCommon = (StringFind(COMM_FILE_PATH, "Common") >= 0);
      int signalHandle = useFileCommon ? 
                        FileOpen(COMM_FILE_PATH, FILE_WRITE|FILE_TXT|FILE_COMMON) :
                        FileOpen(COMM_FILE_PATH, FILE_WRITE|FILE_TXT);
      
      if(signalHandle != INVALID_HANDLE)
      {
         FileWriteString(signalHandle, "TEST_SIGNAL,INIT," + IntegerToString(TimeCurrent()));
         FileFlush(signalHandle);
         FileClose(signalHandle);
         Print("✅ Signal file test successful: ", COMM_FILE_PATH);
      }
      else
      {
         int error = GetLastError();
         Print("❌ Signal file test failed. Error: ", error, " (", GetErrorDescription(error), ")");
         
         // If we're still using Common path and it failed, try MQL5\Files fallback
         if(useFileCommon)
         {
            Print("Trying signal file with MQL5\\Files\\ fallback...");
            string altSignalPath = "MQL5\\Files\\MT5com.txt";
            ResetLastError();
            int altSignalHandle = FileOpen(altSignalPath, FILE_WRITE|FILE_TXT);
            if(altSignalHandle != INVALID_HANDLE)
            {
               FileWriteString(altSignalHandle, "TEST_SIGNAL,INIT," + IntegerToString(TimeCurrent()));
               FileFlush(altSignalHandle);
               FileClose(altSignalHandle);
               Print("✅ Alternative signal file successful: ", altSignalPath);
               COMM_FILE_PATH = altSignalPath;  // Update the path
               
               // Update SignalFilePath too for consistency
               SignalFilePath = "MQL5\\Files\\Synergy_Signals.txt";
               Print("Updated COMM_FILE_PATH and SignalFilePath to MQL5\\Files\\");
            }
            else
            {
               Print("❌ Alternative signal file also failed. Error: ", GetLastError(), " (", GetErrorDescription(GetLastError()), ")");
            }
         }
      }
   }
   else if(EnableHedgeCommunication && CommunicationMethod == GLOBAL_VARS)
   {
      Print("Using GLOBAL_VARS communication method");
   }
   else if(!EnableHedgeCommunication)
   {
      Print("Hedge communication is DISABLED");
   }
   else
   {
      Print("❌ Unknown communication configuration!");
   }
   
   // Store initial balance
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   hedgeFactor = MathMin(1.0, (ChallengeC * (1.0 + SlipBufD)) / MaxDD);
   
   // Initialize Session Filters
   if(!InitTradingSessions())
   {
      Print("Failed to initialize trading sessions");
      return(INIT_FAILED);
   }
   
   // Initialize all indicators and systems
   if(!InitSynergyIndicators())
   {
      Print("Failed to initialize Synergy Score indicators");
      return(INIT_FAILED);
   }
   
   if(!InitMarketBias())
   {
      Print("Failed to initialize Market Bias indicator");
      return(INIT_FAILED);
   }
   
   if(!InitADXFilter())
   {
      Print("Failed to initialize ADX Filter");
      return(INIT_FAILED);
   }
   
   // Set up arrays for price data
   ArraySetAsSeries(Open, true);
   ArraySetAsSeries(High, true);
   ArraySetAsSeries(Low, true);
   ArraySetAsSeries(Close, true);
   ArraySetAsSeries(TimeSeries, true);

   // Compute dynamic history requirement
   // We must ensure enough bars for the longest indicators (e.g. 200 period MA)
   int warmupSynergy  = 200;                        // slowest MA period used
   int warmupADX      = ADXPeriod + ADXLookbackPeriod; // ADX lookback requirement
   int warmupBias     = HeikinAshiPeriod + 1;          // HA bias lookback

   BARS_REQUIRED = MathMax(PivotTPBars + PivotLengthLeft + PivotLengthRight + 5, 100);
   BARS_REQUIRED = MathMax(BARS_REQUIRED, warmupSynergy);
   BARS_REQUIRED = MathMax(BARS_REQUIRED, warmupADX);
   BARS_REQUIRED = MathMax(BARS_REQUIRED, warmupBias);

   Print("History warm-up requirement set to ",BARS_REQUIRED," bars");
   WarmupIndicatorHistory();
   
   // Create dashboard 
   CreateDashboard();
   
   // Initialize scale-out tracking variables
   scaleOut1LongTriggered = false;
   scaleOut1ShortTriggered = false;
   beAppliedLong = false;
   beAppliedShort = false;
   

   // Master trigger – enable if Synergy or Bias filter active
   entryTriggersEnabled = UseSynergyScore || UseMarketBias;

   // Enable entry triggers regardless of optional filters
   entryTriggersEnabled = true;

   // Set up hedge communication if enabled
   Print("=== FINAL COMMUNICATION SETUP ===");
   if(EnableHedgeCommunication)
   {
      if(CommunicationMethod == GLOBAL_VARS)
      {
         // Initialize the global variables for the hedge EA to find
         GlobalVariableSet("PROP_HB_" + IntegerToString(Magic_Number), (double)TimeCurrent());
         GlobalVariableSet("EASignal_Connected_"+IntegerToString(HedgeEA_Magic), (double)TimeCurrent());
         Print("✅ Hedge communication enabled (Global Variables). Target EA Magic: ", HedgeEA_Magic);
         Print("Main EA registered heartbeat with Magic: ", Magic_Number);
         Print("Main EA looking for hedge with Magic: ", HedgeEA_Magic);
         
         // Add diagnostic output of all global variables
         Print("--- GLOBAL VARIABLES AT INIT ---");
         for(int i=0; i<GlobalVariablesTotal(); i++) {
            string name = GlobalVariableName(i);
            double value = GlobalVariableGet(name);
            Print(name, " = ", value);
         }
         Print("-------------------------------");
      }
      else // FILE_BASED
      {
         Print("✅ File-based communication enabled. Target EA Magic: ", HedgeEA_Magic);
         Print("File communication paths:");
         Print("- Main heartbeat: ", HEARTBEAT_FILE_PATH);
         Print("- Hedge heartbeat: ", HEDGE_HEARTBEAT_FILE_PATH);
         Print("- Signal file: ", COMM_FILE_PATH);
         Print("- Additional signals: ", SignalFilePath);
         Print("Communication ready with proper file handle management and synchronized paths");
      }
   }
   else
   {
      Print("❌ Hedge communication is DISABLED");
   }

   // Start heartbeat system
   EventSetTimer(HEARTBEAT_SEC);
   SendHeartbeat(true);
   linkWasOK = IsLinkAlive(true);

   // Print initial settings for verification
   Print("=== SETTINGS VERIFICATION ===");
   Print("UseFixedLot = ", UseFixedLot ? "TRUE" : "FALSE");
   Print("FixedLotSize = ", FixedLotSize);
   Print("RiskPercent = ", RiskPercent);
   Print("MinLot = ", MinLot);
   Print("Magic_Number = ", Magic_Number);
   Print("HedgeEA_Magic = ", HedgeEA_Magic);
   Print("EnableHedgeCommunication = ", EnableHedgeCommunication ? "TRUE" : "FALSE");
   Print("CommunicationMethod = ", CommunicationMethod == GLOBAL_VARS ? "GLOBAL_VARS" : "FILE_BASED");
   Print("Synergy Strategy v1.04 initialised. Hedge factor:",DoubleToString(hedgeFactor,4));
   Print("=== INITIALIZATION COMPLETED ===");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function (hardened v1.02)                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // === DEBUGGING SECTION START ===
   static int debugCounter = 0;
   static datetime lastDebugTime = 0;
   debugCounter++;
   
   // Print basic status every 50 ticks or every 30 seconds
   if(debugCounter % 50 == 0 || TimeCurrent() - lastDebugTime > 30) {
      Print("=== BASIC STATUS CHECK #", debugCounter, " ===");
      Print("Time: ", TimeToString(TimeCurrent()));
      Print("EnableTrading: ", EnableTrading);
      Print("IsMarketOpen: ", IsMarketOpen());
      Print("Bars Available: ", Bars(_Symbol,PERIOD_CURRENT), " / Required: ", BARS_REQUIRED);
      Print("Has Open Position: ", HasOpenPosition());
      // Add debugging to see actual score values
      Print("DEBUG: Synergy Score calculated: ", DoubleToString(synergyScore, 3));
      lastDebugTime = TimeCurrent();
   }
   
   // Step 0 - global guards with detailed logging
   if(!EnableTrading) {
      if(debugCounter % 100 == 0) Print("DEBUG: Trading disabled");
      return;
   }
   if(!IsMarketOpen()) {
      if(debugCounter % 100 == 0) Print("DEBUG: Market closed");
      return;
   }
   if(Bars(_Symbol,PERIOD_CURRENT)<BARS_REQUIRED) {
      if(debugCounter % 100 == 0) Print("DEBUG: Insufficient bars - Available: ", Bars(_Symbol,PERIOD_CURRENT), " Required: ", BARS_REQUIRED);
      return;
   }

   // Step 1 - update dashboard & visuals every tick
   UpdateDashboard();
   if(ShowMarketBias)  ShowMarketBiasIndicator();

   // Step 2 - CHECK FOR NEW BAR - CRITICAL FOR BAR CLOSE TRADING
   if(!IsNewBar()) return;
   
   // Step 3 - WAIT FOR BAR CONFIRMATION - ONLY TRADE ON BAR CLOSE
   if(!IsConfirmedBar())
   {
      static datetime lastBarWait = 0;
      if(TimeCurrent() - lastBarWait > 30)
      {
         Print("DEBUG: Waiting for bar close confirmation...");
         lastBarWait = TimeCurrent();
      }
      return;
   }

   Print("====================================================");
   Print("=== BAR CLOSE ANALYSIS - ", TimeToString(TimeCurrent()), " ===");
   Print("====================================================");
   
   // Step 4 - pull fresh history with detailed logging
   int needBars = MathMax(PivotTPBars + PivotLengthLeft + PivotLengthRight + 5 , 100);
   Print("DEBUG: Need ", needBars, " bars for analysis");
   
   if(CopyClose(_Symbol,PERIOD_CURRENT,0,needBars,Close) < needBars) {
      Print("ERROR: Failed to copy Close prices - got ", ArraySize(Close), " need ", needBars);
      return;
   }
   if(CopyOpen(_Symbol,PERIOD_CURRENT,0,needBars,Open) < needBars) {
      Print("ERROR: Failed to copy Open prices");
      return;
   }
   if(CopyHigh(_Symbol,PERIOD_CURRENT,0,needBars,High) < needBars) {
      Print("ERROR: Failed to copy High prices");
      return;
   }
   if(CopyLow(_Symbol,PERIOD_CURRENT,0,needBars,Low) < needBars) {
      Print("ERROR: Failed to copy Low prices");
      return;
   }
   if(CopyTime(_Symbol,PERIOD_CURRENT,0,needBars,TimeSeries) < needBars) {
      Print("ERROR: Failed to copy Time series");
      return;
   }
   Print("DEBUG: Successfully copied price data - Arrays size: ", ArraySize(Close));

   // Step 5 - session filter with logging
   bool inSession = IsInTradingSession();
   Print("DEBUG: Trading Session Check: ", inSession ? "IN SESSION" : "OUT OF SESSION");
   if(!inSession) {
      Print("DEBUG: Outside trading session - exiting");
      return;
   }

   // Step 6 - refresh indicators ONLY ON BAR CLOSE
   Print("--- INDICATOR CALCULATIONS (BAR CLOSE) ---");
   double oldSynergyScore = synergyScore;
   bool oldBiasPositive = currentBiasPositive;
   bool oldBiasChangedToBullish = biasChangedToBullish;
   bool oldBiasChangedToBearish = biasChangedToBearish;
   bool oldAdxCondition = adxTrendCondition;
   
   CalculateSynergyScore();
   CalculateMarketBias();
   CalculateADXFilter();
   
   Print("SYNERGY SCORE: ", DoubleToString(synergyScore, 3), " (was: ", DoubleToString(oldSynergyScore, 3), ") - Enabled: ", UseSynergyScore);
   Print("MARKET BIAS: Current=", currentBiasPositive ? "BULLISH" : "BEARISH", " (was: ", oldBiasPositive ? "BULLISH" : "BEARISH", ") - Enabled: ", UseMarketBias);
   Print("BIAS CHANGES: ToBullish=", biasChangedToBullish, " (was: ", oldBiasChangedToBullish, "), ToBearish=", biasChangedToBearish, " (was: ", oldBiasChangedToBearish, ")");
   Print("ADX TREND: ", adxTrendCondition ? "TRUE" : "FALSE", " (was: ", oldAdxCondition ? "TRUE" : "FALSE", ") - Enabled: ", EnableADXFilter);
   if(EnableADXFilter) Print("ADX Threshold: ", DoubleToString(effectiveADXThreshold, 2));

   // Step 7 - derive swing-pivots with detailed logging and selection criteria
   Print("--- PIVOT CALCULATION ---");
   Print("Pivot Selection Criteria:");
   Print("  LONG SL  = DEEPEST pivot low BELOW current price (within ", PivotTPBars, " bars)");
   Print("  LONG TP  = HIGHEST pivot high ABOVE current price (within ", PivotTPBars, " bars)");
   Print("  SHORT SL = HIGHEST pivot high ABOVE current price (within ", PivotTPBars, " bars)");
   Print("  SHORT TP = DEEPEST pivot low BELOW current price (within ", PivotTPBars, " bars)");
   
   double slLong  = FindDeepestPivotLowBelowClose(PivotTPBars);   // Deepest (lowest) pivot low below price
   double tpLong  = FindHighestPivotHighAboveClose(PivotTPBars);  // Highest pivot high above price
   double slShort = FindHighestPivotHighAboveClose(PivotTPBars);  // Highest pivot high above price  
   double tpShort = FindDeepestPivotLowBelowClose(PivotTPBars);   // Deepest (lowest) pivot low below price

   Print("Current Price: ", DoubleToString(Close[0], 5));
   Print("SELECTED PIVOTS:");
   Print("  LONG  - SL: ", DoubleToString(slLong, 5), " (DEEPEST low below, valid: ", (slLong > 0 && slLong < Close[0]) ? "YES" : "NO", ")");
   Print("  LONG  - TP: ", DoubleToString(tpLong, 5), " (HIGHEST high above, valid: ", (tpLong > 0 && tpLong > Close[0]) ? "YES" : "NO", ")");
   Print("  SHORT - SL: ", DoubleToString(slShort, 5), " (HIGHEST high above, valid: ", (slShort > 0 && slShort > Close[0]) ? "YES" : "NO", ")");
   Print("  SHORT - TP: ", DoubleToString(tpShort, 5), " (DEEPEST low below, valid: ", (tpShort > 0 && tpShort < Close[0]) ? "YES" : "NO", ")");

   // NO FALLBACK - Strategy requires valid pivot points only
   bool hasValidLongPivots = (slLong > 0 && slLong < Close[0] && tpLong > 0 && tpLong > Close[0]);
   bool hasValidShortPivots = (slShort > 0 && slShort > Close[0] && tpShort > 0 && tpShort < Close[0]);
   
   // CORRECTED: Debug Synergy Score details
if(UseSynergyScore) {
   double oldScore = synergyScore;
   CalculateSynergyScore();  // Force calculation to see debug output
   Print("=== SYNERGY SCORE DETAILS ===");
   Print("Synergy Score: ", DoubleToString(synergyScore, 3), " (previous: ", DoubleToString(oldScore, 3), ")");
   Print("M5 enabled: ", UseTF5min ? "true" : "false", ", weight: ", DoubleToString(Weight_M5, 2));
   Print("M15 enabled: ", UseTF15min ? "true" : "false", ", weight: ", DoubleToString(Weight_M15, 2));  
   Print("H1 enabled: ", UseTF1hour ? "true" : "false", ", weight: ", DoubleToString(Weight_H1, 2));
   Print("RSI weight: ", DoubleToString(RSI_Weight, 2));
   Print("Trend weight: ", DoubleToString(Trend_Weight, 2));
   Print("MACDV Slope weight: ", DoubleToString(MACDV_Slope_Weight, 2));
   
   // If score is still zero, check what's happening with each component
   if(synergyScore == 0) {
      if(UseTF5min && rsiHandle_M5 != INVALID_HANDLE) {
         // Correct way to check RSI values directly:
         double rsiData[];
         ArraySetAsSeries(rsiData, true);
         // Inspect previous closed bar value
         int copied = CopyBuffer(rsiHandle_M5, 0, 1, 1, rsiData);
         if(copied == 1) {
            Print("Direct RSI M5 check - Current value: ", DoubleToString(rsiData[0], 2));
         } else {
            Print("Failed to get direct RSI value. Copied: ", copied);
         }
      }
   }
}
   
   if(!hasValidLongPivots && !hasValidShortPivots)
   {
      Print("DEBUG: No valid pivot combinations found - NO TRADE (Strategy requires strict pivot SL/TP)");
   }
   else if(!hasValidLongPivots)
   {
      Print("DEBUG: No valid LONG pivot combination (SL:", DoubleToString(slLong,5), " TP:", DoubleToString(tpLong,5), ")");
   }
   else if(!hasValidShortPivots)
   {
      Print("DEBUG: No valid SHORT pivot combination (SL:", DoubleToString(slShort,5), " TP:", DoubleToString(tpShort,5), ")");
   }

   // Draw pivot lines on chart
   
   {
   if(!ShowPivotLines) return;

   // Remove previously drawn lines
   ObjectsDeleteAll(0, "PivotDetected_");

   double currentPrice = Close[0];

   // ── Long SL (deepest pivot low below price) ──
   if(pivotStopLongEntry > 0 && pivotStopLongEntry < currentPrice)
   {
      ObjectCreate      (0, "PivotDetected_LongSL",  OBJ_HLINE, 0, 0, pivotStopLongEntry);
      ObjectSetInteger  (0, "PivotDetected_LongSL",  OBJPROP_COLOR,  clrGreen);
      ObjectSetInteger  (0, "PivotDetected_LongSL",  OBJPROP_STYLE,  STYLE_DOT);
      ObjectSetInteger  (0, "PivotDetected_LongSL",  OBJPROP_WIDTH,  2);
      ObjectSetString   (0, "PivotDetected_LongSL",  OBJPROP_TEXT,
                         "Long SL: " + DoubleToString(pivotStopLongEntry, 5));
   }

   // ── Long TP (highest pivot high above price) ──
   if(pivotTpLongEntry > 0 && pivotTpLongEntry > currentPrice)
   {
      ObjectCreate     (0, "PivotDetected_LongTP",  OBJ_HLINE, 0, 0, pivotTpLongEntry);
      ObjectSetInteger (0, "PivotDetected_LongTP",  OBJPROP_COLOR,  clrLime);
      ObjectSetInteger (0, "PivotDetected_LongTP",  OBJPROP_STYLE,  STYLE_DOT);
      ObjectSetInteger (0, "PivotDetected_LongTP",  OBJPROP_WIDTH,  2);
      ObjectSetString  (0, "PivotDetected_LongTP",  OBJPROP_TEXT,
                        "Long TP: " + DoubleToString(pivotTpLongEntry, 5));
   }

   // ── Short SL (highest pivot high above price) ──
   if(pivotStopShortEntry > 0 && pivotStopShortEntry > currentPrice)
   {
      ObjectCreate     (0, "PivotDetected_ShortSL",  OBJ_HLINE, 0, 0, pivotStopShortEntry);
      ObjectSetInteger (0, "PivotDetected_ShortSL",  OBJPROP_COLOR,  clrRed);
      ObjectSetInteger (0, "PivotDetected_ShortSL",  OBJPROP_STYLE,  STYLE_DOT);
      ObjectSetInteger (0, "PivotDetected_ShortSL",  OBJPROP_WIDTH,  2);
      ObjectSetString  (0, "PivotDetected_ShortSL",  OBJPROP_TEXT,
                        "Short SL: " + DoubleToString(pivotStopShortEntry, 5));
   }

   // ── Short TP (deepest pivot low below price) ──
   if(pivotTpShortEntry > 0 && pivotTpShortEntry < currentPrice)
   {
      ObjectCreate     (0, "PivotDetected_ShortTP",  OBJ_HLINE, 0, 0, pivotTpShortEntry);
      ObjectSetInteger (0, "PivotDetected_ShortTP",  OBJPROP_COLOR,  clrMaroon);
      ObjectSetInteger (0, "PivotDetected_ShortTP",  OBJPROP_STYLE,  STYLE_DOT);
      ObjectSetInteger (0, "PivotDetected_ShortTP",  OBJPROP_WIDTH,  2);
      ObjectSetString  (0, "PivotDetected_ShortTP",  OBJPROP_TEXT,
                        "Short TP: " + DoubleToString(pivotTpShortEntry, 5));
   }
}

   if(slLong  >0) pivotStopLongEntry  = slLong;
   if(tpLong  >0) pivotTpLongEntry    = tpLong;
   if(slShort >0) pivotStopShortEntry = slShort;
   if(tpShort >0) pivotTpShortEntry   = tpShort;

   // Step 8 - build entry conditions with detailed breakdown
   Print("--- ENTRY CONDITIONS ANALYSIS ---");
   
   // Common conditions
   bool confirmedBar = true; // We already checked this above
   bool hasPosition = HasOpenPosition();
   bool inSessionCheck2 = IsInTradingSession(); // Double check
   
   Print("COMMON CONDITIONS:");
   Print("  ✓ Bar Close Confirmed: TRUE");
   Print("  ✓ Entry Triggers Enabled: ", entryTriggersEnabled ? "TRUE" : "FALSE");
   Print("  ✓ ADX Trend Condition: ", adxTrendCondition ? "TRUE" : "FALSE");
   Print("  ✓ In Trading Session: ", inSessionCheck2 ? "TRUE" : "FALSE");
   Print("  ✓ No Open Position: ", !hasPosition ? "TRUE" : "FALSE");
   
   // Long conditions breakdown
   bool longSynergyOK = UseSynergyScore ? synergyScore>0 : true;
   bool longBiasOK = UseMarketBias ? biasChangedToBullish : true; // Keep original logic as requested
   bool longPivotSLOK = slLong > 0 && slLong < Close[0];
   bool longPivotTPOK = tpLong > 0 && tpLong > Close[0];
   
   Print("LONG CONDITIONS:");
   Print("  ✓ Synergy OK: ", longSynergyOK ? "TRUE" : "FALSE", " (Score: ", DoubleToString(synergyScore, 3), ", Required: >0, Enabled: ", UseSynergyScore, ")");
   Print("  ✓ Bias OK: ", longBiasOK ? "TRUE" : "FALSE", " (ChangedToBullish: ", biasChangedToBullish, ", Enabled: ", UseMarketBias, ")");
   Print("  ✓ Pivot SL OK: ", longPivotSLOK ? "TRUE" : "FALSE", " (", DoubleToString(slLong, 5), " < ", DoubleToString(Close[0], 5), ")");
   Print("  ✓ Pivot TP OK: ", longPivotTPOK ? "TRUE" : "FALSE", " (", DoubleToString(tpLong, 5), " > ", DoubleToString(Close[0], 5), ")");

   bool longCond = confirmedBar && entryTriggersEnabled && adxTrendCondition && 
                   longSynergyOK && longBiasOK && longPivotSLOK && longPivotTPOK && 
                   inSessionCheck2 && !hasPosition;
   
   // Short conditions breakdown
   bool shortSynergyOK = UseSynergyScore ? synergyScore<0 : true;
   bool shortBiasOK = UseMarketBias ? biasChangedToBearish : true; // Keep original logic as requested
   bool shortPivotSLOK = slShort > 0 && slShort > Close[0];
   bool shortPivotTPOK = tpShort > 0 && tpShort < Close[0];
   
   Print("SHORT CONDITIONS:");
   Print("  ✓ Synergy OK: ", shortSynergyOK ? "TRUE" : "FALSE", " (Score: ", DoubleToString(synergyScore, 3), ", Required: <0, Enabled: ", UseSynergyScore, ")");
   Print("  ✓ Bias OK: ", shortBiasOK ? "TRUE" : "FALSE", " (ChangedToBearish: ", biasChangedToBearish, ", Enabled: ", UseMarketBias, ")");
   Print("  ✓ Pivot SL OK: ", shortPivotSLOK ? "TRUE" : "FALSE", " (", DoubleToString(slShort, 5), " > ", DoubleToString(Close[0], 5), ")");
   Print("  ✓ Pivot TP OK: ", shortPivotTPOK ? "TRUE" : "FALSE", " (", DoubleToString(tpShort, 5), " < ", DoubleToString(Close[0], 5), ")");

   bool shortCond = confirmedBar && entryTriggersEnabled && adxTrendCondition && 
                    shortSynergyOK && shortBiasOK && shortPivotSLOK && shortPivotTPOK && 
                    inSessionCheck2 && !hasPosition;

   Print("--- FINAL RESULTS ---");
   Print("LONG CONDITION RESULT: ", longCond ? "✓ TRUE - TRADE SIGNAL!" : "✗ FALSE");
   Print("SHORT CONDITION RESULT: ", shortCond ? "✓ TRUE - TRADE SIGNAL!" : "✗ FALSE");
   Print("DEBUG: Trade conditions - confirmedBar:", confirmedBar,
      " entryTriggersEnabled:", entryTriggersEnabled, 
      " adxTrendCondition:", adxTrendCondition,
      " longSynergyOK:", longSynergyOK, " (score:", DoubleToString(synergyScore, 2), ")",
      " longPivotSLOK:", longPivotSLOK, " longPivotTPOK:", longPivotTPOK,
      " inSession:", inSessionCheck2, " noPosition:", !hasPosition);
   
   if(!longCond && !shortCond) {
      Print("❌ NO TRADE SIGNALS - Check failed conditions above");
      
      // Identify the most likely blockers
      if(!entryTriggersEnabled) Print("🚫 BLOCKER: Entry triggers disabled");
      if(!adxTrendCondition && EnableADXFilter) Print("🚫 BLOCKER: ADX condition failed");
      if(hasPosition) Print("🚫 BLOCKER: Position already open");
      if(!inSessionCheck2) Print("🚫 BLOCKER: Outside trading session");
      if(UseMarketBias && !biasChangedToBullish && !biasChangedToBearish) Print("🚫 BLOCKER: Market bias not changing (waiting for bias shift)");
      if(!hasValidLongPivots && !hasValidShortPivots) Print("🚫 BLOCKER: No valid pivot SL/TP combinations found (strict pivot strategy)");
   }

   // Step 9 - execute with enhanced logging - ONLY ON BAR CLOSE
   if(longCond && !HasOpenPosition()) {
      Print("🚀 EXECUTING LONG TRADE ON BAR CLOSE!");
      Print("   Entry Price: ~", DoubleToString(Close[0], 5));
      Print("   Stop Loss: ", DoubleToString(slLong, 5));
      Print("   Take Profit: ", DoubleToString(tpLong, 5));
      Print("   Using Fallback Levels: NO - Strict pivot strategy");
      OpenTrade(true, slLong, tpLong);
   }
   if(shortCond && !HasOpenPosition()) {
      Print("🚀 EXECUTING SHORT TRADE ON BAR CLOSE!");
      Print("   Entry Price: ~", DoubleToString(Close[0], 5));
      Print("   Stop Loss: ", DoubleToString(slShort, 5));
      Print("   Take Profit: ", DoubleToString(tpShort, 5));
      Print("   Using Fallback Levels: NO - Strict pivot strategy");
      OpenTrade(false, slShort, tpShort);
      Print("DEBUG: Pivot points - Long SL:", DoubleToString(slLong, 5), 
      " Long TP:", DoubleToString(tpLong, 5),
      " Short SL:", DoubleToString(slShort, 5),
      " Short TP:", DoubleToString(tpShort, 5));
   }

   // Redraw pivot visuals with latest levels
   if(ShowPivotLines)
      DrawPivotLines();

}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicators
   ReleaseSynergyIndicators();
   ReleaseMarketBias();
   ReleaseADXFilter();
   
   // Delete dashboard and other objects
   DeleteDashboard();
   EventKillTimer();
   
   // Clean up visual elements
   if(ShowPivotLines) ObjectsDeleteAll(0, "PivotLine_");
   if(ShowMarketBias) ObjectsDeleteAll(0, "MarketBias_");
   
   // Clean up communication global variables
   if(EnableHedgeCommunication && CommunicationMethod == GLOBAL_VARS)
   {
      GlobalVariableDel("EASignal_Connected_"+IntegerToString(HedgeEA_Magic));
      GlobalVariableDel("EASignal_Type_"+IntegerToString(HedgeEA_Magic));
      GlobalVariableDel("EASignal_Direction_"+IntegerToString(HedgeEA_Magic));
      GlobalVariableDel("EASignal_Volume_"+IntegerToString(HedgeEA_Magic));
      GlobalVariableDel("EASignal_SL_"+IntegerToString(HedgeEA_Magic));
      GlobalVariableDel("EASignal_TP_"+IntegerToString(HedgeEA_Magic));
      GlobalVariableDel("EASignal_Time_"+IntegerToString(HedgeEA_Magic));
   }
   
   Print("Synergy Strategy stopped. Reason: ", GetUninitReasonText(reason));
}

//+------------------------------------------------------------------+
//| Trade transaction handler - reacts to manual trades               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &request,
                        const MqlTradeResult     &result)
{
   if(!EnableHedgeCommunication)              return;
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol!=_Symbol)                  return;

   // Pull deal info from history for reliability
   if(!HistoryDealSelect(trans.deal))
      return; // no info available

   long          magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   // Ignore EA managed positions
   if(magic==Magic_Number) return;

   if(entry==DEAL_ENTRY_IN)
   {
      bool isLong = (trans.deal_type==DEAL_TYPE_BUY);

      lastEntryLots  = trans.volume;
      hedgeLotsLast  = NormalizeLots(lastEntryLots*hedgeFactor);

      SendHedgeSignal("OPEN", isLong?"SELL":"BUY", hedgeLotsLast,
                      trans.price_tp, trans.price_sl);
   }
   else if(entry==DEAL_ENTRY_OUT)
   {
      bool closingLong  = (trans.deal_type==DEAL_TYPE_SELL);
      double vol        = NormalizeLots(trans.volume*hedgeFactor);

      SendHedgeSignal("PARTIAL_CLOSE", closingLong?"SELL":"BUY", vol, 0, 0);
   }
}

//+------------------------------------------------------------------+
//| Pulse & link-status checker                                      |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Step 1 - send our heartbeat every HEARTBEAT_SEC
   SendHeartbeat(true);   // hedge EA uses false

   // Step 2 - evaluate link
   bool ok = IsLinkAlive(true);
   if(ok != linkWasOK)              // state changed → print once
   {
      Print("Hedge link is now ", ok ? "OK ✅" : "NOT OK ❌");
      
      // When link fails, print global variables for diagnostic
      if(!ok) {
         Print("--- GLOBAL VARIABLES WHEN LINK FAILED ---");
         for(int i=0; i<GlobalVariablesTotal(); i++) {
            string name = GlobalVariableName(i);
            double value = GlobalVariableGet(name);
            Print(name, " = ", value);
         }
         Print("-------------------------------");
      }
      
      linkWasOK = ok;
   }
}


//+------------------------------------------------------------------+
//| Draw Pivot Lines on Chart                                        |
//+------------------------------------------------------------------+
void DrawPivotLines()
{
   // Delete existing zig-zag segments first
   ObjectsDeleteAll(0, "PivotLine_");

   if(!ShowPivotLines) return;

   // Build arrays of pivot points within the lookback window
   double pivotPrices[];
   datetime pivotTimes[];

   int total = ArraySize(Low);
   if(total==0) return;

   int maxLook = MathMin(PivotTPBars, total-PivotLengthRight-1);

   for(int i=maxLook; i>=PivotLengthRight; i--)
   {
      bool isLow=true;
      for(int l=1;l<=PivotLengthLeft && isLow;l++)
         if(i+l<total && Low[i+l]<=Low[i]) isLow=false;
      for(int r=1;r<=PivotLengthRight && isLow;r++)
         if(i-r>=0 && Low[i-r]<=Low[i]) isLow=false;
      if(isLow)
      {
         int sz=ArraySize(pivotPrices);
         ArrayResize(pivotPrices,sz+1);
         ArrayResize(pivotTimes ,sz+1);
         pivotPrices[sz]=Low[i];
         pivotTimes[sz]=TimeSeries[i];
      }

      bool isHigh=true;
      for(int l=1;l<=PivotLengthLeft && isHigh;l++)
         if(i+l<total && High[i+l]>=High[i]) isHigh=false;
      for(int r=1;r<=PivotLengthRight && isHigh;r++)
         if(i-r>=0 && High[i-r]>=High[i]) isHigh=false;
      if(isHigh)
      {
         int sz=ArraySize(pivotPrices);
         ArrayResize(pivotPrices,sz+1);
         ArrayResize(pivotTimes ,sz+1);
         pivotPrices[sz]=High[i];
         pivotTimes[sz]=TimeSeries[i];
      }
   }

   // Draw zig-zag by connecting consecutive pivot points
   for(int i=1;i<ArraySize(pivotPrices);i++)
   {
      string name="PivotLine_"+IntegerToString(i);
      ObjectCreate(0,name,OBJ_TREND,0,
                   pivotTimes[i-1],pivotPrices[i-1],
                   pivotTimes[i],pivotPrices[i]);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrOrange);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   }
}

//+------------------------------------------------------------------+
//| Show Market Bias Indicator                                       |
//+------------------------------------------------------------------+
void ShowMarketBiasIndicator()
{
   // Delete existing indicator first
   ObjectsDeleteAll(0, "MarketBias_");
   
   if(!ShowMarketBias) return;
   
   // Create market bias indicator
   string name = "MarketBias_Indicator";
   
   // Create the dot
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 80);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 20);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 20);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, currentBiasPositive ? BullishColor : BearishColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   
   // Add label
   ObjectCreate(0, name+"_Label", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name+"_Label", OBJPROP_XDISTANCE, 40);
   ObjectSetInteger(0, name+"_Label", OBJPROP_YDISTANCE, 85);
   ObjectSetString(0, name+"_Label", OBJPROP_TEXT, "Bias");
   ObjectSetInteger(0, name+"_Label", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name+"_Label", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
}

//+------------------------------------------------------------------+
//| Session Management Functions                                      |
//+------------------------------------------------------------------+
bool InitTradingSessions()
{
   if(!EnableSessionFilter)
   {
      inSession = true;
      return true;
   }
   
   // Nothing special to initialize for sessions, just return success
   return true;
}

//+------------------------------------------------------------------+
//| Check if we're in trading session                                |
//+------------------------------------------------------------------+
bool IsInTradingSession()
{
   if(!EnableSessionFilter) return true;
   
   // Get current time
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   string currentSession1 = "";
   string currentSession2 = "";
   
   // Determine which day's sessions to check
   switch(dt.day_of_week)
   {
      case 0: // Sunday
         currentSession1 = SundaySession1;
         currentSession2 = SundaySession2;
         break;
      case 1: // Monday
         currentSession1 = MondaySession1;
         currentSession2 = MondaySession2;
         break;
      case 2: // Tuesday
         currentSession1 = TuesdaySession1;
         currentSession2 = TuesdaySession2;
         break;
      case 3: // Wednesday
         currentSession1 = WednesdaySession1;
         currentSession2 = WednesdaySession2;
         break;
      case 4: // Thursday
         currentSession1 = ThursdaySession1;
         currentSession2 = ThursdaySession2;
         break;
      case 5: // Friday
         currentSession1 = FridaySession1;
         currentSession2 = FridaySession2;
         break;
      case 6: // Saturday
         currentSession1 = SaturdaySession1;
         currentSession2 = SaturdaySession2;
         break;
      default:
         return false; // Should never reach here
   }
   
   // Check if current time is within session times
   bool inSession1 = IsTimeInSession(serverTime, currentSession1);
   bool inSession2 = currentSession2 != "" ? IsTimeInSession(serverTime, currentSession2) : false;
   
   return inSession1 || inSession2;
}

//+------------------------------------------------------------------+
//| Check if time is within a session                                |
//+------------------------------------------------------------------+
bool IsTimeInSession(datetime serverTime, string sessionTime)
{
   if(sessionTime == "") return false;
   
   // Parse session start and end times
   string parts[];
   StringSplit(sessionTime, '-', parts);
   
   if(ArraySize(parts) != 2) return false;
   
   int startHour = (int)StringSubstr(parts[0], 0, 2);
   int startMin = (int)StringSubstr(parts[0], 2, 2);
   int endHour = (int)StringSubstr(parts[1], 0, 2);
   int endMin = (int)StringSubstr(parts[1], 2, 2);
   
   // Get current hours and minutes
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   int currentHour = dt.hour;
   int currentMin = dt.min;
   
   // Convert to minutes for easy comparison
   int startMinutes = startHour * 60 + startMin;
   int endMinutes = endHour * 60 + endMin;
   int currentMinutes = currentHour * 60 + currentMin;
   
   // Check if current time is in session
   if(startMinutes <= endMinutes)
   {
      // Normal session (e.g., 0900-1700)
      return (currentMinutes >= startMinutes && currentMinutes <= endMinutes);
   }
   else
   {
      // Overnight session (e.g., 2200-0600)
      return (currentMinutes >= startMinutes || currentMinutes <= endMinutes);
   }
}


//────────────────────────────────────────────────────────────────────
// 4.  PIVOT‑SCAN FUNCTIONS  (fully replaced)                       
//────────────────────────────────────────────────────────────────────

double FindDeepestPivotLowBelowClose(int lookbackBars)
{
   int total = ArraySize(Low);
   if(total==0) return 0;
   int maxLook = MathMin(lookbackBars, total-PivotLengthRight-1);
   double deepest = 0;
   for(int i=PivotLengthRight; i<=maxLook; i++)
   {
      double cand = Low[i]; bool isPivot=true;
      for(int l=1; l<=PivotLengthLeft && isPivot; l++)
         if(i+l<total && Low[i+l] < cand) isPivot=false;
      for(int r=1; r<=PivotLengthRight && isPivot; r++)
         if(i-r>=0   && Low[i-r] < cand) isPivot=false;
      if(isPivot && cand<Close[0] && (deepest==0||cand<deepest)) deepest=cand;
   }
   return deepest;
}

double FindHighestPivotHighAboveClose(int lookbackBars)
{
   int total = ArraySize(High);
   if(total==0) return 0;
   int maxLook = MathMin(lookbackBars, total-PivotLengthRight-1);
   double highest = 0;
   for(int i=PivotLengthRight; i<=maxLook; i++)
   {
      double cand = High[i]; bool isPivot=true;
      for(int l=1; l<=PivotLengthLeft && isPivot; l++)
         if(i+l<total && High[i+l] > cand) isPivot=false;
      for(int r=1; r<=PivotLengthRight && isPivot; r++)
         if(i-r>=0   && High[i-r] > cand) isPivot=false;
      if(isPivot && cand>Close[0] && (highest==0||cand>highest)) highest=cand;
   }
   return highest;
}

//+------------------------------------------------------------------+
//| Initialize Synergy Score indicators                              |
//+------------------------------------------------------------------+
bool InitSynergyIndicators()
{
   // 5 Minute Timeframe
   if(UseTF5min)
   {
      rsiHandle_M5 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
      maFastHandle_M5 = iMA(_Symbol, PERIOD_M5, 10, 0, MODE_EMA, PRICE_CLOSE);
      maSlowHandle_M5 = iMA(_Symbol, PERIOD_M5, 100, 0, MODE_EMA, PRICE_CLOSE);
      macdHandle_M5 = iMACD(_Symbol, PERIOD_M5, 12, 26, 9, PRICE_CLOSE);
      
      if(rsiHandle_M5 == INVALID_HANDLE || maFastHandle_M5 == INVALID_HANDLE || 
         maSlowHandle_M5 == INVALID_HANDLE || macdHandle_M5 == INVALID_HANDLE)
      {
         Print("Error initializing 5 minute indicators: ", GetLastError());
         return false;
      }
   }
   
   // 15 Minute Timeframe
   if(UseTF15min)
   {
      rsiHandle_M15 = iRSI(_Symbol, PERIOD_M15, 14, PRICE_CLOSE);
      maFastHandle_M15 = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
      maSlowHandle_M15 = iMA(_Symbol, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE);
      macdHandle_M15 = iMACD(_Symbol, PERIOD_M15, 12, 26, 9, PRICE_CLOSE);
      
      if(rsiHandle_M15 == INVALID_HANDLE || maFastHandle_M15 == INVALID_HANDLE || 
         maSlowHandle_M15 == INVALID_HANDLE || macdHandle_M15 == INVALID_HANDLE)
      {
         Print("Error initializing 15 minute indicators: ", GetLastError());
         return false;
      }
   }
   
   // 1 Hour Timeframe
   if(UseTF1hour)
   {
      rsiHandle_H1 = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
      maFastHandle_H1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
      maSlowHandle_H1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
      macdHandle_H1 = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
      
      if(rsiHandle_H1 == INVALID_HANDLE || maFastHandle_H1 == INVALID_HANDLE || 
         maSlowHandle_H1 == INVALID_HANDLE || macdHandle_H1 == INVALID_HANDLE)
      {
         Print("Error initializing 1 hour indicators: ", GetLastError());
         return false;
      }
   }
   
   // Allocate arrays
   ArraySetAsSeries(rsiBuffer_M5, true);
   ArraySetAsSeries(maFastBuffer_M5, true);
   ArraySetAsSeries(maSlowBuffer_M5, true);
   ArraySetAsSeries(macdBuffer_M5, true);
   ArraySetAsSeries(macdPrevBuffer_M5, true);
   
   ArraySetAsSeries(rsiBuffer_M15, true);
   ArraySetAsSeries(maFastBuffer_M15, true);
   ArraySetAsSeries(maSlowBuffer_M15, true);
   ArraySetAsSeries(macdBuffer_M15, true);
   ArraySetAsSeries(macdPrevBuffer_M15, true);
   
   ArraySetAsSeries(rsiBuffer_H1, true);
   ArraySetAsSeries(maFastBuffer_H1, true);
   ArraySetAsSeries(maSlowBuffer_H1, true);
   ArraySetAsSeries(macdBuffer_H1, true);
   ArraySetAsSeries(macdPrevBuffer_H1, true);
   
   return true;
}

//--------------------------------------------------------------------
// 5.  SYNERGY SCORE  (identical maths, wrapped with CopyOk)         
//--------------------------------------------------------------------
//+------------------------------------------------------------------+
//| Calculate the multi-time-frame “Synergy” score                   |
//+------------------------------------------------------------------+
double CalculateSynergyScore()
{
   if(!UseSynergyScore)
      return 0.0;

   double score   = 0.0;
   bool   hasData = false;           // at least one TF must contribute

   // -------- M5 --------
   if(UseTF5min)
   {
      int g1 = CopyBuffer(rsiHandle_M5 ,0,0,2,rsiBuffer_M5 );
      int g2 = CopyBuffer(maFastHandle_M5,0,0,2,maFastBuffer_M5);
      int g3 = CopyBuffer(maSlowHandle_M5,0,0,2,maSlowBuffer_M5);
      int g4 = CopyBuffer(macdHandle_M5 ,0,0,2,macdBuffer_M5 );
      int g5 = CopyBuffer(macdHandle_M5 ,0,1,2,macdPrevBuffer_M5);
      if(CopyOk(2,g1) && CopyOk(2,g2) && CopyOk(2,g3) && CopyOk(2,g4) && CopyOk(2,g5))
      {
         // Use previous closed bar (index 1) to match TradingView logic
         score += SynergyAdd(rsiBuffer_M5[1]  > 50, rsiBuffer_M5[1]  < 50,
                             RSI_Weight,        Weight_M5);
         score += SynergyAdd(maFastBuffer_M5[1] > maSlowBuffer_M5[1],
                             maFastBuffer_M5[1] < maSlowBuffer_M5[1],
                             Trend_Weight,      Weight_M5);
         score += SynergyAdd(macdBuffer_M5[1]  > macdPrevBuffer_M5[1],
                             macdBuffer_M5[1]  < macdPrevBuffer_M5[1],
                             MACDV_Slope_Weight,Weight_M5);
         hasData = true;
      }
      else
      {
         Print("DEBUG: M5 data missing - rsi:",g1," fast:",g2," slow:",g3,
               " macd:",g4," prev:",g5);
      }
   }

   // -------- M15 --------
   if(UseTF15min)
   {
      int h1 = CopyBuffer(rsiHandle_M15 ,0,0,2,rsiBuffer_M15 );
      int h2 = CopyBuffer(maFastHandle_M15,0,0,2,maFastBuffer_M15);
      int h3 = CopyBuffer(maSlowHandle_M15,0,0,2,maSlowBuffer_M15);
      int h4 = CopyBuffer(macdHandle_M15 ,0,0,2,macdBuffer_M15 );
      int h5 = CopyBuffer(macdHandle_M15 ,0,1,2,macdPrevBuffer_M15);
      if(CopyOk(2,h1) && CopyOk(2,h2) && CopyOk(2,h3) && CopyOk(2,h4) && CopyOk(2,h5))
      {
         // Use bar-1 values for parity with TradingView
         score += SynergyAdd(rsiBuffer_M15[1]  > 50, rsiBuffer_M15[1]  < 50,
                             RSI_Weight,        Weight_M15);
         score += SynergyAdd(maFastBuffer_M15[1] > maSlowBuffer_M15[1],
                             maFastBuffer_M15[1] < maSlowBuffer_M15[1],
                             Trend_Weight,       Weight_M15);
         score += SynergyAdd(macdBuffer_M15[1]  > macdPrevBuffer_M15[1],
                             macdBuffer_M15[1]  < macdPrevBuffer_M15[1],
                             MACDV_Slope_Weight, Weight_M15);
         hasData = true;
      }
      else
      {
         Print("DEBUG: M15 data missing - rsi:",h1," fast:",h2," slow:",h3,
               " macd:",h4," prev:",h5);
      }
   }

   // -------- H1 --------
   if(UseTF1hour)
   {
      int k1 = CopyBuffer(rsiHandle_H1 ,0,0,2,rsiBuffer_H1 );
      int k2 = CopyBuffer(maFastHandle_H1,0,0,2,maFastBuffer_H1);
      int k3 = CopyBuffer(maSlowHandle_H1,0,0,2,maSlowBuffer_H1);
      int k4 = CopyBuffer(macdHandle_H1 ,0,0,2,macdBuffer_H1 );
      int k5 = CopyBuffer(macdHandle_H1 ,0,1,2,macdPrevBuffer_H1);
      if(CopyOk(2,k1) && CopyOk(2,k2) && CopyOk(2,k3) && CopyOk(2,k4) && CopyOk(2,k5))
      {
         // Previous closed bar values
         score += SynergyAdd(rsiBuffer_H1[1]  > 50, rsiBuffer_H1[1]  < 50,
                             RSI_Weight,        Weight_H1);
         score += SynergyAdd(maFastBuffer_H1[1] > maSlowBuffer_H1[1],
                             maFastBuffer_H1[1] < maSlowBuffer_H1[1],
                             Trend_Weight,       Weight_H1);
         score += SynergyAdd(macdBuffer_H1[1]  > macdPrevBuffer_H1[1],
                             macdBuffer_H1[1]  < macdPrevBuffer_H1[1],
                             MACDV_Slope_Weight, Weight_H1);
         hasData = true;
      }
      else
      {
         Print("DEBUG: H1 data missing - rsi:",k1," fast:",k2," slow:",k3,
               " macd:",k4," prev:",k5);
      }
   }

   // preserve previous reading if *no* timeframe had enough data
   if(!hasData)
      return synergyScore;           // don’t force zero early-in-history 

   synergyScore = score;
   return score;
}

//+------------------------------------------------------------------+
//| Helper function for Synergy Score calculation                     |
//+------------------------------------------------------------------+
double SynergyAdd(bool aboveCondition, bool belowCondition, double factor, double timeFactor)
{
   if(aboveCondition) return factor * timeFactor;
   if(belowCondition) return -(factor * timeFactor);
   return 0;
}

//+------------------------------------------------------------------+
//| Release Synergy Score indicator handles                          |
//+------------------------------------------------------------------+
void ReleaseSynergyIndicators()
{
   // Release indicator handles
   if(rsiHandle_M5 != INVALID_HANDLE) IndicatorRelease(rsiHandle_M5);
   if(maFastHandle_M5 != INVALID_HANDLE) IndicatorRelease(maFastHandle_M5);
   if(maSlowHandle_M5 != INVALID_HANDLE) IndicatorRelease(maSlowHandle_M5);
   if(macdHandle_M5 != INVALID_HANDLE) IndicatorRelease(macdHandle_M5);
   
   if(rsiHandle_M15 != INVALID_HANDLE) IndicatorRelease(rsiHandle_M15);
   if(maFastHandle_M15 != INVALID_HANDLE) IndicatorRelease(maFastHandle_M15);
   if(maSlowHandle_M15 != INVALID_HANDLE) IndicatorRelease(maSlowHandle_M15);
   if(macdHandle_M15 != INVALID_HANDLE) IndicatorRelease(macdHandle_M15);
   
   if(rsiHandle_H1 != INVALID_HANDLE) IndicatorRelease(rsiHandle_H1);
   if(maFastHandle_H1 != INVALID_HANDLE) IndicatorRelease(maFastHandle_H1);
   if(maSlowHandle_H1 != INVALID_HANDLE) IndicatorRelease(maSlowHandle_H1);
   if(macdHandle_H1 != INVALID_HANDLE) IndicatorRelease(macdHandle_H1);
}

//+------------------------------------------------------------------+
//| Initialize Market Bias indicator                                 |
//+------------------------------------------------------------------+
bool InitMarketBias()
{
   if(!UseMarketBias) return true;

   // no external indicator needed – we'll compute Heiken Ashi manually
   haHandle = INVALID_HANDLE;

   ArraySetAsSeries(haOpen,  true);
   ArraySetAsSeries(haHigh,  true);
   ArraySetAsSeries(haLow,   true);
   ArraySetAsSeries(haClose, true);

   return true;
}

//+------------------------------------------------------------------+
//| Calculate Market Bias                                             |
//+------------------------------------------------------------------+
bool CalculateMarketBias()
{
   if(!UseMarketBias) return true;

   ENUM_TIMEFRAMES tf = GetTimeframeFromString(BiasTimeframe);

   int need = HeikinAshiPeriod + 1;
   MqlRates rates[];
   if(CopyRates(_Symbol, tf, 0, need, rates) < need)
      return false;
   ArraySetAsSeries(rates, true);

   ArrayResize(haOpen, need);
   ArrayResize(haHigh, need);
   ArrayResize(haLow,  need);
   ArrayResize(haClose,need);

   for(int i = need - 1; i >= 0; --i)
   {
      double cPrice = (rates[i].open + rates[i].high + rates[i].low + rates[i].close) / 4.0;
      double oPrice;
      if(i == need - 1)
         oPrice = (rates[i].open + rates[i].close) / 2.0;
      else
         oPrice = (haOpen[i+1] + haClose[i+1]) / 2.0;

      double hPrice = MathMax(rates[i].high, MathMax(oPrice, cPrice));
      double lPrice = MathMin(rates[i].low,  MathMin(oPrice, cPrice));

      haOpen[i]  = oPrice;
      haHigh[i]  = hPrice;
      haLow[i]   = lPrice;
      haClose[i] = cPrice;
   }

   double o = CalculateEMAValue(haOpen,  HeikinAshiPeriod);
   double h = CalculateEMAValue(haHigh,  HeikinAshiPeriod);
   double l = CalculateEMAValue(haLow,   HeikinAshiPeriod);
   double c = CalculateEMAValue(haClose, HeikinAshiPeriod);
   
   // Calculate oscillator
   oscBias = 100 * (c - o);
   
   // Calculate smooth oscillator with manual EMA
   double alphaOsc = 2.0 / (OscillatorPeriod + 1);
   
   static double lastOscSmooth = 0;
   if(lastOscSmooth == 0) lastOscSmooth = oscBias;
   
   oscSmooth = (oscBias - lastOscSmooth) * alphaOsc + lastOscSmooth;
   lastOscSmooth = oscSmooth;
   
   // Detect bias changes
   prevBiasPositive = currentBiasPositive;
   currentBiasPositive = oscBias > 0;
   
   biasChangedToBullish = !prevBiasPositive && currentBiasPositive;
   biasChangedToBearish = prevBiasPositive && !currentBiasPositive;
   
   return true;
}

//────────────────────────────────────────────────────────────────────
// 6.  SAFE EMA CALC                                                 
//────────────────────────────────────────────────────────────────────

double CalculateEMAValue(double &array[], int period)
{
   int len = ArraySize(array);
   if(len==0) return 0;
   if(len<period) period=len;
   double alpha=2.0/(period+1);
   double ema=array[period-1];
   for(int i=period-2;i>=0;i--)
      ema = (array[i]-ema)*alpha + ema;
   return ema;
}

//+------------------------------------------------------------------+
//| Release Market Bias indicator handle                              |
//+------------------------------------------------------------------+
void ReleaseMarketBias()
{
   if(haHandle != INVALID_HANDLE)
      IndicatorRelease(haHandle);
}

//+------------------------------------------------------------------+
//| Initialize ADX Filter                                             |
//+------------------------------------------------------------------+
bool InitADXFilter()
{
   if(!EnableADXFilter) return true;
   
   // Create ADX indicator handle
   adxHandle = iADX(_Symbol, PERIOD_CURRENT, ADXPeriod);
   
   if(adxHandle == INVALID_HANDLE)
   {
      Print("Error initializing ADX indicator: ", GetLastError());
      return false;
   }
   
   // Set arrays as series
   ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(adxPlus, true);
   ArraySetAsSeries(adxMinus, true);
   
   return true;
}

//────────────────────────────────────────────────────────────────────
// 7.  ADX FILTER – history guard                                    
//────────────────────────────────────────────────────────────────────

bool CalculateADXFilter()
{
   if(!EnableADXFilter){ adxTrendCondition=true; return true; }
   int need = ADXLookbackPeriod+1;
   if(CopyBuffer(adxHandle,0,0,need,adxMain)  < need) { adxTrendCondition=false; return false; }
   if(CopyBuffer(adxHandle,1,0,1,adxPlus)    < 1   ) { adxTrendCondition=false; return false; }
   if(CopyBuffer(adxHandle,2,0,1,adxMinus)   < 1   ) { adxTrendCondition=false; return false; }
   double adxAvg=0;
   if(UseDynamicADX)
   {
      for(int i=0;i<ADXLookbackPeriod;i++) adxAvg+=adxMain[i];
      adxAvg/=ADXLookbackPeriod;
      effectiveADXThreshold = MathMax(ADXMinThreshold, adxAvg*ADXMultiplier);
   }
   else effectiveADXThreshold = StaticADXThreshold;
   adxTrendCondition = adxMain[0] > effectiveADXThreshold;
   return true;
}

//+------------------------------------------------------------------+
//| Release ADX Filter indicator handle                               |
//+------------------------------------------------------------------+
void ReleaseADXFilter()
{
   if(adxHandle != INVALID_HANDLE)
      IndicatorRelease(adxHandle);
}

//+------------------------------------------------------------------+
//| Force-load history for all synergy timeframes                     |
//+------------------------------------------------------------------+
void WarmupIndicatorHistory()
{
   ENUM_TIMEFRAMES tfs[] = {PERIOD_M5, PERIOD_M15, PERIOD_H1};
   MqlRates tmp[];
   for(int i=0;i<ArraySize(tfs);i++)
   {
      int need = BARS_REQUIRED;
      ResetLastError();
      int got = CopyRates(_Symbol, tfs[i], 0, need, tmp);
      Print("Warmup ",EnumToString(tfs[i]),": requested ",need," got ",got,
            ", err ",GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Convert string timeframe to ENUM_TIMEFRAMES                       |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetTimeframeFromString(string tfString)
{
   if(tfString == "current") return PERIOD_CURRENT;
   if(tfString == "M1") return PERIOD_M1;
   if(tfString == "M5") return PERIOD_M5;
   if(tfString == "M15") return PERIOD_M15;
   if(tfString == "M30") return PERIOD_M30;
   if(tfString == "H1") return PERIOD_H1;
   if(tfString == "H4") return PERIOD_H4;
   if(tfString == "D1") return PERIOD_D1;
   if(tfString == "W1") return PERIOD_W1;
   if(tfString == "MN1") return PERIOD_MN1;
   
   // Default to current timeframe
   return PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| Input Parameters - Dashboard Settings (Add to your inputs)       |
//+------------------------------------------------------------------+
input group "Dashboard Settings"
input bool      ShowDashboard = true;                  // Show Dashboard
input int       DashboardFontSize = 9;                 // Dashboard Font Size
input int       DashboardTransparency = 80;            // Background Transparency (0-255)
input int       DashboardXPosition = 10;               // Dashboard X Position
input int       DashboardYPosition = 10;               // Dashboard Y Position

//+------------------------------------------------------------------+
//| Dashboard Variables (Updated)                                     |
//+------------------------------------------------------------------+
string dashboardPrefix = "PropEA_Dashboard_";
color headerBgColor = clrNavy;
color sectionHeaderBg = clrDarkSlateGray;
color dataBgColor = clrIndigo;
color textColor = clrWhite;
color statusGreen = clrLime;
color statusRed = clrRed;
color statusOrange = clrOrange;
color costRecoveryHeaderBg = clrDarkSlateGray;
color costRecoveryCriteriaBg = clrGray;

// Live account simulation variables
double liveAccountBalance = 0;
double liveAccountEquity = 0;
double liveAccountMargin = 0;
double liveDailyStartBalance = 0;
datetime lastDayCheck = 0;

//+------------------------------------------------------------------+
//| Initialize Live Account Simulation                                |
//+------------------------------------------------------------------+
void InitializeLiveAccountSimulation()
{
   liveAccountBalance = initialBalance * hedgeFactor;
   liveAccountEquity = liveAccountBalance;
   liveAccountMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * hedgeFactor;
   liveDailyStartBalance = liveAccountBalance;
   lastDayCheck = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Update Live Account Simulation                                    |
//+------------------------------------------------------------------+
void UpdateLiveAccountSimulation()
{
   // Check for new day
   MqlDateTime currentTime, lastTime;
   TimeToStruct(TimeCurrent(), currentTime);
   TimeToStruct(lastDayCheck, lastTime);
   
   if(currentTime.day != lastTime.day)
   {
      liveDailyStartBalance = liveAccountBalance;
      lastDayCheck = TimeCurrent();
   }
   
   // Update live account values based on prop account performance
   double propPerformance = (AccountInfoDouble(ACCOUNT_BALANCE) - initialBalance) / initialBalance;
   liveAccountBalance = (initialBalance * hedgeFactor) * (1 + propPerformance);
   liveAccountEquity = liveAccountBalance + (AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE)) * hedgeFactor;
   liveAccountMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * hedgeFactor;
}

//+------------------------------------------------------------------+
//| Create Dashboard (Fixed and Enhanced)                             |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   if(!ShowDashboard) return;
   
   // Remove any existing dashboard objects
   DeleteDashboard();
   
   // Initialize live account simulation
   InitializeLiveAccountSimulation();
   
   // Create main background panel with transparency - ADJUST SIZE
   ObjectCreate(0, dashboardPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_XDISTANCE, DashboardXPosition);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_YDISTANCE, DashboardYPosition);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_XSIZE, 450);  // REDUCED WIDTH
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_YSIZE, 530);  // ADJUSTED HEIGHT
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_BGCOLOR, dataBgColor);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_SELECTED, false);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, dashboardPrefix + "BG", OBJPROP_ZORDER, 0);
   
   // Update transparency panel to match new size
   ObjectCreate(0, dashboardPrefix + "Transparency", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_XDISTANCE, DashboardXPosition);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_YDISTANCE, DashboardYPosition);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_XSIZE, 450);  // MATCH WIDTH
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_YSIZE, 530);  // MATCH HEIGHT
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_BACK, false);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_SELECTED, false);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, dashboardPrefix + "Transparency", OBJPROP_ZORDER, 1);
   
   // Add Main Title - CENTERED AT 225px (half of 450px width)
   CreateLabel(dashboardPrefix + "Title", _Symbol + " Synergy + PropEA Hedge v1.02", 225, 20, clrWhite, DashboardFontSize + 3, "Arial Bold", true);
   
   int y = 50;
   
   // Create Phase and Hedge Link section
   CreateLabel(dashboardPrefix + "PhaseLabel", "Phase:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "PhaseValue", IntegerToString(CurrentPhase), 80, y, clrYellow, DashboardFontSize);
   
   CreateLabel(dashboardPrefix + "HedgeLinkLabel", "Hedge Link:", 300, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "HedgeLinkValue", "NOT OK", 380, y, statusRed, DashboardFontSize);
   
   y += 30;
   
   // Trading Information Section
   CreateSectionHeader("Trading Information", y);
   y += 25;
   
   // Column headers with better positioning
   CreateLabel(dashboardPrefix + "PropHeader", "PropAcc", 200, y, clrYellow, DashboardFontSize, "Arial Bold", true);
   CreateLabel(dashboardPrefix + "LiveHeader", "LiveAcc", 380, y, clrYellow, DashboardFontSize, "Arial Bold", true);
   
   y += 20;
   
   CreateDataRow("Volume", "0.00", "0.00", y);
   y += 20;
   
   CreateDataRow("Daily PnL", "0.00", "0.00", y);
   y += 20;
   
   CreateDataRow("Summary PnL", "0.00 / " + DoubleToString(MaxDD, 2), "0.00 / " + DoubleToString(ChallengeC, 2), y);
   y += 20;
   
   CreateDataRow("Trading Days", "0 / 0", "0 / 0", y);
   y += 20;
   
   // Account Status Section
   CreateSectionHeader("Account Status", y);
   y += 25;
   
   // Column headers
   CreateLabel(dashboardPrefix + "PropHeader2", "PropAcc", 200, y, clrYellow, DashboardFontSize, "Arial Bold", true);
   CreateLabel(dashboardPrefix + "LiveHeader2", "LiveAcc", 380, y, clrYellow, DashboardFontSize, "Arial Bold", true);
   
   y += 20;
   
   CreateDataRow("Account", IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), "LIVE-" + IntegerToString(HedgeEA_Magic), y);
   y += 20;
   
   CreateDataRow("Currency", AccountInfoString(ACCOUNT_CURRENCY), AccountInfoString(ACCOUNT_CURRENCY), y);
   y += 20;
   
   CreateDataRow("Free Margin", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2), "0.00", y);
   y += 20;
   
   CreateDataRow("Symbol", _Symbol, _Symbol, y);
   y += 20;
   
   CreateDataRow("Daily DD Type", "Balance & Equity", "Balance & Equity", y);
   y += 20;
   
   CreateDataRow("Today DD", DoubleToString(dailyDD, 2), "100.0%", y);
   y += 20;
   
   CreateDataRow("Max DD", DoubleToString(MaxDD, 2), "100.0%", y);
   y += 20;
   
   // Cost Recovery Section
   CreateCostRecoverySection(y);
   y += 100;
   
   // Strategy Status Section
   CreateSectionHeader("Strategy Status", y);
   y += 25;
   
   // Market Bias
   CreateLabel(dashboardPrefix + "BiasLabel", "Market Bias:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "BiasValue", "NEUTRAL", 120, y, clrGray, DashboardFontSize);
   CreateLabel(dashboardPrefix + "BiasIndicator", "●", 200, y, currentBiasPositive ? statusGreen : statusRed, DashboardFontSize + 3);
   y += 18;
   
   // Synergy Score
   CreateLabel(dashboardPrefix + "SynergyLabel", "Synergy Score:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "SynergyValue", DoubleToString(synergyScore, 2), 120, y, textColor, DashboardFontSize);
   y += 18;
   
   // ADX Status
   CreateLabel(dashboardPrefix + "ADXLabel", "ADX Status:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "ADXValue", "Waiting", 120, y, statusRed, DashboardFontSize);
   CreateLabel(dashboardPrefix + "ADXValueNum", "(0.0)", 180, y, textColor, DashboardFontSize - 1);
   y += 18;
   
   // Scale Out Features
   CreateLabel(dashboardPrefix + "ScaleOutLabel", "Scale Out:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "ScaleOutValue", "OFF", 120, y, statusRed, DashboardFontSize);
   CreateLabel(dashboardPrefix + "ScaleOutDetails", "", 160, y, textColor, DashboardFontSize - 1);
   y += 18;
   
   // Pivot Settings
   CreateLabel(dashboardPrefix + "PivotLabel", "Pivot Settings:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "PivotValue", IntegerToString(PivotLengthLeft) + "/" + IntegerToString(PivotLengthRight), 120, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "PivotBars", "LB:" + IntegerToString(PivotTPBars), 170, y, textColor, DashboardFontSize - 1);
   y += 18;
   
   // Session Filter
   CreateLabel(dashboardPrefix + "SessionLabel", "Session Filter:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "SessionValue", EnableSessionFilter ? "ON" : "OFF", 120, y, EnableSessionFilter ? statusGreen : statusRed, DashboardFontSize);
   y += 18;
   
   // Signal Ready Status
   CreateLabel(dashboardPrefix + "SignalLabel", "Signal Ready:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "SignalValue", "CHECKING", 120, y, statusOrange, DashboardFontSize);
   y += 18;
   
   // Trading Enabled
   CreateLabel(dashboardPrefix + "TradingLabel", "Trading:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "TradingValue", EnableTrading ? "ENABLED" : "DISABLED", 120, y, EnableTrading ? statusGreen : statusRed, DashboardFontSize);
   y += 18;
   
   // Last Updated
   CreateLabel(dashboardPrefix + "TimeLabel", "Last Updated:", 20, y, textColor, DashboardFontSize);
   CreateLabel(dashboardPrefix + "TimeValue", TimeToString(TimeCurrent(), TIME_SECONDS), 120, y, textColor, DashboardFontSize);
}

//+------------------------------------------------------------------+
//| Get Actual Account Volume (Fix #1)                               |
//+------------------------------------------------------------------+
double GetActualAccountVolume()
{
   double totalVolume = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0)
      {
         totalVolume += PositionGetDouble(POSITION_VOLUME);
      }
   }
   return totalVolume;
}

//+------------------------------------------------------------------+
//| Get Live Account Free Margin (Fix #3)                            |
//+------------------------------------------------------------------+
double GetLiveAccountFreeMargin()
{
   // In a real implementation, this would query the actual live account
   // For simulation, we'll use a realistic calculation based on hedge positions
   double propMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double liveMargin = 0;
   
   if(EnableHedgeCommunication && IsLinkAlive(true))
   {
      // Simulate live account margin based on hedge positions
      double hedgeVolume = GetActualAccountVolume() * hedgeFactor;
      double marginPerLot = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_INITIAL);
      liveMargin = (initialBalance * hedgeFactor) - (hedgeVolume * marginPerLot);
   }
   else
   {
      // No connection - show estimated margin
      liveMargin = propMargin * hedgeFactor;
   }
   
   return MathMax(0, liveMargin);
}

//+------------------------------------------------------------------+
//| Get Real Daily PnL from History (Fix #4)                         |
//+------------------------------------------------------------------+
double GetRealDailyPnLFromHistory()
{
   datetime startOfDay = 0;
   datetime currentTime = TimeCurrent();
   
   // Get start of current day
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   startOfDay = StructToTime(dt);
   
   // Select history for today
   if(!HistorySelect(startOfDay, currentTime))
   {
      Print("Failed to select history for today");
      return 0;
   }
   
   double dailyProfit = 0;
   int totalDeals = HistoryDealsTotal();
   
   // Sum all deals from today
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0)
      {
         string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
         if(dealSymbol == _Symbol || dealSymbol == "") // Include all symbols or current symbol
         {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            
            dailyProfit += (profit + swap + commission);
         }
      }
   }
   
   return dailyProfit;
}

//+------------------------------------------------------------------+
//| Get Real Total PnL from History (Fix #4)                         |
//+------------------------------------------------------------------+
double GetRealTotalPnLFromHistory()
{
   // Get account's actual starting balance from first deposit
   double startingBalance = initialBalance;
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Calculate total PnL as difference from starting balance
   // This accounts for any deposits/withdrawals that may have occurred
   double totalPnL = currentBalance - startingBalance;
   
   // Add floating PnL
   double floatingPnL = currentEquity - currentBalance;
   
   return totalPnL + floatingPnL;
}

//+------------------------------------------------------------------+
//| Update Dashboard with latest values (All Fixes Applied)           |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!ShowDashboard) return;
   
   // Update live account simulation
   UpdateLiveAccountSimulation();
   
   // Update Hedge Link Status
   bool linkOK = IsLinkAlive(true);
   ObjectSetString(0, dashboardPrefix + "HedgeLinkValue", OBJPROP_TEXT, linkOK ? "CONNECTED" : "NOT OK");
   ObjectSetInteger(0, dashboardPrefix + "HedgeLinkValue", OBJPROP_COLOR, linkOK ? statusGreen : statusRed);
   
   // FIX #1: Update Trading Information - Use actual account volumes
   double propVolume = GetActualAccountVolume();  // All positions, not just EA-managed
   double hedgeVolume = propVolume * hedgeFactor; // Simulated hedge volume
   ObjectSetString(0, dashboardPrefix + "Volume_Prop", OBJPROP_TEXT, DoubleToString(propVolume, 2));
   ObjectSetString(0, dashboardPrefix + "Volume_Real", OBJPROP_TEXT, DoubleToString(hedgeVolume, 2));
   
   // FIX #4: Update PnL values - Use real history data
   double propDailyPnL = GetRealDailyPnLFromHistory();
   double liveDailyPnL = propDailyPnL * hedgeFactor; // Simulated live daily PnL
   
   ObjectSetString(0, dashboardPrefix + "Daily PnL_Prop", OBJPROP_TEXT, 
                  (propDailyPnL >= 0 ? "+" : "") + DoubleToString(propDailyPnL, 2));
   ObjectSetString(0, dashboardPrefix + "Daily PnL_Real", OBJPROP_TEXT, 
                  (liveDailyPnL >= 0 ? "+" : "") + DoubleToString(liveDailyPnL, 2));
   
   // Summary PnL - Use real total PnL from history
   double propTotalPnL = GetRealTotalPnLFromHistory();
   double liveTotalPnL = propTotalPnL * hedgeFactor; // Simulated live total PnL
   
   ObjectSetString(0, dashboardPrefix + "Summary PnL_Prop", OBJPROP_TEXT, 
                  (propTotalPnL >= 0 ? "+" : "") + DoubleToString(propTotalPnL, 2) + " / " + DoubleToString(MaxDD, 2));
   ObjectSetString(0, dashboardPrefix + "Summary PnL_Real", OBJPROP_TEXT, 
                  (liveTotalPnL >= 0 ? "+" : "") + DoubleToString(liveTotalPnL, 2) + " / " + DoubleToString(ChallengeC, 2));
   
   // Update Account Status - Fixed live account display
   ObjectSetString(0, dashboardPrefix + "Account_Real", OBJPROP_TEXT, "LIVE-" + IntegerToString(HedgeEA_Magic));
   
   // FIX #3: Update margins - Use real live account margin calculation
   double propMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double liveMargin = GetLiveAccountFreeMargin(); // Proper live margin calculation
   ObjectSetString(0, dashboardPrefix + "Free Margin_Prop", OBJPROP_TEXT, DoubleToString(propMargin, 2));
   ObjectSetString(0, dashboardPrefix + "Free Margin_Real", OBJPROP_TEXT, DoubleToString(liveMargin, 2));
   
   // Update Trading Days
   int tradingDays = GetTradingDaysCount();
   ObjectSetString(0, dashboardPrefix + "Trading Days_Prop", OBJPROP_TEXT, IntegerToString(tradingDays) + " / " + IntegerToString(tradingDays));
   ObjectSetString(0, dashboardPrefix + "Trading Days_Real", OBJPROP_TEXT, IntegerToString(tradingDays) + " / " + IntegerToString(tradingDays));
   
   // FIX #2: Update Cost Recovery section - Fixed object naming
   double propLoss = MathMin(0, propTotalPnL);
   double propLossAbs = MathAbs(propLoss);
   double realProfit = MathMax(0, liveTotalPnL);
   double recoveryPct = 0;
   
   if(propLossAbs > 0 && realProfit > 0) {
      recoveryPct = (realProfit / propLossAbs) * 100;
   } else if(propLossAbs == 0 && realProfit > 0) {
      recoveryPct = 100.0;
   }
   
   // Fixed object names to match creation
   ObjectSetString(0, dashboardPrefix + "CostRecovery_Loss_Prop", OBJPROP_TEXT, 
                  propLoss < -0.01 ? DoubleToString(propLoss, 2) : "0.00");
   ObjectSetString(0, dashboardPrefix + "CostRecovery_Profit_Real", OBJPROP_TEXT, 
                  DoubleToString(realProfit, 2));
   ObjectSetString(0, dashboardPrefix + "CostRecovery_Recovery", OBJPROP_TEXT, 
                  DoubleToString(recoveryPct, 1) + "%");
   
   // Update Strategy Status indicators
   // Market Bias
   string biasText = "NEUTRAL";
   color biasColor = clrGray;
   if(UseMarketBias) {
      biasText = currentBiasPositive ? "BULLISH" : "BEARISH";
      biasColor = currentBiasPositive ? statusGreen : statusRed;
   }
   ObjectSetString(0, dashboardPrefix + "BiasValue", OBJPROP_TEXT, biasText);
   ObjectSetInteger(0, dashboardPrefix + "BiasValue", OBJPROP_COLOR, biasColor);
   ObjectSetInteger(0, dashboardPrefix + "BiasIndicator", OBJPROP_COLOR, biasColor);
   
   // Synergy Score
   ObjectSetString(0, dashboardPrefix + "SynergyValue", OBJPROP_TEXT, DoubleToString(synergyScore, 2));
   ObjectSetInteger(0, dashboardPrefix + "SynergyValue", OBJPROP_COLOR, 
                   synergyScore > 0 ? statusGreen : (synergyScore < 0 ? statusRed : textColor));
   
   // ADX Status - Fixed to show actual status
   bool actualADXCondition = EnableADXFilter ? adxTrendCondition : true;
   ObjectSetString(0, dashboardPrefix + "ADXValue", OBJPROP_TEXT, actualADXCondition ? "Active" : "Waiting");
   ObjectSetInteger(0, dashboardPrefix + "ADXValue", OBJPROP_COLOR, actualADXCondition ? statusGreen : statusRed);
   if(EnableADXFilter) {
      ObjectSetString(0, dashboardPrefix + "ADXValueNum", OBJPROP_TEXT, 
                     "(" + DoubleToString(effectiveADXThreshold, 1) + ")");
   } else {
      ObjectSetString(0, dashboardPrefix + "ADXValueNum", OBJPROP_TEXT, "(OFF)");
   }
   
   // Scale Out Status
   bool scaleOutActive = EnableScaleOut && ScaleOut1Enabled;
   ObjectSetString(0, dashboardPrefix + "ScaleOutValue", OBJPROP_TEXT, scaleOutActive ? "ON" : "OFF");
   ObjectSetInteger(0, dashboardPrefix + "ScaleOutValue", OBJPROP_COLOR, scaleOutActive ? statusGreen : statusRed);
   if(scaleOutActive) {
      ObjectSetString(0, dashboardPrefix + "ScaleOutDetails", OBJPROP_TEXT, 
                     "(" + DoubleToString(ScaleOut1Pct, 0) + "% at " + DoubleToString(ScaleOut1Size, 0) + "%)");
   } else {
      ObjectSetString(0, dashboardPrefix + "ScaleOutDetails", OBJPROP_TEXT, "");
   }
   
   // Session Filter Status
   ObjectSetString(0, dashboardPrefix + "SessionValue", OBJPROP_TEXT, EnableSessionFilter ? "ON" : "OFF");
   ObjectSetInteger(0, dashboardPrefix + "SessionValue", OBJPROP_COLOR, EnableSessionFilter ? statusGreen : statusRed);
   
   // Signal Ready Status
   bool signalReady = entryTriggersEnabled && 
                     (EnableADXFilter ? adxTrendCondition : true) && 
                     IsInTradingSession() &&
                     EnableTrading &&
                     !HasOpenPosition();
   
   string signalStatus = "NOT READY";
   color signalColor = statusRed;
   
   if(signalReady) {
      signalStatus = "READY";
      signalColor = statusGreen;
   } else if(!EnableTrading) {
      signalStatus = "DISABLED";
      signalColor = statusRed;
   } else if(HasOpenPosition()) {
      signalStatus = "IN TRADE";
      signalColor = statusOrange;
   } else if(!IsInTradingSession()) {
      signalStatus = "OUT OF SESSION";
      signalColor = statusOrange;
   } else if(EnableADXFilter && !adxTrendCondition) {
      signalStatus = "ADX WAIT";
      signalColor = statusOrange;
   }
   
   ObjectSetString(0, dashboardPrefix + "SignalValue", OBJPROP_TEXT, signalStatus);
   ObjectSetInteger(0, dashboardPrefix + "SignalValue", OBJPROP_COLOR, signalColor);
   
   // Trading Status
   ObjectSetString(0, dashboardPrefix + "TradingValue", OBJPROP_TEXT, EnableTrading ? "ENABLED" : "DISABLED");
   ObjectSetInteger(0, dashboardPrefix + "TradingValue", OBJPROP_COLOR, EnableTrading ? statusGreen : statusRed);
   
   // Update timestamp
   ObjectSetString(0, dashboardPrefix + "TimeValue", OBJPROP_TEXT, TimeToString(TimeCurrent(), TIME_SECONDS));
}

//+------------------------------------------------------------------+
//| Create a section header (Fixed positioning)                       |
//+------------------------------------------------------------------+
void CreateSectionHeader(string title, int y)
   {
      if(!ShowDashboard) return;
      
      string name = dashboardPrefix + "Section_" + title;
      
      // Create background
      ObjectCreate(0, name + "_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name + "_BG", OBJPROP_XDISTANCE, DashboardXPosition);
      ObjectSetInteger(0, name + "_BG", OBJPROP_YDISTANCE, DashboardYPosition + y);
      ObjectSetInteger(0, name + "_BG", OBJPROP_XSIZE, 450);  // UPDATED WIDTH
      ObjectSetInteger(0, name + "_BG", OBJPROP_YSIZE, 25);
      ObjectSetInteger(0, name + "_BG", OBJPROP_BGCOLOR, sectionHeaderBg);
      ObjectSetInteger(0, name + "_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name + "_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name + "_BG", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name + "_BG", OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name + "_BG", OBJPROP_BACK, false);
      ObjectSetInteger(0, name + "_BG", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name + "_BG", OBJPROP_SELECTED, false);
      ObjectSetInteger(0, name + "_BG", OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name + "_BG", OBJPROP_ZORDER, 2);
      
      // Create label - CENTER AT 225px
      CreateLabel(name, title, 225, y + 13, clrWhite, DashboardFontSize, "Arial Bold", true);
   }
   
   // 2. Update all data rows
   // REPLACE THIS FUNCTION:
   void CreateDataRow(string label, string propValue, string liveValue, int y)
   {
      if(!ShowDashboard) return;
      
      string name = dashboardPrefix + label;
      
      // Create background
      ObjectCreate(0, name + "_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name + "_BG", OBJPROP_XDISTANCE, DashboardXPosition);
      ObjectSetInteger(0, name + "_BG", OBJPROP_YDISTANCE, DashboardYPosition + y);
      ObjectSetInteger(0, name + "_BG", OBJPROP_XSIZE, 450);  // UPDATED WIDTH
      ObjectSetInteger(0, name + "_BG", OBJPROP_YSIZE, 20);
      ObjectSetInteger(0, name + "_BG", OBJPROP_BGCOLOR, dataBgColor);
      ObjectSetInteger(0, name + "_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name + "_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name + "_BG", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name + "_BG", OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name + "_BG", OBJPROP_BACK, false);
      ObjectSetInteger(0, name + "_BG", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name + "_BG", OBJPROP_SELECTED, false);
      ObjectSetInteger(0, name + "_BG", OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name + "_BG", OBJPROP_ZORDER, 2);
      
      // Create label text
      CreateLabel(name, label, 15, y + 10, textColor, DashboardFontSize, "Arial", false);
      
      // Create prop value - adjusted position 180px (left of center)
      CreateLabel(name + "_Prop", propValue, 180, y + 10, textColor, DashboardFontSize, "Arial", true);
      
      // Create live value - adjusted position 340px (right of center)
      CreateLabel(name + "_Real", liveValue, 340, y + 10, textColor, DashboardFontSize, "Arial", true);
   }
   


//+------------------------------------------------------------------+
//| Create Cost Recovery section (Fix #2 - Correct Object Names)     |
//+------------------------------------------------------------------+
void CreateCostRecoverySection(int y)
{
   if(!ShowDashboard) return;
   
   string name = dashboardPrefix + "CostRecovery";
   
   // Create header
   CreateSectionHeader("Cost Recovery Estimate", y);
   y += 25;
   
   // Create column headers with proper alignment
   CreateLabel(name + "_Criteria", "Criteria", 20, y + 10, textColor, DashboardFontSize);
   CreateLabel(name + "_Loss_Header", "Loss PropAcc", 200, y + 10, clrYellow, DashboardFontSize, "Arial", true);
   CreateLabel(name + "_Profit_Header", "Profit LiveAcc", 350, y + 10, clrYellow, DashboardFontSize, "Arial", true);
   CreateLabel(name + "_Recovery_Header", "Recovery %", 450, y + 10, clrYellow, DashboardFontSize, "Arial", true);
   
   y += 20;
   
   // Create Max DD row background
   ObjectCreate(0, name + "_MaxDD_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_XDISTANCE, DashboardXPosition);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_YDISTANCE, DashboardYPosition + y);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_XSIZE, 520);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_YSIZE, 20);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_BGCOLOR, costRecoveryCriteriaBg);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name + "_MaxDD_BG", OBJPROP_ZORDER, 2);
   
   // Create Max DD row labels with CORRECT names that match UpdateDashboard()
   CreateLabel(name + "_MaxDD", "Max DD", 20, y + 10, textColor, DashboardFontSize);
   CreateLabel(name + "_Loss_Prop", "0.00", 200, y + 10, textColor, DashboardFontSize, "Arial", true);
   CreateLabel(name + "_Profit_Real", "0.00", 350, y + 10, textColor, DashboardFontSize, "Arial", true);
   CreateLabel(name + "_Recovery", "0.0%", 450, y + 10, textColor, DashboardFontSize, "Arial", true);
}

//+------------------------------------------------------------------+
//| Delete dashboard                                                  |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   ObjectsDeleteAll(0, dashboardPrefix);
}

//+------------------------------------------------------------------+
//| Create a text label (Enhanced with positioning)                   |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int fontSize, 
                string font = "Arial", bool centered = false)
{
   if(!ShowDashboard) return;
   
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, DashboardXPosition + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, DashboardYPosition + y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, centered ? ANCHOR_CENTER : ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 3);
}

//+------------------------------------------------------------------+
//| Get Daily PnL (Helper function)                                   |
//+------------------------------------------------------------------+
double GetDailyPnL()
{
   static double dayStartBalance = 0;
   static datetime lastDay = 0;
   
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   // Check for new day
   if(lastDay != dt.day || dayStartBalance == 0)
   {
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDay = dt.day;
   }
   
   return AccountInfoDouble(ACCOUNT_EQUITY) - dayStartBalance;
}

//+------------------------------------------------------------------+
//| Get Trading Days Count (Helper function)                          |
//+------------------------------------------------------------------+
int GetTradingDaysCount()
{
   static int tradingDays = 1;
   static datetime lastCheck = 0;
   
   datetime currentTime = TimeCurrent();
   MqlDateTime current, last;
   TimeToStruct(currentTime, current);
   TimeToStruct(lastCheck, last);
   
   if(lastCheck == 0) {
      lastCheck = currentTime;
      return tradingDays;
   }
   
   if(current.day != last.day) {
      tradingDays++;
      lastCheck = currentTime;
   }
   
   return tradingDays;
}

//+------------------------------------------------------------------+
//| Fixed StringGetTickCount function (type conversion fix)           |
//+------------------------------------------------------------------+
double StringGetTickCount(string text)
{
   ulong result = 0;
   for(int i = 0; i < StringLen(text); i++)
   {
      result += (ulong)StringGetCharacter(text, i);
   }
   return (double)result;  // Explicit cast to fix type conversion warning
}
//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(last_time == current_time) 
   {
      g_newBarJustDetected = false;  // Reset flag when not a new bar
      return false;
   }
   
   last_time = current_time;
   g_newBarJustDetected = true;  // Set flag when new bar detected
   return true;
}

//+------------------------------------------------------------------+
//| Check if bar is confirmed (not still forming)                    |
//+------------------------------------------------------------------+
bool IsConfirmedBar()
{
   // Check if we have enough history
   if(ArraySize(TimeSeries) < 2)
      return false;
   
   // PATCH: If IsNewBar() just detected a new bar, consider it confirmed
   if(g_newBarJustDetected)
   {
      Print("DEBUG: Bar confirmed as part of new bar detection at ", TimeToString(TimeCurrent()));
      return true;
   }
   
   // The rest of the function remains the same
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   // Method 1: Check if we're in a new bar (just after previous bar closed)
   if(lastBarTime != currentBarTime)
   {
      lastBarTime = currentBarTime;
      Print("DEBUG: New bar detected at ", TimeToString(currentBarTime), " - previous bar confirmed closed");
      return true;
   }
   
   // Method 2: Alternative - check if current bar is near close (last 10 seconds)
   datetime nextBarTime = currentBarTime + PeriodSeconds();
   int secondsUntilClose = (int)(nextBarTime - TimeCurrent());
   
   if(secondsUntilClose <= 10) // Last 10 seconds of current bar
   {
      static datetime lastNearCloseWarning = 0;
      if(TimeCurrent() - lastNearCloseWarning > 30)
      {
         Print("DEBUG: Near bar close - ", secondsUntilClose, " seconds until next bar");
         lastNearCloseWarning = TimeCurrent();
      }
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Cleanup any potentially open file handles                        |
//+------------------------------------------------------------------+
void CleanupFileHandles()
{
   // Force garbage collection
   // This is a workaround for potential handle leaks
   static datetime lastCleanup = 0;
   if(TimeCurrent() - lastCleanup > 5) // Only every 5 seconds
   {
      // Try to close any handles that might be stuck
      for(int i = 0; i < 100; i++) // Arbitrary range
      {
         // This will fail silently for invalid handles
         FileClose(i);
      }
      lastCleanup = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Get human-readable error description                             |
//+------------------------------------------------------------------+
string GetErrorDescription(int errorCode)
{
   switch(errorCode)
   {
      case 0:     return "ERR_SUCCESS";
      case 4001:  return "ERR_FUNCTION_NOT_CONFIRMED";
      case 5002:  return "ERR_FILE_TOO_MANY_OPENED";
      case 5003:  return "ERR_FILE_WRONG_FILENAME";
      case 5004:  return "ERR_FILE_TOO_LONG_FILENAME";
      case 5005:  return "ERR_FILE_CANNOT_OPEN";
      case 5006:  return "ERR_FILE_BUFFER_ALLOCATION_ERROR";
      case 5007:  return "ERR_FILE_CANNOT_DELETE";
      case 5008:  return "ERR_FILE_INVALID_HANDLE";
      case 5009:  return "ERR_FILE_WRONG_HANDLE";
      case 5010:  return "ERR_FILE_NOT_TOWRITE";
      case 5011:  return "ERR_FILE_NOT_TOREAD";
      case 5012:  return "ERR_FILE_NOT_BIN";
      case 5013:  return "ERR_FILE_NOT_TXT";
      case 5014:  return "ERR_FILE_NOT_TXTORCSV";
      case 5015:  return "ERR_FILE_NOT_CSV";
      case 5016:  return "ERR_FILE_READ_ERROR";
      case 5017:  return "ERR_FILE_WRITE_ERROR";
      case 5018:  return "ERR_FILE_BIN_STRINGSIZE";
      case 5019:  return "ERR_FILE_INCOMPATIBLE";
      case 5020:  return "ERR_FILE_IS_DIRECTORY";
      default:    return "Unknown error " + IntegerToString(errorCode);
   }
}

//+------------------------------------------------------------------+
//| Try alternative signal method as last resort                     |
//+------------------------------------------------------------------+
void TryAlternativeSignalMethod(string signalData)
{
   Print("🔄 Trying alternative signal method...");
   
   // Try using MQL5\\Files\\ path instead of common
   string altPath = "MQL5\\Files\\MT5com.txt";
   
   ResetLastError();
   int fileHandle = FileOpen(altPath, FILE_WRITE|FILE_TXT);
   if(fileHandle != INVALID_HANDLE)
   {
      FileWriteString(fileHandle, signalData);
      FileFlush(fileHandle);
      FileClose(fileHandle);
      
      Print("✅ Alternative signal method succeeded: ", altPath);
      COMM_FILE_PATH = altPath; // Update path for future use
   }
   else
   {
      int error = GetLastError();
      Print("❌ Alternative signal method also failed. Error: ", error, " (", GetErrorDescription(error), ")");
      
      // Final fallback - try global variables as emergency
      Print("🚨 Emergency fallback to Global Variables...");
      string magicStr = IntegerToString(HedgeEA_Magic);
      GlobalVariableSet("EASignal_Emergency_" + magicStr, (double)TimeCurrent());
      GlobalVariableSet("EASignal_Data_" + magicStr, (double)StringGetTickCount(signalData));
      Print("Emergency signal sent via Global Variables");
   }
}

//+------------------------------------------------------------------+
//| Check if market is open                                          |
//+------------------------------------------------------------------+
bool IsMarketOpen()
{
   // For Forex, we can check if trading is allowed
   return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_DISABLED;
}
   
//+------------------------------------------------------------------+
//| Check if we have an open position                                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk                            |
//+------------------------------------------------------------------+
// riskPercent parameter expects a percentage value (e.g. 0.3 for 0.3%)
double CalculatePositionSize(double slPips, double riskPercent)
{
   // Add validation and logging
   if(slPips <= 0) {
      Print("ERROR: Invalid stop loss distance of ", slPips, " pips. Using minimum lot.");
      return MinLot;
   }
   
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   // Calculate risk amount based on percentage
   double riskAmount = accountBalance * riskPercent / 100;
   
   // Calculate pip value with validation
   double pipValue = 0;
   if(tickSize > 0) {
      pipValue = tickValue * (GetPipSize() / tickSize);
   } else {
      Print("ERROR: Tick size is zero. Using minimum lot.");
      return MinLot;
   }
   
   if(pipValue <= 0) {
      Print("ERROR: Invalid pip value. Using minimum lot.");
      return MinLot;
   }
   
   // Calculate lot size with validation
   double lotSize = riskAmount / (slPips * pipValue);
   
   // Log the calculation for debugging
   Print("Risk calculation: Balance=", accountBalance, 
         ", Risk%=", riskPercent, 
         ", SL pips=", slPips, 
         ", Pip value=", pipValue,
         ", Risk amount=", riskAmount, 
         ", Calculated lot=", lotSize);
   
   // Apply maximum risk limit (10% of balance)
   return MathMax(MinLot, MathMin(lotSize, accountBalance * 0.1));
}

//+------------------------------------------------------------------+
//| Get pip size for current symbol                                  |
//+------------------------------------------------------------------+
double GetPipSize()
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // For Forex
   if(digits == 3 || digits == 5) return (10 * tickSize);
   
   // For other instruments
   return tickSize;
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker's requirements                      |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathRound(lots / lotStep) * lotStep;
   
   return lots;
}

//+------------------------------------------------------------------+
//| Calculate total volume of open positions                          |
//+------------------------------------------------------------------+
double CalculateTotalVolume()
{
   double volume = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket)
      {
         // Check if position belongs to this EA
         if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         {
            volume += PositionGetDouble(POSITION_VOLUME);
         }
      }
   }
   
   return volume;
}

//+------------------------------------------------------------------+
//| Calculate daily PnL                                              |
//+------------------------------------------------------------------+
double CalculateDailyPnL()
{
   // Return current open profit for basic implementation
   static double dayStartEquity = 0;
   static datetime lastDay = 0;
   
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   // New day check
   if(lastDay != dt.day)
   {
      dayStartEquity = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDay = dt.day;
   }
   
   return AccountInfoDouble(ACCOUNT_EQUITY) - dayStartEquity;
}

//+------------------------------------------------------------------+
//| Send hedge signal to hedge EA                                     |
//+------------------------------------------------------------------+

void SendHedgeSignal(string signalType, string direction, double volume, double tp, double sl)
{
   if(!EnableHedgeCommunication) 
   {
      Print("DEBUG: SendHedgeSignal called but communication disabled");
      return;
   }
   
   // CRITICAL FIX: Adjust SL/TP for hedge direction
   double adjustedSL = sl;
   double adjustedTP = tp;
   
   if(signalType == "OPEN")
   {
      double currentPrice = Close[0];
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      Print("=== HEDGE SIGNAL ADJUSTMENT ===");
      Print("Main trade SL: ", DoubleToString(sl, 5), " TP: ", DoubleToString(tp, 5));
      Print("Current Ask: ", DoubleToString(ask, 5), " Bid: ", DoubleToString(bid, 5));
      Print("Hedge Direction: ", direction);
      
      if(direction == "SELL") // Hedge for LONG main trade
      {
         // For hedge SELL: SL should be above entry, TP should be below entry
         // We need to ensure SL > current price and TP < current price
         if(sl < bid) // Original SL is below current price (from LONG trade)
         {
            // Swap: Use main TP as hedge SL, main SL as hedge TP
            adjustedSL = tp;  // Main TP becomes hedge SL (above price)
            adjustedTP = sl;  // Main SL becomes hedge TP (below price)
            Print("🔄 HEDGE SELL: Swapped SL/TP");
            Print("   Adjusted SL: ", DoubleToString(adjustedSL, 5), " (was TP)");
            Print("   Adjusted TP: ", DoubleToString(adjustedTP, 5), " (was SL)");
         }
      }
      else if(direction == "BUY") // Hedge for SHORT main trade
      {
         // For hedge BUY: SL should be below entry, TP should be above entry
         if(sl > ask) // Original SL is above current price (from SHORT trade)
         {
            // Swap: Use main TP as hedge SL, main SL as hedge TP
            adjustedSL = tp;  // Main TP becomes hedge SL (below price)
            adjustedTP = sl;  // Main SL becomes hedge TP (above price)
            Print("🔄 HEDGE BUY: Swapped SL/TP");
            Print("   Adjusted SL: ", DoubleToString(adjustedSL, 5), " (was TP)");
            Print("   Adjusted TP: ", DoubleToString(adjustedTP, 5), " (was SL)");
         }
      }
   }
   
   if(CommunicationMethod == GLOBAL_VARS)
   {
      // Fix type conversions
      string magicStr = IntegerToString(HedgeEA_Magic);
      GlobalVariableSet("EASignal_Type_" + magicStr, (double)StringGetTickCount(signalType));
      GlobalVariableSet("EASignal_Direction_" + magicStr, (double)StringGetTickCount(direction));
      GlobalVariableSet("EASignal_Volume_" + magicStr, volume);
      GlobalVariableSet("EASignal_SL_" + magicStr, adjustedSL);
      GlobalVariableSet("EASignal_TP_" + magicStr, adjustedTP);
      GlobalVariableSet("EASignal_Time_" + magicStr, (double)TimeCurrent());
      
      Print("✅ Signal sent via GLOBAL_VARS: ", signalType, " ", direction, " ", 
            DoubleToString(volume, 2), " lots, TP: ", DoubleToString(adjustedTP, 5), 
            ", SL: ", DoubleToString(adjustedSL, 5));
   }
   else // FILE_BASED
   {
      // Create a signal string with ADJUSTED parameters
      string signalData = signalType + "," + 
                        direction + "," + 
                        DoubleToString(volume, 2) + "," + 
                        DoubleToString(adjustedTP, 5) + "," + 
                        DoubleToString(adjustedSL, 5) + "," + 
                        IntegerToString(Magic_Number) + "," +
                        IntegerToString((int)TimeCurrent()); // Fix type conversion
      
      Print("📤 SENDING FILE SIGNAL: ", signalData);
      Print("   File path: ", COMM_FILE_PATH);
      
      // Force close any potentially open handles first
      CleanupFileHandles();
      
      // Try to write the signal file with retries
      bool success = false;
      for(int attempt = 1; attempt <= FILE_WRITE_RETRY && !success; attempt++)
      {
         Print("   Attempt ", attempt, " of ", FILE_WRITE_RETRY);
         
         // Reset last error before attempting
         ResetLastError();
         
         int fileHandle = INVALID_HANDLE;
         
         // Use appropriate flags based on which path we're using
         bool useFileCommon = (StringFind(COMM_FILE_PATH, "Common") >= 0);
         fileHandle = useFileCommon ? 
                     FileOpen(COMM_FILE_PATH, FILE_WRITE|FILE_TXT|FILE_COMMON) :
                     FileOpen(COMM_FILE_PATH, FILE_WRITE|FILE_TXT);
         
         if(fileHandle != INVALID_HANDLE)
         {
            // Successfully opened file
            int writeResult = FileWriteString(fileHandle, signalData);
            FileFlush(fileHandle);  // Force write to disk
            FileClose(fileHandle);  // Always close immediately
            fileHandle = INVALID_HANDLE; // Mark as closed
            
            if(writeResult > 0)
            {
               success = true;
               Print("✅ Signal sent to hedge EA via file successfully!");
               Print("   Signal: ", signalType, " ", direction, " ", DoubleToString(volume, 2), " lots");
               Print("   Adjusted TP: ", DoubleToString(adjustedTP, 5), " SL: ", DoubleToString(adjustedSL, 5));
               Print("   Bytes written: ", writeResult);
            }
            else
            {
               int writeError = GetLastError();
               Print("❌ File write failed. Error: ", writeError, " (", GetErrorDescription(writeError), ")");
            }
         }
         else
         {
            int errorCode = GetLastError();
            Print("❌ File open attempt ", attempt, " failed. Error: ", errorCode, " (", GetErrorDescription(errorCode), ")");
            Print("   Path: ", COMM_FILE_PATH);
            
            if(attempt < FILE_WRITE_RETRY)
            {
               Print("   Waiting 200ms before retry...");
               Sleep(200); // Increased wait time
               CleanupFileHandles(); // Clean up before retry
            }
         }
      }
      
      if(!success)
      {
         Print("💥 CRITICAL ERROR: Failed to send signal to hedge EA after ", 
               IntegerToString(FILE_WRITE_RETRY), " attempts!");
         Print("   Signal data: ", signalData);
         Print("   File path: ", COMM_FILE_PATH);
         
         // Try alternative method as last resort
         TryAlternativeSignalMethod(signalData);
      }
   }
}



//+------------------------------------------------------------------+
//| Send hedge bleed signal                                           |
//+------------------------------------------------------------------+
void SendHedgeBleedSignal()
{
   // Calculate bleed amount (50% of the hedge)
   double bleedVolume = hedgeLotsLast * 0.5;
   
   // Get current position type
   string direction = "BUY";
   if(PositionSelect(_Symbol))
   {
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
         direction = "SELL";
   }
   
   // Send the signal
   SendHedgeSignal("BLEED", direction, bleedVolume, 0, 0);
}

//+------------------------------------------------------------------+
//| Convert uninit reason to text                                     |
//+------------------------------------------------------------------+
string GetUninitReasonText(int reason)
{
   switch(reason)
   {
      case REASON_PROGRAM:     return "Program called uninit";
      case REASON_REMOVE:      return "Expert removed from chart";
      case REASON_RECOMPILE:   return "Expert recompiled";
      case REASON_CHARTCHANGE: return "Symbol or timeframe changed";
      case REASON_CHARTCLOSE:  return "Chart closed";
      case REASON_PARAMETERS:  return "Parameters changed";
      case REASON_ACCOUNT:     return "Another account activated";
      default:                 return "Unknown reason: " + IntegerToString(reason);
   }
}
   
