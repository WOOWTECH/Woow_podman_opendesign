#!/usr/bin/env bash
# tests/smoke.sh: post-install checks for Woow OpenDesign, run on the host where it is installed
# (install.sh, upgrade.sh and restore.sh call it too). Read-only: it creates nothing.
#
#   tests/smoke.sh [--quick]
#
#   --quick   units, health, published ports and the health endpoint only
#
# The API token is read with `podman secret inspect --showsecret` into a variable and reaches curl
# through a 0600 netrc-style config file, so it never appears in a process argument.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
export QL_LOG_PREFIX=smoke

quick=0
while (($#)); do
  case $1 in
    --quick) quick=1 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done

npass=0 nfail=0 nwarn=0
pass() { printf 'PASS %s\n' "$*"; npass=$((npass + 1)); }
fail() { printf 'FAIL %s\n' "$*"; nfail=$((nfail + 1)); }
warn() { printf 'WARN %s\n' "$*"; nwarn=$((nwarn + 1)); }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/od-smoke.XXXXXX")
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE not found; is OpenDesign installed?"
app_env_load
bind=$(ql_env_get WOOW_OD_BIND)
port=$(ql_env_get WOOW_OD_PORT)
auth=$(ql_env_get WOOW_OD_AUTH basic)
host=$(app_local_host "$bind")
url=http://$host:$port

# A1 units
for u in open-design.service open-design-nginx.service; do
  if systemctl --user is-active --quiet "$u"; then pass "A1 $u is active"; else fail "A1 $u is not active"; fi
done

# A2 health of both containers (podman's health timer runs under Quadlet)
for c in open-design open-design-nginx; do
  if ql_wait_container_healthy "$c" 300 2>/dev/null; then pass "A2 $c is healthy"; else fail "A2 $c is not healthy"; fi
done

# A3 only nginx's port is published, and the daemon's 7457 is not on the host at all
want="7456/tcp -> $bind:$port"
[[ $bind == all ]] && want="7456/tcp -> 0.0.0.0:$port"
got=$(podman port open-design 2>/dev/null || true)
if [[ $got == "$want" ]]; then pass "A3 open-design publishes only $want"; else fail "A3 open-design publishes '${got//$'\n'/, }', want '$want'"; fi
# NOT `ss ... | grep -q`: grep -q exits at the first match, ss is then killed by
# SIGPIPE and pipefail makes that the pipeline's status. Latent only while ss's
# output fits the 64 KiB pipe buffer.
host_listeners=$(ss -Htln 2>/dev/null || true)
if grep -qE '[:.]7457[[:space:]]' <<<"$host_listeners"; then fail "A3 something listens on host port 7457"; else pass "A3 the daemon port 7457 is not on the host"; fi

# A4 the health endpoint is reachable without credentials (nginx exempts it)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url/api/health" || true)
if [[ $code == 200 ]]; then pass "A4 /api/health returns 200 without credentials"; else fail "A4 /api/health returned $code"; fi

if ((quick)); then
  printf '%s passed, %s failed, %s warnings (quick)\n' "$npass" "$nfail" "$nwarn"
  ((nfail == 0))
  exit
fi

# A5 the limits podman-compose dropped are really applied
read -r pids_d mem_d cpu_d < <(podman inspect --format '{{.HostConfig.PidsLimit}} {{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' open-design 2>/dev/null || echo "? ? ?")
read -r pids_n mem_n cpu_n < <(podman inspect --format '{{.HostConfig.PidsLimit}} {{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' open-design-nginx 2>/dev/null || echo "? ? ?")
if [[ $pids_d == 512 && $pids_n == 128 ]]; then pass "A5 pids limits are 512 / 128"; else fail "A5 pids limits are $pids_d / $pids_n, want 512 / 128"; fi
if [[ $mem_d -gt 0 && $cpu_d -gt 0 && $mem_n == 134217728 && $cpu_n == 500000000 ]]; then
  pass "A5 memory and cpu limits are applied (daemon $mem_d bytes / $cpu_d nanocpus)"
else
  fail "A5 memory/cpu limits: daemon $mem_d/$cpu_d, nginx $mem_n/$cpu_n"
fi

# A6 rootless, read-only root filesystem, writable data volume, host-owned volume (keep-id)
uid=$(podman exec open-design id -u 2>/dev/null || true)
if [[ $uid == 1001 ]]; then pass "A6 the daemon runs as uid 1001"; else fail "A6 the daemon runs as uid '${uid:-?}'"; fi
if podman exec open-design sh -c 'touch /woow-smoke-readonly' >/dev/null 2>&1; then
  fail "A6 the root filesystem is writable"
  podman exec open-design rm -f /woow-smoke-readonly >/dev/null 2>&1 || true
else
  pass "A6 the root filesystem is read-only"
fi
if podman exec open-design sh -c 'touch /app/.od/.woow-smoke && rm -f /app/.od/.woow-smoke' >/dev/null 2>&1; then
  pass "A6 /app/.od is writable"
else
  fail "A6 /app/.od is not writable"
fi
mp=$(podman volume inspect --format '{{.Mountpoint}}' open-design_open_design_data 2>/dev/null || true)
owner=$(stat -c %U "$mp" 2>/dev/null || true)
if [[ $owner == "$(id -un)" ]]; then pass "A6 the data volume is owned by $owner on the host (keep-id)"; else fail "A6 the data volume is owned by '${owner:-?}'"; fi

# A7 the credential boundary
token=$(app_secret_read open-design-api-token || true)
(umask 077 && printf 'user = "open-design:%s"\n' "$token" >"$TMP/curlrc")
code_anon=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$url/" || true)
code_auth=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -K "$TMP/curlrc" "$url/" || true)
code_models=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$url/api/models-config" || true)
if [[ $auth == basic ]]; then
  if [[ $code_anon == 401 ]]; then pass "A7 / without credentials returns 401"; else fail "A7 / without credentials returned $code_anon, want 401"; fi
  if [[ $code_auth == 200 ]]; then pass "A7 / with the token returns 200"; else fail "A7 / with the token returned $code_auth"; fi
  if [[ $code_models == 401 ]]; then pass "A7 /api/models-config needs credentials"; else fail "A7 /api/models-config returned $code_models without credentials (it can contain provider keys)"; fi
  hdr=$(curl -s -o /dev/null -D- -m 15 "$url/" 2>/dev/null | grep -i '^www-authenticate' || true)
  if [[ -n $hdr ]]; then pass "A7 the browser gets a sign-in dialog"; else fail "A7 no WWW-Authenticate header"; fi
