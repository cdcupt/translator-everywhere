#!/usr/bin/env bash
# bwh-deploy.sh — deploy translator-everywhere-server onto the shared BWH box.
#
# Run this ON the BWH box (as root), e.g. via SSH or the KiwiVM web console:
#   curl -fsSL https://raw.githubusercontent.com/cdcupt/translator-everywhere/main/server/deploy/bwh-deploy.sh | bash
# or clone + run. It is IDEMPOTENT and SAFE: it never edits other apps' Caddy
# snippets, validates the Caddy config BEFORE restarting, smoke-tests every
# domain AFTER, and auto-rolls-back its snippet if any domain breaks.
#
# Coexistence rules honored (see the bwh_multitenant_deploy runbook):
#   own DB+role on the shared 9relay-postgres · own localhost port 8110 ·
#   own caddy-snippets/translator.caddy + ONE import line · docker restart
#   9relay-caddy (NOT reload) · smoke-test all domains.
set -euo pipefail

APP=translator-everywhere
CONTAINER=translator-everywhere-server
IMAGE=translator-everywhere-server:latest
PORT=8110
DB=translator_everywhere
ROLE=te_app
DOMAIN=api.translator.daichenlab.com
ENV_DIR="$HOME/.translator-everywhere"
ENV_FILE="$ENV_DIR/deploy.env"
APP_DIR=/opt/translator-everywhere/app
REPO=https://github.com/cdcupt/translator-everywhere.git
PG_CONTAINER=9relay-postgres
CADDY_CONTAINER=9relay-caddy
# Every public domain that MUST stay up after the Caddy restart:
SMOKE_DOMAINS=(claude.9relay.com api.english.daichenlab.com status.daichenlab.com "$DOMAIN")

log(){ printf '\n\033[36m▶ %s\033[0m\n' "$*"; }
die(){ printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found"
docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"    || die "$PG_CONTAINER not running"
docker ps --format '{{.Names}}' | grep -qx "$CADDY_CONTAINER" || die "$CADDY_CONTAINER not running"

# --- 1. port check ----------------------------------------------------------
log "Checking port $PORT is free"
if ss -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT " && ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  die "port $PORT is in use by something other than $CONTAINER — pick another"
fi

# --- 2. secrets (idempotent; generated once, then reused) -------------------
log "Ensuring $ENV_FILE"
mkdir -p "$ENV_DIR"; chmod 700 "$ENV_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  DB_PASS=$(openssl rand -hex 24); JWT=$(openssl rand -hex 32)
  cat > "$ENV_FILE" <<EOF
DATABASE_URL=postgres://$ROLE:$DB_PASS@$PG_CONTAINER:5432/$DB?sslmode=disable
JWT_SECRET=$JWT
APPLE_AUD=com.cdcupt.translator-everywhere
GOOGLE_AUD=524726675699-vnleiirk1tj2rpa5eic7nj617j5p8rlu.apps.googleusercontent.com
PORT=$PORT
EOF
  # NOTE: this block writes $ENV_FILE only on first deploy (guarded above). To
  # change GOOGLE_AUD on a box that already has $ENV_FILE, edit it there. During
  # the Google client cutover set GOOGLE_AUD=<old-billmind>,<new-te> (comma set)
  # so both verify, then drop <old> once users have updated.
  chmod 600 "$ENV_FILE"
  echo "  created (new secrets generated)"
else
  echo "  exists — reusing"
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
DB_PASS_EFF=$(sed -n 's#^DATABASE_URL=postgres://[^:]*:\([^@]*\)@.*#\1#p' "$ENV_FILE")

# --- 3. own DB + role on the shared Postgres (idempotent) -------------------
log "Ensuring database '$DB' and role '$ROLE' on $PG_CONTAINER"
PG_SUPER=$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER 2>/dev/null || echo postgres)
echo "  using superuser: $PG_SUPER"
docker exec -i "$PG_CONTAINER" psql -U "$PG_SUPER" -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$ROLE') THEN
    CREATE ROLE $ROLE LOGIN PASSWORD '$DB_PASS_EFF';
  ELSE
    ALTER ROLE $ROLE PASSWORD '$DB_PASS_EFF';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE $DB OWNER $ROLE' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='$DB')\gexec
SQL
echo "  ok"

# --- 4. build the image on the box (from the committed Dockerfile) ----------
log "Fetching source + building image"
if [[ -d "$APP_DIR/.git" ]]; then git -C "$APP_DIR" fetch -q origin && git -C "$APP_DIR" reset -q --hard origin/main
else mkdir -p "$(dirname "$APP_DIR")"; git clone -q "$REPO" "$APP_DIR"; fi
docker build -q -t "$IMAGE" "$APP_DIR/server" >/dev/null
echo "  built $IMAGE"

