#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move an existing podman-compose / docker-compose OpenDesign deployment
# (compose project "open-design": containers open-design and open-design-nginx, both on the HOST
# network, volume open-design_open_design_data, an nginx.conf and od-export-bridge.js bind-mounted
# from the build directory) to the Quadlet units of this repo.
#
# The data volume is ADOPTED IN PLACE: quadlet/open-design-data.volume keeps the podman-compose
# name, so the same volume is opened again and every project, board, app.sqlite row and OpenCode
# credential stays where it is. Nothing is copied. The legacy containers stay for --rollback.
#
# Two things deliberately CHANGE, because they are why this repo's Quadlet conversion exists:
#   * Networking. The legacy pair ran with `network_mode: host`, so nginx listened on every
#     interface and the daemon held 127.0.0.1:7457 on the host itself. The Quadlet daemon owns a
#     private network namespace, nginx joins it (Network=container:open-design), and only nginx's
#     port is published - on 127.0.0.1 unless --bind says otherwise.
#   * Authentication. The legacy front had no credential check at all (on woowtechopenclaw
#     http://192.168.2.197:7456 is reachable by anything on the LAN). The Quadlet front asks for
#     HTTP Basic auth as user "open-design" with the API token as the password. --auth off is
#     accepted only while the front stays on loopback.
# Both are reported before the cutover and again at the end.
#
#   scripts/migrate-legacy.sh [--legacy-dir DIR] [--bind ADDR] [--port N] [--auth basic|off]
#                             [--suffix S] [--force-capture] [--no-cold-copy]
#                             [--allow-version-change] [--prepare-only | --dry-run]
#                             [--no-auto-rollback] [--yes]
#   scripts/migrate-legacy.sh --rollback [--yes]
#   scripts/migrate-legacy.sh --status
#
#   --legacy-dir DIR         the old build directory (~/od-podman-align on woowtechopenclaw); its
#                            compose file and .env are archived into the backup. Everything the
#                            migration needs is read from the running containers, not from here.
#   --bind ADDR              where the new front publishes (default 127.0.0.1; the legacy stack was
#                            on every interface). "all" keeps the old reach.
#   --port N                 the host port (default: the `listen` directive of the legacy nginx.conf)
#   --auth basic|off         nginx credential check (default basic; "off" needs --bind 127.0.0.1)
#   --suffix S               the legacy containers become <name>-legacy-S (rename path only)
#   --force-capture          take the capture path even where this host would allow a rename
#   --no-cold-copy           skip the cold `podman volume export` during the cutover
#   --allow-version-change   continue although the legacy daemon and the image this repo builds are
#                            different OpenDesign minor versions
#   --prepare-only           steps 1-2 only, no downtime: checks, secrets, THE IMAGE BUILD, backup
#   --dry-run                step 1 and a render of the units; changes nothing
#   --no-auto-rollback       leave a failed cutover in place for inspection
#   --rollback               undo the cutover and bring the legacy containers back
#   --status                 print the recorded migration state
#
# Rollback shape (STANDARD 7a): the legacy containers are kept for --rollback either by renaming
# them and leaving them stopped, or - where the user unit podman-restart.service is enabled and a
# legacy container's restart policy is exactly `always`, because a renamed copy would revive at the
# next boot and a second OpenDesign would open the same data volume - by capturing them into the
# backup directory and removing them. ql_rollback_strategy decides from this host's real state,
# never from its name. The capture is taken before any downtime.
#
# Steps:  1 pre-flight checks: containers, the data volume, the front's port, the app version, the
#           origin list, and the two config files the legacy nginx reads
#         2 prepare (no downtime): env file, secrets, THE IMAGE BUILD (10-20 minutes; doing it here
#           is what keeps the cutover short), backup, volume fingerprint, capture
#         3 cutover: stop the legacy containers, cold volume export, retire them (downtime starts
#           here and is measured)
#         4 scripts/install.sh --no-build adopts the volume
#         5 prove the adoption, wait for /api/health, tests/smoke.sh, report the downtime
#         6 --rollback when needed
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=od-helpers.sh
. "$REPO/scripts/od-helpers.sh"
# shellcheck source=legacy-helpers.sh
. "$REPO/scripts/legacy-helpers.sh"

