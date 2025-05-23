#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  compile.sh – build every .mq5 in Experts/ via CrossOver + MetaEditor
# ---------------------------------------------------------------------
set -euo pipefail

# ─── basic config ─────────────────────────────────────────────────────
CROSSOVER_APP="/Applications/CrossOver.app"           # adjust if you moved it
BOTTLE="MT5"                                          # CrossOver bottle name
MT5_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

# ─── derived paths (do not edit) ──────────────────────────────────────
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
INSTALLER_DIR="$BASE_DIR/build/installers"
LOG_DIR="$BASE_DIR/build/logs"
MQ5_DIR="$BASE_DIR/Experts"

mkdir -p "$INSTALLER_DIR" "$LOG_DIR"

# ─── sanity-check CrossOver install ───────────────────────────────────
if [ ! -d "$CROSSOVER_APP" ]; then
  echo "❌  CrossOver not found at '$CROSSOVER_APP' – install it first." >&2
  exit 1
fi

# ─── download MetaTrader 5 installer (first run only) ─────────────────
if [ ! -f "$INSTALLER_DIR/mt5setup.exe" ]; then
  echo "⬇️   Fetching official MT5 installer…"
  curl -L "$MT5_URL" -o "$INSTALLER_DIR/mt5setup.exe"
fi

# ─── locate CrossOver CLI helper (cxstart) ────────────────────────────
if [ -x "$CROSSOVER_APP/Contents/SharedSupport/CrossOver/CrossOver-Hosted Application/cxstart" ]; then
  CX="$CROSSOVER_APP/Contents/SharedSupport/CrossOver/CrossOver-Hosted Application/cxstart"
elif [ -x "$CROSSOVER_APP/Contents/SharedSupport/CrossOver/bin/cxstart" ]; then
  CX="$CROSSOVER_APP/Contents/SharedSupport/CrossOver/bin/cxstart"
elif [ -x "$CROSSOVER_APP/Contents/Resources/start_crossover" ]; then
  CX="$CROSSOVER_APP/Contents/Resources/start_crossover"
else
  echo "❌  Cannot find 'cxstart' (CrossOver command-line helper)." >&2
  exit 1
fi
CXRUN="$CX"      # newer CrossOver uses the same binary for run/install

# ─── create bottle & install MT5 if absent ────────────────────────────
BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
if [ ! -d "$BOTTLE_DIR" ]; then
  echo "🍾  Creating bottle '$BOTTLE' & installing MT5 (silent)…"
  "$CX" --bottle "$BOTTLE" --install "$INSTALLER_DIR/mt5setup.exe" --silent
fi

# ─── compile every .mq5 file ──────────────────────────────────────────
shopt -s nullglob
srcs=("$MQ5_DIR"/*.mq5)
if [ ${#srcs[@]} -eq 0 ]; then
  echo "⚠️  No .mq5 files found in $MQ5_DIR" >&2
  exit 1
fi

for src in "${srcs[@]}"; do
  base=$(basename "$src" .mq5)
  echo "🛠   Compiling ${base}.mq5 …"
  "$CXRUN" --bottle "$BOTTLE" metaeditor.exe /compile:"$src" /log:"$LOG_DIR/${base}.log"
done

echo "✅  All builds complete — check *.ex5 files in Experts/."
