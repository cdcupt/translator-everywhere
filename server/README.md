# Translator Everywhere — backend (`/server`)

A small, stateless **Go** auth + vocab-sync API. It lets a signed-in user's
vocabulary notebook follow them across Macs. It stores **text vocab rows + user
identity only** — no OCR, no translation, no AI ever runs server-side.

Implements TECH §1–7. Stack: **Go + chi + sqlc + goose**, shipped as a single
static container (GHA → GHCR), deployed on the shared BWH box (slice 6b).

## Layout

```
server/
├── cmd/server/        # main: runs goose migrations on boot, then serves
├── internal/
│   ├── api/           # chi router, auth middleware, handlers
│   ├── auth/          # Apple/Google JWKS verification + session JWT/refresh
│   ├── config/        # env-only config (no hardcoded secrets)
│   └── db/            # Repository interface, pgx impl, in-memory fake
├── migrations/        # goose SQL (embedded into the binary)
├── sqlc.yaml          # sqlc config + internal/db/queries.sql (reference SQL)
├── Dockerfile         # multi-stage static build → distroless
└── .env.example       # placeholder env (real envs are gitignored)
```

## Endpoints

| Method · path                  | Auth        | Purpose                                              |
|--------------------------------|-------------|------------------------------------------------------|
| `GET·POST /auth/apple/callback`| public      | Sign in with Apple WEB flow: exchange code → 302 to app scheme |
| `POST /auth/google`            | public      | Verify Google id_token → upsert user → session       |
| `POST /auth/refresh`      | refresh tok | Exchange a refresh token for a fresh access JWT      |
| `POST /auth/signout`      | Bearer JWT  | Best-effort revoke the refresh token                 |
| `GET  /vocab?since=<ts>`  | Bearer JWT  | Pull rows (incl. tombstones) changed after a cursor  |
| `POST /vocab`             | Bearer JWT  | Batch upsert; idempotent + last-write-wins           |
| `DELETE /account`         | Bearer JWT  | Delete user + all rows (cascade)                     |
| `GET  /healthz`           | public      | Liveness `{ "ok": true }`                            |

## Auth model

- **Apple** uses the **WEB OAuth flow**. The app opens
  `ASWebAuthenticationSession` against Apple's authorize URL with the Services ID
  as `client_id`; Apple posts the authorization `code` to
  `/auth/apple/callback` (`form_post` when name/email scope is requested,
  otherwise a query GET). The backend mints an ES256 `client_secret` JWT, trades
  the code at Apple's token endpoint for an `id_token`, verifies it against
  Apple's JWKS (`aud`=Services ID, `iss`, `exp`), then **302-redirects** to
  `translator-everywhere://apple-callback?session=…&refresh=…&state=…` (on error
  `…?error=<msg>&state=…`). No Apple secret ever reaches the client.
- **Google** id_tokens are verified directly against Google's JWKS (RS256
  signature, `aud`, `iss`, `exp`). On success the user is upserted by
  `(provider, subject)`.
- **Our session JWT** is HS256, signed with `JWT_SECRET` (env). Short-lived
  access token + a long-lived opaque refresh token (only a SHA-256 hash of the
  refresh token is stored server-side).
- `/vocab` and `/account` require `Authorization: Bearer <session-jwt>`; the
  user id is always derived from the verified JWT `sub`, never from the body.

## Sync merge

Last-write-wins per row keyed on `(user_id, client_uuid)` by `updated_at`;
deletes are tombstones (`deleted=true`) so they propagate. A re-pushed row
upserts rather than duplicates.

## Config (env only)

| Var            | Required | Default                               |
|----------------|----------|---------------------------------------|
| `DATABASE_URL` | yes      | —                                     |
| `JWT_SECRET`   | yes      | —                                     |
| `APPLE_AUD`    | no       | `com.cdcupt.translator-everywhere`    |
| `GOOGLE_AUD`   | no       | the public OAuth client id (CONFIG)   |
| `PORT`         | no       | `8110`                                |
| `APPLE_SERVICES_ID`      | for Apple web | `com.cdcupt.translator-everywhere.web` (placeholder) |
| `APPLE_KEY_ID`           | for Apple web | — (.p8 key id; SECRET-adjacent)      |
| `APPLE_TEAM_ID`          | no            | `NK3U2C365Z`                         |
| `APPLE_PRIVATE_KEY` / `APPLE_PRIVATE_KEY_FILE` | for Apple web | — (.p8 PEM; **SECRET**) |
| `APPLE_REDIRECT_URI`     | no            | `https://api.translator.daichenlab.com/auth/apple/callback` |
| `APP_CALLBACK_SCHEME`    | no            | `translator-everywhere`              |

When the Apple web secrets are absent the server still boots; `/auth/apple/callback`
degrades to an error redirect instead of failing startup.

## Develop

```bash
cd server
go build ./...
go vet ./...
go test -race ./...
```

Tests need **no Postgres and no network**: the auth tests serve a fake JWKS
from an in-process `httptest` server, and handler tests use an in-memory
`db.FakeRepository`.

If `sqlc.yaml` queries change, regenerate with `sqlc generate` (the committed
pgx code in `internal/db` is hand-written to mirror those queries so the build
never depends on the sqlc binary).