OD_CONTAINER=open-design
NGINX_CONTAINER=open-design-nginx
# Dependency first: open-design-nginx is created with --requires=open-design.
LEGACY_ALL=("$OD_CONTAINER" "$NGINX_CONTAINER")
DATA_VOLUME=open-design_open_design_data
# The legacy pair had no systemd unit at all on woowtechopenclaw (OPENCLAW_FACTS 7.3). These are the
# names a hand-written one would have had; an absent unit is the normal case, not an error.
LEGACY_UNITS=(open-design.service podman-open-design.service)
STATE=$(app_state_dir)/migration.state

mode=migrate legacy_dir='' bind=127.0.0.1 port='' auth=basic suffix=$(date +%Y%m%d)
force_capture=0 cold_copy=1 allow_version=0 auto_rollback=1 ASSUME_YES=0
while (($#)); do
  case $1 in
    --legacy-dir) legacy_dir=${2:?--legacy-dir needs a directory}; shift ;;
    --bind) bind=${2:?--bind needs an address}; shift ;;
    --port) port=${2:?--port needs a number}; shift ;;
    --auth) auth=${2:?--auth needs basic or off}; shift ;;
    --suffix) suffix=${2:?--suffix needs a value}; shift ;;
    --force-capture) force_capture=1 ;;
    --no-cold-copy) cold_copy=0 ;;
    --allow-version-change) allow_version=1 ;;
    --prepare-only) mode=prepare ;;
    --dry-run) mode=dry-run ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,62p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_assert_match --suffix "$suffix" '[A-Za-z0-9._-]+'
ql_assert_match --auth "$auth" 'basic|off'
ql_assert_match --bind "$bind" 'all|[0-9]{1,3}(\.[0-9]{1,3}){3}'

