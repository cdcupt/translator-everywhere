# Provisioned identifiers — Translator Everywhere

> These are **public identifiers** (they ship inside the distributed app / appear in config), safe to commit.
> **Secrets** (Apple app-specific password, any client secret, DB password) live ONLY in
> `~/.translator-everywhere/deploy.env` on the dev Mac / VPS — never in this repo.

## App / Apple
- **Bundle ID:** `com.cdcupt.translator-everywhere`
- **Apple Team ID:** `NK3U2C365Z`
- **Sign in with Apple:** **WEB OAuth flow** (`ASWebAuthenticationSession`, `response_mode=form_post`) — the native `ASAuthorizationController` flow is NOT available for Developer-ID (non-App-Store) distribution. Uses a **Services ID** `com.cdcupt.translator-everywhere.web` (the OAuth `client_id`), a **Sign-in-with-Apple key** (`.p8`, Key ID `57Z3AW3BS6`) for the client-secret JWT, redirect `https://api.translator.daichenlab.com/auth/apple/callback`, app callback scheme `translator-everywhere`. See the "Apple web OAuth flow defaults" block below.

## Google sign-in
- **OAuth Client ID (Desktop app):** `524726675699-vnleiirk1tj2rpa5eic7nj617j5p8rlu.apps.googleusercontent.com`
  (Translator-Everywhere GCP project `524726675699`). Replaced the old
  `328818408791-641sqb…`, which lived in **BillMind's** project (wrong consent-screen
  brand) and was an **iOS**-type client whose custom-scheme redirect desktop Chrome
  dropped. See `feedback/raw/fb-2026-06-30-google-oauth-billmind-client.md`.
- Flow: **PKCE with an `http://127.0.0.1:<ephemeral-port>/oauth2redirect` loopback
  redirect** (`LoopbackRedirectListener` — the app binds localhost, opens the consent
  page in the default browser, captures `?code` on localhost; no client secret).
  Backend verifies the Google `id_token` (`aud` ∈ the configured client id(s) —
  `GOOGLE_AUD` supports a comma-separated set for cutover; `iss = https://accounts.google.com`).

## Backend host
- **Domain:** `api.translator.daichenlab.com` → **`67.230.179.139`** (BWH), DNS-only / unproxied.
- TLS via the shared Caddy (`9relay-caddy`) using its own snippet `translator.caddy`.
- Deploy pattern: own DB+role on the shared Postgres; own container; own Caddy snippet (one `import`).

## Pending (slice 8 — signing/notarization only)
- Developer ID Application certificate (in login keychain).
- App-specific password for `notarytool` → store in `~/.translator-everywhere/deploy.env`.

## Backend deploy (slice 6b) — ✅ DEPLOYED 2026-06-22
- DB `translator_everywhere` + role `te_app` on shared `9relay-postgres`; container `translator-everywhere-server` on `127.0.0.1:8110`; Caddy snippet `caddy-snippets/translator.caddy` → `api.translator.daichenlab.com`.
- Secrets (DB pass, JWT_SECRET) generated on the box into `~/.translator-everywhere/deploy.env` — never in repo.
- One-shot idempotent deployer: `server/deploy/bwh-deploy.sh` (run on BWH; validates Caddy before restart, smoke-tests all domains, auto-rolls-back on failure).
- LIVE at https://api.translator.daichenlab.com (TLS via shared Caddy). Container `translator-everywhere-server` on 9relay_default, restart=unless-stopped; DB `translator_everywhere`/role `te_app` on 9relay-postgres (superuser `litellm`); snippet `/opt/9relay/caddy-snippets/translator.caddy` reverse_proxy→`translator-everywhere-server:8110`. Re-deploy = re-run `server/deploy/bwh-deploy.sh` on BWH (idempotent). Deploy was run detached over SSH (the dev Mac's SSH drops on long commands, so the script logs to /tmp/te-deploy.log on the box).
