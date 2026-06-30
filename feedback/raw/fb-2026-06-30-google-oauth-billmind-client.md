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