state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -n1; fi; }
state_set() {
  local dir tmp
  dir=$(app_state_dir)
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.migration.XXXXXX")
  { if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$STATE"
}

if [[ $mode == status ]]; then
  if [[ -f $STATE ]]; then cat "$STATE"; else echo "no migration recorded in $STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
app_lock

legacy_url() { printf 'http://127.0.0.1:%s' "$(state_get LEGACY_PORT)"; }

# =================================================================================================
# 6. rollback
# =================================================================================================
rollback() {
  local status sfx bk c u want now i
  local -a retired=() units=() legacy_ids=()
  status=$(state_get STATUS) sfx=$(state_get SUFFIX) bk=$(state_get BACKUP)
  read -ra retired <<<"$(state_get RETIRED)"
  [[ $status == cutover || $status == "done" ]] || ql_die "nothing to roll back (migration status: ${status:-none})"
  ((${#retired[@]})) || ql_die "no legacy containers recorded in $STATE"
  app_confirm open-design "$ASSUME_YES" "--rollback removes the OpenDesign Quadlet units and brings the legacy containers back"
  ql_info "stopping and removing the Quadlet units (the data volume and the secrets are kept)"
  ql_uninstall_units "$APP"
  rm -f -- "$(app_state_dir)/applied-env.sha256"
  # Quadlet runs its containers with --replace, so a unit that got as far as starting leaves a
  # container of our name behind. Remove only what is demonstrably ours; a container that is
  # demonstrably the LEGACY one (its id is the one recorded before the cutover, i.e. the cutover
  # stopped it but died before retiring it) is left where it is, for app_legacy_restore to pick up.
  read -ra legacy_ids <<<"$(state_get LEGACY_IDS)"
  for i in "${!retired[@]}"; do
    c=${retired[i]}
    podman container exists "$c" || continue
    want=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c" 2>/dev/null || true)
    if [[ $want == open-design.service || $want == open-design-nginx.service ]]; then
      podman rm -f "$c" >/dev/null
      continue
    fi
    now=$(podman inspect --format '{{.Id}}' "$c" 2>/dev/null || true)
    [[ -n $now && $now == "${legacy_ids[i]:-}" ]] \
      || ql_die "container $c exists, is not a Quadlet leftover of this repo (PODMAN_SYSTEMD_UNIT='$want') and is not the legacy container recorded before the cutover; resolve it by hand"
    ql_info "$c is the legacy container the cutover stopped but never retired; keeping it"
  done
  # renamed back, or recreated from the capture the cutover took - whichever the host needed
  app_legacy_restore "$sfx" "$bk" "${retired[@]}"
  read -ra units <<<"$(state_get LEGACY_UNITS_ENABLED)"
  for u in "${units[@]}"; do
    [[ -n $u ]] || continue
    systemctl --user enable "$u" >/dev/null 2>&1 || ql_warn "could not re-enable $u"
    systemctl --user start "$u" || ql_warn "could not start $u; starting the containers directly"
  done
  # Whether or not a unit did it, the containers have to run again: the daemon before its front.
  for c in "${retired[@]}"; do
    if podman container exists "$c" && ! app_running "$c"; then app_unlocked podman start "$c" >/dev/null; fi
  done
  ql_wait_http "$(legacy_url)/api/health" '200' 300 \
    || ql_die "the legacy OpenDesign did not answer on $(legacy_url)/api/health after the rollback; check: podman logs $NGINX_CONTAINER"
  state_set STATUS rolled-back
  ql_info "rolled back: the legacy stack serves again on $(legacy_url)/ (host networking, no credential check). Backup of the attempt: $bk"
  ql_info "the data volume $DATA_VOLUME and the open-design-* podman secrets are shared with the legacy stack and were deliberately left in place; the empty Quadlet network can go with: podman network rm open-design"
}

if [[ $mode == rollback ]]; then
  rollback
  exit 0
fi

# =================================================================================================
# 1. pre-flight checks (read-only; every one of them refuses rather than guesses)
# =================================================================================================
ql_info "step 1/5: pre-flight checks"
case $(state_get STATUS) in
  cutover | "done")
    ql_die "a migration is already recorded in $STATE (STATUS=$(state_get STATUS)). Re-running would migrate a second time; use --status, or --rollback" ;;
esac
if [[ $mode == dry-run ]]; then QL_DRY_RUN=1 ql_enable_linger; else ql_enable_linger; fi

for c in "${LEGACY_ALL[@]}"; do
  podman container exists "$c" || ql_die "legacy container $c not found; this host has no compose OpenDesign deployment to migrate"
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c" 2>/dev/null || true)
  case $label in
    open-design.service | open-design-nginx.service)
      ql_die "$c is already managed by the Quadlet units of this repo (PODMAN_SYSTEMD_UNIT=$label); this host needs no migration" ;;
  esac
  app_running "$c" || ql_die "legacy container $c is not running; start the legacy stack first (the checks below read it)"
done
if app_is_installed && [[ $(state_get STATUS) != prepared ]]; then
  ql_die "the OpenDesign Quadlet units are already installed on this host ($(app_state_dir)/manifest); this host needs no migration"
fi

# --- the data is where we expect it -------------------------------------------------------------
data_mount=$(app_mount_source "$OD_CONTAINER" /app/.od)
[[ ${data_mount%%|*} == volume ]] || ql_die "$OD_CONTAINER does not mount a named volume at /app/.od (got '${data_mount:-nothing}'); this migration adopts a volume, not a bind directory"
data_vol=$(cut -d'|' -f2 <<<"$data_mount")
[[ $data_vol == "$DATA_VOLUME" ]] || ql_die "$OD_CONTAINER uses the volume '$data_vol', but quadlet/open-design-data.volume pins VolumeName=$DATA_VOLUME. Adopting would start on an empty app.sqlite; rename the volume or adjust the unit first"

# --- the two files the legacy nginx reads --------------------------------------------------------
legacy_nginx_conf=$(cut -d'|' -f3 <<<"$(app_mount_source "$NGINX_CONTAINER" /etc/nginx/nginx.conf)")
legacy_bridge=$(cut -d'|' -f3 <<<"$(app_mount_source "$NGINX_CONTAINER" /etc/nginx/od-export-bridge.js)")
[[ -r $legacy_nginx_conf ]] || ql_die "cannot read the nginx.conf $NGINX_CONTAINER mounts ('${legacy_nginx_conf:-nothing}'); it is the only statement of which host port this stack serves"
[[ -r $legacy_bridge ]] || ql_warn "cannot read the export bridge $NGINX_CONTAINER mounts ('${legacy_bridge:-nothing}')"

# --- the host port the legacy front serves -------------------------------------------------------
# Host networking means podman records no port binding at all, so the listen directive is the only
# source. --port overrides it.
if [[ -z $port ]]; then
  port=$(od_nginx_listen_port "$legacy_nginx_conf") \
    || ql_die "cannot determine the host port the legacy front serves from $legacy_nginx_conf; pass --port"
fi
ql_assert_match "the publish port" "$port" '[1-9][0-9]{0,4}'
((port <= 65535)) || ql_die "--port $port is not a TCP port"
mapfile -t publishers < <(app_port_publishers "$port")
for c in "${publishers[@]:-}"; do
  [[ -z $c ]] && continue
  case $c in "$OD_CONTAINER" | "$NGINX_CONTAINER") ;; *) ql_die "container $c also publishes host port $port; the Quadlet front could not bind it" ;; esac
