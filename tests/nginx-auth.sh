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
# Paseo on, rendered as install.sh does, for a made-up HTTPS origin.
PASEO_ORIGIN=https://od.example.com
sed "s|@@PASEO_ORIGIN_RE@@|https://od\\\\.example\\\\.com|g" "$REPO/config/nginx-paseo.on.conf" >"$WORK/nginx-paseo.conf"
echo "t:$(openssl passwd -apr1 pw)" >"$WORK/htpasswd"
# Every upstream becomes a stub that echoes the request line, so a body shows the daemon was reached;
# the Paseo bridge's stub says PASEO.
python3 - "$REPO/config/nginx.conf" "$WORK/nginx.conf" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'proxy_pass http://(127\.0\.0\.1:(8081|7681)|unix:/run/od-mcp/admin\.sock:/);', 'proxy_pass http://127.0.0.1:7457;', s)
i = s.rstrip().rfind('}')
stub = ('server { listen 7457; location / { default_type text/plain; return 200 "UP $request_method $request_uri\\n"; } }\n'
        'server { listen 7460; location / { default_type text/plain; return 200 "PASEO $request_method $request_uri\\n"; } }\n')
open(sys.argv[2], 'w').write(s[:i] + stub + '}\n')
PY
podman run -d --name "$NAME" -p "127.0.0.1:$PORT:7456" \
  -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro,Z" \
  -v "$WORK/nginx-auth.basic.conf:/etc/nginx/woow-auth.conf:ro,Z" \
  -v "$WORK/nginx-paseo.conf:/etc/nginx/woow-paseo.conf:ro,Z" \
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

# Paseo: behind the sign-in, a change needs the Paseo origin, and the bridge's health stays private.
check "paseo setup, no cred"     "401 1" - "$B/paseo/setup/"
check "paseo setup"              "200 0" "PASEO GET /paseo/setup/" -u t:pw "$B/paseo/setup/"
check "paseo setup, no slash"    "200 0" "PASEO GET /paseo/setup" -u t:pw "$B/paseo/setup"
check "paseo asset"              "200 0" "PASEO GET /paseo/assets/a.js" -u t:pw "$B/paseo/assets/a.js"
check "paseo asset, no cred"     "401 1" - "$B/paseo/assets/a.js"
check "paseo POST, its origin"   "200 0" "PASEO POST /api/paseo-bridge" -u t:pw -X POST -H "Origin: $PASEO_ORIGIN" "$B/api/paseo-bridge"
check "paseo POST, other origin" "403 0" - -u t:pw -X POST -H 'Origin: https://evil.example' "$B/api/paseo-bridge"
check "paseo POST, look-alike"   "403 0" - -u t:pw -X POST -H 'Origin: https://odxexample.com' "$B/api/paseo-bridge"
check "paseo POST, suffix"       "403 0" - -u t:pw -X POST -H "Origin: $PASEO_ORIGIN.evil" "$B/api/paseo-bridge"
check "paseo POST, no origin"    "403 0" - -u t:pw -X POST "$B/api/paseo-bridge"
check "paseo GET, other origin"  "403 0" - -u t:pw -H 'Origin: https://evil.example' "$B/api/paseo-bridge"
check "paseo GET, no origin"     "200 0" "PASEO GET /api/paseo-bridge" -u t:pw "$B/api/paseo-bridge"
check "paseo POST, no cred"      "401 1" - -X POST -H "Origin: $PASEO_ORIGIN" "$B/api/paseo-bridge"
check "bridge health not routed" "200 0" "UP GET /healthz" -u t:pw "$B/healthz"
check "other paseo path"         "200 0" "UP GET /paseo/other" -u t:pw "$B/paseo/other"

# Paseo off: nginx accepts the include and answers without reaching anything.
cp "$REPO/config/nginx-paseo.off.conf" "$WORK/nginx-paseo.conf"
podman exec "$NAME" nginx -s reload >/dev/null 2>&1
sleep 1
check "paseo off"                "503 0" "Paseo is off" -u t:pw "$B/paseo/setup/"
check "paseo off, bridge API"    "401 1" - "$B/api/paseo-bridge"

((failed == 0)) || { echo "nginx-auth: $failed check(s) failed"; exit 1; }
echo "nginx-auth: all checks passed"
