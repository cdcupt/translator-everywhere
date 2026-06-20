#!/usr/bin/env bash
# install.sh — put `fy` on your PATH and register the macOS "翻译 (fy)" Quick Action.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${FY_BIN_DIR:-$HOME/.local/bin}"
SERVICES_DIR="$HOME/Library/Services"
WORKFLOWS=("Translate with fy (AI).workflow" "Translate with fy (Google).workflow")

echo "fy: installing from $REPO_DIR"

# 1) symlink the CLI onto PATH
mkdir -p "$BIN_DIR"
ln -sf "$REPO_DIR/fy" "$BIN_DIR/fy"
echo "  • linked  $BIN_DIR/fy -> $REPO_DIR/fy"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  ! $BIN_DIR is not on your PATH — add:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# 2) install the Quick Actions (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
  mkdir -p "$SERVICES_DIR"
  # remove the old single-engine bundle from earlier versions, if present
  rm -rf "$SERVICES_DIR/Translate with fy.workflow"
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
  fy "I have to paste them into Google Translate."   # inline EN -> ZH (AI)
  fy 我的母语是中文                                    # inline ZH -> EN (auto-detect)
  fy -g hello                                         # free Google engine
  fy -e ubiquitous                                    # AI + pinyin / usage note
  fy                                                  # translate the clipboard
  fy -i                                               # interactive REPL

System-wide (your "two-finger tap"):
  Select text, two-finger-tap (right-click) → Services → choose one:
    "翻译 (AI)"      — high-quality OpenAI translation
    "翻译 (Google)"  — free Google Translate
  The result shows in a dialog and is copied to your clipboard.

Optional — give either one a keyboard shortcut:
  System Settings → Keyboard → Keyboard Shortcuts… → Services → Text →
  "翻译 (AI)" / "翻译 (Google)", then assign a hotkey (e.g. ⌃⌥T).
EOF