done
mapfile -t listeners < <(app_port_listeners "$port")
ql_info "host port $port currently has ${#listeners[@]} listener(s): ${listeners[*]:-none}"
od_check_auth "$auth" "$bind"

# --- the version this repo would install must be the version that is running ---------------------
legacy_version=$(od_health_version "http://127.0.0.1:$port")
target_version=$(od_dockerfile_od_version "$REPO/Dockerfile.full")
[[ -n $legacy_version ]] || ql_warn "the legacy front did not answer /api/health on 127.0.0.1:$port; the version check is skipped"
[[ -n $target_version ]] || ql_warn "cannot read the pinned OpenDesign version from Dockerfile.full; the version check is skipped"
if [[ -n $legacy_version && -n $target_version && $(od_version_series "$legacy_version") != "$(od_version_series "$target_version")" ]]; then
  if ((allow_version)); then
    ql_warn "--allow-version-change: the legacy daemon is OpenDesign $legacy_version and this checkout builds $target_version; the adopted app.sqlite will be opened by a different minor version"
  else
    ql_die "the legacy daemon runs OpenDesign $legacy_version but this checkout builds $target_version. A migration must not smuggle in an upgrade of the app that owns app.sqlite; align the versions, or pass --allow-version-change if you have decided this is safe"
  fi
fi

# --- the settings the daemon is running with, which the new env file has to reproduce ------------
legacy_origins=$(od_legacy_env "$OD_CONTAINER" OD_ALLOWED_ORIGINS)
origins=$(od_origins_with_local "$legacy_origins" "$port")
[[ $origins == "$legacy_origins" ]] \
  || ql_info "adding http://127.0.0.1:$port to OD_ALLOWED_ORIGINS (install.sh and tests/smoke.sh need the local origin; the daemon answers 403 on every data route without it)"
