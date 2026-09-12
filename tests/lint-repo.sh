#!/usr/bin/env bash
# tests/lint-repo.sh: static repository checks for CI (.github/workflows/repo-checks.yml) and local
# use. Creates nothing and needs no podman.
#
#   1. no plaintext credentials or well-known default passwords in tracked files
#   2. the compose deployment is gone (decision D1: Docker users use the compose-final tag)
#   3. both READMEs lead with the Quadlet install and point Docker users to compose-final
#   4. repo-specific checks (lint_local, at the end of this file): VERSION parity, the nginx
#      credential boundary, the loopback bind and the pids limits
#
# Matches are reported as file:line only; the matched text is never printed.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$REPO"
fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
ok() { printf 'ok   %s\n' "$*"; }
# where <hits>: print file:line only, never the matched text
where() { cut -d: -f1,2 | sed 's/^/     /'; }

# The vendored library and this script itself carry the patterns by nature.
mapfile -t files < <(git ls-files --cached --others --exclude-standard \
  | grep -vE '^(scripts/lib/quadlet-lib\.sh|tests/lint-repo\.sh)$' || true)
text=()
for f in "${files[@]}"; do [[ -f $f ]] && grep -Iq . "$f" 2>/dev/null && text+=("$f"); done

# ---- 1. credentials ------------------------------------------------------------------------------
# KEY=value lines whose key names a credential and whose value is a literal (not empty, not a
# $VAR / @@TOKEN@@ / <placeholder> / *_FILE path).
cred_re='(^|[^A-Za-z0-9_])[A-Z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|_KEY)=[^[:space:]$@<"'\''`{}(%]'
# Obvious placeholders (dummy/example/placeholder/changeme/redacted values) are not credentials.
hits=$(grep -nHE "$cred_re" "${text[@]}" 2>/dev/null \
  | grep -vE '(_FILE|_PATH)=' \
  | grep -viE '=[A-Za-z0-9_-]*(dummy|example|placeholder|changeme|redacted|your[_-]?)[A-Za-z0-9_-]*([[:space:]]|$)' || true)
if [[ -n $hits ]]; then fail "literal credential assignments at:"; where <<<"$hits"; else ok "no literal credential assignments"; fi
# Well-known defaults and token formats.
known='admin_passwd[[:space:]]*=[[:space:]]*admin([[:space:]]|$)|DEFAULT_PASSWORD[=:][[:space:]]*public|DASHBOARD_PASSWORD[=:][[:space:]]*(public|admin)([[:space:]]|$)'
known+='|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{32,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}'
known+='|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJhbGciOi[A-Za-z0-9_-]{20,}\.'
hits=$(grep -nHE "$known" "${text[@]}" 2>/dev/null || true)
if [[ -n $hits ]]; then fail "default passwords or token-shaped strings at:"; where <<<"$hits"; else ok "no default passwords or token-shaped strings"; fi

# ---- 2. D1: compose files are gone ---------------------------------------------------------------
left=$(printf '%s\n' "${files[@]}" | grep -E '(^|/)(docker|podman)-compose[^/]*\.ya?ml$|^compose/|^\.env\.example$' || true)
if [[ -n $left ]]; then fail "compose deployment files remain (D1):"; while IFS= read -r l; do printf "     %s\n" "$l"; done <<<"$left"; else ok "no compose files (D1)"; fi

# ---- 3. READMEs --------------------------------------------------------------------------------
for r in README.md README_zh-TW.md; do
  if [[ ! -f $r ]]; then fail "$r is missing"; continue; fi
  grep -q 'scripts/install.sh' "$r" || fail "$r does not document scripts/install.sh"
  grep -q 'compose-final' "$r" || fail "$r does not point Docker users to the compose-final tag"
  if grep -qi 'portainer' "$r"; then fail "$r still mentions Portainer"; fi
done
ok "README checks done"

# ---- 4. repo-specific ----------------------------------------------------------------------------
lint_local() {
  # The local image tag must equal VERSION, so an upgrade builds a new tag and the previous image
  # stays available for a rollback.
  local version unit_img
  version=$(cat VERSION)
  unit_img=$(sed -n 's/^Image=//p' quadlet/open-design.container)
  [[ $unit_img == "localhost/woow-open-design:$version" ]] \
    || fail "quadlet/open-design.container pins $unit_img, but VERSION says $version"
  # The registry image is pinned by digest.
  unit_img=$(sed -n 's/^Image=//p' quadlet/open-design-nginx.container)
  [[ $unit_img == *@sha256:* ]] || fail "image not pinned by digest: $unit_img"
  # The credential boundary: nginx checks credentials, /api/health is the only exemption, and the
  # export bridge is still injected.
  grep -qF 'include /etc/nginx/woow-auth.conf;' config/nginx.conf || fail "config/nginx.conf lost the credential include"
  grep -qF 'auth_basic_user_file /etc/nginx/htpasswd;' config/nginx-auth.basic.conf || fail "the basic auth variant no longer asks for a password"
  grep -qF 'sub_filter' config/nginx.conf || fail "config/nginx.conf lost the export-bridge injection"
  grep -qxF 'WOOW_OD_AUTH=basic' config/open-design.env.example || fail "the shipped default is no longer WOOW_OD_AUTH=basic"
  # The daemon keeps its loopback bind and the limits podman-compose dropped.
  grep -qxF 'Environment=OD_BIND_HOST=127.0.0.1' quadlet/open-design.container || fail "the daemon no longer binds loopback only"
  grep -qxF 'PidsLimit=512' quadlet/open-design.container || fail "the daemon has no PidsLimit"
  grep -qxF 'PidsLimit=128' quadlet/open-design-nginx.container || fail "nginx has no PidsLimit"
  # The dropped compose-era env names must not come back.
  if grep -rqE 'OPEN_DESIGN_(IMAGE|DISABLE_API_AUTH|MEM_LIMIT|ALLOWED_ORIGINS)' config quadlet scripts 2>/dev/null; then
    fail "a compose-era OPEN_DESIGN_* variable is back (use OD_ALLOWED_ORIGINS and the WOOW_OD_* knobs)"
  fi
  ok "OpenDesign checks done"
}
lint_local

((fails == 0)) && echo "lint-repo: all checks passed" || echo "lint-repo: $fails check(s) failed"
((fails == 0))
