#!/usr/bin/env bash
# tests/migrate-model.sh: pins the behaviour of scripts/migrate-legacy.sh that decides what happens
# to real data and to the rollback path. The helpers it exercises live in scripts/legacy-helpers.sh,
# which is the only code that:
#   * chooses between "rename and leave stopped" and "capture and remove" (STANDARD 7a),
#   * reads the settings the legacy daemon is running with, including the host port that only
#     exists in the bind-mounted nginx.conf,
#   * proves that the Quadlet containers opened the SAME volumes the compose stack used,
#   * decides whether the legacy API token may be carried forward.
#
#   tests/migrate-model.sh [name-filter]
#
# podman and systemctl are the doubles in tests/shims, placed first on PATH; every test gets its own
# HOME and shim state. No container is created and the real user manager is never touched. Two host
# shapes are modelled:
#   toypark1234       podman-restart.service disabled -> rename, exactly as the live migrations
#                     there behave today
#   woowtechopenclaw  podman-restart.service enabled and a container with restart-policy `always`
#                     -> capture and remove, because a renamed copy would revive at the next boot
#                     and a second OpenDesign would open open-design_open_design_data
# Both OpenDesign containers are `unless-stopped` on woowtechopenclaw today, so that host resolves to
# `rename`; --force-capture is what lets the capture path be exercised on a host that does not need
# it, and it is pinned here too.
#
# Every test runs in its own subshell on purpose (isolated HOME, shim state, env), so the
# "modified in a subshell" notes do not apply here. Several tests replace a helper of
# scripts/legacy-helpers.sh with a stub so the logic above it can be exercised without podman;
# the linter cannot see that the code under test calls those stubs.
# shellcheck disable=SC2030,SC2031,SC2329
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/open-design-migrate-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
calls() { cat "$SHIM_STATE/calls"; }
ncalls() { grep -cF -- "$1" "$SHIM_STATE/calls" || true; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

# ---- fixtures ------------------------------------------------------------------------------------
# mk_legacy <name> <policy>: a podman-compose style legacy container in the shim state. Its
# CreateCommand is a `podman run` that carries -d/--rm/--replace/--cidfile and NO --restart, which is
# how podman-compose 1.0.6 leaves one (the policy lives on the container object only) - verified
# against the real open-design and open-design-nginx on woowtechopenclaw.
mk_legacy() {
  local name=$1 policy=$2 image=localhost/open-design-aligned:pdffix d
  d=$SHIM_STATE/containers/$name
  mkdir -p "$d" "$SHIM_STATE/image-ids"
  printf '%s' "$policy" >"$d/policy"
  printf '0' >"$d/retries"
  printf 'cid-%s' "$name" >"$d/id"
  printf '%s' "$image" >"$d/image"
  printf 'imgid-od' >"$d/image_id"
  printf 'imgid-od' >"$SHIM_STATE/image-ids/${image//[\/:@]/_}"
  printf 'bridge' >"$d/netmode"
  printf 'false' >"$d/autoremove"
  printf 'open-design' >"$d/project"
  printf '%s' "$name" >"$d/service"
  printf '4096' >"$d/sizerw"
  printf 'volume|open-design-nginx-data|/vol/open-design-nginx-data|/app/.od|true|rprivate\n' >"$d/mounts"
  printf 'open-design|%s cid-%s |10.89.2.7|aa:bb:cc:dd:ee:03\n' "$name" "$name" >"$d/networks"
  printf '\n' >"$d/ports"
  printf 'io.podman.compose.project=open-design\n' >"$d/labels"
  : >"$d/label"
  printf '%s\0' /usr/bin/podman run "--name=$name" -d --rm --replace \
    --cidfile "/run/user/1000/$name.cid" --label io.podman.compose.project=open-design \
    -v open-design-nginx-data:/app/.od --net open-design     localhost/open-design-aligned:pdffix >"$d/createcommand.argv0"
}
# mk_dependent <name> <policy> <requires>: like mk_legacy, but the create command carries the
# `--requires=<other>` that podman-compose 1.0.6 writes for a `depends_on:` - which is what both
# open-design-nginx and open-design-nginx carry on woowtechopenclaw.
mk_dependent() {
  mk_legacy "$1" "$2"
  printf '%s\0' /usr/bin/podman run "--name=$1" -d "--requires=$3" --rm --replace \
    -v open-design-nginx-data:/app/.od --net open-design \
    localhost/open-design-aligned:pdffix >"$SHIM_STATE/containers/$1/createcommand.argv0"
  printf '%s' "$3" >"$SHIM_STATE/containers/$1/requires"
}
# mk_api_created <name> <policy>: a container created through the podman API (docker-compose over
# the socket, podman play): its CreateCommand is empty, so nothing can be replayed.
mk_api_created() {
  mk_legacy "$1" "$2"
  : >"$SHIM_STATE/containers/$1/createcommand.argv0"
}
enable_restart_unit() { # what woowtechopenclaw looks like
  mkdir -p "$SHIM_STATE/units/podman-restart.service"
  echo enabled >"$SHIM_STATE/units/podman-restart.service/UnitFileState"
}

# ---- the toypark shape: rename, and nothing else --------------------------------------------------
t_disabled_restart_unit_keeps_the_rename_path() {
  mk_legacy open-design unless-stopped
  mk_legacy open-design-nginx unless-stopped
  eq "$(ql_rollback_strategy open-design open-design-nginx 2>/dev/null)" rename "strategy on a toypark-like host"
  expect_ok app_legacy_retire rename 20260914 "$T/bk" open-design open-design-nginx
  has "$OUT" "renamed open-design-nginx -> open-design-nginx-legacy-20260914"
  eq "$(ncalls 'podman rename open-design open-design-legacy-20260914')" 1 "rename of the daemon"
  eq "$(ncalls 'podman rename open-design-nginx open-design-nginx-legacy-20260914')" 1 "rename of the nginx front"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed on the rename path"
  eq "$(ncalls 'podman commit')" 0 "nothing is committed on the rename path"
  [[ ! -d $T/bk/legacy-container ]] || die_t "the rename path must not write a capture"
  podman container exists open-design-nginx-legacy-20260914 || die_t "the renamed container is missing"
  expect_ok app_legacy_restore 20260914 "$T/bk" open-design open-design-nginx
  has "$OUT" "renamed open-design-nginx-legacy-20260914 -> open-design-nginx"
  podman container exists open-design-nginx || die_t "the rollback did not bring open-design-nginx back"
  eq "$(ncalls 'podman create')" 0 "a renamed container is not recreated"
}

t_always_policy_with_a_disabled_unit_is_still_rename() {
  mk_legacy open-design always
  mk_legacy open-design-nginx always
  eq "$(ql_rollback_strategy open-design open-design-nginx 2>/dev/null)" rename "a disabled unit never revives anything"
}

# ---- the openclaw shape: capture, then remove -----------------------------------------------------
t_enabled_restart_unit_and_always_policy_takes_the_capture_path() {
  enable_restart_unit
  mk_legacy open-design always
  mk_legacy open-design-nginx always
  eq "$(ql_rollback_strategy open-design open-design-nginx 2>/dev/null)" capture "strategy on an openclaw-like host"
  expect_ok app_legacy_capture "$T/bk" open-design open-design-nginx
  local c
  for c in open-design-nginx open-design; do
    [[ -s $T/bk/legacy-container/$c/meta ]] || die_t "no capture of $c"
    eq "$(sed -n 's/^RECREATABLE=//p' "$T/bk/legacy-container/$c/meta")" 1 "$c is recreatable"
    eq "$(sed -n 's/^RESTART_POLICY=//p' "$T/bk/legacy-container/$c/meta")" always "$c policy recorded"
  done
  eq "$(ncalls 'podman rm ')" 0 "the capture removes nothing"
  eq "$(ncalls 'podman rename')" 0 "the capture renames nothing"
  expect_ok app_legacy_retire capture 20260914 "$T/bk" open-design open-design-nginx
  has "$OUT" "removed open-design-nginx;"
  eq "$(ncalls 'podman rename')" 0 "the capture path must not rename"
  podman container exists open-design-nginx && die_t "open-design-nginx was not removed"
  podman container exists open-design-nginx-legacy-20260914 && die_t "the capture path must not leave a renamed copy"
  return 0
}

t_unless_stopped_on_an_enabled_host_is_still_rename() {
  # woowtechopenclaw today: the restart unit IS enabled, but open-design/-web are unless-stopped and
  # `podman start --all --filter restart-policy=always` compares the policy string exactly.
  enable_restart_unit
  mk_legacy open-design unless-stopped
  mk_legacy open-design-nginx unless-stopped
  eq "$(ql_rollback_strategy open-design open-design-nginx 2>/dev/null)" rename "unless-stopped is not matched by the restart filter"
}

t_the_capture_path_removes_dependents_first() {
  # podman-compose turns `depends_on:` into `--requires=`, and podman then refuses
  #   "container <db> has dependent containers which must be removed before it: <web>".
  # That is exactly what stopped the first capture-path rehearsal on toypark1234, half way through
  # the cutover, with the legacy stack already stopped.
  enable_restart_unit
  mk_legacy open-design always
  mk_dependent open-design-nginx always open-design
  expect_ok app_legacy_capture "$T/bk" open-design open-design-nginx
  expect_ok app_legacy_retire capture 20260914 "$T/bk" open-design open-design-nginx
  # the dependent has to be gone before the one it requires
  local web db
  web=$(grep -n '^podman rm open-design-nginx$' "$SHIM_STATE/calls" | cut -d: -f1)
  db=$(grep -n '^podman rm open-design$' "$SHIM_STATE/calls" | cut -d: -f1)
  [[ -n $web && -n $db ]] || die_t "both containers should have been removed"
  ((web < db)) || die_t "open-design-nginx (which requires open-design) must be removed first; podman refuses otherwise"
}

t_the_rename_path_keeps_the_order_it_was_given() {
  mk_legacy open-design unless-stopped
  mk_legacy open-design-nginx unless-stopped
  expect_ok app_legacy_retire rename 20260914 "$T/bk" open-design open-design-nginx
  local web db
  db=$(grep -n '^podman rename open-design ' "$SHIM_STATE/calls" | cut -d: -f1)
  web=$(grep -n '^podman rename open-design-nginx ' "$SHIM_STATE/calls" | cut -d: -f1)
  ((db < web)) || die_t "a rename has no dependency constraint and must keep the given order"
}

t_the_restore_recreates_the_dependency_before_the_dependent() {
  enable_restart_unit
  mk_legacy open-design always
  mk_dependent open-design-nginx always open-design
  expect_ok app_legacy_capture "$T/bk" open-design open-design-nginx
  expect_ok app_legacy_retire capture 20260914 "$T/bk" open-design open-design-nginx
  expect_ok app_legacy_restore 20260914 "$T/bk" open-design open-design-nginx
  local web db
  db=$(grep -n 'podman create .*--name=open-design' "$SHIM_STATE/calls" | head -n1 | cut -d: -f1)
  web=$(grep -n 'podman create .*--name=open-design-nginx' "$SHIM_STATE/calls" | head -n1 | cut -d: -f1)
  [[ -n $db && -n $web ]] || die_t "both containers should have been recreated"
  ((db < web)) || die_t "open-design must be recreated before open-design-nginx, which requires it"
}

t_a_cutover_that_failed_before_retiring_can_still_be_rolled_back() {
  # The cutover stops the legacy containers first and retires them afterwards. If it dies in
  # between - as the --requires failure above did - the containers are still there under their own
  # names, merely stopped, and the rollback must accept that instead of trying to recreate a
  # container that already exists.
  enable_restart_unit
  mk_legacy open-design always
  mk_legacy open-design-nginx always
  expect_ok app_legacy_capture "$T/bk" open-design open-design-nginx
  # no retire at all: this is the half-done cutover
  expect_ok app_legacy_restore 20260914 "$T/bk" open-design open-design-nginx
  has "$OUT" "open-design is already present under its own name"
  eq "$(ncalls 'podman create')" 0 "nothing is recreated over a container that is still there"
  podman container exists open-design-nginx || die_t "open-design-nginx disappeared"
}

t_the_capture_path_never_removes_the_anonymous_volumes() {
  enable_restart_unit
  mk_legacy open-design-nginx always
  expect_ok app_legacy_capture "$T/bk" open-design-nginx
  expect_ok app_legacy_retire capture 20260914 "$T/bk" open-design-nginx
  hasnt "$(calls)" "podman rm -v" "rm -v would delete the anonymous volumes the capture expects back"
  hasnt "$(calls)" "podman rm --volumes" "rm --volumes would delete the anonymous volumes"
}

t_the_rollback_recreates_a_captured_container_with_its_policy() {
  enable_restart_unit
  mk_legacy open-design-nginx always
  expect_ok app_legacy_capture "$T/bk" open-design-nginx
  expect_ok app_legacy_retire capture 20260914 "$T/bk" open-design-nginx
  expect_ok app_legacy_restore 20260914 "$T/bk" open-design-nginx
  has "$OUT" "recreated open-design-nginx"
  podman container exists open-design-nginx || die_t "the rollback did not recreate open-design-nginx"
  eq "$(ql_container_restart_policy open-design-nginx)" always "the original restart policy comes back"
}

t_capture_refuses_a_container_the_library_cannot_replay() {
  enable_restart_unit
  mk_api_created open-design-nginx always
  expect_fail app_legacy_capture "$T/bk" open-design-nginx
  has "$OUT" "podman API"
  eq "$(ncalls 'podman rm ')" 0 "a refused capture removes nothing"
}

t_retire_refuses_to_remove_without_a_capture() {
  enable_restart_unit
  mk_legacy open-design-nginx always
  expect_fail app_legacy_retire capture 20260914 "$T/bk" open-design-nginx
  has "$OUT" "no rollback copy of open-design-nginx"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed without a capture"
}

t_capture_is_idempotent_between_prepare_only_and_the_cutover() {
  enable_restart_unit
  mk_legacy open-design-nginx always
  expect_ok app_legacy_capture "$T/bk" open-design-nginx # --prepare-only
  expect_ok app_legacy_capture "$T/bk" open-design-nginx # the cutover reuses the same backup dir
  has "$OUT" "already in"
}

t_the_capture_path_works_with_an_empty_suffix() {
  # A capture-path cutover renames nothing, so it has no <name>-legacy-<suffix> to name and may pass
  # an empty suffix. `${2:?}` would abort the script there; `${2-}` must not.
  enable_restart_unit
  mk_legacy open-design-nginx always
  expect_ok app_legacy_capture "$T/bk" open-design-nginx
  expect_ok app_legacy_retire capture "" "$T/bk" open-design-nginx
  podman container exists open-design-nginx && die_t "open-design-nginx was not removed"
  expect_ok app_legacy_restore "" "$T/bk" open-design-nginx
  has "$OUT" "recreated open-design-nginx"
  expect_fail app_legacy_restore "" "$T/empty" open-design-absent
  hasnt "$OUT" "-legacy- " "an empty suffix must not be spelled into the message"
  return 0
}

# ---- the per-app lock must not leak into the containers the rollback starts ------------------------
t_a_container_started_by_the_rollback_does_not_inherit_the_lock() {
  # ql_lock keeps an open file descriptor for the life of the script, and bash does not mark it
  # close-on-exec. A container this script starts itself inherits it into conmon and keeps the
  # flock held after the script exits, so the NEXT install/backup/upgrade/rollback refuses with
  # "another install/upgrade/uninstall is running". Reproduced live on toypark1234 against the
  # UNMODIFIED scripts/install.sh and scripts/backup.sh, so it is the vendored library's lock, not
  # this migration's - but this migration is what starts a legacy container directly.
  local f=$T/lockfile
  : >"$f"
  exec {QL_LOCK_FD}>"$f"
  flock -n "$QL_LOCK_FD" || die_t "could not take the test lock"
  bash -c 'ls -l /proc/self/fd' | grep -q "$f" \
    || die_t "the fixture is wrong: a plain child should inherit the lock descriptor"
  app_unlocked bash -c 'ls -l /proc/self/fd' | grep -q "$f" \
    && die_t "app_unlocked still handed the lock descriptor to the child"
  # the lock itself survives: the variable and the descriptor are untouched in this shell
  [[ -n ${QL_LOCK_FD:-} ]] || die_t "app_unlocked lost QL_LOCK_FD"
  flock -n "$QL_LOCK_FD" || die_t "this shell no longer holds the lock"
  # and without a lock at all it is an ordinary call
  local saved=$QL_LOCK_FD
  QL_LOCK_FD=''
  eq "$(app_unlocked printf hello)" hello "app_unlocked without a lock"
  QL_LOCK_FD=$saved
  return 0
}

t_the_rollback_starts_legacy_containers_without_the_lock() {
  grep -qE 'app_unlocked podman start' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "the rollback starts a legacy container with the lock descriptor still open"
  return 0
}

t_the_backup_is_private() {
  # The backup holds the legacy container's full inspect, whose environment carries OD_API_TOKEN and
  # any BYOK provider key. podman writes `volume export` archives 0644 and a plain redirect follows
  # the umask, so the files inside a 0700 directory are not private by themselves.
  mkdir -p "$T/bk/volumes"
  : >"$T/bk/inspect.json"
  : >"$T/bk/volumes/open-design_open_design_data.tar"
  chmod 755 "$T/bk/volumes"
  chmod 644 "$T/bk/inspect.json" "$T/bk/volumes/open-design_open_design_data.tar"
  expect_ok app_tighten_backup "$T/bk"
  eq "$(stat -c %a "$T/bk/inspect.json")" 600 "the archived inspect"
  eq "$(stat -c %a "$T/bk/volumes/open-design_open_design_data.tar")" 600 "the exported volume"
  eq "$(stat -c %a "$T/bk/volumes")" 700 "a directory inside the backup"
}

# ---- reading the legacy stack, which is host-networked and therefore opaque to podman ---------------
t_the_front_port_comes_from_the_bind_mounted_nginx_conf() {
  # Both legacy containers run with --network host, so podman records NO port binding for either of
  # them and `podman port` prints nothing. The only statement of which host port the stack serves is
  # the `listen` directive of the nginx.conf bind-mounted into open-design-nginx - the exact file
  # woowtechopenclaw keeps in ~/od-podman-align.
  printf 'server {\n  listen 7456 default_server;\n  listen [::]:7456 default_server;\n}\n' >"$T/n1.conf"
  eq "$(od_nginx_listen_port "$T/n1.conf")" 7456 "the IPv4 and IPv6 listen lines agree"
  printf 'server {\n    listen   37456;\n}\n' >"$T/n2.conf"
  eq "$(od_nginx_listen_port "$T/n2.conf")" 37456 "a single listen line with odd spacing"
  # disagreeing ports are a refusal, not a guess
  printf 'server {\n listen 7456;\n}\nserver {\n listen 9999;\n}\n' >"$T/n3.conf"
  expect_fail od_nginx_listen_port "$T/n3.conf"
  has "$OUT" "listens on several different ports"
  printf 'server {\n}\n' >"$T/n4.conf"
  expect_fail od_nginx_listen_port "$T/n4.conf"
  has "$OUT" "no listen directive"
  expect_fail od_nginx_listen_port "$T/does-not-exist.conf"
  has "$OUT" "cannot read"
}

t_the_resource_limits_are_read_back_as_env_values() {
  # podman records HostConfig.Memory in bytes and HostConfig.NanoCpus in billionths; the env file
  # wants podman size and cpu strings. woowtechopenclaw's open-design has 2147483648 / 2000000000.
  eq "$(od_bytes_to_size 2147483648)" 2g "2 GiB"
  eq "$(od_bytes_to_size 134217728)" 128m "128 MiB"
  eq "$(od_bytes_to_size 1536)" 2k "an odd byte count rounds up to KiB"
  eq "$(od_bytes_to_size 0)" "" "no limit keeps the example default"
  eq "$(od_bytes_to_size '')" "" "an unreadable value keeps the example default"
  eq "$(od_nanocpus_to_cpus 2000000000)" 2 "2 CPUs"
  eq "$(od_nanocpus_to_cpus 500000000)" 0.5 "half a CPU"
  eq "$(od_nanocpus_to_cpus 1500000000)" 1.5 "one and a half CPUs"
  eq "$(od_nanocpus_to_cpus 0)" "" "no limit keeps the example default"
}

t_the_local_origin_is_always_in_the_allowlist() {
  # A missing local origin makes the daemon answer 403 on every data route, and install.sh refuses
  # it (od_check_origins) - which on the cutover path would be AFTER the downtime started.
  local legacy='http://127.0.0.1:7456,http://192.168.2.197:7456,https://openclaw197-hermes.woowtech.io'
  eq "$(od_origins_with_local "$legacy" 7456)" "$legacy" "a list that already has the local origin is unchanged"
  eq "$(od_origins_with_local 'http://192.168.2.197:7456' 7456)" \
    'http://192.168.2.197:7456,http://127.0.0.1:7456' "the local origin is appended when missing"
  eq "$(od_origins_with_local '' 37456)" 'http://127.0.0.1:37456' "an empty list still gets the local origin"
  eq "$(od_origins_with_local 'http://a:1,http://a:1,http://b:2' 9) " \
    'http://a:1,http://b:2,http://127.0.0.1:9 ' "duplicates are dropped, order is kept"
  # a moved port means the old local origin is not the new one
  eq "$(od_origins_with_local 'http://127.0.0.1:7456' 37456)" \
    'http://127.0.0.1:7456,http://127.0.0.1:37456' "a changed port adds the new local origin"
}

t_the_app_version_is_compared_on_the_minor_series() {
  eq "$(od_version_series 0.21.1)" 0.21 "a three-part version"
  eq "$(od_version_series 0.21)" 0.21 "a two-part version"
  eq "$(od_version_series '')" "" "an empty version"
  eq "$(od_version_series unknown)" "" "an unparsable version"
  [[ $(od_version_series 0.21.1) == "$(od_version_series 0.21.9)" ]] \
    || die_t "a patch bump must not be treated as a version change"
  [[ $(od_version_series 0.21.1) != "$(od_version_series 0.22.0)" ]] \
    || die_t "a minor bump must be treated as a version change"
}

t_the_pinned_version_is_read_from_the_dockerfile() {
  # The image this repo builds is FROM a digest-pinned upstream od tag; that tag is the version the
  # migration compares against what the legacy daemon reports on /api/health.
  local v
  v=$(od_dockerfile_od_version "$REPO/Dockerfile.full")
  [[ $v =~ ^[0-9]+\.[0-9]+ ]] || die_t "cannot read the pinned OpenDesign version from Dockerfile.full (got '$v')"
  # shellcheck disable=SC2016 # a Dockerfile fixture: ${BUILD_FROM} must stay literal
  printf 'ARG BUILD_FROM=ghcr.io/nexu-io/od:0.99.7@sha256:deadbeef\nFROM ${BUILD_FROM}\n' >"$T/df"
  eq "$(od_dockerfile_od_version "$T/df")" 0.99.7 "the tag, without the digest"
}

t_the_health_version_is_parsed_from_the_api() {
  # OpenDesign answers {"ok":true,"version":"0.21.1"} - verified live on woowtechopenclaw. The
  # parsing is a function of its own so this exercises the real one, not a stub of it.
  eq "$(printf '%s' '{"ok":true,"version":"0.21.1"}' | od_parse_health_version)" 0.21.1 "the version field"
  eq "$(printf '%s' '{"ok": true, "version" : "0.22.0"}' | od_parse_health_version)" 0.22.0 "with spaces"
  eq "$(printf '%s' '{"ok":true}' | od_parse_health_version)" "" "no version field"
  eq "$(printf '' | od_parse_health_version)" "" "no answer at all"
  grep -q 'od_parse_health_version' "$REPO/scripts/legacy-helpers.sh" \
    || die_t "od_health_version does not go through the parser this test exercises"
}

# ---- proving the volumes were adopted, rather than assuming it -------------------------------------
t_matching_volume_fingerprints_prove_the_adoption() {
  app_volume_fingerprint() { printf '2026-08-28 04:38:10 +0800|4242|4343'; }
  expect_ok app_record_fingerprints "$T/fp" open-design-data open-design-nginx-data
  expect_ok app_verify_fingerprints "$T/fp"
  has "$OUT" "volume open-design-data was adopted in place"
  has "$OUT" "volume open-design-nginx-data was adopted in place"
}

t_a_freshly_created_volume_is_detected_as_not_adopted() {
  # Exactly what a .volume without VolumeName= would cause: Quadlet makes systemd-open-design-data,
  # OpenDesign comes up healthy on an EMPTY app.sqlite - no projects, no boards - and nothing else
  # in the migration would notice.
  app_volume_fingerprint() { printf '2026-08-28 04:38:10 +0800|4242|4343'; }
  expect_ok app_record_fingerprints "$T/fp" open-design-data
  app_volume_fingerprint() { printf '2026-09-14 02:00:00 +0800|9999|8888'; }
  expect_fail app_verify_fingerprints "$T/fp"
  has "$OUT" "volume open-design-data is NOT the volume the legacy stack used"
}

t_a_missing_fingerprint_file_is_not_a_pass() {
  expect_fail app_verify_fingerprints "$T/does-not-exist"
  has "$OUT" "no volume fingerprint recorded"
}

t_a_volume_that_cannot_be_fingerprinted_stops_the_recording() {
  app_volume_fingerprint() { return 1; }
  expect_fail app_record_fingerprints "$T/fp" open-design-data
  has "$OUT" "cannot fingerprint volume open-design-data"
}

# ---- what the script itself must keep doing ---------------------------------------------------------
t_the_rollback_tells_the_legacy_container_from_a_stranger() {
  # A cutover that died between "stop" and "retire" leaves the legacy container in place under its
  # own name. The rollback must keep that one (it is the thing being rolled back to), remove a
  # container this repo's Quadlet units created, and refuse anything else - so the container id
  # recorded before the cutover has to be in the state file and has to be consulted.
  local s=$REPO/scripts/migrate-legacy.sh
  grep -q 'state_set LEGACY_IDS' "$s" || die_t "the prepare phase does not record the legacy container ids"
  grep -q 'state_get LEGACY_IDS' "$s" || die_t "the rollback does not read the recorded legacy container ids"
  grep -q 'is the legacy container the cutover stopped but never retired' "$s" \
    || die_t "the rollback has no branch for a legacy container that was never retired"
  grep -q 'is not the legacy container recorded before the cutover' "$s" \
    || die_t "the rollback does not refuse a stranger that took the name"
  return 0
}

t_migrate_legacy_asks_the_host_instead_of_hardcoding_a_path() {
  local s=$REPO/scripts/migrate-legacy.sh
  # An invocation, not just the word: a comment mentioning it would satisfy a bare grep.
  grep -qE '^STRATEGY=\$\(ql_rollback_strategy ' "$s" \
    || die_t "scripts/migrate-legacy.sh does not set STRATEGY from ql_rollback_strategy"
  grep -q 'is-enabled podman-restart.service' "$s" \
    && die_t "scripts/migrate-legacy.sh decides from podman-restart.service by itself instead of asking the library"
  grep -q 'app_legacy_retire' "$s" || die_t "the cutover does not go through app_legacy_retire"
  grep -q 'app_legacy_restore' "$s" || die_t "the rollback does not go through app_legacy_restore"
  grep -q 'app_legacy_capture' "$s" || die_t "the prepare phase does not capture"
  return 0
}

t_force_capture_only_ever_tightens() {
  # --force-capture may turn rename into capture and must never turn capture into rename.
  local s=$REPO/scripts/migrate-legacy.sh
  # shellcheck disable=SC2016 # a grep pattern, not a string to expand
  grep -qE 'force_capture\)\) *&& *\[\[ \$STRATEGY == rename \]\]' "$s" \
    || die_t "--force-capture is not guarded by 'the host said rename'"
  grep -qE 'STRATEGY=rename' "$s" && die_t "scripts/migrate-legacy.sh assigns STRATEGY=rename somewhere; only the library may choose rename"
  return 0
}

t_no_printf_format_starts_with_a_dash() {
  # bash's printf builtin reads a format string that begins with "-" as an OPTION:
  # `printf '--- /api/health ---\n'` dies with "printf: --: invalid option". That killed the first
  # live rehearsal of this script half way through writing precheck.txt, after the secrets had
  # already been created - so the whole prepare phase has to be re-runnable, and this must not
  # come back.
  local hits
  hits=$(grep -nE "printf +['\"]-" "$REPO/scripts/migrate-legacy.sh" "$REPO/scripts/legacy-helpers.sh" || true)
  [[ -z $hits ]] || die_t "printf format string starting with a dash:"$'\n'"$hits"
}

t_the_image_is_built_before_the_downtime_starts() {
  # Building localhost/woow-open-design takes 10-20 minutes. Doing it inside the cutover would make
  # the downtime that long, so the prepare phase builds it and install.sh is called with --no-build.
  local s=$REPO/scripts/migrate-legacy.sh a b
  a=$(grep -n 'od_build_image' "$s" | tail -n1 | cut -d: -f1)
  b=$(grep -n 'DOWN_FROM=' "$s" | tail -n1 | cut -d: -f1)
  [[ -n $a && -n $b ]] || die_t "migrate-legacy.sh must build the image and must measure the downtime"
  ((a < b)) || die_t "the image build must happen before the downtime starts"
  grep -q 'install.sh" --no-build' "$s" || die_t "the cutover must call install.sh with --no-build"
  return 0
}

t_the_exposure_and_auth_changes_are_not_silent() {
  local s=$REPO/scripts/migrate-legacy.sh
  grep -q 'bind=127.0.0.1' "$s" || die_t "the default publish address is not loopback; the legacy stack was on every interface"
  grep -q 'auth=basic' "$s" || die_t "the default is not Basic auth; the legacy front had no credential check"
  grep -q 'od_check_auth' "$s" || die_t "auth=off is not checked against the publish address"
  grep -q 'OD_DISABLE_API_AUTH' "$s" || die_t "the migration says nothing about the legacy OD_DISABLE_API_AUTH=1"
  return 0
}

t_a_host_local_edit_of_the_front_config_is_reported() {
  # install.sh installs this repo's own config/nginx.conf and config/od-export-bridge.js. On
  # woowtechopenclaw those two files are host-local and live in a directory that is not a git repo
  # at all, so a difference has to be surfaced and archived, never silently overwritten.
  local s=$REPO/scripts/migrate-legacy.sh
  grep -q 'od-export-bridge.js' "$s" || die_t "the export bridge is not considered"
  grep -q 'differs from this repo' "$s" || die_t "a host-local front config difference is not reported"
  grep -qE '\.diff' "$s" || die_t "the difference is not written anywhere"
  return 0
}

t_the_cutover_refuses_to_run_twice() {
  grep -qE 'cutover \| "done"\)' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "a recorded cutover/done state does not stop a second migration"
  return 0
}

t_the_adoption_is_proved_before_the_smoke_test() {
  local s=$REPO/scripts/migrate-legacy.sh a b
  a=$(grep -n 'app_verify_fingerprints' "$s" | tail -n1 | cut -d: -f1)
  b=$(grep -n 'tests/smoke.sh' "$s" | tail -n1 | cut -d: -f1)
  [[ -n $a && -n $b ]] || die_t "migrate-legacy.sh must both verify the fingerprints and run the smoke test"
  ((a < b)) || die_t "the volume adoption must be proved before tests/smoke.sh, which would pass on an empty app.sqlite"
  return 0
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run" "$T/bk"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=migrate-model
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "the shims are not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/common.sh
    . "$REPO/scripts/common.sh"
    # shellcheck source=../scripts/od-helpers.sh
    . "$REPO/scripts/od-helpers.sh"
    # shellcheck source=../scripts/legacy-helpers.sh
    . "$REPO/scripts/legacy-helpers.sh"
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1))
    printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1))
    FAILED+=("$t")
    printf 'FAIL  %s\n' "$t"
    tail -n 25 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
