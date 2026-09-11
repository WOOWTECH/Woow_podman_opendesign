#!/usr/bin/env bash
# scripts/install.sh: install or update Woow OpenDesign (daemon + nginx front) as rootless Quadlet
# units (podman >= 4.9, systemd --user, linger). Idempotent: a re-run with nothing changed restarts
# nothing.
#
#   scripts/install.sh [options]
#
#   --set KEY=VALUE    store a per-host setting in ~/.config/open-design/open-design.env first
#                      (repeatable), e.g. --set WOOW_OD_PORT=27456. Only keys of the example file.
#   --no-build         do not build the image; fail when localhost/woow-open-design:<VERSION> is missing
#   --rebuild          build the image even when that tag already exists
#   --rotate-token     generate a new API token (and with it the browser password), then restart
#   --accept-defaults  on the first run, continue with the example settings instead of stopping
#   --no-start         install the files and daemon-reload only
#   --no-smoke         skip tests/smoke.sh at the end
#   --dry-run          render and validate, report what would change, touch nothing
#
# Order: preflight -> env and origin check -> guards -> render -> dry-run -> image -> pull -> secrets
# -> install -> apply -> health -> smoke.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=od-helpers.sh
. "$REPO/scripts/od-helpers.sh"

sets=() no_build=0 rebuild=0 rotate=0 accept=0 no_start=0 no_smoke=0
while (($#)); do
  case $1 in
    --set) (($# >= 2)) || ql_die "--set needs KEY=VALUE"; sets+=("$2"); shift ;;
    --set=*) sets+=("${1#--set=}") ;;
    --no-build) no_build=1 ;;
    --rebuild) rebuild=1 ;;
    --rotate-token) rotate=1 ;;
    --accept-defaults) accept=1 ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ------------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
app_lock

# ---- 2. per-host settings ---------------------------------------------------------------------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
if [[ $QL_ENV_CREATED == 1 && $accept == 0 && ${#sets[@]} == 0 ]]; then
  ql_info "review $ENV_FILE (at least OD_ALLOWED_ORIGINS), then run $0 again (or pass --accept-defaults)"
  exit 0
fi
((${#sets[@]} == 0)) || app_apply_sets "${sets[@]}"
app_env_load
app_env_overlay "${sets[@]}"
app_refuse_env_secrets
port=$(ql_env_get WOOW_OD_PORT)
bind=$(ql_env_get WOOW_OD_BIND)
auth=$(ql_env_get WOOW_OD_AUTH basic)
od_check_origins "$port" "$bind"

# ---- 3. legacy guards -------------------------------------------------------------------------
app_guard_containers

# ---- 4. stage, render, validate -----------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/out/config"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
RENDER_ARGS=()
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"
render_args "$RENDER_ENV"
ql_render "$WORK/src" "$RENDER_ENV" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
cp -p "$REPO/config/nginx.conf" "$REPO/config/od-export-bridge.js" "$WORK/out/config/"
cp -p "$REPO/config/nginx-auth.$auth.conf" "$WORK/out/config/nginx-auth.conf"
ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
  || ql_die "the rendered units failed the Quadlet dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# ---- 5. image, then the registry images and the secrets ---------------------------------------
if ((no_build)); then
  podman image exists "$OD_IMAGE" || [[ $dry == 1 ]] || ql_die "--no-build, but $OD_IMAGE is missing"
elif ((rebuild)); then
  od_build_image --force
else
  od_build_image
fi
ql_pull_images "$WORK/out"
restart_daemon=0 restart_nginx=0
if ((rotate)); then
  ql_secret_ensure open-design-api-token random:64 --replace
  restart_daemon=1 restart_nginx=1
else
  ql_secret_ensure open-design-api-token random:64
fi
if [[ $dry == 1 ]] && ! podman secret exists open-design-api-token; then
  ql_info "[dry-run] would derive secret open-design-htpasswd from the API token"
else
  QL_SECRET_CHANGED=0
  od_htpasswd_secret
  [[ $QL_SECRET_CHANGED == 0 ]] || restart_nginx=1
fi

# ---- 6. install changed files, then start / restart only what changed --------------------------
changed=$(ql_install_files "$WORK/out" "$APP" --prune)
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
grep -qE '^config/(nginx\.conf|nginx-auth\.conf|od-export-bridge\.js)$' <<<"$changed" && restart_nginx=1
app_env_changed && restart_daemon=1
if [[ $dry == 1 ]]; then
  ((restart_daemon)) && ql_info "[dry-run] would restart open-design.service (settings or token changed)"
  ((restart_nginx)) && ql_info "[dry-run] would restart open-design-nginx.service (front config changed)"
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
((restart_daemon == 0)) || ql_mark_changed "$APP" open-design.service
((restart_nginx == 0)) || ql_mark_changed "$APP" open-design-nginx.service
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start open-design.service"
  exit 0
fi
ql_apply_units "$APP" open-design.service open-design-nginx.service

# ---- 7. health and smoke ----------------------------------------------------------------------
app_wait_healthy open-design 300 open-design.service
app_wait_healthy open-design-nginx 120 open-design-nginx.service
host=$(app_local_host "$bind")
ql_wait_http "http://$host:$port/api/health" '200' 120 || ql_die "the nginx front does not answer on $host:$port"
app_env_record
if ((no_smoke == 0)); then
  "$REPO/tests/smoke.sh" || ql_die "tests/smoke.sh failed; see the FAIL lines above"
fi

cat >&2 <<EOF
$APP $OD_VERSION is installed and healthy.
  UI         http://$host:$port/
  Sign in    user "open-design", password = the API token:
             (private terminal) podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token
  Auth       WOOW_OD_AUTH=$auth
  Settings   $ENV_FILE (edit, then run scripts/install.sh again)
EOF