node_options=$(od_legacy_env "$OD_CONTAINER" NODE_OPTIONS)
codex_sandbox=$(od_legacy_env "$OD_CONTAINER" OD_CODEX_SANDBOX)
mem=$(od_bytes_to_size "$(podman inspect --format '{{.HostConfig.Memory}}' "$OD_CONTAINER" 2>/dev/null || echo 0)")
cpus=$(od_nanocpus_to_cpus "$(podman inspect --format '{{.HostConfig.NanoCpus}}' "$OD_CONTAINER" 2>/dev/null || echo 0)")
LEGACY_TOKEN=$(od_legacy_env "$OD_CONTAINER" OD_API_TOKEN)
adopt_token=0
if [[ $LEGACY_TOKEN =~ ^[A-Za-z0-9._-]{16,}$ ]]; then
  adopt_token=1
  ql_info "the legacy OD_API_TOKEN will be adopted into the open-design-api-token secret, so existing API clients keep working"
else
  ql_warn "the legacy stack has no usable OD_API_TOKEN; install.sh generates one. It is also the browser password for user \"open-design\""
fi
if [[ $(od_legacy_env "$OD_CONTAINER" OD_DISABLE_API_AUTH) == 1 ]]; then
  ql_warn "the legacy daemon runs with OD_DISABLE_API_AUTH=1. That key is NOT carried over: the Quadlet daemon exempts loopback peers (which is all nginx ever is) and checks the token for everything else"
fi

# --- how the legacy containers are kept for --rollback -------------------------------------------
STRATEGY=$(ql_rollback_strategy "${LEGACY_ALL[@]}")
if ((force_capture)) && [[ $STRATEGY == rename ]]; then
  STRATEGY=capture
  ql_info "--force-capture: taking the capture path although this host would allow a rename (the legacy containers are removed after being captured into the backup directory, and --rollback recreates them)"
fi
if [[ $STRATEGY == rename ]]; then
  for c in "${LEGACY_ALL[@]}"; do
    if podman container exists "$c-legacy-$suffix"; then ql_die "$c-legacy-$suffix already exists; pick another --suffix"; fi
  done
fi

legacy_units_present=() legacy_units_enabled=()
for u in "${LEGACY_UNITS[@]}"; do
  if app_unit_exists "$u"; then
    legacy_units_present+=("$u")
    [[ $(systemctl --user is-enabled "$u" 2>/dev/null || true) == enabled ]] && legacy_units_enabled+=("$u")
  fi
