#!/usr/bin/env bash
set -Eeuo pipefail

# The credential boundary of config/nginx.conf, against the real nginx image with a stub in place of
# the daemon: what is open, what asks for the password, and what is refused without a dialog.
REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=$(sed -n 's/^Image=//p' "$REPO/quadlet/open-design-nginx.container")
NAME=od-nginx-auth-test
PORT=${WOOW_OD_TEST_PORT:-17456}
WORK=$(mktemp -d)
trap 'podman rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

cp "$REPO/config/nginx-auth.basic.conf" "$REPO/config/od-export-bridge.js" "$WORK/"
echo "t:$(openssl passwd -apr1 pw)" >"$WORK/htpasswd"
# Every upstream becomes a stub that echoes the request line, so a body shows the daemon was reached.
python3 - "$REPO/config/nginx.conf" "$WORK/nginx.conf" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'proxy_pass http://(127\.0\.0\.1:(8081|7681)|unix:/run/od-mcp/admin\.sock:/);', 'proxy_pass http://127.0.0.1:7457;', s)
i = s.rstrip().rfind('}')
stub = 'server { listen 7457; location / { default_type text/plain; return 200 "UP $request_method $request_uri\\n"; } }\n'
open(sys.argv[2], 'w').write(s[:i] + stub + '}\n')
PY
podman run -d --name "$NAME" -p "127.0.0.1:$PORT:7456" \
  -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro,Z" \
  -v "$WORK/nginx-auth.basic.conf:/etc/nginx/woow-auth.conf:ro,Z" \
  -v "$WORK/htpasswd:/etc/nginx/htpasswd:ro,Z" \
  -v "$WORK/od-export-bridge.js:/etc/nginx/od-export-bridge.js:ro,Z" \
  "$IMAGE" >/dev/null

B=http://127.0.0.1:$PORT
for _ in {1..30}; do curl -fs -o /dev/null "$B/api/health" && break; sleep 1; done

U=11111111-2222-3333-4444-555555555555
C=aaaaaaaa-2222-3333-4444-555555555555
failed=0
# check <description> <expected "status challenge"> <expected body substring or -> <curl args...>
check() {
  local what=$1 want=$2 body=$3 got
  shift 3
  curl -s -o "$WORK/b" -D "$WORK/h" "$@" || true
  got="$(awk 'NR==1{print $2}' "$WORK/h") $(grep -ci '^www-authenticate' "$WORK/h" || true)"
  if [[ $got != "$want" ]] || { [[ $body != - ]] && ! grep -qF -- "$body" "$WORK/b"; }; then
    echo "FAIL $what: got '$got', wanted '$want' body '$body'; body was: $(head -c 100 "$WORK/b")"
    failed=$((failed + 1))
  else
    echo "ok   $what"
  fi
}

# Open: reading a project's files.
check "raw GET"               "200 0" "UP GET /api/projects/$U/raw/a.png" "$B/api/projects/$U/raw/a.png"
check "preview GET"           "200 0" - "$B/api/projects/$U/preview/sc/a.png"
check "raw asset as image"    "200 0" - -H 'Sec-Fetch-Dest: image' "$B/api/projects/$U/raw/a.png"
check "health"                "200 0" - "$B/api/health"
# A thumbnail's relative asset goes to the file; the app's own /files/ route does not.
check "thumbnail asset"       "200 0" "UP GET /api/projects/$U/raw/logo.svg" -H 'Sec-Fetch-Dest: image' "$B/projects/$U/conversations/logo.svg"
check "thumbnail asset, dir"  "200 0" "/raw/assets/a.png" "$B/projects/$U/conversations/assets/a.png"
check "app route keeps path"  "200 0" "/conversations/$C/files/x.png" -u t:pw "$B/projects/$U/conversations/$C/files/x.png"

# Asks for the password.
check "app route"             "401 1" - "$B/projects/$U/conversations/$C/files/x.png"
check "root document"         "401 1" - -H 'Sec-Fetch-Dest: document' "$B/"
check "project list"          "401 1" - "$B/api/projects"
check "project metadata"      "401 1" - "$B/api/projects/$U"
check "models-config"         "401 1" - "$B/api/models-config"
check "raw PUT"               "401 1" - -X PUT "$B/api/projects/$U/raw/a.png"
check "raw POST"              "401 1" - -X POST "$B/api/projects/$U/raw/a.png"
check "preview renew"         "401 1" - -X POST "$B/api/projects/$U/preview/sc/renew"
check "raw, id is not a UUID" "401 1" - "$B/api/projects/abc/raw/a.png"
check "traversal"             "401 1" - --path-as-is "$B/api/projects/$U/raw/../../../models-config"
check "encoded traversal"     "401 1" - --path-as-is "$B/api/projects/$U/raw/%2e%2e/%2e%2e/%2e%2e/models-config"
check "encoded slash"         "401 1" - --path-as-is "$B/api/projects/$U/raw/..%2f..%2f..%2fmodels-config"
check "wrong password"        "401 1" - -u t:bad "$B/api/projects"

# Refused without a dialog: never reaches the daemon.
check "stray asset"           "401 0" - -H 'Sec-Fetch-Dest: image' "$B/logo.svg"
check "forged dest"           "401 0" - -H 'Sec-Fetch-Dest: image' "$B/api/models-config"

# Signed in.
check "right password"        "200 0" "UP GET /api/projects" -u t:pw "$B/api/projects"
check "stray asset, signed in" "200 0" - -u t:pw -H 'Sec-Fetch-Dest: image' "$B/logo.svg"

((failed == 0)) || { echo "nginx-auth: $failed check(s) failed"; exit 1; }
echo "nginx-auth: all checks passed"
