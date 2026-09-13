#!/usr/bin/env bash
# scripts/backup.sh: cold backup of the OpenDesign data volume (projects, app.sqlite and the OpenCode
# credentials under $HOME=/app/.od/home).
#
#   scripts/backup.sh [--hot]
#
#   --hot   export the volume without stopping the daemon. Faster, but app.sqlite may be mid-write;
#           use it only for a quick copy, never as the backup you plan to restore from.
#
# Prints the backup directory on stdout. Files are 0600 in 0700 directories, with SHA256SUMS.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

hot=0
while (($#)); do
  case $1 in
    --hot) hot=1 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
podman volume exists open-design_open_design_data || ql_die "volume open-design_open_design_data does not exist"

dest=$(app_new_backup_dir backup)
was_running=$(systemctl --user is-active open-design.service 2>/dev/null || true)
if ((hot == 0)) && [[ $was_running == active ]]; then
  # nginx follows through BindsTo=, and comes back with the daemon.
  systemctl --user stop open-design.service
  start_again() { systemctl --user start open-design.service || ql_warn "could not start open-design.service again"; }
  # a hook, not `trap ... EXIT`, which would replace the handler ql_lock armed
  ql_cleanup restart start_again
fi
ql_backup_volume open-design_open_design_data "$dest" >/dev/null
printf '%s\n' "$OD_VERSION" >"$dest/VERSION"
if ((hot == 0)) && [[ $was_running == active ]]; then
  ql_cleanup_clear restart
  start_again
  app_wait_healthy open-design 300 open-design.service
fi
app_checksums "$dest"
ql_info "backup complete: $dest"
printf '%s\n' "$dest"
