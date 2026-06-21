#!/usr/bin/env bash
# install.sh — put `te` on your PATH and register the macOS "翻译 (te)" Quick Action.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${TE_BIN_DIR:-$HOME/.local/bin}"
SERVICES_DIR="$HOME/Library/Services"
WORKFLOWS=("Translate with te (AI).workflow" "Translate with te (Google).workflow" "Translate screen region (te).workflow")

echo "te: installing from $REPO_DIR"

# 1) symlink the CLI onto PATH
mkdir -p "$BIN_DIR"
ln -sf "$REPO_DIR/te" "$BIN_DIR/te"
echo "  • linked  $BIN_DIR/te -> $REPO_DIR/te"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  ! $BIN_DIR is not on your PATH — add:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# 2) install the Quick Actions (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
  mkdir -p "$SERVICES_DIR"
  # remove bundles from earlier versions, if present (single-engine, and the
  # pre-rename `fy`-named two-engine bundles) so re-installs migrate cleanly
  rm -rf "$SERVICES_DIR/Translate with fy.workflow" \
         "$SERVICES_DIR/Translate with te.workflow" \
         "$SERVICES_DIR/Translate with fy (AI).workflow" \
         "$SERVICES_DIR/Translate with fy (Google).workflow"
  for wf in "${WORKFLOWS[@]}"; do
    rm -rf "$SERVICES_DIR/$wf"
    cp -R "$REPO_DIR/quick-action/$wf" "$SERVICES_DIR/$wf"
    echo "  • installed Quick Action: $wf"
  done
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
  echo "  • flushed Services cache"
fi

cat <<'EOF'

Done. Try it:
  te "I have to paste them into Google Translate."   # inline EN -> ZH (AI)
  te 我的母语是中文                                    # inline ZH -> EN (auto-detect)
  te -g hello                                         # free Google engine
  te -e ubiquitous                                    # AI + pinyin / usage note
  te                                                  # translate the clipboard
  te -i                                               # interactive REPL
  te -c                                               # drag a screen region -> OCR + translate (AI)

System-wide (your "two-finger tap"):
  Select text, two-finger-tap (right-click) → Services → choose one:
    "翻译 (AI)"      — high-quality OpenAI translation
    "翻译 (Google)"  — free Google Translate
  Or, to translate anything on screen (a video frame, an image, a PDF):
    "翻译 (截图)"    — drag a screen region; it OCRs + translates it
  The result shows in a dialog and is copied to your clipboard.

Recommended — give the screen-region action a keyboard shortcut:
  System Settings → Keyboard → Keyboard Shortcuts… → Services → General →
  "翻译 (截图)", then assign a hotkey (e.g. ⌃⌥Y). The text actions live under
  Services → Text and can take a hotkey there too (e.g. ⌃⌥T).
EOF
