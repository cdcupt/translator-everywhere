# fb-2026-06-29-web-signin-stuck-loading

- **Source:** field-note (Erik, in conversation)
- **Date:** 2026-06-29
- **Screenshot:** `./fb-2026-06-29-web-signin-stuck-loading.png`

## Verbatim report

> I found another problem when I want to log in to this application. I click
> "Login with Google account," but the pop-up window still shows "Loading."

## Context

Preferences → Account tab. After clicking **Sign in with Google**, the tab sits in
the `.signingIn` state forever: both sign-in buttons greyed out (disabled) and a
`ProgressView` spinner spinning indefinitely. No usable auth browser appears.

## Root cause (traced)

`macos/Sources/Auth/WebGoogleAuthorizationProvider.swift` and
`macos/Sources/Auth/AppleWebAuthorizationProvider.swift` both implement
`presentationAnchor(for:) -> ASPresentationAnchor` by returning a brand-new
`ASPresentationAnchor()` — which on macOS is a freshly-constructed `NSWindow`
that is never shown. `ASWebAuthenticationSession` needs a **real, visible**
window to anchor its auth UI to. With a phantom anchor the session fails to
present and its completion handler never fires, so the
`withCheckedThrowingContinuation` in `start(url:scheme:)` never resumes →
`AccountViewModel.signIn` stays at `phase = .signingIn` indefinitely.
`AccountTab` disables both buttons and shows the spinner while `.signingIn`,
producing the stuck "Loading" UI.

Backend reachability ruled out: `api.translator.daichenlab.com` responds from
this Mac (HTTP, ~1.2s). Affects **both** Apple and Google web sign-in (shared
anchor bug), so it is not provider-specific and is not network-specific.

## Likely fix direction (for bpl — sensitive path: auth/**)

Return the app's real on-screen window as the anchor, e.g.
`NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()`
(requires `import AppKit`). Fix both providers. Consider a defensive watchdog
timeout in the sign-in flow so a future presentation failure can't brick the UI
into a permanent `.signingIn` state. Cannot be runtime-verified headlessly
(needs a real OAuth round-trip + browser + URL-scheme callback) — ship on
root-cause evidence + expert review + a real-device check.
