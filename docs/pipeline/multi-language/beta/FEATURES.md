# Multi-Language — Full Feature List (beta coverage spine)

Every user-facing capability of the multi-language feature, across both surfaces. The beta coverage tester (Tester C) returns a PASS / FAIL / BLOCKED verdict for each ID. CLI rows are headlessly driveable; macOS GUI-interaction rows need screen-recording permission + real UI events → expected **BLOCKED — needs on-device** (PM verifies), still verifiable at the code/unit-test level.

## A. macOS app — translation core
- **A1** Auto source detection (Google-backed `SourceDetector`, works on both engines)
- **A2** From picker includes an "Auto-detect" row
- **A3** To picker selects the target language
- **A4** Searchable catalog of ~100+ languages (133) — filter by englishName/endonym/code/aliases
- **A5** "Recent & last-used" section pinned at top of the picker
- **A6** Swap ⇄ (promotes the detected source into From)
- **A7** Per-translation re-translate, in place (generation-token guarded; no out-of-order overwrite)
- **A8** Detected-source line ("Detected: <lang>") shown when From = Auto
- **A9** Engine badge (FREE / AI) on the result
- **A10** "via Google" note when AI can't serve a target or the AI call fails (runtime fallback)
- **A11** Same-language guard: Auto + detected == target + distinct secondary → routes to secondary (preserves EN⇄ZH flip)
- **A12** Last-used pair remembered across launches; sensible first-run default (Auto → 中文) — **S4**
- **A13** EN⇄ZH still behaves exactly as before (no regression) — **S5**

## B. macOS app — Preferences ▸ Languages tab
- **B1** Home target picker (bound to SettingsStore.homeTarget, default 中文)
- **B2** Secondary picker (bound to secondaryLanguage, default English)
- **B3** Read-only "Last used: From → To" line
- **B4** Tab registered as the 5th Preferences tab

## C. macOS app — notebook (regression surface)
- **C1** New notebook rows carry the real from/to BCP-47 languages — **S6**
- **C2** Existing rows untouched (no migration); export/sync tolerate mixed values
- **C3** Notebook Summarize / study list still works (pair-agnostic, unchanged)
- **C4** "Ask your AI" hand-off still works (unchanged)

## D. `te` CLI (parity surface) — **S7**
- **D1** `te -t <code> <text>` translates into an arbitrary target
- **D2** `te -f <code>` sets an explicit source; default `auto`
- **D3** `te -l [query]` lists / searches the shared catalog
- **D4** `te --detect <text>` prints only the detected source
- **D5** `~/.te/config` exports TE_FROM / TE_TO / TE_SECONDARY (sourced; flags override)
- **D6** Same-language guard: `echo 你好 | te` (TE_TO=zh-CN) still outputs English
- **D7** Quick actions inherit TE_TO (call `te` with no `-t`) + popup title note
- **D8** `te` resolves `languages.tsv` via the `$0` symlink (shared catalog, no app/CLI drift)

## E. Cross-cutting
- **E1** Single source of truth: `languages.tsv` drives both the Swift generated catalog and `te` (CI/local drift-guard)
- **E2** Privacy unchanged: translation goes direct to the engine, never through the sync server
- **E3** Ships clean: macOS app builds + full test suite green (149 tests) — **S8**

## Success-criteria map
S1 any↔any both engines both surfaces · S2 Auto detects + shows · S3 searchable picker usable at 100+ · S4 last-used remembered + default · S5 EN⇄ZH no-regression · S6 notebook + quick actions · S7 te parity · S8 ships clean.
