#!/usr/bin/env bash
# scripts/uninstall.sh: remove the Woow OpenDesign Quadlet units. Keeps all data by default.
#
#   scripts/uninstall.sh                  stop and remove the units; keep the data volume, network,
#                                         secrets, images, ~/.config/open-design and every backup
#   scripts/uninstall.sh --purge [--yes]  also delete the volume (projects, app.sqlite and the
#                                         OpenCode credentials in $HOME=/app/.od/home), the network,
#                                         the secrets and ~/.config/open-design, after a final backup
#   scripts/uninstall.sh --purge-images   also remove localhost/woow-open-design:*
#   scripts/uninstall.sh --dry-run        report what would be removed
#
# --purge is the only way this repo deletes data. Backups are never deleted.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

purge=0 yes=0 purge_images=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    --purge-images) purge_images=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
if ((purge)); then
  app_confirm "$APP" "$yes" "--purge deletes the OpenDesign projects, credentials, network and settings"
  if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
    final=$(app_new_backup_dir final)
    systemctl --user stop open-design.service >/dev/null 2>&1 || true
    if podman volume exists open-design_open_design_data; then
      ql_backup_volume open-design_open_design_data "$final" >/dev/null
    fi
    if [[ -f $ENV_FILE ]]; then install -m 600 -- "$ENV_FILE" "$final/${ENV_FILE##*/}"; fi
    app_checksums "$final"
    ql_info "final backup: $final"
  fi
  ql_uninstall_units "$APP" --purge
  if [[ ${QL_DRY_RUN:-0} == 1 ]]; then
    ql_info "[dry-run] --purge would also remove $HOME/.config/$APP"
  else
    rm -rf -- "$HOME/.config/$APP"
    ql_info "removed $HOME/.config/$APP (a copy of the env file is in the final backup)"
  fi
else
  ql_uninstall_units "$APP"
fi

if ((purge_images)); then
  if [[ ${QL_DRY_RUN:-0} == 1 ]]; then
    ql_info "[dry-run] would remove the localhost/woow-open-design images"
  else
    mapfile -t imgs < <(podman images --filter reference='localhost/woow-open-design' --format '{{.ID}}' | sort -u)
    ((${#imgs[@]} == 0)) || podman rmi -f "${imgs[@]}" >/dev/null 2>&1 || ql_warn "could not remove every local image"
    ql_info "removed ${#imgs[@]} local OpenDesign image(s); the nginx image is left (other stacks may use it)"
  fi
fi
