#!/usr/bin/env bash
#
# build-dmg.sh — build a styled installer .dmg for Translator Everywhere.
#
#   ./build-dmg.sh <path-to-.app> <output.dmg>
#
# Produces a compressed (UDZO) DMG whose Finder window has:
#   • a clean solid warm canvas (no picture — see note below)
#   • the .app on the left, an /Applications symlink on the right
#   • 120 px icons, no toolbar / no sidebar, a fixed 660×420 window
#
# Backend: `dmgbuild` (https://pypi.org/project/dmgbuild). It writes the
# .DS_Store window layout DIRECTLY, so the styling is produced HEADLESSLY and
# DETERMINISTICALLY — no Finder GUI session, no AppleScript, no race.
#
# Why a solid color instead of a brand background image: on macOS 26 (Darwin 25)
# Finder will NOT render a DMG *picture* background at all — the AppleScript
# `set background picture` path fails (-10006) and a .DS_Store backgroundImageAlias
# never resolves (the window just shows white). Finder DOES honor a solid
# background color, which is also the clean look we want. The color + layout live
# in dmg/dmgbuild-settings.py.
#
# Install dmgbuild once:  python3 -m pip install --user dmgbuild
#
set -euo pipefail

# ----- args ---------------------------------------------------------------
APP_PATH="${1:-}"
OUT_DMG="${2:-}"
if [[ -z "$APP_PATH" || -z "$OUT_DMG" ]]; then
  echo "usage: $0 <path-to-.app> <output.dmg>" >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found: $APP_PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$SCRIPT_DIR/dmgbuild-settings.py"
VOL_NAME="Translator Everywhere"

# ----- locate dmgbuild ----------------------------------------------------
DMGBUILD="$(command -v dmgbuild || true)"
if [[ -z "$DMGBUILD" ]]; then
  USER_BIN="$(python3 -m site --user-base 2>/dev/null)/bin"
  [[ -x "$USER_BIN/dmgbuild" ]] && DMGBUILD="$USER_BIN/dmgbuild"
fi
if [[ -z "$DMGBUILD" ]]; then
  echo "error: dmgbuild not found on PATH or in the Python user base." >&2
  echo "       install it with:  python3 -m pip install --user dmgbuild" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_DMG")"
rm -f "$OUT_DMG"

echo "==> Building DMG with dmgbuild"
echo "    app:    $APP_PATH"
echo "    out:    $OUT_DMG"
"$DMGBUILD" -s "$SETTINGS" -D app="$APP_PATH" "$VOL_NAME" "$OUT_DMG"

echo "==> Done: $OUT_DMG"
hdiutil imageinfo "$OUT_DMG" >/dev/null 2>&1 && echo "    (valid disk image)"
