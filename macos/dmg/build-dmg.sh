#!/usr/bin/env bash
#
# build-dmg.sh — build a styled installer .dmg for Translator Everywhere.
#
#   ./build-dmg.sh <path-to-.app> <output.dmg>
#
# Produces a DMG whose Finder window has:
#   • the brand background image (dmg/background.png, retina-aware)
#   • the .app on the left, an /Applications symlink on the right
#   • a "drag to install →" arrow already drawn into the background
#   • 120 px icons, no toolbar / no sidebar, a fixed window size
#
# Two backends, picked automatically:
#   1. `create-dmg` (npm: `npm i -g create-dmg`, or brew `create-dmg`) if on PATH
#      — fully scriptable, no GUI Finder session needed (preferred for CI).
#   2. AppleScript + Finder + hdiutil fallback — needs a logged-in GUI session
#      so Finder can apply icon positions & background. In a headless/SSH-only
#      session the styling step may be skipped; the script still emits a valid,
#      compressed (UDZO) DMG with the app + Applications symlink, just without
#      the custom icon layout. See the note printed at the end.
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
BACKGROUND="$SCRIPT_DIR/background.png"
VOL_NAME="Translator Everywhere"
APP_NAME="$(basename "$APP_PATH")"

# Window geometry (must match the icon coordinates baked into background.png).
WIN_X=200; WIN_Y=120
WIN_W=660; WIN_H=420
ICON_SIZE=120
APP_ICON_X=180;  APP_ICON_Y=215    # left slot
APPS_ICON_X=480; APPS_ICON_Y=215   # right slot (under the arrow)

mkdir -p "$(dirname "$OUT_DMG")"
rm -f "$OUT_DMG"

# =========================================================================
# Backend 1 — create-dmg (preferred, headless-friendly)
# =========================================================================
if command -v create-dmg >/dev/null 2>&1; then
  echo "==> Using create-dmg"
  # The Sindre Sorhus npm `create-dmg` auto-styles; the Andrey Tarantsov
  # bash `create-dmg` takes explicit flags. Detect which one we have.
  if create-dmg --help 2>&1 | grep -q -- '--volname'; then
    # bash create-dmg (brew "create-dmg")
    create-dmg \
      --volname "$VOL_NAME" \
      --background "$BACKGROUND" \
      --window-pos "$WIN_X" "$WIN_Y" \
      --window-size "$WIN_W" "$WIN_H" \
      --icon-size "$ICON_SIZE" \
      --icon "$APP_NAME" "$APP_ICON_X" "$APP_ICON_Y" \
      --app-drop-link "$APPS_ICON_X" "$APPS_ICON_Y" \
      --no-internet-enable \
      "$OUT_DMG" "$APP_PATH"
    echo "==> Done: $OUT_DMG"
    exit 0
  else
    # npm create-dmg (less configurable — emits next to the app); then move it.
    TMP_OUT_DIR="$(mktemp -d)"
    ( cd "$TMP_OUT_DIR" && create-dmg "$APP_PATH" >/dev/null )
    FOUND="$(find "$TMP_OUT_DIR" -name '*.dmg' | head -1)"
    mv "$FOUND" "$OUT_DMG"
    rm -rf "$TMP_OUT_DIR"
    echo "==> Done (npm create-dmg, default style): $OUT_DMG"
    exit 0
  fi
fi

# =========================================================================
# Backend 2 — AppleScript + Finder + hdiutil (fallback)
# =========================================================================
echo "==> create-dmg not found; using hdiutil + Finder AppleScript fallback"

STAGING="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
trap 'rm -rf "$STAGING"; rm -f "$RW_DMG"' EXIT

# Stage contents: the app + a hidden .background dir holding the image.
cp -R "$APP_PATH" "$STAGING/$APP_NAME"
mkdir "$STAGING/.background"
cp "$BACKGROUND" "$STAGING/.background/background.png"
ln -s /Applications "$STAGING/Applications"

# Size the read/write image to fit the payload + slack.
SIZE_KB=$(du -sk "$STAGING" | awk '{print $1}')
SIZE_MB=$(( SIZE_KB / 1024 + 60 ))

echo "==> Creating read/write image (~${SIZE_MB} MB)"
hdiutil create \
  -srcfolder "$STAGING" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "$RW_DMG" >/dev/null

echo "==> Mounting"
MOUNT_DIR="/Volumes/$VOL_NAME"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | grep -E '^/dev/' | grep "Apple_HFS" | awk '{print $1}')"
[[ -z "$DEV" ]] && DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 2

# Try to style via Finder. This REQUIRES a GUI session; in headless/SSH it
# fails gracefully and we just ship the unstyled-but-valid DMG.
STYLED=0
if osascript - "$VOL_NAME" "$APP_NAME" \
      "$WIN_X" "$WIN_Y" "$WIN_W" "$WIN_H" "$ICON_SIZE" \
      "$APP_ICON_X" "$APP_ICON_Y" "$APPS_ICON_X" "$APPS_ICON_Y" <<'APPLESCRIPT' 2>/dev/null
on run argv
  set volName    to item 1 of argv
  set appName    to item 2 of argv
  set winX       to (item 3 of argv) as integer
  set winY       to (item 4 of argv) as integer
  set winW       to (item 5 of argv) as integer
  set winH       to (item 6 of argv) as integer
  set iconSize   to (item 7 of argv) as integer
  set appX       to (item 8 of argv) as integer
  set appY       to (item 9 of argv) as integer
  set appsX      to (item 10 of argv) as integer
  set appsY      to (item 11 of argv) as integer

  tell application "Finder"
    tell disk volName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {winX, winY, winX + winW, winY + winH}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to iconSize
      set background picture of viewOptions to file ".background:background.png"
      set position of item appName of container window to {appX, appY}
      set position of item "Applications" of container window to {appsX, appsY}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
then
  STYLED=1
  echo "==> Finder styling applied"
else
  echo "==> WARNING: Finder styling step failed (likely no GUI session)."
  echo "    The DMG will still be valid but without custom icon layout/background."
fi

sync
# Bless not required; just detach.
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
sleep 1

echo "==> Converting to compressed UDZO"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null

echo "==> Done: $OUT_DMG"
if [[ "$STYLED" -eq 0 ]]; then
  echo ""
  echo "NOTE: custom window styling (icon positions + background) was NOT applied"
  echo "      because Finder needs a logged-in GUI session. Re-run this script from"
  echo "      a desktop session (or install create-dmg: 'npm i -g create-dmg') to get"
  echo "      the fully styled drag-to-install layout. The background image and the"
  echo "      coordinates are already wired in — only the Finder apply step is gated."
fi
