# shellcheck shell=bash
# scripts/legacy-helpers.sh: everything scripts/migrate-legacy.sh needs that is not already in
# scripts/common.sh or scripts/od-helpers.sh. It is a separate file on purpose: common.sh is kept
# byte-identical below its settings block across Woow_podman_emqx, _hermes, _odoo and _opendesign,
# and the migration is not part of that shared surface.
#
# Sourced after scripts/lib/quadlet-lib.sh, scripts/common.sh and scripts/od-helpers.sh.
# tests/migrate-model.sh sources the same file, which is what pins these helpers.

# ---- small predicates --------------------------------------------------------------------------
app_running() { [[ $(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
app_is_installed() { [[ -s "$(app_state_dir)/manifest" ]]; }
app_unit_exists() { [[ -n $(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) ]]; }


# app_spec_path <abs path>: rewrite $HOME/... as %h/... so a rendered unit carries no literal home
# path (systemd expands %h when it starts the unit; STANDARD section 2).
app_spec_path() {
  local p=$1
  [[ $p == "$HOME"/* ]] && p="%h/${p#"$HOME"/}"
  printf '%s' "$p"
}

# app_mount_source <container> <destination>: the host path or volume name mounted there.
# Prints "<type>|<name>|<source>"; empty when the container does not mount that destination.
# The template addresses Go FIELD names, never the lowercase JSON tags (STANDARD section 8).
app_mount_source() {
  podman inspect --format '{{range .Mounts}}{{.Destination}}|{{.Type}}|{{.Name}}|{{.Source}}{{println}}{{end}}' "$1" 2>/dev/null \
    | sed -n "s#^$2|##p" | tail -n1
}

# app_published <container> <port/proto>: "<host ip>|<host port>" of the first binding.
# `.HostIP` is the Go field name; the JSON tag is `HostIp` and a template using that spelling
# fails the WHOLE template with exit 125 and no stdout (STANDARD section 8, seen live in W2).
app_published() {
  podman inspect --format "{{range \$p, \$bs := .NetworkSettings.Ports}}{{if eq \$p \"$2\"}}{{range \$bs}}{{.HostIP}}|{{.HostPort}}{{println}}{{end}}{{end}}{{end}}" "$1" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | head -n1
}

# app_bind_for <host ip>: the WOOW_ODOO_BIND value that reproduces a podman port binding.
# podman reports the host IP of an all-interfaces publish as the EMPTY STRING, not as 0.0.0.0:
# `podman ps` prints "0.0.0.0:38069->8069/tcp" while `{{.HostIP}}` on the same container returns "".
# Verified live on podman 4.9.3 with a podman-compose `"${ODOO_PORT}:8069"` mapping, which is what
# the compose-final docker-compose.yml of this repo produces. Feeding that empty string straight
# into the env file makes render_args refuse WOOW_ODOO_BIND before anything is installed.
app_bind_for() {
  case ${1:-} in
    '' | 0.0.0.0 | '::' | '[::]') printf 'all' ;;
    *) printf '%s' "$1" ;;
  esac
}

# app_port_listeners <port>: every listening socket on that TCP port, one "addr" per line
app_port_listeners() { ss -ltnH "sport = :$1" 2>/dev/null | awk '{print $4}' | LC_ALL=C sort -u; }

# app_port_publishers <port>: the containers publishing that host port, one name per line
app_port_publishers() {
  local c
  local -a names=()
  mapfile -t names < <(podman ps --format '{{.Names}}' 2>/dev/null || true)
  for c in "${names[@]}"; do
    [[ -n $c ]] || continue
    if podman port "$c" 2>/dev/null | grep -qE "(^|:)$1\$"; then printf '%s\n' "$c"; fi
  done
}

# ---- backup bookkeeping ------------------------------------------------------------------------
# app_tighten_backup <dir>: 0700 directories, 0600 files. The backup holds the legacy container's
# full inspect, whose environment carries OD_API_TOKEN and any BYOK provider key. `app_new_backup_dir` already creates the top
# directory 0700, but podman writes `volume export` archives with its own mode (0644 on 4.9.3) and
# a plain `printf >file` follows the caller's umask, so the files inside are not private by
# themselves. Ownership of the tree is never changed.
app_tighten_backup() {
  find "$1" -type d -exec chmod 700 {} + || ql_warn "could not tighten the directories under $1"
  find "$1" -type f -exec chmod 600 {} + || ql_warn "could not tighten the files under $1"
}

# app_write_checksums <dir>: SHA256SUMS over every file in <dir>, relative paths, sorted.
app_write_checksums() {
  local list
  list=$(cd -- "$1" && find . -type f ! -name 'SHA256SUMS*' ! -name '*.sha256' -printf '%P\n' | LC_ALL=C sort) \
    || ql_die "cannot list $1"
  (cd -- "$1" && umask 077 && while IFS= read -r f; do if [[ -n $f ]]; then sha256sum -- "$f"; fi; done <<<"$list" >SHA256SUMS.tmp \
    && mv -f SHA256SUMS.tmp SHA256SUMS) || ql_die "cannot write $1/SHA256SUMS"
}

# ---- proving the data was adopted, never assuming it -------------------------------------------
# quadlet/open-design-data.volume keeps the podman-compose name
# (VolumeName=open-design_open_design_data), so the new container is supposed to open the SAME
# volume. Without VolumeName= Quadlet would have made systemd-open-design-data and OpenDesign would
# have come up perfectly healthy on an empty app.sqlite - no projects, no boards, no BYOK
# credentials, and nothing else in the migration would have noticed. So the fingerprint of the
# volume is recorded before the cutover and compared afterwards.
#
# A file inside the volume whose inode is a second, content-level proof that the SAME data came
# back. app.sqlite is OpenDesign's database: every project, board and setting lives in it.
APP_VOLUME_MARKER=app.sqlite

# app_volume_fingerprint <volume>: "<CreatedAt>|<mountpoint inode>|<marker inode or ->".
# `podman unshare` is needed because the volume belongs to the container's uid 1001.
app_volume_fingerprint() {
  local vol=$1 created mp ino mino=-
  created=$(podman volume inspect --format '{{.CreatedAt}}' "$vol" 2>/dev/null) || return 1
  mp=$(podman volume inspect --format '{{.Mountpoint}}' "$vol" 2>/dev/null) || return 1
  [[ $mp == /* && $mp != / ]] || return 1
  ino=$(podman unshare stat -c %i -- "$mp" 2>/dev/null) || return 1
  if podman unshare test -f "$mp/$APP_VOLUME_MARKER"; then
    mino=$(podman unshare stat -c %i -- "$mp/$APP_VOLUME_MARKER" 2>/dev/null || echo -)
  fi
  printf '%s|%s|%s' "$created" "$ino" "$mino"
}

# app_record_fingerprints <file> <volume>...
app_record_fingerprints() {
  local f=${1:?} v fp
  shift
  : >"$f"
  for v in "$@"; do
    fp=$(app_volume_fingerprint "$v") || ql_die "cannot fingerprint volume $v"
    printf '%s=%s\n' "$v" "$fp" >>"$f"
  done
}

# app_verify_fingerprints <file>: every recorded volume must still be the same volume, with the
# same on-disk directory. Returns 1 and names the volume when it is not.
app_verify_fingerprints() {
  local f=${1:?} v want got rc=0
  [[ -f $f ]] || { ql_warn "no volume fingerprint recorded in $f"; return 1; }
  while IFS='=' read -r v want; do
    [[ -n $v ]] || continue
    got=$(app_volume_fingerprint "$v") || got='(missing)'
    if [[ $got == "$want" ]]; then
      ql_info "volume $v was adopted in place (CreatedAt and inode unchanged: $want)"
    else
      ql_warn "volume $v is NOT the volume the legacy stack used: recorded [$want], now [$got]"
      rc=1
    fi
  done <"$f"
  return "$rc"
}

# ---- the legacy rollback model (STANDARD 7a; quadlet-lib >= 1.4.0) -----------------------------
# Keeping the legacy containers renamed and stopped is a rollback path only while nothing starts
# them again. The user unit podman-restart.service runs
# `podman start --all --filter restart-policy=always` at boot, so where it is enabled a renamed,
# stopped container whose policy is exactly `always` revives and fights the new Quadlet container
# for its name, ports and volumes. podman 4.9.3 cannot defuse that in place (`podman update` is
# cgroup-only; a restart policy is fixed at create time), so there the answer is to capture the
# container and remove it. ql_rollback_strategy asks this host - is that unit enabled, what is each
# container's policy - and answers `rename` or `capture`; it never looks at a host name.
#
# open-design and open-design-nginx are `unless-stopped` on woowtechopenclaw today, so that host
# resolves to `rename`. That is a fact about today, not a property of the stack: --force-capture exercises the
# other path, and a host that later recreates them with `always` gets it automatically.
#
# Neither container is given --commit. `open-design` runs with `--read-only`, so it has no writable
# layer to lose at all, and everything it keeps is in open-design_open_design_data or in the two
# tmpfs mounts that are ephemeral by design. `open-design-nginx` is the stock nginx image whose only
# writes are /var/cache/nginx and /var/run.

# app_legacy_capture <backup dir> <container>...: write the rollback copy of each container.
# Read-only towards the containers, so it belongs in the prepare phase, before any downtime: a
# container the library cannot replay (an empty CreateCommand - created through the podman API
# rather than the CLI) is refused here, while the legacy stack is still running.
app_legacy_capture() {
  local bk=${1:?usage: app_legacy_capture <backup dir> <container>...} c meta
  shift
  for c in "$@"; do
    meta=$bk/legacy-container/$c/meta
    if [[ -f $meta ]]; then
      ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
    else
      ql_capture_container "$c" "$bk" >/dev/null
    fi
    [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
      "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy containers can simply be renamed) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
  done
}

# app_legacy_retire <strategy> <suffix> <backup dir> <container>...: take the legacy containers out
# of the new stack's way, in the shape the strategy asked for.
#
# The containers are listed DEPENDENCY FIRST (the daemon, then its nginx front). The rename
# path does not care, but the capture path removes them in REVERSE, dependents first, because
# podman-compose 1.0.6 turns `depends_on:` into `--requires=<name>` and podman then refuses to
# remove a container that something else requires:
#
#   Error: container <open-design> has dependent containers which must be removed before it: <nginx>
#
# Reproduced on toypark1234, and it is the shape woowtechopenclaw runs today: its open-design-nginx
# carries `--requires=open-design` (and its odoo18-web carries `--requires=odoo18-db`).
# `podman rm --depend` would remove the
# dependent too, which is not what we want - each container has its own capture and its own removal.
app_legacy_retire() {
  # The suffix is empty on the capture path: nothing is renamed there, so there is no
  # <name>-legacy-<suffix> to name. ${2-} rather than ${2:?}, which would abort the script.
  local strategy=${1:?} sfx=${2-} bk=${3:?} c i
  shift 3
  local -a order=("$@")
  case $strategy in
    rename)
      for c in "${order[@]}"; do
        [[ -n $sfx ]] || ql_die "the rename path needs a suffix for $c-legacy-<suffix>"
        podman rename "$c" "$c-legacy-$sfx" || ql_die "podman rename $c failed"
        ql_info "renamed $c -> $c-legacy-$sfx (stopped, kept for --rollback)"
      done ;;
    capture)
      for ((i = ${#order[@]} - 1; i >= 0; i--)); do
        c=${order[i]}
        [[ -f $bk/legacy-container/$c/meta ]] || ql_die "no rollback copy of $c in $bk; nothing was removed"
        # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes that the capture
        # records and expects to find again, and `--depend` would remove a container that has its
        # own capture without going through it.
        podman rm "$c" >/dev/null || ql_die "podman rm $c failed"
        ql_info "removed $c; --rollback recreates it from $bk/legacy-container/$c"
      done ;;
    *) ql_die "unknown rollback strategy '$strategy'" ;;
  esac
}

# app_legacy_restore <suffix> <backup dir> <container>...: bring the legacy containers back,
# whichever shape the cutover used. A recreated container comes back stopped and with its original
# restart policy; the caller starts it, exactly as it starts a renamed one.
app_legacy_restore() {
  # An empty suffix means the cutover captured rather than renamed: there is no
  # <name>-legacy-<suffix> to look for, only the rollback copy.
  local sfx=${1-} bk=${2:?} c
  shift 2
  # Dependency first (the daemon before its nginx front): a captured container is recreated
  # with the `--requires=` its create command carried, and podman refuses that if the container it
  # requires does not exist yet.
  for c in "$@"; do
    if podman container exists "$c"; then
      # The cutover did not get as far as retiring this one - it failed between the stop and the
      # rename/removal - so it is already back under its own name, merely stopped. The caller has
      # already removed any container of this name that belonged to the Quadlet units.
      ql_info "$c is already present under its own name; nothing to restore"
    elif [[ -n $sfx ]] && podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container ${sfx:+$c-legacy-$sfx }nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}

# ---- reading the legacy OpenDesign stack --------------------------------------------------------
# od_legacy_env <container> <KEY>: one value from the container's environment ("" when unset).
od_legacy_env() {
  podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | sed -n "s/^$2=//p" | tail -n1
}

# od_nginx_listen_port <nginx.conf>: the port the legacy front listens on.
#
# The legacy nginx runs with `--network host`, so podman records NO port binding for it and
# `podman port` prints nothing: the only statement of which host port the stack serves is the
# `listen` directive of the nginx.conf that is bind-mounted into it. Both `listen 7456
# default_server;` and `listen [::]:7456 default_server;` are accepted, and every listen line has
# to agree, or the migration cannot say which port the Quadlet unit should publish.
od_nginx_listen_port() {
  local conf=$1 ports
  [[ -r $conf ]] || { ql_warn "cannot read $conf"; return 1; }
  ports=$(sed -nE 's/^[[:space:]]*listen[[:space:]]+(\[[0-9a-fA-F:]*\]:)?([0-9]+).*;.*$/\2/p' "$conf" \
    | LC_ALL=C sort -u)
  [[ -n $ports ]] || { ql_warn "no listen directive in $conf"; return 1; }
  if [[ $(wc -l <<<"$ports") -ne 1 ]]; then
    ql_warn "$conf listens on several different ports (${ports//$'\n'/ }); pass --port to say which one the Quadlet front should publish"
    return 1
  fi
  printf '%s' "$ports"
}

# od_bytes_to_size <bytes>: podman records HostConfig.Memory in bytes; WOOW_OD_MEMORY is a podman
# size string. 0 (no limit) prints nothing so the caller can keep the example's default.
od_bytes_to_size() {
  local b=${1:-0}
  [[ $b =~ ^[0-9]+$ ]] || return 0
  ((b == 0)) && return 0
  if ((b % 1073741824 == 0)); then printf '%dg' "$((b / 1073741824))"
  elif ((b % 1048576 == 0)); then printf '%dm' "$((b / 1048576))"
  else printf '%dk' "$(((b + 1023) / 1024))"; fi
}

# od_nanocpus_to_cpus <nanocpus>: 2000000000 -> 2, 1500000000 -> 1.5. 0 prints nothing.
od_nanocpus_to_cpus() {
  local n=${1:-0} whole frac
  [[ $n =~ ^[0-9]+$ ]] || return 0
  ((n == 0)) && return 0
  whole=$((n / 1000000000))
  frac=$(((n % 1000000000) / 100000000))
  if ((frac == 0)); then printf '%d' "$whole"; else printf '%d.%d' "$whole" "$frac"; fi
}

# od_origins_with_local <origins> <port>: the legacy OD_ALLOWED_ORIGINS with http://127.0.0.1:<port>
# guaranteed to be in it. A missing local origin makes the daemon answer 403 on every data route,
# which install.sh refuses (od_check_origins) - after the downtime has already started. Entries are
# de-duplicated and their order is otherwise kept, because the operator's list names real hosts.
od_origins_with_local() {
  local origins=${1:-} port=${2:?} local_origin entry out='' seen=''
  local_origin=http://127.0.0.1:$port
  local IFS=,
  for entry in $origins; do
    [[ -n $entry ]] || continue
    [[ ",$seen," == *",$entry,"* ]] && continue
    seen=${seen:+$seen,}$entry
    out=${out:+$out,}$entry
  done
  [[ ",$seen," == *",$local_origin,"* ]] || out=${out:+$out,}$local_origin
  printf '%s' "$out"
}

# od_version_series <version>: 0.21.1 -> 0.21. An empty or unparsable value prints nothing.
od_version_series() {
  [[ ${1:-} =~ ^([0-9]+)\.([0-9]+) ]] || return 0
  printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# od_parse_health_version: read /api/health's body on stdin and print its "version" field ("" when
# there is none). OpenDesign answers {"ok":true,"version":"0.21.1"} - verified live.
od_parse_health_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# od_health_version <base url>: the version the running daemon reports ("" when it does not answer).
od_health_version() {
  curl -fsS -m 10 "$1/api/health" 2>/dev/null | od_parse_health_version
}

# od_dockerfile_od_version <Dockerfile>: the upstream OpenDesign version the image is built FROM,
# read from the pinned `ARG BUILD_FROM=ghcr.io/nexu-io/od:<version>@sha256:...`.
od_dockerfile_od_version() {
  sed -n 's|^ARG BUILD_FROM=.*/od:\([0-9][^@[:space:]]*\).*|\1|p' "$1" | tail -n1
}
