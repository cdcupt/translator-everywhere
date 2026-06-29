# Translator Everywhere — Feedback Backlog

The durable, prioritized record of user feedback on the shipped app and what we did about it. Front door for maintenance work: each item is routed to **bpl** (small fix), **sdd_pipeline** (substantial feature), or **defer / wontfix**. Triage only — the delivery skills do the building.

- **Source of truth:** this file. Reference it by path; don't re-paste it into context.
- **Per-project:** this backlog is Translator Everywhere's only.
- Long raw reports (if any) live under `feedback/raw/<id>.md`.

_Last triaged: 2026-06-29. Source of these items: Erik's own field-notes/observations (a shipped-app feedback source like any other)._

## Prioritized backlog

Ordered by impact (severity × count). Open items first.

| id | title | source | count | severity | type | route | status | notes |
|----|-------|--------|:-:|----------|------|-------|--------|-------|
| `fb-2026-06-29-recognized-selection-deselect` | Selected Recognized/Translation text won't deselect on an outside click | field-note | 1 | friction | ux | `bpl` | **shipped (merged to main, PR #40; rides next release)** | Repro: in the result panel, select the "Recognized" text → click empty panel area/chrome → selection stays highlighted; only clicking the *other* selectable text view clears it. Root cause: `ResultPanel.scrollableText` builds selectable `NSTextView`s but nothing resigns first responder / clears `selectedRange` on a background click (`ResultPanel.swift` ~570–593). Fix: clear selection on outside click (content-view `mouseDown`/click gesture → `makeFirstResponder(nil)` + reset ranges). Raw + screenshot: `feedback/raw/fb-2026-06-29-recognized-selection-deselect.{md,png}`. |
| `fb-2026-06-27-prefs-first-render` | Preferences shows the wrong page on first open (recovers after switching tabs) | field-note | 1 | broken | bug | `bpl` | **shipped (v1.2.2)** | Repro: open Preferences fresh → General is highlighted but the wrong tab's content renders; switch to another tab and back to recover. Root cause: `PreferencesWindowController` hosts the SwiftUI `TabView` with `sizingOptions = []` but **no explicit content size**, so the first tab never gets a correct first layout (sibling `NotebookWindowController` sets an explicit size and is fine). Fix: force layout + `setContentSize(fittingSize)` (500×460 fallback; keeps `sizingOptions=[]` so no crash regression) — PR #37, Codex PASS. Shipped in **v1.2.2** (PR #38). ⚠️ First-render is window behavior, not headlessly verifiable — shipped on the root-cause + working-sibling evidence; PM to confirm visually via the Sparkle update. |
| `fb-2026-06-27-capture-dead-air` | No feedback during capture→translate; show the panel immediately | field-note | 1 | friction | ux | `bpl` | **shipped** | After drag-select, OCR + the (now network-bound) translate ran with no UI — dead air. Fix: the result panel appears instantly with a spinner + "Translating…", fills recognized text after OCR, then the result in place. Shipped in **v1.2.1** (PR #33). |
| `fb-2026-06-13-notebook-byo-ai` | Let users summarize saved vocab with their own AI (ChatGPT) | field-note | 1 | request | feature | `bpl` | **shipped (partial)** | Notebook "Ask your AI" hand-off — Copy study prompt / Open ChatGPT (PR #27). The honest export path; verified that no app can drive a user's actual ChatGPT account/custom GPT. **Deferred sub-items** (see below): in-app BYOK summary polish, Codex-CLI local handoff, app-as-MCP-server. |

## Deferred (real, not now)

Lower-impact or needs-more-signal. Promote when warranted.

| id | title | route | why deferred |
|----|-------|-------|--------------|
| `fb-defer-byoai-inapp` | In-app BYOK summary polish (model picker + base-URL) on top of the existing OpenAI summarize | `bpl` | Export hand-off covers the core ask; in-app result is a "both" nicety. |
| `fb-defer-byoai-codex-mcp` | Codex-CLI local handoff + app-as-MCP-server for notebook summary | `sdd_pipeline` | Build only on real demand — niche; the only paths that ride a ChatGPT *plan* and return in-app. |

## Engineering follow-ups (not user feedback — tracked for completeness)

From the multi-language final review; none user-reported, none blocking. Route `bpl` when picked up: app offline-Han detect fast-path (accepted-latency tradeoff); `OpenAIEngine` retry-on-401/429; `te` temp-file `mktemp` + `TE_CONFIG`/`TE_KEY_FILE` sourcing hardening; Swift-6 `Sendable` prep; retranslate `Task` cancellation on rapid picks.

## Status legend
`new` → `routed` → `in-progress` → `shipped` → `closed`. severity: crash / broken / friction / cosmetic / request. type: bug / feature / ux / perf / copy / question.
