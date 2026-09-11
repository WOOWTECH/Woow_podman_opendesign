#!/usr/bin/env bash
# scripts/restore.sh: restore the OpenDesign data volume from a backup made by scripts/backup.sh.
#
#   scripts/restore.sh --archive FILE --confirm-restore open-design
#
# The daemon (and with it nginx) is stopped, a pre-restore copy of the current volume is taken, the
# volume is emptied and re-imported, and the stack is started and smoke-checked again.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

archive='' confirm=''
while (($#)); do
  case $1 in
    --archive) (($# >= 2)) || ql_die "--archive needs a path"; archive=$2; shift ;;
    --confirm-restore) (($# >= 2)) || ql_die "--confirm-restore needs the word $APP"; confirm=$2; shift ;;
    -h | --help) sed -n '2,9p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ -n $archive && $confirm == "$APP" ]] || ql_die "usage: scripts/restore.sh --archive FILE --confirm-restore $APP"
archive=$(realpath -- "$archive")
[[ -f $archive && -s $archive ]] || ql_die "archive not found or empty: $archive"
ql_require_rootless
app_lock

sums=$(dirname -- "$archive")/SHA256SUMS
if [[ -f $sums ]] && grep -q "  ${archive##*/}\$" "$sums"; then
  (cd "$(dirname -- "$archive")" && grep "  ${archive##*/}\$" SHA256SUMS | sha256sum -c --quiet -) \
    || ql_die "checksum mismatch for $archive"
  ql_info "checksum ok: ${archive##*/}"
fi

pre=$(app_new_backup_dir pre-restore)
systemctl --user stop open-design.service || true
ql_backup_volume open-design_open_design_data "$pre" >/dev/null
app_checksums "$pre"
ql_info "pre-restore copy of the current data: $pre"
mp=$(podman volume inspect --format '{{.Mountpoint}}' open-design_open_design_data)
[[ $mp == /* && $mp != / ]] || ql_die "unexpected mountpoint for open-design_open_design_data"
podman unshare find "$mp" -mindepth 1 -delete
podman volume import open-design_open_design_data "$archive" \
  || ql_die "podman volume import failed; the previous data is in $pre"
systemctl --user start open-design.service
app_wait_healthy open-design 300 open-design.service
"$REPO/tests/smoke.sh" --quick || ql_die "restored, but the quick smoke check failed"
ql_info "restore complete (previous data kept in $pre)"
