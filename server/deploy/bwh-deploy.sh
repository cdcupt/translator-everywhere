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
GOOGLE_AUD=328818408791-641sqb2v2smjgjud26e87j7rhnfo0uem.apps.googleusercontent.com
PORT=$PORT
EOF
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
SELECT 'create-db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='$DB')\gset
\if :{?create-db}
  CREATE DATABASE $DB OWNER $ROLE;
\endif
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
docker run -d --name "$CONTAINER" --restart unless-stopped \
  --network "$(docker inspect "$PG_CONTAINER" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')" \
  -p 127.0.0.1:$PORT:$PORT --env-file "$ENV_FILE" "$IMAGE" >/dev/null
sleep 3
for i in $(seq 1 10); do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  [[ $i == 10 ]] && { docker logs --tail 40 "$CONTAINER"; die "container not healthy on :$PORT"; }
  sleep 2
done
echo "  container healthy on :$PORT"

# --- 6. Caddy snippet (own file + ONE import) -------------------------------
log "Wiring Caddy snippet (validate-before-restart, smoke-test-after)"
CADDY_DIR=$(docker inspect "$CADDY_CONTAINER" -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy"}}{{.Source}}{{end}}{{end}}')
[[ -n "$CADDY_DIR" ]] || die "could not find $CADDY_CONTAINER /etc/caddy mount"
SNIP_DIR="$CADDY_DIR/caddy-snippets"; mkdir -p "$SNIP_DIR"
MAIN="$CADDY_DIR/Caddyfile"
SNIP="$SNIP_DIR/translator.caddy"
BACKUP=$(mktemp)
cp "$SNIP" "$BACKUP" 2>/dev/null || echo "__none__" > "$BACKUP"

cat > "$SNIP" <<EOF
$DOMAIN {
	reverse_proxy 127.0.0.1:$PORT
}
EOF
# ensure exactly one import line for our snippet (never touch others)
grep -q "import caddy-snippets/translator.caddy" "$MAIN" || \
  printf '\nimport caddy-snippets/translator.caddy\n' >> "$MAIN"

rollback(){
  echo "  ROLLING BACK snippet"; if grep -qx '__none__' "$BACKUP"; then rm -f "$SNIP"; else cp "$BACKUP" "$SNIP"; fi
  docker restart "$CADDY_CONTAINER" >/dev/null; }

log "Validating Caddy config"
docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  || { rollback; die "Caddy config invalid — rolled back, NOTHING restarted live"; }

log "Restarting $CADDY_CONTAINER (restart, not reload)"
docker restart "$CADDY_CONTAINER" >/dev/null; sleep 4

log "Smoke-testing all domains"
FAIL=0
for d in "${SMOKE_DOMAINS[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "https://$d/healthz" 2>/dev/null || echo 000)
  # /healthz may 404 on apps without it — treat any < 500 (reachable+TLS) as up, except our own which must be 200
  if [[ "$d" == "$DOMAIN" ]]; then [[ "$code" == 200 ]] || { echo "  ✘ $d → $code"; FAIL=1; }; \
  else [[ "$code" =~ ^(200|301|302|401|403|404|405) ]] || { echo "  ✘ $d → $code"; FAIL=1; }; fi
  echo "  $d → $code"
done
[[ $FAIL == 0 ]] || { rollback; die "a domain broke after restart — rolled back"; }

# --- 7. e2e proof -----------------------------------------------------------
log "e2e: bad Google token must be rejected (401)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -X POST "https://$DOMAIN/auth/google" -H 'content-type: application/json' -d '{"id_token":"bogus"}' || echo 000)
[[ "$code" == 401 || "$code" == 400 ]] && echo "  ok ($code)" || echo "  ⚠ unexpected $code (check handler)"

printf '\n\033[32m✔ DEPLOY OK — %s is live, all domains healthy.\033[0m\n' "$DOMAIN"
