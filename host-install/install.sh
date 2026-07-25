#!/usr/bin/env bash
# =============================================================================
# Open-Design host-install (podman branch)
# =============================================================================
# Installs the od-runner (headless-entry.mjs + headless-renderer.py) onto an
# Ubuntu 24.04 host as a systemd --user service. This is the HOST half of the
# podman-branch deployment; the PODMAN half is under ../podman-stack/.
#
# Idempotent. Safe to re-run.
#
# What this installs:
#   - apt: build-essential, python3.12-venv, ca-certificates, curl, git,
#          openssh-server (defensive, for desktop-image machines)
#   - nvm 0.40.x -> Node 22.x
#   - npm globals used by od-runner
#   - Playwright + Chromium (npx playwright install --with-deps chromium)
#   - Python 3.12 venv at ~/od/.venv with headless-renderer requirements
#   - ~/od/ layout with symlinks back to this repo checkout
#   - systemd --user unit at ~/.config/systemd/user/od.service
#   - user linger (so od.service survives logout)
# =============================================================================

set -euo pipefail

# ---- constants --------------------------------------------------------------
readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OD_HOME="${HOME}/od"
readonly OD_VENV="${OD_HOME}/.venv"
readonly OD_CONFIG_DIR="${HOME}/.config/od"
readonly SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
readonly NVM_VERSION="v0.40.1"
readonly NODE_MAJOR="22"

# ---- helpers ----------------------------------------------------------------
log()  { printf '\033[1;36m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need_sudo() {
  if ! sudo -n true 2>/dev/null; then
    warn "This step needs sudo. You may be prompted for your password."
  fi
}

# ---- preflight --------------------------------------------------------------
[[ "${EUID}" -ne 0 ]] || die "Run as your normal user, NOT as root."
command -v apt-get >/dev/null 2>&1 || die "This script targets Ubuntu (apt-get missing)."

log "Repo checkout: ${REPO_DIR}"
log "Target OD home: ${OD_HOME}"

# ---- 1. apt packages --------------------------------------------------------
log "Installing apt packages (idempotent)…"
need_sudo
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential \
  python3.12 python3.12-venv python3-pip \
  openssh-server

# Ensure OpenSSH is enabled+running (host is the sole access plane).
sudo systemctl enable --now ssh.service || warn "Could not enable ssh.service (already active?)"

# ---- 2. nvm + Node 22 -------------------------------------------------------
export NVM_DIR="${HOME}/.nvm"
if [[ ! -s "${NVM_DIR}/nvm.sh" ]]; then
  log "Installing nvm ${NVM_VERSION}…"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
else
  log "nvm already present at ${NVM_DIR}"
fi
# shellcheck disable=SC1091
. "${NVM_DIR}/nvm.sh"

if ! nvm ls "${NODE_MAJOR}" >/dev/null 2>&1; then
  log "Installing Node ${NODE_MAJOR}.x via nvm…"
  nvm install "${NODE_MAJOR}"
fi
nvm alias default "${NODE_MAJOR}" >/dev/null
nvm use default >/dev/null
log "Node: $(node --version)  npm: $(npm --version)"

# ---- 3. ~/od/ layout --------------------------------------------------------
log "Preparing ${OD_HOME}/…"
mkdir -p "${OD_HOME}" "${OD_CONFIG_DIR}"

# Symlink the runner sources from the repo into ~/od/ so systemd has a
# stable path regardless of where you cloned the repo.
ln -sfn "${REPO_DIR}/headless-entry.mjs"    "${OD_HOME}/headless-entry.mjs"
ln -sfn "${REPO_DIR}/headless-renderer.py"  "${OD_HOME}/headless-renderer.py"

# If the repo ships a package.json at root, symlink it too; otherwise create
# a minimal one so `npm install` has a home.
if [[ -f "${REPO_DIR}/package.json" ]]; then
  ln -sfn "${REPO_DIR}/package.json" "${OD_HOME}/package.json"
else
  if [[ ! -f "${OD_HOME}/package.json" ]]; then
    cat > "${OD_HOME}/package.json" <<'JSON'
{
  "name": "od-runner-host",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "dependencies": {
    "playwright": "^1.47.0"
  }
}
JSON
  fi
fi

# ---- 4. Node deps + Playwright browsers ------------------------------------
log "Installing Node deps under ${OD_HOME}…"
(
  cd "${OD_HOME}"
  npm install --no-audit --no-fund
)

log "Installing Playwright + Chromium (with system deps)…"
(
  cd "${OD_HOME}"
  npx --yes playwright install --with-deps chromium
)

# ---- 5. Python venv for headless-renderer.py -------------------------------
log "Creating Python venv at ${OD_VENV}…"
if [[ ! -x "${OD_VENV}/bin/python" ]]; then
  python3.12 -m venv "${OD_VENV}"
fi
# shellcheck disable=SC1091
. "${OD_VENV}/bin/activate"
python -m pip install --upgrade pip wheel

# Install renderer requirements if a requirements file exists in the repo.
if [[ -f "${REPO_DIR}/requirements.txt" ]]; then
  pip install -r "${REPO_DIR}/requirements.txt"
elif [[ -f "${REPO_DIR}/headless-renderer.requirements.txt" ]]; then
  pip install -r "${REPO_DIR}/headless-renderer.requirements.txt"
else
  warn "No requirements.txt found; installing a conservative default set."
  pip install pillow requests jinja2
fi
deactivate

# ---- 6. Config stub ---------------------------------------------------------
if [[ ! -f "${OD_CONFIG_DIR}/config.json" ]]; then
  log "Writing config stub ${OD_CONFIG_DIR}/config.json (edit before starting)…"
  cat > "${OD_CONFIG_DIR}/config.json" <<'JSON'
{
  "listen": { "host": "127.0.0.1", "port": 7001 },
  "renderer": { "python": "~/od/.venv/bin/python" },
  "notes": "Edit this file, then: systemctl --user restart od"
}
JSON
  chmod 0600 "${OD_CONFIG_DIR}/config.json"
fi

# ---- 7. systemd --user unit -------------------------------------------------
log "Installing systemd --user unit…"
mkdir -p "${SYSTEMD_USER_DIR}"
install -m 0644 "${REPO_DIR}/host-install/od.service" "${SYSTEMD_USER_DIR}/od.service"

# Enable linger so the service survives logout (needed for headless boxes).
if ! loginctl show-user "${USER}" 2>/dev/null | grep -q '^Linger=yes$'; then
  log "Enabling linger for user ${USER}…"
  need_sudo
  sudo loginctl enable-linger "${USER}"
fi

systemctl --user daemon-reload
systemctl --user enable od.service || true

# ---- 8. next steps ----------------------------------------------------------
cat <<EOF

============================================================================
  Open-Design host-install COMPLETE.
============================================================================

Next steps:

  1) Edit config (API keys / paths):
       \$EDITOR ${OD_CONFIG_DIR}/config.json

  2) Start the od-runner:
       systemctl --user start od
       systemctl --user status od
       journalctl --user -u od -f

  3) Start the od-console podman stack:
       cd ${REPO_DIR}/podman-stack
       cp .env.example .env    # if you haven't already
       podman-compose up -d
       podman logs -f od-console

  4) Open the console:
       http://\$(hostname -I | awk '{print \$1}'):4000

Notes:
  - This host is the sole access plane. SSH in, then use \`podman exec\`
    for containers or \`systemctl --user\` for host services.
  - No ttyd is installed anywhere.

EOF
