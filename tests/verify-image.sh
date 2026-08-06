#!/usr/bin/env bash
#
# usage: tests/verify-image.sh <image> [manifest]
#
# Assert that a built image LOADS every curated package, and that the base
# image's own contents survived the bake.
#
# Files on disk prove nothing here: a package in the wrong directory is present
# and undiscoverable, which is precisely the failure this guards against. Every
# assertion below asks the running server what it sees.

set -o nounset
set -o pipefail

IMAGE="${1:?usage: verify-image.sh <image> [manifest]}"
MANIFEST="${2:-plugins.list}"
PORT="${PORT:-3998}"
NAME="verify-$$"

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1"
  fail=1
}

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# The entrypoint hard-codes --securityenabled, so the module listings are 401
# without a bootstrapped admin. Seed the shape halos-marine-containers'
# prestart.sh writes, then log in for a token.
PASSWORD="verify-$$-pw"
HASH="$(printf '%s' "$PASSWORD" |
  python3 -c 'import sys,bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt()).decode())')"
mkdir -p "$WORK/.signalk"
cat >"$WORK/.signalk/security.json" <<EOF
{ "strategy": "./tokensecurity",
  "users": [{ "username": "admin", "type": "admin", "password": "${HASH}" }],
  "allow_readonly": true,
  "secretKey": "$(openssl rand -hex 32)" }
EOF
chmod -R a+rwX "$WORK"

docker run -d --name "$NAME" -p "${PORT}:3000" \
  -v "$WORK/.signalk:/home/node/.signalk" "$IMAGE" >/dev/null ||
  {
    echo "container failed to start"
    exit 1
  }

# Poll /signalk, not /signalk/v1/api/ -- the latter is 401 even when the server
# is fully up, so it never reports ready.
printf 'waiting for server'
ready=0
for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/signalk")" = "200" ]; then
    ready=1
    break
  fi
  printf '.'
  sleep 1
done
printf '\n'
if [ "$ready" != 1 ]; then
  echo "server never became ready"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi

TOKEN="$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${PASSWORD}\"}" \
  "http://localhost:${PORT}/signalk/v1/auth/login" |
  python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
[ -n "$TOKEN" ] || {
  echo "could not authenticate"
  exit 1
}

# Union of both listings: /skServer/webapps filters out packages whose plugin is
# not enabled, and the image enables nothing, so most curated entries appear
# only in /skServer/plugins.
LOADED="$(for ep in plugins webapps; do
  curl -s -H "Authorization: Bearer ${TOKEN}" "http://localhost:${PORT}/skServer/${ep}" |
    python3 -c 'import sys,json
try:
    for m in json.load(sys.stdin): print(m.get("packageName") or m.get("name",""))
except Exception: pass'
done | sort -u)"

expected="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$MANIFEST" | tr -d '\r' | sed 's/[[:space:]]*$//')"
count=0
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  count=$((count + 1))
  if grep -qxF "$pkg" <<<"$LOADED"; then ok "loaded: $pkg"; else bad "NOT loaded: $pkg"; fi
done <<<"$expected"
[ "$count" -gt 0 ] || bad "manifest parsed to zero entries -- the check would pass vacuously"
echo "  (${count} manifest entries checked)"

# The bake mutates a tree upstream hand-relocated, so assert what was already
# there survived -- not just that our additions arrived. During development the
# require.resolve check below passed while the admin UI returned 500: the
# package directory survived, something it needed did not. Keep the HTTP check.
status="$(curl -s -o "$WORK/admin.html" -w '%{http_code}' "http://localhost:${PORT}/admin/")"
if [ "$status" = "200" ] && [ -s "$WORK/admin.html" ]; then
  ok "admin UI serves (200, non-empty)"
else
  bad "admin UI broken (HTTP ${status})"
fi

SERVER_ROOT=/home/node/signalk/node_modules/signalk-server
if docker exec "$NAME" node -e \
  "require.resolve('serialport',{paths:['${SERVER_ROOT}']})" >/dev/null 2>&1; then
  ok "serialport resolves from server root"
else
  bad "serialport no longer resolves"
fi

echo
if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit "$fail"
