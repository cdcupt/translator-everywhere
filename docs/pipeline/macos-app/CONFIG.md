# Provisioned identifiers — Translator Everywhere

> These are **public identifiers** (they ship inside the distributed app / appear in config), safe to commit.
> **Secrets** (Apple app-specific password, any client secret, DB password) live ONLY in
> `~/.translator-everywhere/deploy.env` on the dev Mac / VPS — never in this repo.

## App / Apple
- **Bundle ID:** `com.cdcupt.translator-everywhere`
- **Apple Team ID:** `NK3U2C365Z`
- **Sign in with Apple:** native macOS flow (`ASAuthorizationController`). Backend verifies the Apple
  identity-token JWT against Apple's public JWKS with `aud = com.cdcupt.translator-everywhere`,
  `iss = https://appleid.apple.com`. No Apple private key / Services ID needed for v1.

## Google sign-in
- **OAuth Client ID (Desktop app):** `328818408791-641sqb2v2smjgjud26e87j7rhnfo0uem.apps.googleusercontent.com`
- Flow: PKCE via `ASWebAuthenticationSession`, loopback redirect. Backend verifies Google `id_token`
  (`aud` = this client ID, `iss = https://accounts.google.com`).

## Backend host
- **Domain:** `api.translator.daichenlab.com` → **`67.230.179.139`** (BWH), DNS-only / unproxied.
- TLS via the shared Caddy (`9relay-caddy`) using its own snippet `translator.caddy`.
- Deploy pattern: own DB+role on the shared Postgres; own container; own Caddy snippet (one `import`).

## Pending (slice 8 — signing/notarization only)
- Developer ID Application certificate (in login keychain).
- App-specific password for `notarytool` → store in `~/.translator-everywhere/deploy.env`.
