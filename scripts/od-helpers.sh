# shellcheck shell=bash
# scripts/od-helpers.sh: OpenDesign-specific helpers, sourced after scripts/common.sh.

# od_check_origins <port> <bind>: every entry of OD_ALLOWED_ORIGINS must be a bare scheme://host[:port]
# (no path, no trailing slash), and the local origin for <port> must be there, or the smoke test and
# every SSH-tunnel user get HTTP 403 from the daemon's origin guard on all data routes.
od_check_origins() {
  local port=$1 bind=$2 origins entry local_origin=http://127.0.0.1:$1 found=0
  origins=$(ql_env_get OD_ALLOWED_ORIGINS '')
  [[ -n $origins ]] || ql_die "OD_ALLOWED_ORIGINS is empty; at least $local_origin is required"
  local IFS=,
  for entry in $origins; do
    [[ -n $entry ]] || continue
    ql_assert_match OD_ALLOWED_ORIGINS "$entry" 'https?://([^/:]+|\[[0-9a-fA-F:]+\])(:[0-9]{1,5})?'
    [[ $entry == "$local_origin" ]] && found=1
    # An https:// origin without a port is a TLS front (a tunnel or a reverse proxy) on 443, not
    # this host's published port.
    if [[ $entry != https://* && $entry != *:[0-9]* && $port != 80 && $port != 443 ]]; then
      ql_warn "OD_ALLOWED_ORIGINS entry '$entry' has no port while OpenDesign is published on $port"
    fi
  done
  ((found)) || ql_die "OD_ALLOWED_ORIGINS must contain $local_origin (the local smoke test and SSH-tunnel users need it)"
  if [[ $bind != 127.0.0.1 ]] && ! grep -qvE '^https?://(127\.0\.0\.1|localhost)' <<<"${origins//,/$'\n'}"; then
    ql_warn "WOOW_OD_BIND=$bind publishes beyond loopback, but OD_ALLOWED_ORIGINS only lists local origins"
  fi
}

# od_check_paseo <paseo> <auth> <out>: with WOOW_OD_PASEO=on, the Paseo bridge (which can start the
# agents and pair a phone) needs nginx's Basic auth in front of it and a concrete https:// origin that
# the daemon also accepts; its own origin check refuses anything else and it would not start. Writes
# the nginx include for either state to <out>.
od_check_paseo() {
  local paseo=$1 auth=$2 out=$3 origin re
  case $paseo in
    off)
      cp -p "$REPO/config/nginx-paseo.off.conf" "$out"
      return 0 ;;
    on) ;;
    *) ql_die "WOOW_OD_PASEO must be on or off, not '$paseo'" ;;
  esac
  [[ $auth == basic ]] || ql_die "WOOW_OD_PASEO=on requires WOOW_OD_AUTH=basic: the Paseo routes have no other credential check"
  origin=$(ql_env_get OPENDESIGN_PASEO_ORIGIN '')
  [[ $origin =~ ^https://[a-z0-9.-]+(:[0-9]{1,5})?$ ]] \
    || ql_die "WOOW_OD_PASEO=on requires OPENDESIGN_PASEO_ORIGIN=https://<host>[:port] (lower case, no path); it is '$origin'"
  [[ ,$(ql_env_get OD_ALLOWED_ORIGINS ''), == *",$origin,"* ]] \
    || ql_die "OPENDESIGN_PASEO_ORIGIN ($origin) must also be listed in OD_ALLOWED_ORIGINS"
  # \\. survives sed as \. : a literal dot in the nginx regex.
  re=${origin//./\\\\.}
  sed "s|@@PASEO_ORIGIN_RE@@|$re|g" "$REPO/config/nginx-paseo.on.conf" >"$out"
  ! grep -q '@@' "$out" || ql_die "the Paseo nginx include was not rendered"
}

# od_check_auth <auth> <bind>: Basic auth may only be turned off while the front is on loopback.
# nginx is the only thing in front of the daemon, and /api/models-config returns the configured
# provider keys, so auth=off on a routable address publishes them to the whole network -- which is
# exactly the state this repo's Quadlet conversion exists to end. Loopback plus an SSH tunnel or an
# authenticated reverse proxy (NPM, Cloudflare Access) is the supported way to expose it.
od_check_auth() {
  local auth=$1 bind=$2
  [[ $auth == off ]] || return 0
  [[ $bind == 127.0.0.1 || $bind == ::1 ]] && return 0
  ql_die "WOOW_OD_AUTH=off is only allowed with WOOW_OD_BIND=127.0.0.1. WOOW_OD_BIND is currently
'$bind', which would serve /api/models-config (your provider keys) to anyone who can reach this host.
Either set WOOW_OD_AUTH=basic, or keep the front on loopback and put an authenticating proxy in front."
}

# od_htpasswd_secret: derive the nginx Basic-auth file from the API token secret (user "open-design",
# password = that token), so one credential covers the browser and API clients. apr1 comes from
# openssl, because the hosts have no htpasswd binary. The salt is derived from the token instead of
# being random, so an unchanged token derives the same file and a re-run changes nothing; a rotated
# token changes it, and the caller restarts nginx. Sets QL_SECRET_CHANGED when it changed.
od_htpasswd_secret() {
  local xt=0 token salt hash OD_HTPASSWD
  [[ $- == *x* ]] && xt=1 && set +x
  command -v openssl >/dev/null 2>&1 || { ((xt)) && set -x; ql_die "openssl is required to derive the nginx credential"; }
  token=$(app_secret_read open-design-api-token || true)
  if [[ -z $token ]]; then
    ((xt)) && set -x
    ql_die "secret open-design-api-token must exist before the nginx credential is derived"
  fi
  salt=$(printf '%s' "$token" | sha256sum) && salt=${salt:0:8}
  hash=$(printf '%s' "$token" | openssl passwd -apr1 -salt "$salt" -stdin) || hash=''
  token=''
  if [[ -z $hash ]]; then
    ((xt)) && set -x
    ql_die "openssl passwd -apr1 failed"
  fi
  # shellcheck disable=SC2034 # read by ql_secret_ensure env:OD_HTPASSWD below
  OD_HTPASSWD="open-design:$hash"
  ql_secret_ensure open-design-htpasswd env:OD_HTPASSWD --update
  unset OD_HTPASSWD
  ((xt)) && set -x
  return 0
}

# od_build_image [--force]: build localhost/woow-open-design:<VERSION> from Dockerfile.full when it is
# missing. nice + --cpuset-cpus keep the build from starving co-located stacks.
od_build_image() {
  local force=${1:-} args=() cpus
  if [[ $force != --force ]] && podman image exists "$OD_IMAGE"; then
    ql_info "image $OD_IMAGE is already present"
    return 0
  fi
  if [[ ${QL_DRY_RUN:-0} == 1 ]]; then ql_info "[dry-run] would build $OD_IMAGE from Dockerfile.full"; return 0; fi
  cpus=$(ql_env_get WOOW_OD_BUILD_CPUS '')
  [[ -z $cpus ]] || args+=(--cpuset-cpus "$cpus")
  ql_info "building $OD_IMAGE (10-20 minutes on a small host)"
  nice -n 10 podman build --format=docker "${args[@]}" \
    --build-arg "BUILD_VERSION=$OD_VERSION" \
    --build-arg "BUILD_REF=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t "$OD_IMAGE" -f "$REPO/Dockerfile.full" "$REPO" \
    || ql_die "podman build failed; nothing was changed"
  ql_info "built $OD_IMAGE"
}

# od_repair_data_ownership <volume>: give every path in a volume back to the account that owns it. 3.0.0 ran its image build as root with HOME inside the volume path, so a volume it created
# got a root-owned home/ by copy-up; the daemon cannot chown it (there is no root under keep-id), and
# the agents could not write their logins. A restore can bring the same paths back. In `podman
# unshare` this account is uid 0. -xdev stays on this mount, and -h changes a symlink, not its target.
od_repair_data_ownership() {
  local volume=$1 mp count
  podman volume exists "$volume" || return 0
  mp=$(podman volume inspect --format '{{.Mountpoint}}' "$volume")
  [[ $mp == /* && $mp != / ]] || ql_die "unexpected mountpoint for $volume"
  count=$(podman unshare find "$mp" -xdev \( ! -user 0 -o ! -group 0 \) -print | wc -l)
  ((count > 0)) || return 0
  if [[ ${QL_DRY_RUN:-0} == 1 ]]; then
    ql_info "[dry-run] would return $count path(s) in $volume to $(id -un)"
    return 0
  fi
  podman unshare find "$mp" -xdev \( ! -user 0 -o ! -group 0 \) -exec chown -h 0:0 {} +
  ql_info "returned $count path(s) in $volume to $(id -un)"
}
