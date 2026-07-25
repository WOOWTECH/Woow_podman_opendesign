# host-install/

Host-side install artifacts for the **`podman`** branch of Open-Design.

The Open-Design runner (`headless-entry.mjs` + `headless-renderer.py`) runs
directly on the Ubuntu host under a `systemd --user` service — not in a
container. Playwright/Chromium and the Python renderer both prefer host
access to GPU / fonts / libraries, and running them on the host also avoids
duplicating a 1+ GB browser image inside podman.

## Files

- **`install.sh`** — idempotent installer. Installs apt deps + nvm + Node 22
  + Playwright/Chromium + Python 3.12 venv, creates `~/od/`, drops
  `od.service` into `~/.config/systemd/user/`, and enables user linger.
- **`od.service`** — the systemd `--user` unit that runs the headless
  entry point. Copied to `~/.config/systemd/user/od.service` by
  `install.sh`.

## Usage

From a fresh clone of this repo on an Ubuntu 24.04 host:

```bash
./host-install/install.sh
$EDITOR ~/.config/od/config.json       # paste real config
systemctl --user start od
systemctl --user status od
journalctl --user -u od -f
```

Then bring up the web console (see `../podman-stack/`).

## Uninstall

```bash
systemctl --user stop od
systemctl --user disable od
rm ~/.config/systemd/user/od.service
systemctl --user daemon-reload
# Optional: rm -rf ~/od  ~/.config/od
```
