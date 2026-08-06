#!/usr/bin/env bash
#
# usage: tests/verify-image.sh <image> [manifest]
#        BASE=<upstream ref>  compares dependency resolution against the base image
#
# Assert that a built image LOADS every curated package at the expected version,
# that its webapps actually serve, that nothing uncurated crept in, and that the
# bake did not displace the base image's own dependency resolution.
#
# Files on disk prove nothing here: a package in the wrong directory is present
# and undiscoverable, and a package in the RIGHT directory can still shadow one
# the server needs. Every assertion below either asks the running server or
# compares against the base image.

set -o nounset
set -o pipefail

IMAGE="${1:?usage: verify-image.sh <image> [manifest]}"
# The manifest is a parameter because the mutation table in README.md drives the
# harness with deliberately broken manifests.
MANIFEST="${2:-plugins.list}"
PORT="${PORT:-3998}"
NAME="verify-$$"
SERVER_ROOT=/home/node/signalk/node_modules/signalk-server

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1"
  fail=1
}
die() {
  # fail=1 so the EXIT trap dumps container logs: the die paths (auth failure, a
  # 500 from a listing) are exactly the ones where the logs are the diagnosis.
  fail=1
  printf 'verify-image: %s\n' "$1" >&2
  exit 1
}

# Comments are stripped only at line start -- an npm spec may contain '#'
# (github:org/repo#ref) and a mid-line strip would silently change what installs.
manifest_entries() {
  sed -e 's/^[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' "$MANIFEST" \
    | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Setup is all preconditions: a silent failure here misattributes the cause of a
# failure 60 seconds later, so each step is checked.
command -v docker >/dev/null || die "docker not found"
WORK="$(mktemp -d)" || die "mktemp failed"
cleanup() {
  if [ "${fail:-1}" != 0 ] && [ -n "${STARTED:-}" ]; then
    printf '\n--- container logs (tail) ---\n' >&2
    docker logs "$NAME" 2>&1 | tail -30 >&2
  fi
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# Manifest preconditions. Contracts about the manifest's contents, not claims
# about the running server, so they are settled before the 90s of booting one.
#
# Vacuity first: an empty parse satisfies "signalk-to-influxdb2 is missing" too,
# and reporting a missing package when the real fault is a broken parser sends
# the reader to the wrong file.
[ "$(manifest_entries | grep -c .)" -gt 0 ] ||
  die "manifest parsed to zero entries -- every check below would pass vacuously"

# halos-marine-containers' prestart.sh writes signalk-to-influxdb2's token config
# on every start unconditionally, because it cannot look for a plugin that lives
# in the image rather than in the data volume. Drop this entry and marine logging
# stops silently: a config file addressed to a plugin that is not there, and
# every other assertion below still green.
manifest_entries | grep -qxF 'signalk-to-influxdb2' ||
  die "signalk-to-influxdb2 is missing from ${MANIFEST} -- halos-marine-containers' prestart.sh writes its config unconditionally, so marine logging would stop with no other assertion failing"

# The entrypoint hard-codes --securityenabled, so the module listings are 401
# without a bootstrapped admin. Seed the shape halos-marine-containers'
# prestart.sh writes, then log in for a token.
PASSWORD="verify-$$-$RANDOM-pw"
HASH="$(printf '%s' "$PASSWORD" |
  python3 -c 'import sys,bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt()).decode())')" ||
  die "could not hash password -- is python3-bcrypt installed?"
SECRET="$(openssl rand -hex 32)" || die "openssl rand failed"
mkdir -p "$WORK/.signalk" || die "could not create work dir"
cat >"$WORK/.signalk/security.json" <<EOF
{ "strategy": "./tokensecurity",
  "users": [{ "username": "admin", "type": "admin", "password": "${HASH}" }],
  "allow_readonly": true,
  "secretKey": "${SECRET}" }
EOF
chmod -R a+rwX "$WORK"

# Loopback only: nothing here needs to be reachable from the LAN.
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:3000" \
  -v "$WORK/.signalk:/home/node/.signalk" "$IMAGE" >/dev/null ||
  die "container failed to start"
STARTED=1

# Poll /signalk, not /signalk/v1/api/ -- the latter is 401 even when the server
# is fully up, so it never reports ready. --max-time bounds a server that binds
# the port and then stops responding, which no connection-refused check catches.
printf 'waiting for server'
ready=0
for _ in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    printf '\n'
    bad "container exited during startup"
    exit 1
  fi
  if [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/signalk")" = "200" ]; then
    ready=1
    break
  fi
  printf '.'
  sleep 1
done
printf '\n'
[ "$ready" = 1 ] || {
  bad "server never became ready"
  exit 1
}

login="$(curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${PASSWORD}\"}" \
  "http://localhost:${PORT}/signalk/v1/auth/login")"
