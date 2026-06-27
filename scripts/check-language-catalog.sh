#!/usr/bin/env bash
# Drift guard: regenerate LanguageCatalog+Generated.swift from languages.tsv and
# fail if the committed file is out of sync. Run locally or from CI.
#
#   scripts/check-language-catalog.sh
#
# (CI wiring under .github/workflows/ is owned by the Coordinator, not this script.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED="macos/Sources/Translate/LanguageCatalog+Generated.swift"

swift "$ROOT/scripts/gen-language-catalog.swift"

if ! git -C "$ROOT" diff --exit-code -- "$GENERATED"; then
  echo "" >&2
  echo "error: $GENERATED is out of sync with languages.tsv." >&2
  echo "       Run 'swift scripts/gen-language-catalog.swift' and commit the result." >&2
  exit 1
fi

echo "language catalog is in sync with languages.tsv"
