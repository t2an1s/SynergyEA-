The project is focused on developing a Metatrader 5 EA, a spin off of my TradingView Strategy (see SourceCode.txt for full script). 

Your task is to analyse the SourceCode and craft an MT5 EA which will be an exact copy of the TradingView Strategy. 

The end goal is to have 1 main EA MarketCrasherProp.mq5, controlling the open trade triggers (Synergy Score and Market Bias), entry/exit logic, as well as the Hedhging mechanics will be attached to the MT5 prop firm account, and a second complementary EA MarketCrasherLive.mq5, which is acting as a "bridge" to the live/Hedged MT5 account and is managing the opposite trade. 

Be critical, meticulous when coding and creative at troubleshooting. 

NOTE: Avoid marking with arrows <<<<<<< or ====== (see example below) the code you deliver as it causes headaches when it comes to merge script in github.

<<<<<<< 6i061f-codex/fix-synergy-score-and-pivot-issues
      
=======

>>>>>>> main



Priority is to ensure parity with TV Strategy and that all ported features are fully functional. Dashboard (below) will be done at a later stage. <img width="513" alt="Screenshot 2025-05-17 at 10 36 05 AM" src="https://github.com/user-attachments/assets/f9df3bb5-1849-4f24-b89a-5b969fcc9f1a" />

I am open to suggestions for improving the codebase.

IMPORTANT ----> Study and verify against the SourceCode every task in order to ensure that all features and funcionalities incorporated in the EA are a perfectly cloned.

IMPORTANT ----> MQL5 development environment is ready! The following script has been uploaded in this environment. Ensure that code passed on is error/warning-free. 

#!/bin/bash
# Ultra Simple MQL5 Setup for Codex - No Docker, No Wine
echo "🚀 Setting up lightweight MQL5 development tools..."

# Create workspace
mkdir -p ~/mql5_workspace
cd ~/mql5_workspace

# Create comprehensive syntax checker
cat > /usr/local/bin/mql5-check-syntax << 'EOF'
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Usage: mql5-check-syntax <file.mq5>"
    exit 1
fi

FILE="$1"
if [ ! -f "$FILE" ]; then
    echo "❌ File not found: $FILE"
    exit 1
fi

echo "🔍 MQL5 Syntax Analysis: $(basename "$FILE")"
echo "========================================"

ERRORS=0
WARNINGS=0

# File stats
LINES=$(wc -l < "$FILE")
SIZE=$(stat -c%s "$FILE")
echo "📊 File: $LINES lines, $SIZE bytes"

# Bracket/Parenthesis balance
OPEN_BRACES=$(grep -o "{" "$FILE" | wc -l)
CLOSE_BRACES=$(grep -o "}" "$FILE" | wc -l)
OPEN_PARENS=$(grep -o "(" "$FILE" | wc -l)
CLOSE_PARENS=$(grep -o ")" "$FILE" | wc -l)

if [ "$OPEN_BRACES" -eq "$CLOSE_BRACES" ]; then
    echo "✅ Braces balanced ($OPEN_BRACES pairs)"
else
    echo "❌ Brace mismatch: $OPEN_BRACES open, $CLOSE_BRACES close"
    ERRORS=$((ERRORS + 1))
fi

if [ "$OPEN_PARENS" -eq "$CLOSE_PARENS" ]; then
    echo "✅ Parentheses balanced ($OPEN_PARENS pairs)"
else
    echo "❌ Parentheses mismatch: $OPEN_PARENS open, $CLOSE_PARENS close"
    ERRORS=$((ERRORS + 1))
fi

# MQL5 structure
if grep -q "OnInit\|OnTick\|OnStart\|OnDeinit\|OnCalculate" "$FILE"; then
    echo "✅ Contains MQL5 event functions"
else
    echo "⚠️  No MQL5 event functions found"
    WARNINGS=$((WARNINGS + 1))
fi

# Properties
if grep -q "#property" "$FILE"; then
    PROP_COUNT=$(grep -c "#property" "$FILE")
    echo "✅ Contains $PROP_COUNT property directives"
else
    echo "⚠️  No property directives"
    WARNINGS=$((WARNINGS + 1))
fi

# Common syntax issues
if grep -q ";;" "$FILE"; then
    echo "⚠️  Double semicolons found"
    WARNINGS=$((WARNINGS + 1))
fi

