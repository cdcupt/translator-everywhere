# Feature Coverage Checklist — Contextual Selection Translate (beta pass)

Worklist for the feature-coverage beta tester. Every row gets an explicit
PASS / FAIL / BLOCKED verdict with a one-line note + screenshot path.
BLOCKED = could not reach/exercise in the test environment (say why), never a silent skip.

## New feature — selection → contextual translation

| # | Feature | Trace |
|---|---------|-------|
| N1 | Select a single word in the Recognized pane → mini dictionary card: contextual translation (prominent), POS chip, in-context sense line, example pair ("Messi scored the final goal." / "scored" → football sense) | AC-1, FR-1..3 |
| N2 | Select a short phrase (≤ 4 words, e.g. "the final goal") → phrase card with contextual translation | AC-2, FR-3 |
| N3 | Select a long span (> 4 words / whole sentence) → plain contextual translation block, no POS/example rows | AC-3, FR-4 |
| N4 | zh→EN capture: select unspaced Chinese characters (≤ 8) → card works | AC-9 |
| N5 | Google-only (no AI key): selection → context-free translation with "Context-free · Google" chip + dashed border; no error | AC-4, FR-5 |
| N6 | Loading skeleton shows while the request is pending (shimmer; static if Reduce Motion is on) | DESIGN §02 |
| N7 | Dismissal: Esc, click-outside, language-bar retranslate, and a new capture each dismiss the card; no stale card over new content | AC-5, FR-6 |
| N8 | Rapid re-selection (select A then immediately B): only B's result renders | AC-7 |
| N9 | ⌘S while card active saves span → source, contextual translation → translation to Notebook; header Save reclaims ⌘S after dismissal | AC-6, FR-7, D-1 |
| N10 | Failure path (timeout/network/malformed): quiet inline "Couldn't translate the selection · Try again" row — never a dialog; Try again re-fires the same span | DESIGN §02 |
| N11 | Re-selecting the identical span is a no-op (no second request/billing) | TECH F-2 |
| N12 | Selecting text in the Translation pane does NOT trigger a card (out of scope surface) | PRD scope-out |

## Regression surface — must behave as on main

| # | Feature | Trace |
|---|---------|-------|
| R1 | ⌃⌥Y zone capture → OCR → whole-text translation renders in the panel | AC-8 |
| R2 | Language bar: changing from/to retranslates the whole capture | AC-8 |
| R3 | Read-aloud speaker buttons on both panes read the full pane text | AC-8, D-3 |
| R4 | IPA phonetics line under English panes | AC-8 |
| R5 | Save to Notebook (no card active) saves the whole capture; "saved" confirmation | AC-8 |
| R6 | Preferences window opens; engine preference (AI / free) switch takes effect | AC-8 |
| R7 | Auto language detection ("Detected: …") still shown | AC-8 |
| R8 | App lives in the menu bar (LSUIElement); panel appears/hides normally across captures | AC-8 |
