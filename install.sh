#!/usr/bin/env bash
# install.sh — put `fy` on your PATH and register the macOS "翻译 (fy)" Quick Action.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${FY_BIN_DIR:-$HOME/.local/bin}"
SERVICES_DIR="$HOME/Library/Services"
WORKFLOW="Translate with fy.workflow"

echo "fy: installing from $REPO_DIR"

# 1) symlink the CLI onto PATH
mkdir -p "$BIN_DIR"
ln -sf "$REPO_DIR/fy" "$BIN_DIR/fy"
echo "  • linked  $BIN_DIR/fy -> $REPO_DIR/fy"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  ! $BIN_DIR is not on your PATH — add:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# 2) install the Quick Action (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
  mkdir -p "$SERVICES_DIR"
  rm -rf "$SERVICES_DIR/$WORKFLOW"
  cp -R "$REPO_DIR/quick-action/$WORKFLOW" "$SERVICES_DIR/$WORKFLOW"
  echo "  • installed Quick Action: $SERVICES_DIR/$WORKFLOW"
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
  echo "  • flushed Services cache"
fi

cat <<'EOF'

Done. Try it:
  fy "I have to paste them into Google Translate."   # inline EN -> ZH
  fy 我的母语是中文                                    # inline ZH -> EN (auto-detect)
  fy                                                  # translate the clipboard
  fy -e ubiquitous                                    # + pinyin / usage note
  fy -i                                               # interactive REPL

System-wide (your "two-finger tap"):
  Select any text, two-finger-tap (right-click) → Services → "翻译 (fy)".
  It shows the translation in a dialog and copies it to your clipboard.

Optional — give it a keyboard shortcut:
  System Settings → Keyboard → Keyboard Shortcuts… → Services → Text →
  "翻译 (fy)", then assign a hotkey (e.g. ⌃⌥T).
EOF
