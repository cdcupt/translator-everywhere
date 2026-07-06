#!/usr/bin/env bash
#
# gen-ipa-dict.sh — build the bundled English IPA pronunciation dictionary.
#
#   ./scripts/gen-ipa-dict.sh [out.txt]
#   (default out: macos/Sources/Resources/english-ipa.txt)
#
# Source: open-dict-data/ipa-dict `en_US.txt` (MIT, © 2016 dohliam) — a curated
# word→IPA list with General-American stress marks. See macos/Sources/Resources/
# THIRD-PARTY.md for attribution.
#
# Preprocessing (deterministic):
#   • keep only the FIRST pronunciation (drop the ", /alt/" variants),
#   • strip the surrounding /slashes/,
#   • normalize the dark-l allophone ɫ → l (not phonemic; reads cleaner for
#     learners), and
#   • lowercase the headword (the lookup key).
# Output is `word<TAB>ipa`, one entry per line, sorted + de-duplicated.
#
set -euo pipefail

# Pinned to an immutable commit (not `master`) so regeneration is reproducible.
SRC_REF="43c3570eb3553bdd19fccd2bd0091534889af023"
SRC_URL="https://raw.githubusercontent.com/open-dict-data/ipa-dict/${SRC_REF}/data/en_US.txt"
OUT="${1:-macos/Sources/Resources/english-ipa.txt}"
MIN_ENTRIES=100000   # sanity floor; the current dict has ~125,900 entries

TMP="$(mktemp)"
STAGE="$(mktemp)"
trap 'rm -f "$TMP" "$STAGE"' EXIT

echo "==> fetching $SRC_URL" >&2
curl -fsSL "$SRC_URL" -o "$TMP"

# -CSD: decode/encode I/O as UTF-8 so the IPA glyph substitution is correct.
# Write to a staging file first; only overwrite the committed dictionary once the
# result clears the sanity floor, so a truncated/failed fetch can't clobber it.
perl -CSD -F'\t' -ane '
    next unless @F >= 2;
    my $word = lc $F[0];
    my ($ipa) = $F[1] =~ m{/([^/]*)/};   # first /.../ pronunciation
    next unless defined $ipa;
    $ipa =~ s/\x{026B}/l/g;               # ɫ (velarized l) → l
    print "$word\t$ipa\n" if length($word) && length($ipa);
' "$TMP" | LC_ALL=C sort -u > "$STAGE"

COUNT="$(wc -l < "$STAGE" | tr -d ' ')"
if [[ "$COUNT" -lt "$MIN_ENTRIES" ]]; then
  echo "error: only $COUNT entries (< $MIN_ENTRIES) — refusing to overwrite $OUT" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
mv "$STAGE" "$OUT"
echo "==> wrote $COUNT entries to $OUT" >&2