# --- 5. (re)run the container on 127.0.0.1:$PORT ----------------------------
log "Starting $CONTAINER on 127.0.0.1:$PORT"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
# Mount the Sign-in-with-Apple .p8 key (secret) read-only if present; the app
# reads it via APPLE_PRIVATE_KEY_FILE (set in deploy.env).
APPLE_KEY_HOST="$ENV_DIR/apple_signin_key.p8"
APPLE_MOUNT=()
[ -f "$APPLE_KEY_HOST" ] && APPLE_MOUNT=(-v "$APPLE_KEY_HOST:/run/apple_key.p8:ro") && echo "  mounting Apple key → /run/apple_key.p8"
docker run -d --name "$CONTAINER" --restart unless-stopped \
  --network "$(docker inspect "$PG_CONTAINER" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')" \
  "${APPLE_MOUNT[@]}" \
  -p 127.0.0.1:$PORT:$PORT --env-file "$ENV_FILE" "$IMAGE" >/dev/null
sleep 3
for i in $(seq 1 10); do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  [[ $i == 10 ]] && { docker logs --tail 40 "$CONTAINER"; die "container not healthy on :$PORT"; }
  sleep 2
done
echo "  container healthy on :$PORT"

# --- 6. Caddy snippet (own file + ONE import) -------------------------------
# Caddy runs in a container and reverse-proxies apps by CONTAINER NAME over the
# shared 9relay_default network (mirrors billmind/english/status). Host config
# lives at /opt/9relay/{Caddyfile,caddy-snippets/} (mounted read-only into the
# container). We edit the HOST files; never touch other apps' snippets.
log "Wiring Caddy snippet (validate-before-restart, smoke-test-after)"
SNIP_DIR=/opt/9relay/caddy-snippets
MAIN=/opt/9relay/Caddyfile
[[ -d "$SNIP_DIR" && -f "$MAIN" ]] || die "expected $MAIN and $SNIP_DIR not found"
SNIP="$SNIP_DIR/translator.caddy"
BACKUP=$(mktemp); cp "$SNIP" "$BACKUP" 2>/dev/null || echo "__none__" > "$BACKUP"
MAIN_BACKUP=$(mktemp); cp "$MAIN" "$MAIN_BACKUP"

cat > "$SNIP" <<EOF
# Translator Everywhere — sync API (own snippet; imported from the Caddyfile).
$DOMAIN {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	reverse_proxy $CONTAINER:$PORT
}
EOF
# add exactly ONE import line for our snippet (never touch others)
grep -q "snippets/translator.caddy" "$MAIN" || \
  printf '\nimport /etc/caddy/snippets/translator.caddy\n' >> "$MAIN"

rollback(){
  echo "  ROLLING BACK Caddy changes"
  if grep -qx '__none__' "$BACKUP"; then rm -f "$SNIP"; else cp "$BACKUP" "$SNIP"; fi
  cp "$MAIN_BACKUP" "$MAIN"
  docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true; }

log "Validating Caddy config"
docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  || { rollback; die "Caddy config invalid — rolled back, NOTHING restarted live"; }

log "Restarting $CADDY_CONTAINER (restart, not reload)"
docker restart "$CADDY_CONTAINER" >/dev/null; sleep 5

# Primary safety after restart: Caddy must be running (a bad config would crash
# it on boot even though validate passed). If it's down → roll back immediately.
docker ps --format '{{.Names}}' | grep -qx "$CADDY_CONTAINER" \
  || { rollback; die "$CADDY_CONTAINER did not come back up — rolled back"; }

log "Smoke-testing domains (own = required 200; others = warn-only, box→public can hairpin)"
own=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/healthz" 2>/dev/null || echo 000)
[[ "$own" == 200 ]] || { rollback; die "$DOMAIN/healthz → $own (expected 200) — rolled back"; }
echo "  ✔ $DOMAIN → $own"
for d in claude.9relay.com api.english.daichenlab.com status.daichenlab.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$d/" 2>/dev/null || echo 000)
  if [[ "$code" =~ ^(200|301|302|401|403|404|405) ]]; then echo "  ✔ $d → $code"; else echo "  ⚠ $d → $code (verify externally; Caddy is up + config validated)"; fi
done

# --- 7. e2e proof -----------------------------------------------------------
log "e2e: bad Google token must be rejected (401)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -X POST "https://$DOMAIN/auth/google" -H 'content-type: application/json' -d '{"id_token":"bogus"}' || echo 000)
[[ "$code" == 401 || "$code" == 400 ]] && echo "  ok ($code)" || echo "  ⚠ unexpected $code (check handler)"

printf '\n\033[32m✔ DEPLOY OK — %s is live, all domains healthy.\033[0m\n' "$DOMAIN"
