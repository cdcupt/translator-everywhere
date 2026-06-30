# fb-2026-06-30-google-oauth-billmind-client

- **Source:** field-note (Erik, in conversation)
- **Date:** 2026-06-30
- **Screenshots:** `./fb-2026-06-30-google-oauth-billmind-client.consent.png` (Google consent says "BillMind"), `./fb-2026-06-30-google-oauth-billmind-client.spinner.png` (Account tab stuck on spinner after login)

## Verbatim report

> 1. When I jumped to the login page for Google Login, I saw the page shows,
>    "You are logging in with the BillMind account." The application's name is
>    Translator Everywhere, [but it shows] as BillMind. Did you use the BillMind
>    account metadata?
> 2. When I finished the login workflow, nothing happened. When I switched to the
>    pop-up window, I just saw the loading icon on the window.

## Root cause (traced)

Both symptoms come from one misconfiguration: **TE's Google OAuth client lives in
BillMind's Google Cloud project** and is an **iOS-type** client (custom-scheme
redirect), which is wrong for a macOS desktop app.

- `AuthConfig.googleClientID = 328818408791-641sqb2v2smjgjud26e87j7rhnfo0uem` and
  `googleRedirectScheme = com.googleusercontent.apps.328818408791-641sqb…`
  (`AuthModels.swift`). The backend agrees (`GOOGLE_AUD` default in
  `server/internal/config/config.go` + `server/deploy/bwh-deploy.sh`).
- Project number **328818408791 is BillMind's GCP project** — BillMind's app uses
  *other* clients in it (`…-q7qpc…`, `…-na01luum…`, in `BillMind/Info.plist`). All
  OAuth clients in a project share ONE consent screen, which is branded
  **"BillMind"** → so TE's Google login shows "You're signing back in to BillMind"
  + "BillMind's Privacy Policy". (**Problem 1**, cosmetic but trust-breaking.)
- The `com.googleusercontent.apps.…` reverse-DNS redirect = an **iOS** client. On
  iOS the OS handles the scheme; on **desktop Chrome** the post-consent redirect to
  that custom scheme does not reliably hand off to the app, so the callback never
  reaches `WebAuthRouter` and the Account tab stays `.signingIn` forever.
  (**Problem 2**, functional — sign-in never completes.) Note v1.2.4's fix made the
  consent page *load* (NSWorkspace.open); this is the next failure in the chain.
- Apple sign-in is unaffected: `appleServicesID = com.cdcupt.translator-everywhere.web`
  (TE-branded, routed via the TE backend).

## Fix direction (needs Erik's Google Cloud action)

Provision a **Translator-Everywhere-branded** Google OAuth setup and switch to a
desktop-appropriate redirect:
1. A TE-branded OAuth **consent screen** (own GCP project, or a TE project) so the
   login shows "Translator Everywhere", not BillMind.
2. A **Desktop-app** OAuth client with a **loopback `http://127.0.0.1:<port>`**
   redirect — reliable on any desktop browser (no custom-scheme handoff). This is
   the "Option B" from the v1.2.4 discussion; the iOS-client custom-scheme path is
   what's failing on desktop Chrome now.
3. Code: update `AuthConfig.googleClientID` + redirect to loopback; replace the
   Google branch of `WebAuthRouter` with a tiny localhost listener (keep Apple as-is);
   backend `GOOGLE_AUD` → new client id (config default + deploy.sh + deployed env);
   redeploy backend; ship a new app version.

Not headlessly verifiable end-to-end (real Google round-trip) — Erik confirms.

## Verified plan (investigation 2026-06-30, 4-lens workflow — all confirmed)

**Both problems = one root cause** (verified): `641sqb` is an **iOS-type** client in
**BillMind's GCP project**. Google: "one brand per project" → BillMind consent
(Problem 1); iOS custom-scheme redirect → desktop Chrome silently drops the
post-consent 302 (`ERR_UNKNOWN_URL_SCHEME`, Chromium bug 738724) → callback never
arrives, `.signingIn` until the 180s watchdog (Problem 2). No existing TE Google
client anywhere; consent branding is not per-client → **new provisioning is
unavoidable**. Apple flow untouched.

**Decision: Desktop-app OAuth client + ephemeral loopback (`http://127.0.0.1:<port>`)
redirect for the Google branch only.** No `client_secret` needed (PKCE) — the
current secret-free token exchange stays. Loopback needs **no entitlement** (sandbox
off; bind 127.0.0.1 → bypasses the app firewall) and is cleanly cancellable (bonus:
closes the existing "Google waiter not cancellation-aware" follow-up).

**PHASE 0 — Erik (Google Cloud, BLOCKING):**
1. NEW GCP project "Translator Everywhere" (do NOT reuse BillMind's 328818408791).
2. OAuth consent screen: External, App name "Translator Everywhere" + TE privacy/ToS
   URLs, scopes `openid`/`userinfo.email`/`userinfo.profile` (non-sensitive → no
   Google review), then **Publish to Production** (else 100-user cap + "unverified").
3. Credentials → OAuth client ID → **Desktop app** (no redirect URI to enter).
4. Hand back the `client_id`; **ignore the client_secret** (not needed, must not ship).

**Doable now (bpl, in parallel, placeholder id):** rewrite the Google branch as a
loopback `LoopbackRedirectListener` (POSIX 127.0.0.1:0, one GET, return code+state,
"you can close this" page) replacing the custom-scheme `WebAuthRouter` use for Google
only; thread the runtime `redirect_uri` into BOTH `googleAuthorizationURL` and
`googleTokenExchangeRequest` (must match); drop the Google entry from
`CFBundleURLTypes` (keep `translator-everywhere` for Apple); backend **dual-audience**
support (`GOOGLE_AUD` comma-split → membership check in `provider.go`); fix the
mislabeled `CONFIG.md`.

**Cutover order (avoid breaking sign-ins):**
1. **Backend first, dual-aud `<old>,<new>`** — ⚠️ edit `~/.translator-everywhere/deploy.env`
   **on BWH** (bwh-deploy.sh REUSES it; editing the repo alone is a silent no-op),
   then run `server/deploy/bwh-deploy.sh` on the box.
2. **Then ship app** v1.2.5/8 → **1.2.6/9** with the new `client_id`, full DMG cut.
3. Later, optionally drop the old aud.
Existing signed-in users are NOT logged out (refresh path doesn't re-check aud).

## Outcome (shipped)

- **v1.2.6** — new TE Desktop client (`524726675699-…`) + loopback listener (PRs #46/#47/#48) + backend dual-aud deployed. Fixed the BillMind branding AND the stuck-spinner (loopback round-trip completes).
- **Follow-on 400** — after consent, Google's token endpoint returned 400: a Google **Desktop** client requires its `client_secret` even with PKCE (the v1.2.6 assumption that none was needed was wrong).
- **v1.2.7** (PR #49) — moved the code→token exchange to the **backend** (`auth.GoogleOAuth`); the app POSTs `code`+`code_verifier`+`redirect_uri` to `/auth/google`; `GOOGLE_CLIENT_SECRET` lives only in BWH `deploy.env` (never in the public repo/app). Backend deployed ("google desktop-loopback code exchange enabled"; bogus id_token & bogus code both → 401). App v1.2.7/build 10 published; feed serves `<sparkle:version>10</sparkle:version>`. **Pending Erik's live Google round-trip confirmation.**
