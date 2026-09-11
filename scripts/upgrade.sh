#!/usr/bin/env bash
# scripts/upgrade.sh: upgrade Woow OpenDesign to the version in this checkout (VERSION plus the
# pinned base image in Dockerfile.full), with automatic rollback of the units when it fails.
#
#   git pull && scripts/upgrade.sh [--no-backup]
#
# Steps: backup -> save the installed units -> scripts/install.sh (builds the new image tag, then
# restarts what changed) -> tests/smoke.sh. On failure the saved units come back, which points the
# daemon at the previous image tag; that image is still there because each VERSION builds its own tag.
# The daemon migrates app.sqlite forward, so a rollback across a data-format change also needs
# scripts/restore.sh with the pre-upgrade archive.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

no_backup=0
while (($#)); do
  case $1 in
    --no-backup) no_backup=1 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_preflight "$PODMAN_MIN"
[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE does not exist: run scripts/install.sh first"
app_lock

snap=$(app_new_backup_dir upgrade)
data=''
if ((no_backup == 0)); then
  data=$("$REPO/scripts/backup.sh") || ql_die "backup failed; nothing was changed"
  ql_info "pre-upgrade backup: $data"
fi
app_snapshot "$snap/units"
podman inspect --format '{{.Name}} {{.ImageName}} {{.Image}}' open-design open-design-nginx >"$snap/images.txt" 2>/dev/null || true

if "$REPO/scripts/install.sh" --no-smoke && "$REPO/tests/smoke.sh"; then
  ql_info "upgrade complete (unit snapshot: $snap)"
  exit 0
fi

ql_warn "upgrade failed; rolling back to the units saved in $snap/units"
app_snapshot_restore "$snap/units" || ql_die "rollback failed: no usable snapshot. Inspect $snap and journalctl --user -u open-design.service"
systemctl --user restart open-design.service || true
if ql_wait_container_healthy open-design 300 && "$REPO/tests/smoke.sh" --quick; then
  ql_die "upgrade failed and was rolled back; the previous version is running again"
fi
ql_die "upgrade failed and the rollback is unhealthy too. Restore data with: scripts/restore.sh --archive ${data:-<backup>} --confirm-restore $APP"