else
  warn "A7 WOOW_OD_AUTH=off: the UI and /api/models-config are served without a credential check"
  if [[ $code_anon == 200 ]]; then pass "A7 / returns 200 (auth off)"; else fail "A7 / returned $code_anon with auth off"; fi
fi

# A8 the daemon's origin guard
evil=$(curl -s -o "$TMP/evil.out" -w '%{http_code}' -m 15 -K "$TMP/curlrc" -X POST \
  -H 'Content-Type: application/json' -H 'Origin: http://evil.example' --data '{}' "$url/api/projects" || true)
good=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -K "$TMP/curlrc" -X POST \
  -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$port" --data '{}' "$url/api/projects" || true)
if [[ $evil == 403 ]] && grep -qi 'cross-origin' "$TMP/evil.out"; then
  pass "A8 a foreign Origin is refused (403 cross-origin)"
else
  fail "A8 a foreign Origin returned $evil (want 403 with a cross-origin message)"
fi
if [[ $good != 403 ]]; then pass "A8 an allowed Origin is not refused ($good)"; else fail "A8 the allowed local Origin was refused"; fi

# A9 the export bridge is injected and served
body=$(curl -s -m 20 -K "$TMP/curlrc" "$url/" || true)
if grep -q '<script src="/od-export-bridge.js"></script>' <<<"$body"; then pass "A9 the export bridge is injected into the page"; else fail "A9 the export bridge is not injected (the PDF button would return 501)"; fi
ctype=$(curl -s -o /dev/null -w '%{content_type}' -m 15 -K "$TMP/curlrc" "$url/od-export-bridge.js" || true)
if [[ $ctype == application/javascript* ]]; then pass "A9 /od-export-bridge.js is served as JavaScript"; else fail "A9 /od-export-bridge.js content type is '${ctype:-none}'"; fi

# A10 the headless renderer and the bundled agent (README claims)
ver=$(curl -s -m 15 -K "$TMP/curlrc" "$url/api/version" || true)
if grep -q '"slideRenderer" *: *true' <<<"$ver"; then pass "A10 /api/version reports the slide renderer"; else warn "A10 /api/version does not report slideRenderer: true"; fi
agents=$(curl -s -m 15 -K "$TMP/curlrc" "$url/api/agents" || true)
if grep -q 'opencode' <<<"$agents"; then pass "A10 /api/agents lists opencode"; else warn "A10 /api/agents does not list opencode"; fi

# A11 gzip and immutable caching for a hashed asset
asset=$(grep -oE '/_next/static/[A-Za-z0-9._/-]+\.(js|css)' <<<"$body" | head -n1 || true)
if [[ -n $asset ]]; then
  hdrs=$(curl -s -o /dev/null -D- -m 15 -K "$TMP/curlrc" -H 'Accept-Encoding: gzip' "$url$asset" || true)
  if grep -qi '^content-encoding: gzip' <<<"$hdrs"; then pass "A11 hashed assets are gzipped"; else fail "A11 $asset is not gzipped"; fi
  if grep -qi 'cache-control:.*immutable' <<<"$hdrs"; then pass "A11 hashed assets are cached immutably"; else fail "A11 $asset has no immutable Cache-Control"; fi
else
  warn "A11 no /_next/static asset found in the page; skipped"
fi

# A12 nginx joined the daemon's namespace cleanly.
# NOT `journalctl | grep -qi`: grep -q exits at the first match, journalctl is then killed by
# SIGPIPE (141) and pipefail makes that the pipeline's status -- so the branch that reports a
# bind error could never be taken and this check always passed. Read the journal first, the
# way A13 below already does.
nginx_journal=$(journalctl --user -u open-design-nginx.service -o cat --no-pager 2>/dev/null || true)
if grep -qiE 'bind\(\) to .* failed|Address (already in use|not available)' <<<"$nginx_journal"; then
  fail "A12 nginx reported a bind error in the shared namespace"
else
  pass "A12 nginx bound both listeners in the shared namespace"
fi

# A13 secret hygiene
journal=$(journalctl --user -u open-design.service -u open-design-nginx.service -o cat --no-pager 2>/dev/null || true)
nginx_inspect=$(podman inspect open-design-nginx 2>/dev/null || true)
if [[ -n $token && ( $journal == *"$token"* || $nginx_inspect == *"$token"* ) ]]; then
  fail "A13 the API token appears in the journal or in the nginx container config"
else
  pass "A13 the API token is not in the journal or the nginx container config"
fi
if [[ -n $token && $(podman inspect open-design 2>/dev/null || true) == *"$token"* ]]; then
  warn "A13 podman inspect shows the env-type token of the daemon (podman behaviour)"
fi
unset token

printf '%s passed, %s failed, %s warnings\n' "$npass" "$nfail" "$nwarn"
((nfail == 0))
