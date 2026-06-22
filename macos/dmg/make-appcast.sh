#!/usr/bin/env bash
#
# make-appcast.sh — produce a signed Sparkle appcast.xml for a release DMG.
#
#   ./make-appcast.sh <signed-or-stapled.dmg> <release-tag> [out-appcast.xml]
#   e.g. ./make-appcast.sh TranslatorEverywhere-1.1.0.dmg v1.1.0 appcast.xml
#
# The appcast's `<enclosure>` EdDSA signature is computed over the EXACT DMG
# bytes, so REGENERATE + re-upload the appcast whenever the served DMG changes —
# in particular AFTER stapling the notarization ticket into the DMG (stapling
# rewrites the file). The enclosure URL points at the GitHub release asset for
# <release-tag>, i.e. https://github.com/<repo>/releases/download/<tag>/<dmg-name>.
#
# Requires:
#   • the Sparkle EdDSA private key at ~/.translator-everywhere/sparkle_ed_private_key
#   • Sparkle's generate_appcast — from ~/.translator-everywhere/sparkle-tools/bin
#     or fetched on demand from the Sparkle GitHub release (needs `gh`).
#
set -euo pipefail

DMG="${1:?usage: make-appcast.sh <dmg> <release-tag> [out.xml]}"
TAG="${2:?release tag, e.g. v1.1.0}"
OUT="${3:-appcast.xml}"
REPO="cdcupt/translator-everywhere"
KEY="$HOME/.translator-everywhere/sparkle_ed_private_key"

[[ -f "$DMG" ]] || { echo "error: DMG not found: $DMG" >&2; exit 1; }
[[ -f "$KEY" ]] || { echo "error: missing EdDSA private key: $KEY" >&2; exit 1; }

# Locate generate_appcast (persisted copy preferred; else fetch the Sparkle dist).
GA="$HOME/.translator-everywhere/sparkle-tools/bin/generate_appcast"
if [[ ! -x "$GA" ]]; then
  echo "==> generate_appcast not found locally; fetching Sparkle tools" >&2
  command -v gh >/dev/null || { echo "error: need gh to fetch Sparkle" >&2; exit 1; }
  TMP_TOOLS="$(mktemp -d)"
  SPARKLE_TAG="$(gh release view --repo sparkle-project/Sparkle --json tagName --jq .tagName)"
  gh release download "$SPARKLE_TAG" --repo sparkle-project/Sparkle \
    --pattern "Sparkle-*.tar.xz" --dir "$TMP_TOOLS"
  tar -xf "$TMP_TOOLS"/Sparkle-*.tar.xz -C "$TMP_TOOLS"
  GA="$TMP_TOOLS/bin/generate_appcast"
fi

# generate_appcast scans a directory; stage just this DMG so the appcast has one item.
STAGE="$(mktemp -d)"
cp "$DMG" "$STAGE/"
"$GA" --ed-key-file "$KEY" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  "$STAGE" >&2

cp "$STAGE/appcast.xml" "$OUT"
echo "==> wrote $OUT (enclosure → $TAG/$(basename "$DMG"))" >&2
echo "$OUT"