if grep -q "=" "$FILE" | grep -v "==" | grep -v "!=" | grep -v ">=" | grep -v "<=" | head -1 | grep -q "[^;]$"; then
    echo "⚠️  Possible missing semicolons detected"
    WARNINGS=$((WARNINGS + 1))
fi

# Summary
echo ""
echo "📋 Analysis Results:"
echo "   Errors: $ERRORS"
echo "   Warnings: $WARNINGS"

if [ "$ERRORS" -eq 0 ]; then
    echo "✅ Syntax check PASSED"
    return 0
else
    echo "❌ Syntax issues found"
    return 1
fi
EOF

# Create MQL5 compiler (simulation)
cat > /usr/local/bin/mql5-compile << 'EOF'
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Usage: mql5-compile <file.mq5>"
    exit 1
fi

FILE="$1"
echo "🔨 MQL5 Compilation Simulation: $(basename "$FILE")"
echo "============================================="

# Run syntax check first
if mql5-check-syntax "$FILE"; then
    echo ""
    echo "🎯 Syntax validation passed!"
    echo "💡 Note: This is syntax validation only."
    echo "   For full compilation, MetaTrader 5 platform is required."
    echo "✅ Code appears ready for compilation"
    return 0
else
    echo ""
    echo "❌ Syntax issues detected"
    echo "   Fix these issues before attempting compilation"
    return 1
fi
EOF

# Create code analyzer
cat > /usr/local/bin/mql5-analyze << 'EOF'
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Usage: mql5-analyze <file.mq5>"
    exit 1
fi

FILE="$1"
echo "🔬 MQL5 Code Analysis: $(basename "$FILE")"
echo "======================================"

echo "📊 Functions Found:"
grep -n "^[a-zA-Z_][a-zA-Z0-9_]*.*(" "$FILE" | head -10

echo ""
echo "⚙️  Input Parameters:"
grep -n "^input " "$FILE" || echo "   None found"

echo ""
echo "🔗 Include Files:"
grep -n "^#include" "$FILE" || echo "   None found"

echo ""
echo "📋 Properties:"
grep -n "^#property" "$FILE" || echo "   None found"

echo ""
echo "🎯 Trading Functions:"
grep -n "OrderSend\|Buy\|Sell\|PositionOpen\|PositionClose" "$FILE" || echo "   None found"

echo ""
echo "📈 Technical Indicators:"
grep -n "iMA\|iRSI\|iMACD\|iBands\|iStochastic\|iCCI\|iADX" "$FILE" || echo "   None found"

echo ""
echo "🔍 Run syntax check for detailed validation:"
echo "   mql5-check-syntax $(basename "$FILE")"
EOF

# Create environment status
cat > /usr/local/bin/mql5-check << 'EOF'
#!/bin/bash
echo "🔍 MQL5 Development Environment"
echo "=============================="
echo "✅ Syntax checker: Available"
echo "✅ Code analyzer: Available"
echo "✅ Compilation simulation: Available"
echo "⚠️  Full compilation: Requires MetaTrader 5"
echo ""
echo "📚 Available Commands:"
echo "  mql5-check-syntax <file.mq5>  - Validate MQL5 syntax"
echo "  mql5-compile <file.mq5>       - Simulate compilation"
echo "  mql5-analyze <file.mq5>       - Analyze code structure"
echo "  mql5-check                    - Show this status"
echo ""
echo "💡 This environment provides syntax validation and code analysis."
echo "   For full compilation, use MetaTrader 5 platform or GitHub Codespaces."
EOF

# Make scripts executable
sudo chmod +x /usr/local/bin/mql5-*

echo ""
echo "✅ Lightweight MQL5 Environment Ready!"
echo "======================================"
echo ""
echo "🎯 Perfect for AI-assisted MQL5 development!"
echo "📁 Workspace: ~/mql5_workspace"
echo ""
echo "Test with: mql5-check"

## **What Works:**

- ✅ **Template creation** - Generate EA, Script, Indicator templates
- ✅ **Syntax validation** - Check for basic errors, bracket balance, etc.
- ✅ **File analysis** - Structure validation, function detection
- ✅ **Development workspace** - Organized file management

**You are now able to:**
1. 📝 Write the MQL5 code
2. 💾 Save it to a file  
3. 🔍 Check syntax automatically
4. 🛠️ Fix any issues found
5. ✅ Confirm the code is valid
