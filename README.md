# Woow OpenDesign on rootless Podman (Quadlet + systemd)

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.9%20rootless-892CA0)](https://podman.io)
[![OD](https://img.shields.io/badge/upstream-ghcr.io%2Fnexu--io%2Fod%200.21.1-blue)](https://github.com/nexu-io/od)
[![OpenCode](https://img.shields.io/badge/opencode--ai-1.18.29-blue)](https://www.npmjs.com/package/opencode-ai)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

Upstream Open Design (`ghcr.io/nexu-io/od`, pinned by digest at 0.21.1) with a headless export
pipeline (Chromium + Playwright + CJK fonts) and the **OpenCode** agent baked in, running as rootless
Podman [Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html) units under
`systemd --user`, with an **nginx front** for gzip, caching, SSE/WebSocket passthrough, the PDF export
bridge — and the sign-in dialog.

**Standalone.** It shares no volume, no credentials and no agent binary with any other deployment, and
mounts nothing from your home directory except its own config files.

> **Docker or podman-compose users:** the compose file was removed in 3.0.0. The last compose version
> is kept at the tag
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_opendesign/tree/compose-final). It is not
> maintained and it serves the UI on every interface without a credential check. Upstream also ships
> its own `deploy/docker-compose.yml`.

## What you get

| | |
|---|---|
| **UI** | `http://127.0.0.1:7456` by default, served by the nginx unit. **Basic auth is on by default**: user `open-design`, password = the generated API token. |
| **Daemon** | `open-design` (unit `open-design.service`), a locally built image `localhost/woow-open-design:<VERSION>`, listening on `127.0.0.1:7457` inside its own network namespace. |
| **nginx front** | `open-design-nginx` (unit `open-design-nginx.service`), pinned `nginx:1.30.4-alpine`, joins the daemon's namespace (`Network=container:open-design`). It stops and starts with the daemon. |
| **Data** | one volume, `open-design_open_design_data` (`/app/.od`): projects, `app.sqlite` and the OpenCode credentials in `$HOME=/app/.od/home`. |
| **Limits** | `PidsLimit` 512 / 128 and memory + CPU limits are really applied now. podman-compose 1.0.6 silently dropped `pids_limit`, so the compose deployment ran with the 2048 default. |
| **Rootless** | `UserNS=keep-id:uid=1001,gid=1001`, read-only root filesystem, `NoNewPrivileges`, tmpfs for `/tmp` and `/home/open-design`. |

> **Where the credential check lives.** Upstream's `OD_API_TOKEN` is only enforced for **non-loopback**
> callers (`apps/daemon/src/api-token-auth.ts`; the desktop UI flow depends on the exemption). nginx
> always reaches the daemon over loopback, so the token alone never protected `:7456` — including
> `/api/models-config`, which returns provider keys. That is why nginx now asks for credentials, with
> the same token as the password, and why `/api/health` is the only exemption.

## Requirements

- Linux with systemd and cgroup v2. Tested on Ubuntu 24.04.
- Podman 4.9 or newer, rootless (`keep-id:uid=…` needs 4.3+), plus `openssl` and `curl`.
- A normal login session for the user who owns the containers, and linger (install.sh enables it).
- About 6 GB of disk for the build (upstream base ~1.2 GB, Chromium/fonts/npm layer ~1 GB, build
  cache), and about 2 GB of RAM for the daemon. A PDF export peaks near that.
- A free port, 7456 by default.

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_opendesign.git
cd Woow_podman_opendesign
scripts/install.sh                           # first run: creates the settings file and stops for review
nano ~/.config/open-design/open-design.env   # at least OD_ALLOWED_ORIGINS
scripts/install.sh                           # build, render, validate, start, smoke
```

The first run builds `localhost/woow-open-design:$(cat VERSION)` from `Dockerfile.full`; that takes
10-20 minutes on a small host. `WOOW_OD_BUILD_CPUS` (and `nice`) keep it from starving co-located
stacks. Then sign in at `http://127.0.0.1:7456/`:

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token   # private terminal
```

| Option | Effect |
|---|---|
| `--accept-defaults` | On the first run, keep going with the example settings. |
| `--set KEY=VALUE` | Store a setting first (repeatable), e.g. `--set WOOW_OD_PORT=27456`. |
| `--no-build` / `--rebuild` | Skip the build (the tag must exist) / force a rebuild of the current tag. |
| `--rotate-token` | Generate a new API token, derive the new browser password, restart. |
| `--dry-run` | Render and validate, show what would change, touch nothing. |

Re-running `install.sh` is safe: with nothing changed it restarts nothing.

## Configure

Edit `~/.config/open-design/open-design.env`, then run `scripts/install.sh` again. The env file is not
a unit, so the installer tracks its hash and restarts the daemon when the file changed.

| Key | Default | Meaning |
|---|---|---|
| `OD_ALLOWED_ORIGINS` | `http://127.0.0.1:7456,http://localhost:7456` | Every `scheme://host:port` the UI is opened from. A missing origin answers `403 {"error":"Cross-origin requests are not allowed"}` on data routes while the UI still renders. `install.sh` validates the syntax and refuses to continue without the local origin. |
| `WOOW_OD_BIND` | `127.0.0.1` | Address the UI port is published on; `all` covers IPv4 and IPv6. |
| `WOOW_OD_PORT` | `7456` | Host port for the UI. |
| `WOOW_OD_AUTH` | `basic` | `off` disables the nginx credential check. Only for a stack behind an authenticating proxy. |
| `WOOW_OD_MEMORY` / `WOOW_OD_CPUS` | `2g` / `2` | Limits for the daemon container. |
| `WOOW_OD_BUILD_CPUS` | empty | `--cpuset-cpus` for the image build, e.g. `0-2`. |
| `NODE_OPTIONS` | `--max-old-space-size=1536` | Node heap; keep it below `WOOW_OD_MEMORY`. |
| `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | empty | Optional BYOK keys; they can also be set on the Models page. |

### Credentials

| Podman secret | What it is |
|---|---|
| `open-design-api-token` | The API token, and the password of the browser user `open-design`. Generated at install. |
| `open-design-htpasswd` | The apr1 hash nginx checks, derived from that token (deterministic salt, so an unchanged token changes nothing). |

Rotate both with `scripts/install.sh --rotate-token`.

## Verify

```bash
tests/smoke.sh            # units, health, ports, limits, rootless/read-only, auth, origins,
                          # export bridge, gzip and caching, namespace, secret hygiene
tests/smoke.sh --quick    # units, health, ports and /api/health only
```

From another machine, use `ssh -L 7456:127.0.0.1:7456 <host>` and open `http://127.0.0.1:7456/`.

## Upgrade

```bash
git pull
scripts/upgrade.sh
```

Backup, unit snapshot, `install.sh` (which builds the new `VERSION` tag), smoke. On failure the
previous units come back, and with them the previous image tag, which is still on the host because
every VERSION builds its own tag. The daemon migrates `app.sqlite` forward, so a rollback across a
data-format change also needs `scripts/restore.sh` with the pre-upgrade archive.

## Backup and restore

```bash
scripts/backup.sh                    # stops the daemon, exports the data volume, checksums it
scripts/backup.sh --hot              # without stopping (app.sqlite may be mid-write)
scripts/restore.sh --archive ~/.local/share/woow-backups/open-design/backup-<ts>/open-design_open_design_data-<ts>.tar --confirm-restore open-design
```

Backups land in `~/.local/share/woow-backups/open-design/` (0600 files, 0700 directories, with
`SHA256SUMS`). A restore stops the stack, keeps a pre-restore copy, replaces the volume and
smoke-checks the result.

## Uninstall

```bash
scripts/uninstall.sh                          # remove the units; keep the volume, network, secrets, settings
scripts/uninstall.sh --purge                  # also delete them, after a final backup (asks you to type "open-design")
scripts/uninstall.sh --purge --purge-images   # and remove the locally built images
```

`--purge` is the only command that deletes data, and it deletes your projects **and** the OpenCode
credentials, which share the one volume.

## Migrating a podman-compose deployment

The volume name is unchanged (`open-design_open_design_data`), so projects, `app.sqlite` and the
OpenCode credentials carry over in place.

1. **Decide how it is exposed.** The compose stack used host networking and nginx listened on every
   interface without credentials. Now the default is `127.0.0.1` with Basic auth. For LAN or tailnet
   users set `WOOW_OD_BIND=all` (it also publishes IPv6, which a `[fd7a:…]` tailnet origin needs) and
   leave auth on, or keep loopback and front it with tailscale serve, NPM or a tunnel.
2. **Import the existing token** so API clients keep working, and copy the origins:
   ```bash
   grep '^OD_API_TOKEN=' .env | cut -d= -f2- | tr -d '\n' | podman secret create open-design-api-token -
   ```
   Copy `OPEN_DESIGN_ALLOWED_ORIGINS` into `OD_ALLOWED_ORIGINS` (same values, the compose-only
   `OPEN_DESIGN_` prefix is gone) and move any BYOK key into the new env file.
3. **Stop the compose stack and rename its containers** so Quadlet cannot replace them:
   `podman stop open-design open-design-nginx`, then
   `podman rename open-design open-design-legacy-$(date +%Y%m%d)` and the same for the nginx one.
   They are `unless-stopped`, so `podman-restart.service` will not bring them back.
4. **Install and verify:** `scripts/install.sh`, then `tests/smoke.sh`.
5. **Roll back** by stopping the Quadlet units and renaming the legacy containers back. Take a
   `scripts/backup.sh` first: the newer daemon may have migrated `app.sqlite` forward.

## Files

```
Dockerfile.full runtime/ rootfs/   image build inputs (unchanged)
VERSION                            the local image tag; the unit and CI follow it
quadlet/                           Quadlet units with @@VAR@@ tokens; quadlet/render-vars is the whitelist
config/nginx.conf                  the front: gzip, caching, SSE, the auth include, the export bridge
config/nginx-auth.{basic,off}.conf installed as ~/.config/open-design/nginx-auth.conf
config/od-export-bridge.js         injected into <head> so the UI's PDF button hits the headless route
config/open-design.env.example     template for ~/.config/open-design/open-design.env
scripts/                           install, upgrade, uninstall, backup, restore
scripts/lib/                       vendored quadlet-lib (do not edit; CI checks its hash)
tests/dryrun.sh                    render + Quadlet 4.9.3 dry-run + systemd-analyze verify (CI and local)
tests/smoke.sh                     post-install checks on a host
tests/lint-repo.sh                 credential scan, VERSION parity, auth-boundary invariants (CI)
docs/plans/                        design history (the host-network compose layout is superseded)
```

## Troubleshooting

| Symptom | Check |
|---|---|
| The browser asks for a password you do not have | `podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token`, user `open-design`. Or rotate: `scripts/install.sh --rotate-token`. |
| The UI renders but every action fails with 403 | The origin you opened is not in `OD_ALLOWED_ORIGINS`. Add it and run `scripts/install.sh`. |
| The PDF button returns 501 | The export bridge is not being injected: check `config/nginx.conf` and `podman logs open-design-nginx`. |
| nginx keeps restarting | It lives in the daemon's namespace: `journalctl --user -u open-design-nginx.service -n 50`, and make sure `open-design.service` is up. |
| The build is slow or starves the host | `WOOW_OD_BUILD_CPUS=0-2`, or build once and copy the image to other hosts. |
| Units gone after logout or reboot | `loginctl show-user $USER -p Linger` must say `yes`. |