TOKEN="$(printf '%s' "$login" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
[ -n "$TOKEN" ] || die "could not authenticate; server said: $(printf '%s' "$login" | head -c 200)"

# Fetch a listing, failing loudly on a non-200 rather than feeding an error page
# to the JSON parser -- otherwise a 401 reports as "nothing loaded" and sends the
# next person debugging the bake instead of the auth.
listing() {
  local ep="$1" body status
  body="$(curl -s --max-time 30 -w '\n%{http_code}' -H "Authorization: Bearer ${TOKEN}" \
    "http://localhost:${PORT}/skServer/${ep}")"
  status="$(printf '%s' "$body" | tail -1)"
  [ "$status" = "200" ] || die "/skServer/${ep} returned HTTP ${status}"
  printf '%s' "$body" | sed '$d'
}

# name<TAB>version, over the union of both listings. /skServer/webapps filters out
# packages whose plugin is not enabled, and the image enables nothing, so most
# curated entries appear only in the plugins listing.
parse='import sys,json
for m in json.load(sys.stdin):
    n = m.get("packageName") or m.get("name","")
    if n: print(n + "\t" + str(m.get("version","")))'
# Fetched separately with their own status checks: `die` inside a pipeline exits
# only that subshell, so a 500 on /skServer/plugins would leave the run continuing
# on webapps-only data and report every plugin as "NOT loaded".
plugins_raw="$(listing plugins)" || exit 1
webapps_raw="$(listing webapps)" || exit 1
LOADED="$( { printf '%s' "$plugins_raw" | python3 -c "$parse"; printf '%s' "$webapps_raw" | python3 -c "$parse"; } | sort -u )"
WEBAPPS="$(printf '%s' "$webapps_raw" | python3 -c "$parse" | cut -f1)"

# --- every manifest entry loads, at the version baked into the image ----------
count=0
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  count=$((count + 1))
  served="$(awk -F'\t' -v p="$pkg" '$1==p{print $2; exit}' <<<"$LOADED")"
  if [ -z "$served" ]; then
    bad "NOT loaded: $pkg"
    continue
  fi
  # Matching on name alone cannot tell the baked copy from a stale one shadowing
  # it from the data volume, so compare against what is actually in the image.
  baked="$(docker exec "$NAME" node -p \
    "require('${SERVER_ROOT}/node_modules/${pkg}/package.json').version" 2>/dev/null)"
  if [ -z "$baked" ]; then
    bad "loaded but not baked into the image: $pkg (served ${served})"
  elif [ "$served" != "$baked" ]; then
    bad "version mismatch: $pkg served ${served}, image has ${baked}"
  else
    ok "loaded: ${pkg}@${served}"
  fi
done < <(manifest_entries)
echo "  (${count} manifest entries checked)"

# --- webapps actually serve their payload ------------------------------------
wa_checked=0
# Presence in /skServer/webapps is a package.json keyword scan, not evidence that
# anything is served: deleting only public/ leaves the listing intact and the URL
# 404ing. These are the UIs users open.
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  grep -qxF "$pkg" <<<"$WEBAPPS" || continue
  wa_checked=$((wa_checked + 1))
  status="$(curl -s --max-time 15 -o "$WORK/wa.out" -w '%{http_code}' "http://localhost:${PORT}/${pkg}/")"
  if [ "$status" = "200" ] && [ -s "$WORK/wa.out" ]; then
    ok "webapp serves: $pkg"
  else
    bad "webapp does not serve: $pkg (HTTP ${status})"
  fi
done < <(manifest_entries)
[ "$wa_checked" -gt 0 ] || bad "no manifest webapp was checked -- the payload assertion asserted nothing"

# --- the base image's own admin UI still serves ------------------------------
# Not a manifest entry, so the webapp loop above does not cover it -- and it is
# the only path by which plugins stay independently updatable, so losing it
# fails a stated requirement while every plugin assertion still passes.
status="$(curl -s --max-time 15 -o "$WORK/admin.out" -w '%{http_code}' "http://localhost:${PORT}/admin/")"
if [ "$status" = "200" ] && [ -s "$WORK/admin.out" ]; then
  ok "admin UI serves (200, non-empty)"
else
  bad "admin UI broken (HTTP ${status})"
fi