done
if ((${#legacy_units_present[@]})); then
  ql_info "legacy units on this host: ${legacy_units_present[*]} (enabled: ${legacy_units_enabled[*]:-none})"
else
  ql_warn "no systemd unit keeps this stack alive (that is the state on woowtechopenclaw: it would not come back after a reboot). --rollback starts the legacy containers with podman start, the same way"
fi
ql_info "legacy OpenDesign ${legacy_version:-?} on host port $port, both containers on the HOST network"
ql_info "data volume: $data_vol - adopted in place"
ql_info "nginx.conf:  $legacy_nginx_conf"
ql_info "after the cutover the front is published on ${bind}:${port} with auth=$auth, and the daemon's 7457 leaves the host loopback entirely"

# =================================================================================================
# derive the env file the Quadlet units render from
# =================================================================================================
derive_env() {
  local f=$1
  ql_env_set "$f" WOOW_OD_BIND "$bind"
  ql_env_set "$f" WOOW_OD_PORT "$port"
  ql_env_set "$f" WOOW_OD_AUTH "$auth"
  ql_env_set "$f" OD_ALLOWED_ORIGINS "$origins"
  [[ -z $mem ]] || ql_env_set "$f" WOOW_OD_MEMORY "$mem"
  [[ -z $cpus ]] || ql_env_set "$f" WOOW_OD_CPUS "$cpus"
  [[ -z $node_options ]] || ql_env_set "$f" NODE_OPTIONS "$node_options"
  ql_env_set "$f" OD_CODEX_SANDBOX "$codex_sandbox"
  # The BYOK keys live in the daemon's environment on the legacy stack; keep whatever is set.
  local k v
  for k in DEEPSEEK_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY; do
    v=$(od_legacy_env "$OD_CONTAINER" "$k")
    ql_env_set "$f" "$k" "$v"
  done
}
app_render() {
  local w=$1 env=$2
  local -a RENDER_ARGS=()
  mkdir -p "$w/src" "$w/out/config"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$w/src/"
  ql_env_load "$env"
  # shellcheck source=render-args.sh
  . "$REPO/scripts/render-args.sh"
  render_args "$env"
  ql_render "$w/src" "$env" "$REPO/quadlet/render-vars" "$w/out" "${RENDER_ARGS[@]}"
  cp -p "$REPO/config/nginx.conf" "$REPO/config/od-export-bridge.js" "$w/out/config/"
  cp -p "$REPO/config/nginx-auth.$auth.conf" "$w/out/config/nginx-auth.conf"
  ql_dryrun "$w/out" --verify --ref-dir "$QL_QUADLET_DIR_REF" \
    || ql_die "the rendered units failed the Quadlet dry-run; nothing was installed"
}
QL_QUADLET_DIR_REF=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-migrate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [[ $mode == dry-run ]]; then
  if [[ -f $ENV_FILE ]]; then cp -p -- "$ENV_FILE" "$WORK/$APP.env"; else install -m 600 -- "$ENV_EXAMPLE" "$WORK/$APP.env"; fi
  derive_env "$WORK/$APP.env"
  ql_env_load "$WORK/$APP.env"
  od_check_origins "$port" "$bind"
  app_render "$WORK/render" "$WORK/$APP.env"
  if [[ $STRATEGY == capture ]]; then
    ql_info "dry-run: every check passed and the units render. The cutover would capture ${LEGACY_ALL[*]} into the backup directory and remove them, and install:"
  else
    ql_info "dry-run: every check passed and the units render. The cutover would rename ${LEGACY_ALL[*]} to *-legacy-$suffix and install:"
  fi
  sed 's/^/    /' < <(grep -vE '^[[:space:]]*(#|$)' "$WORK/$APP.env") >&2
  exit 0
fi

# =================================================================================================
# 2. prepare (no downtime): env file, secrets, the image build, backup, fingerprint, capture
# =================================================================================================
ql_info "step 2/5: env file, secrets, the image build and a backup (no downtime yet)"
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
[[ $QL_ENV_CREATED != 1 ]] || ql_info "creating $ENV_FILE from the example and filling it in from the running stack"
derive_env "$ENV_FILE"
ql_env_load "$ENV_FILE"
app_refuse_env_secrets
od_check_origins "$port" "$bind"
if ((adopt_token)); then
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_TOKEN
  ql_secret_ensure open-design-api-token env:LEGACY_TOKEN --update
else
  ql_secret_ensure open-design-api-token random:64
fi
LEGACY_TOKEN=''
od_htpasswd_secret
app_render "$WORK/render" "$ENV_FILE"
# The image build is the slow part (10-20 minutes on a small host). Doing it here, while the legacy
# stack is still serving, is what keeps the cutover to the length of a container restart.
od_build_image
ql_pull_images "$WORK/render/out"

bk=$(state_get BACKUP)
if [[ $(state_get STATUS) != prepared || ! -d $bk ]]; then
  bk=$(app_new_backup_dir migrate)
fi
podman inspect "${LEGACY_ALL[@]}" >"$bk/inspect.json"
for u in "${legacy_units_present[@]:-}"; do
  [[ -n $u ]] || continue
  systemctl --user cat "$u" >"$bk/$u" 2>/dev/null || true
done
cp -p -- "$legacy_nginx_conf" "$bk/legacy-nginx.conf"
[[ -r $legacy_bridge ]] && cp -p -- "$legacy_bridge" "$bk/legacy-od-export-bridge.js"
if [[ -n $legacy_dir ]]; then
  legacy_dir=$(cd -- "$legacy_dir" && pwd -P) || ql_die "no such directory: $legacy_dir"
  for f in .env docker-compose.podman.yml docker-compose.yml; do
    [[ -r $legacy_dir/$f ]] && cp -p -- "$legacy_dir/$f" "$bk/legacy-$f"
  done
  ql_info "archived the legacy build directory's compose file and .env from $legacy_dir"
fi
# The repo installs its OWN nginx.conf and export bridge; a host-local edit would be lost silently.
for pair in "nginx.conf:$legacy_nginx_conf" "od-export-bridge.js:$legacy_bridge"; do
  ours=$REPO/config/${pair%%:*} theirs=${pair#*:}
  [[ -r $theirs ]] || continue
  if ! cmp -s "$ours" "$theirs"; then
    diff -u "$theirs" "$ours" >"$bk/${pair%%:*}.diff" || true
    ql_warn "the legacy ${pair%%:*} differs from this repo's config/${pair%%:*}, which install.sh will use instead. The difference is in $bk/${pair%%:*}.diff and the legacy copy is kept in the backup"
  fi
done
app_record_fingerprints "$bk/volume-fingerprints" "$DATA_VOLUME"
{
  printf 'opendesign version: %s (this checkout builds %s)\n' "${legacy_version:-?}" "${target_version:-?}"
  printf 'host port: %s\nnew publish: %s:%s\nnew auth: %s\n' "$port" "$bind" "$port" "$auth"
  printf 'memory: %s\ncpus: %s\n' "${mem:-unset}" "${cpus:-unset}"
  printf 'data volume: %s\n' "$data_vol"
  printf 'allowed origins: %s\n' "$origins"
  printf 'rollback strategy: %s\n' "$STRATEGY"
  printf '%s\n' "--- volume fingerprints (CreatedAt|mountpoint inode|$APP_VOLUME_MARKER inode) ---"
  cat "$bk/volume-fingerprints"
  printf '%s\n' "--- /api/health ---"
  curl -fsS -m 10 "http://127.0.0.1:$port/api/health" 2>/dev/null || true
  printf '\n%s\n' "--- the data volume, as the daemon sees it ---"
  podman exec "$OD_CONTAINER" sh -c 'ls -la /app/.od' 2>/dev/null || true
} >"$bk/precheck.txt"
ql_info "pre-migration state saved in $bk/precheck.txt"
state_set STATUS prepared
state_set BACKUP "$bk"
state_set SUFFIX "$suffix"
state_set LEGACY_PORT "$port"
state_set LEGACY_BIND "$bind"
state_set RETIRED "${LEGACY_ALL[*]}"
state_set LEGACY_UNITS_ENABLED "${legacy_units_enabled[*]:-}"
legacy_ids=()
for c in "${LEGACY_ALL[@]}"; do legacy_ids+=("$(podman inspect --format '{{.Id}}' "$c")"); done
state_set LEGACY_IDS "${legacy_ids[*]}"
# On the capture path the rollback copy is written now, while the legacy stack still runs: a
# container whose create command cannot be replayed is refused before any downtime.
if [[ $STRATEGY == capture ]]; then app_legacy_capture "$bk" "${LEGACY_ALL[@]}"; fi
state_set STRATEGY "$STRATEGY"
app_tighten_backup "$bk"
app_write_checksums "$bk"
if [[ $mode == prepare ]]; then
  ql_info "prepared (the image is built). Run the cutover with the same options minus --prepare-only"
  exit 0
fi

# =================================================================================================
# 3. cutover: stop, cold copy, retire (downtime starts here and is measured)
# =================================================================================================
app_confirm open-design "$ASSUME_YES" "the cutover stops OpenDesign for a few minutes and moves the front behind HTTP Basic auth"
ql_info "step 3/5: stopping the legacy stack, cold volume export, retiring the containers ($STRATEGY)"
state_set STATUS cutover
DOWN_FROM=$(date +%s)
for u in "${legacy_units_present[@]:-}"; do
  [[ -n $u ]] || continue
  systemctl --user disable "$u" >/dev/null 2>&1 || true
  systemctl --user stop "$u" >/dev/null 2>&1 || true
  ! systemctl --user is-active --quiet "$u" || ql_die "$u is still active"
done
# The front first: it holds the browser connections and it requires the daemon.
for c in "$NGINX_CONTAINER" "$OD_CONTAINER"; do
  if app_running "$c"; then podman stop -t 30 "$c" >/dev/null; fi
  ! app_running "$c" || ql_die "$c is still running"
done
mapfile -t listeners < <(app_port_listeners "$port")
((${#listeners[@]} == 0)) || ql_die "host port $port is still bound by ${listeners[*]} after the legacy stack stopped; the Quadlet front could not bind it"
ql_info "host port $port is free"
if ((cold_copy)); then
  ql_backup_volume "$DATA_VOLUME" "$bk/volumes" >/dev/null
else
  ql_warn "--no-cold-copy: no podman volume export was taken; the volume is adopted in place and never rewritten, but there is no copy of app.sqlite from before the cutover"
fi
app_legacy_retire "$STRATEGY" "$suffix" "$bk" "${LEGACY_ALL[@]}"
app_tighten_backup "$bk"
app_write_checksums "$bk"

# =================================================================================================
# 4. install    5. prove the adoption, wait, smoke, report the downtime
# =================================================================================================
ql_info "step 4/5: scripts/install.sh --no-build (the image was built in step 2)"
failed=0
"$REPO/scripts/install.sh" --no-build --no-smoke --accept-defaults || failed=1
DOWN_TO=$(date +%s)
if ((!failed)); then
  ql_info "step 5/5: proving the data was adopted, then the checks"
  app_verify_fingerprints "$bk/volume-fingerprints" || { ql_warn "the new container is NOT on the legacy data volume"; failed=1; }
fi
if ((!failed)); then
  # With auth=basic the front answers 401 without a credential, which is the point of the change.
  ql_wait_http "http://$(app_local_host "$bind"):$port/api/health" '200|401' 300 || failed=1
fi
if ((!failed)); then
  "$REPO/tests/smoke.sh" || failed=1
fi
if ((failed)); then
  if ((auto_rollback)); then
    ql_warn "the cutover failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    ASSUME_YES=1 rollback
    ql_die "migration failed and was rolled back; the legacy stack serves again. Logs: journalctl --user -u open-design.service -u open-design-nginx.service"
  fi
  ql_die "the cutover failed; the new units are left in place. Inspect, then run: $0 --rollback"
fi
state_set STATUS "done"
state_set DOWNTIME_S "$((DOWN_TO - DOWN_FROM))"
ql_info "migration complete. Measured downtime: $((DOWN_TO - DOWN_FROM))s (from stopping the legacy stack to install.sh returning)."
ql_info "compare with $bk/precheck.txt (version, origins, the data volume listing, the volume fingerprint)."
ql_info "the front is now on ${bind}:${port} with auth=$auth. Sign in as user \"open-design\" with the API token:"
ql_info "  podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token"
ql_info "the daemon's 7457 is no longer on the host: it lives in the container's own network namespace."
if [[ $STRATEGY == capture ]]; then
  ql_info "the legacy containers were captured into $bk/legacy-container and removed; --rollback recreates them."
else
  ql_info "the legacy containers ${LEGACY_ALL[0]}-legacy-$suffix and ${LEGACY_ALL[1]}-legacy-$suffix are kept, stopped, for --rollback."
fi
ql_info "  $0 --rollback"
ql_info "after the soak period, clean up as described in README ('After the soak')"
