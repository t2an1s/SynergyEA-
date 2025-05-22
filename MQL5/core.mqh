#ifndef __CORE_MQH__
#define __CORE_MQH__

// Shared helper prototypes
bool InitSynergyIndicators();
double CalculateSynergyScore();
double SynergyAdd(bool aboveCondition, bool belowCondition, double factor, double timeFactor);
void ReleaseSynergyIndicators();

bool InitMarketBias();
bool CalculateMarketBias();

bool InitADXFilter();
bool CalculateADXFilter();
void ReleaseADXFilter();

double FindDeepestPivotLowBelowClose(int lookbackBars);
double FindHighestPivotHighAboveClose(int lookbackBars);

void OpenTrade(bool isLong, const double sl, const double tp);
void ManageOpenPositions();

//----------------------------------------------------------------------
//  Implementations
//----------------------------------------------------------------------

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
         score += SynergyAdd(rsiBuffer_M5[0]  > 50, rsiBuffer_M5[0]  < 50,
                             RSI_Weight,        Weight_M5);
         score += SynergyAdd(maFastBuffer_M5[0] > maSlowBuffer_M5[0],
                             maFastBuffer_M5[0] < maSlowBuffer_M5[0],
                             Trend_Weight,      Weight_M5);
         score += SynergyAdd(macdBuffer_M5[0]  > macdPrevBuffer_M5[0],
                             macdBuffer_M5[0]  < macdPrevBuffer_M5[0],
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
         score += SynergyAdd(rsiBuffer_M15[0]  > 50, rsiBuffer_M15[0]  < 50,
                             RSI_Weight,        Weight_M15);
         score += SynergyAdd(maFastBuffer_M15[0] > maSlowBuffer_M15[0],
                             maFastBuffer_M15[0] < maSlowBuffer_M15[0],
                             Trend_Weight,       Weight_M15);
         score += SynergyAdd(macdBuffer_M15[0]  > macdPrevBuffer_M15[0],
                             macdBuffer_M15[0]  < macdPrevBuffer_M15[0],
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
         score += SynergyAdd(rsiBuffer_H1[0]  > 50, rsiBuffer_H1[0]  < 50,
                             RSI_Weight,        Weight_H1);
         score += SynergyAdd(maFastBuffer_H1[0] > maSlowBuffer_H1[0],
                             maFastBuffer_H1[0] < maSlowBuffer_H1[0],
                             Trend_Weight,       Weight_H1);
         score += SynergyAdd(macdBuffer_H1[0]  > macdPrevBuffer_H1[0],
                             macdBuffer_H1[0]  < macdPrevBuffer_H1[0],
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
#endif // __CORE_MQH__
