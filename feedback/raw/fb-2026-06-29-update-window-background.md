# fb-2026-06-29-update-window-background

- **Source:** field-note (Erik, in conversation)
- **Date:** 2026-06-29
- **Screenshot:** `./fb-2026-06-29-update-window-background.png`

## Verbatim report

> I found a little issue when I click the update button. The update window opens
> on the backend but not the frontend. Can you check it again and fix the problem?

("backend/frontend" = background/foreground.)

## Context

Clicking **Check for Updates…** correctly detects v1.2.4 (the Sparkle
"A new version of Translator Everywhere is available!" dialog shows 1.2.4 vs the
installed 1.2.1 — confirms update detection works). But the update window opens
**in the background**, behind other apps, instead of coming to the foreground.

## Root cause

Translator Everywhere is an `LSUIElement` menu-bar agent (no Dock icon), so it is
not the active app when Sparkle presents its update UI — and with no Dock icon
there's nothing to click to bring it forward. `AppDelegate` constructs
`SPUStandardUpdaterController(..., userDriverDelegate: nil)`, so nothing activates
the app when the update window/alert appears.

## Fix

Make `AppDelegate` conform to `SPUStandardUserDriverDelegate`, pass it as the
`userDriverDelegate`, and call `NSApp.activate(ignoringOtherApps: true)` in:
- `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)` — the
  update-available window (the screenshot), and
- `standardUserDriverWillShowModalAlert()` — modal alerts ("up to date", errors).
Also activate in the `checkForUpdates` menu action for the immediate user-initiated
path.

## Note (forward-only)

The activation lives in the *running* app's code. The 1.2.1 prompt Erik saw was
shown by 1.2.1 and can't be retroactively fixed; the fix takes effect for future
update prompts once on v1.2.5+. Not headlessly verifiable (Sparkle UI + window
focus) — ship on the documented-pattern + root-cause evidence; confirm visually.
