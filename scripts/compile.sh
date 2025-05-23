#!/usr/bin/env bash
set -euo pipefail

# ——— configuration ————————————————————————————————————————————
CROSSOVER_APP="/Applications/CrossOver.app"     # CrossOver must be here
BOTTLE="MT5"
MT5_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
INSTALLER_DIR="$BASE_DIR/build/installers"
LOG_DIR="$BASE_DIR/build/logs"
MQ5_DIR="$BASE_DIR/Experts"
# ————————————————————————————————————————————————————————————————

mkdir -p "$INSTALLER_DIR" "$LOG_DIR"

# 1) verify CrossOver exists
if [ ! -d "$CROSSOVER_APP" ]; then
  echo "‼️  CrossOver not found in /Applications. Install it first." >&2
  exit 1
fi

# 2) fetch MT5 installer if absent
if [ ! -f "$INSTALLER_DIR/mt5setup.exe" ]; then
  echo "⬇️  Downloading official MT5 installer…"
  curl -L "$MT5_URL" -o "$INSTALLER_DIR/mt5setup.exe"
fi

CX="$CROSSOVER_APP/Contents/Resources/start_crossover"
CXRUN="$CROSSOVER_APP/Contents/Resources/cxrun"

# 3) create bottle on first run
if ! "$CX" --bottle "$BOTTLE" --list 2>/dev/null | grep -q "$BOTTLE"; then
  echo "🍾  Creating bottle '$BOTTLE' (silent install of MT5)…"
  "$CX" --bottle "$BOTTLE" --install "$INSTALLER_DIR/mt5setup.exe" --silent
fi

# 4) compile every .mq5 in Experts/
shopt -s nullglob
for src in "$MQ5_DIR"/*.mq5; do
  base=$(basename "$src" .mq5)
  echo "🛠  Compiling $base.mq5 …"
  "$CXRUN" --bottle "$BOTTLE" metaeditor.exe /compile:"$src" /log:"$LOG_DIR/$base.log"
done

echo "✅  Done. Check Experts/*.ex5 for outputs."
