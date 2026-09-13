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
| `WOOW_OD_AUTH` | `basic` | `off` disables the nginx credential check. `install.sh` refuses it unless `WOOW_OD_BIND` is loopback: `/api/models-config` returns your provider keys. Use it only behind an authenticating proxy or an SSH tunnel. |
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

`scripts/migrate-legacy.sh` moves a running podman-compose / docker-compose deployment of the
`open-design` project (containers `open-design` and `open-design-nginx`, both on the **host**
network, the volume `open-design_open_design_data`, and an `nginx.conf` plus `od-export-bridge.js`
bind-mounted from the build directory) onto the Quadlet units of this repo.

The volume name is unchanged (`VolumeName=open-design_open_design_data`), so projects, `app.sqlite`
and the OpenCode credentials are **adopted in place**: nothing is copied. The legacy containers are
kept for `--rollback`.

```bash
scripts/migrate-legacy.sh --dry-run                  # checks + render, changes nothing
scripts/migrate-legacy.sh --prepare-only             # + secrets and THE IMAGE BUILD; no downtime
scripts/migrate-legacy.sh                            # the cutover
scripts/migrate-legacy.sh --status                   # what was recorded
scripts/migrate-legacy.sh --rollback                 # back to the legacy stack
```

Useful options: `--legacy-dir DIR` archives the old build directory's compose file and `.env`;
`--bind ADDR` / `--port N` / `--auth basic|off` override the derived exposure; `--suffix S` names
the kept containers; `--force-capture` takes the capture path on a host that would allow a rename;
`--no-cold-copy` skips the cold `podman volume export`; `--allow-version-change` permits a different
OpenDesign minor version.

**Two things deliberately change**, because they are why this repo's Quadlet conversion exists, and
the script says so before the cutover and again at the end:

| | compose (host network) | Quadlet |
|---|---|---|
| the front | listens on **every** interface | published on `127.0.0.1` (`--bind all` keeps the old reach) |
| the daemon | holds `127.0.0.1:7457` on the host | inside its own network namespace; the host port is gone |
| credentials | **none** | HTTP Basic as user `open-design`, password = the API token |

`--auth off` is accepted only while the front stays on loopback: `/api/models-config` returns the
configured provider keys. The legacy `OD_DISABLE_API_AUTH=1` is **not** carried over — the Quadlet
daemon exempts loopback peers, which is all nginx ever is, and checks the token for everything else.

**The image is built in the prepare phase, not during the cutover.** Building
`localhost/woow-open-design:<VERSION>` takes 10-20 minutes on a small host; doing it while the
legacy stack is still serving is what keeps the downtime to the length of a container restart, and
`install.sh` is then called with `--no-build`.

**What it reads from where.** Everything comes from the *running containers*, because on
`woowtechopenclaw` the deployed tree (`~/od-podman-align`) is not a git repository and is not the
tree this repo describes. `OD_ALLOWED_ORIGINS`, `NODE_OPTIONS`, `OD_CODEX_SANDBOX`, the BYOK
provider keys and `OD_API_TOKEN` come from the daemon's environment; `WOOW_OD_MEMORY` and
`WOOW_OD_CPUS` from its `HostConfig`. The **host port comes from the `listen` directive of the
bind-mounted `nginx.conf`**: with host networking podman records no port binding at all, so that
file is the only statement of which port the stack serves. `http://127.0.0.1:<port>` is added to
the origin list if it is missing, because without it the daemon answers 403 on every data route.

**The API token is adopted** into the `open-design-api-token` secret when the legacy stack has a
usable one, so API clients keep working; it is also the browser password. Read it with
`podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token`.

**Your `nginx.conf` and `od-export-bridge.js` are replaced by this repo's copies.** Both legacy
files are archived in the backup and, if they differ, a unified diff is written next to them and the
difference is reported. On a host whose build directory is not a git repository this is the only
record of what was there.

**What it refuses rather than guesses.** A legacy container that is missing or not running; one that
is already managed by these units; Quadlet units that are already installed; a volume whose name
differs from what `open-design-data.volume` pins (adopting would silently start on an empty
`app.sqlite`); an `nginx.conf` that cannot be read or whose `listen` directives disagree; another
container publishing the same host port; a port still bound after the legacy stack stopped; a
different OpenDesign minor version; `--auth off` on a routable address; and a second run after a
recorded cutover.

**How the legacy containers are kept** (STANDARD 7a). Either renamed to `<name>-legacy-<suffix>` and
left stopped, or — where `podman-restart.service` is enabled *and* a legacy container's restart
policy is exactly `always` — captured into the backup directory and removed. `ql_rollback_strategy`
decides from the host's real state, never from its name. Both containers are `unless-stopped` today,
so both hosts resolve to `rename`; `--force-capture` exercises the other path. Neither container is
captured with `--commit`: `open-design` runs with `--read-only` and has no writable layer to lose,
and `open-design-nginx` is the stock nginx image.

**What the backup holds** (`~/.local/share/woow-backups/open-design/migrate-<stamp>/`, 0700):
`inspect.json`, the legacy `nginx.conf` and `od-export-bridge.js` (plus a `.diff` against this
repo's copies), the legacy compose file and `.env`, a cold `podman volume export` of the data
volume, `volume-fingerprints`, `precheck.txt` and `SHA256SUMS` — and `legacy-container/` on the
capture path.

**Adoption is proved, not assumed.** The volume's `CreatedAt` and the on-disk inodes of its
directory and of `app.sqlite` are recorded before the cutover and compared after `install.sh`. A
mismatch fails the migration and rolls it back, instead of reporting a healthy OpenDesign sitting on
an empty database.

**Downtime** is measured by the script, from stopping the legacy stack to `install.sh` returning,
and printed at the end (and recorded as `DOWNTIME_S` in `--status`).

### Rolling back

```bash
scripts/migrate-legacy.sh --rollback
```

It stops and removes the Quadlet units (the data volume and the secrets are kept, because both
stacks share them), removes any container this repo's units left behind, brings the legacy
containers back — renamed back, or recreated from the capture with their original restart policy
and their host networking — starts the daemon before its front, and waits for `/api/health` on the
legacy port. A failed cutover rolls itself back automatically unless `--no-auto-rollback` was given.
The empty Quadlet network is a harmless leftover: `podman network rm open-design`.

### After the soak

Once the Quadlet stack has run long enough, remove the legacy containers — **the nginx one first**,
because `open-design-nginx` was created with `--requires=open-design` and podman refuses to remove a
container something else requires:

```bash
podman rm open-design-nginx-legacy-<suffix> open-design-legacy-<suffix>
```

Then remove the old build directory's image tag if nothing else uses it, and keep the migration
backup until you are sure.

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
scripts/migrate-legacy.sh          adopt a running compose deployment; --rollback, --status
scripts/legacy-helpers.sh          the helpers migrate-legacy.sh uses (kept out of common.sh, which is
                                   byte-identical across four repos below its settings block)
scripts/lib/                       vendored quadlet-lib (do not edit; CI checks its hash)
tests/dryrun.sh                    render + Quadlet 4.9.3 dry-run + systemd-analyze verify (CI and local)
tests/smoke.sh                     post-install checks on a host
tests/lint-repo.sh                 credential scan, VERSION parity, auth-boundary invariants (CI)
tests/migrate-model.sh             pins the migration: both rollback strategies, the dependency order,
                                   reading a host-networked stack, the adoption proof (shim-driven)
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
