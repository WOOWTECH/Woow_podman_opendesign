# Changelog

## 4.0.0 — 2026-11-05 (BREAKING)

Phase 1 of aligning with the PaaS service and the Home Assistant add-on.

- **The image is now built on the shared WoowTech core** (`ghcr.io/woowtech/open-design-core`
  `20261101.2319`, by digest), replacing upstream `ghcr.io/nexu-io/od:0.21.1`. OpenDesign goes from
  0.21.1 to 0.24.1. The image grows from about 1 GB to about 5.8 GB and is amd64 only.
- **Four agents:** Claude Code 2.1.296, Codex 0.162.1, Pi 1.1.0 and OpenCode 1.18.33 come from the
  core. The last build step fails on any other version. Their logins and settings live in
  `$HOME=/app/.od/home`, in the data volume.
- **The export renderer and its helper tree are root-owned** and not writable by the agents' UID.
- **Shutdown:** the daemon closes its server and exits explicitly, the fix the HA add-on carries for
  0.24.1.
- **Fix: `home/` in the data volume was not writable.** A volume created by 3.0.0 has a root-owned
  `/app/.od/home`, left by the image build, so agents could not write their logins or settings.
  `install.sh`, `upgrade.sh` and `restore.sh` now return such paths to the account that owns the
  volume, and the image starts new volumes with an empty home.
- **`WOOW_OD_MEMORY` now defaults to `4g`** (was `2g`). An existing env file keeps its value.
- **Upgrading is one-way for data:** the daemon migrates `app.sqlite` forward, so going back to 3.0.0
  needs the pre-upgrade archive that `scripts/upgrade.sh` takes.
- CI builds the image, which runs the core contract.
- Not in this release: the built-in MCP server, the Paseo and Omnigent setup and the web terminal.
  Their plugin cards can appear in the UI, but those features are not wired up yet.

## 3.0.0 — 2026-09-12 (BREAKING)

Quadlet + systemd is now the only deployment in this repo.

- **Quadlet units** `open-design.service` (the daemon, which owns the network namespace) and
  `open-design-nginx.service` (the front, `Network=container:open-design`, `BindsTo=` the daemon).
  They start at boot through linger and restart on failure; the compose stack had no boot recovery on
  rootless podman.
- **nginx Basic auth is on by default** (BREAKING). Upstream enforces `OD_API_TOKEN` only for
  non-loopback callers, and nginx is always a loopback caller, so the token never protected the
  published port: the UI, and `/api/models-config` with its provider keys, were served to anyone who
  could reach it. The browser now signs in as user `open-design` with the generated token as the
  password (upstream's own Docker sign-in shape). `WOOW_OD_AUTH=off` is documented for stacks behind
  an authenticating proxy; `/api/health` is the only exemption.
- **Loopback by default** (BREAKING). Only nginx's port is published, on `127.0.0.1:7456`. Use
  `WOOW_OD_BIND=all` for LAN or tailnet access (it publishes IPv6 too). The daemon's 7457 is no
  longer on the host at all: the stack moved off host networking onto a private bridge namespace.
- **The pids limits are really applied now.** podman-compose 1.0.6 silently dropped `pids_limit`, so
  the compose deployment ran with the 2048 default even though the file said 512/128.
- **The image tag bug is fixed.** The old installer built `${OPEN_DESIGN_IMAGE}:latest`, which turned
  a tag like `foo:1.0` into `foo:1.0:latest`. The tag now comes from the `VERSION` file, CI checks
  that the unit agrees with it, and each version keeps its own image so a rollback has one.
- **Environment variables renamed** (BREAKING): `OPEN_DESIGN_ALLOWED_ORIGINS` becomes
  `OD_ALLOWED_ORIGINS` (the daemon's own name), and `OPEN_DESIGN_IMAGE`,
  `OPEN_DESIGN_DISABLE_API_AUTH` and `OPEN_DESIGN_MEM_LIMIT` are replaced by the `VERSION` file, the
  nginx auth setting and `WOOW_OD_MEMORY`. `install.sh` validates every origin and refuses to
  continue without the local one.
- **New scripts:** `install.sh` (build, render, validate, secrets, start), `upgrade.sh` (with unit
  rollback), `uninstall.sh` (`--purge` is the only way to delete data; `--purge-images`),
  `backup.sh`, `restore.sh`.
- **Tests and CI:** `tests/dryrun.sh` (Quadlet 4.9.3 dry-run and `systemd-analyze verify`),
  `tests/smoke.sh` (auth, origins, limits, export bridge, gzip, namespace, secret hygiene),
  `tests/lint-repo.sh`, plus `nginx -t` for both auth variants and hadolint in CI.
- **Moved:** `nginx.conf` and `od-export-bridge.js` now live in `config/` and are installed into
  `~/.config/open-design/`. `nginx` is pinned at `1.30.4-alpine` by digest (was `1.27-alpine`).
- **Removed:** `docker-compose.podman.yml` and `.env.example`. Docker users stay on the
  `compose-final` tag; upstream also ships its own compose file.
- **Docs:** both READMEs describe the Quadlet install and correct the old claims (first boot does not
  pull `od:latest`, there is one volume, and the origin guard is OpenDesign's own, not pi-web's).
