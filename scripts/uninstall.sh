#!/usr/bin/env bash
# Take the OD stack down. The named volume open_design_data is KEPT by
# default (it holds sessions, models config, uploaded assets); pass --purge
# to delete it. pi-agent-data is EXTERNAL — never removed by this script.
#
#   ./scripts/uninstall.sh            keep open_design_data, keep the image
#   ./scripts/uninstall.sh --purge    also delete open_design_data
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

PURGE="${1:-}"

say "Stopping services"
podman-compose -f docker-compose.podman.yml down 2>&1 | tail -5 || true

if [ "${PURGE}" = "--purge" ]; then
    say "Deleting open_design_data (--purge given)"
    podman volume rm -f open-design_open_design_data 2>/dev/null || true
    warn "pi-agent-data was NOT touched — it is shared with pi-web and other consumers."
else
    say "Keeping open_design_data — remove with: podman volume rm open-design_open_design_data"
fi

say "Done."