# --- nothing uncurated crept in ----------------------------------------------
# The subset check is one-directional; without this, a plugin arriving as another
# plugin's dependency ships enabled-by-default with a green run.
if [ -n "${BASE:-}" ]; then
  enumerate='const fs=require("fs"),p="/home/node/signalk/node_modules/signalk-server/node_modules";
for(const e of fs.readdirSync(p)) if(e.startsWith("@")) for(const s of fs.readdirSync(p+"/"+e)) console.log(e+"/"+s); else console.log(e);'
  FROM_BASE="$(docker run --rm --entrypoint node "$BASE" -e "$enumerate" 2>/dev/null)"
  [ -n "$FROM_BASE" ] || die "could not enumerate the base image's packages"
  expected="$(
    manifest_entries
    printf '%s\n' "$FROM_BASE"
  )"
  unexpected=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qxF "$name" <<<"$expected" || unexpected="${unexpected}${name} "
  done < <(cut -f1 <<<"$LOADED")
  if [ -n "$unexpected" ]; then
    bad "uncurated packages loaded: ${unexpected}"
  else
    ok "no uncurated packages loaded"
  fi
else
  die "BASE is unset -- cannot enumerate the base image's packages"
fi

# --- the bake did not displace the base image's own dependency resolution -----
# This is the assertion the first version of this harness lacked. A hoisted copy
# put 380 packages into the server root, ahead of the server's own 569 at the top
# level, and silently substituted 35 of them -- including a ws major downgrade.
# Names and load-success both looked perfect.
if [ -n "${BASE:-}" ]; then
  # Walk the filesystem rather than require.resolve. An earlier probe used
  # require.resolve('<pkg>/package.json'), which throws ERR_PACKAGE_PATH_NOT_EXPORTED
  # for any package with a restrictive exports map -- 13 of signalk-server's 61
  # declared dependencies, including bcryptjs, @signalk/server-api and helmet. Those
  # were silently dropped, so the check caught 5 of 35 real displacements and passed
  # an image that had lost every security header.
  #
  # This resolves the way Node does for the server's own code (server root first,
  # then top level) across the WHOLE closure, not just declared dependencies, and
  # reports a package that disappeared as loudly as one that changed version.
  probe='const fs=require("fs"),path=require("path");
const SR="/home/node/signalk/node_modules/signalk-server/node_modules";
const TL="/home/node/signalk/node_modules";
function scan(dir){const o={};let e=[];try{e=fs.readdirSync(dir)}catch{return o}
  for(const n of e){ if(n.startsWith(".")) continue;
    const names = n.startsWith("@") ? (()=>{try{return fs.readdirSync(path.join(dir,n)).map(s=>n+"/"+s)}catch{return[]}})() : [n];
    for(const m of names){ try{ o[m]=JSON.parse(fs.readFileSync(path.join(dir,m,"package.json"),"utf8")).version||"?" }catch{} } }
  return o;}
const sr=scan(SR), tl=scan(TL);
// What signalk-server`s own code resolves: server root shadows top level.
const out={}; for(const k of Object.keys(tl)) out[k]=tl[k];
for(const k of Object.keys(sr)) out[k]=sr[k];
console.log(JSON.stringify(out));'
  docker run --rm --entrypoint node "$BASE"  -e "$probe" >"$WORK/base.json" 2>/dev/null
  docker run --rm --entrypoint node "$IMAGE" -e "$probe" >"$WORK/img.json"  2>/dev/null
  drift="$(python3 - "$WORK/base.json" "$WORK/img.json" <<'PY_CMP'
import json,sys
try:
    b=json.load(open(sys.argv[1])); i=json.load(open(sys.argv[2]))
except Exception as e:
    print("COMPARATOR-FAILED:", e); sys.exit(0)
if len(b) < 100:
    print(f"COMPARATOR-FAILED: base probe returned only {len(b)} packages"); sys.exit(0)
out=[f"{k}:{b[k]}->{i[k]}" for k in sorted(b) if k in i and b[k]!=i[k]]
out+= [f"{k}:{b[k]}->GONE" for k in sorted(b) if k not in i]
print(" ".join(out))
PY_CMP
)" || drift="COMPARATOR-FAILED: python exited non-zero"
  case "$drift" in
    "") ok "server's resolution matches the base image across the whole closure" ;;
    COMPARATOR-FAILED*) bad "dependency comparison did not run: ${drift}" ;;
    *) bad "bake changed the server's resolution: ${drift}" ;;
  esac
else
  die "BASE is unset -- the uncurated-package and dependency-resolution checks cannot run. Use ./run verify, or set BASE explicitly."
fi

echo
if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit "$fail"
