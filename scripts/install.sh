#!/usr/bin/env bash
# Build the OD image and bring the stack up under rootless podman-compose.
#
# Prerequisites on the host:
#   - Podman >= 4.4, podman-compose 1.0.6+
#   - Rootless user with subuids and linger enabled (loginctl enable-linger)
#   - A same-host `pi-agent-data` volume (from Woow_podman_pi_agent_package)
#     if you want the pi-od integration; otherwise the daemon still runs
#     but the /api/pi routes fail at spawn time.
#
# Usage:
#   ./scripts/install.sh                    # build image, up -d
#   OD_SKIP_BUILD=1 ./scripts/install.sh    # skip image build (use existing)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run this as root. Rootless podman is the design."
command -v podman >/dev/null || die "podman not found"
command -v podman-compose >/dev/null || die "podman-compose not found"

if [ ! -f .env ]; then
    say "No .env found — copying from .env.example. Edit it before starting for real."
    cp .env.example .env
    warn "Fill OPEN_DESIGN_ALLOWED_ORIGINS with every hostname the UI will be opened from."
    warn "Otherwise pi-web's origin guard returns 403 and the UI renders but does nothing."
fi

# pi-agent-data volume — external, from the sibling pi-web package. Create an
# empty one if it does not exist so podman-compose does not refuse to start.
if ! podman volume exists pi-agent-data 2>/dev/null; then
    warn "External volume pi-agent-data missing — creating an empty one."
    warn "The pi-od integration works better when this is the same volume as"
    warn "the Woow_podman_pi_agent_package deployment's pi-agent-data."
    podman volume create pi-agent-data >/dev/null
fi

if [ "${OD_SKIP_BUILD:-0}" != "1" ]; then
    IMAGE_TAG="$(grep '^OPEN_DESIGN_IMAGE=' .env | cut -d= -f2)"
    IMAGE_TAG="${IMAGE_TAG:-open-design-full}"
    say "Building image ${IMAGE_TAG} from Dockerfile.full"
    # Build context is the repo root — Dockerfile.full COPYs deploy/pi-od,
    # which lives at the repo root here.
    podman build --format=docker -t "${IMAGE_TAG}:latest" -f Dockerfile.full .
fi

say "Bringing up the stack (podman-compose)"
podman-compose -f docker-compose.podman.yml up -d

say "Waiting for the daemon to report healthy"
for i in $(seq 1 60); do
    status="$(podman inspect --format '{{.State.Health.Status}}' open-design 2>/dev/null || echo starting)"
    [ "${status}" = "healthy" ] && { say "  healthy after ~$((i*5))s"; break; }
    [ "$i" -eq 60 ] && warn "still ${status} after 5 minutes — check: podman logs open-design"
    sleep 5
done

cat <<EOF

$(say "Done")

  UI         http://127.0.0.1:$(grep '^OPEN_DESIGN_PORT=' .env | cut -d= -f2) — served by the nginx sidecar
  Logs       podman logs -f open-design
             podman logs -f open-design-nginx
  Shell      podman exec -it open-design sh
  Stop       podman-compose -f docker-compose.podman.yml down
  Status     podman ps --format '{{.Names}}\t{{.Status}}'

  Any browser origin the UI is opened from MUST be in
  OPEN_DESIGN_ALLOWED_ORIGINS in .env, and the container recreated
  (podman rm -f open-design && podman-compose ... up -d) for it to take
  effect. Missing origins fail with a distinctive HTTP 403 from the
  daemon's origin-validation middleware.

EOF
