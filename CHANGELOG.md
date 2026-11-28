# Changelog

## 4.3.1 — 2026-11-28

- **Install and upgrade no longer fail at random while building `node-pty`.** Agent Connect 0.3.1 compiles
  `node-pty` for musl against the Node headers that ship in the image. Before, node-gyp downloaded them from
  unofficial-builds.nodejs.org. That host publishes an IPv4 and an IPv6 address and Node gives each address only
  250 ms, while from Asia its IPv4 connect takes 0.23–0.26 s (sometimes over a second), so on a host without IPv6
  routing `podman build` stopped with `NATIVE_NODE_PTY_BUILD_FAILED` now and then: a fresh 4.3.0 install failed
  once on 2026-11-27 and three times in a row on another fresh VM on 2026-11-28 (the installer changed nothing each
  time; resolving that host to its IPv4 address alone made the same build pass). A failed build now keeps npm's
  own error in the log.
- Paseo stays 0.17.5 and the runtime revision stays `0.17.5-r2-186f173be43b`: upgrading from 4.3.0 keeps the
  installed runtime, the provider homes, the pairing and the conversations. The card shows Agent Connect 0.3.1.
- `paseo/` is a copy of the published `v0.3.1` release (see `paseo/SOURCE.md`).

## 4.3.0 — 2026-11-27

- **Agent Connect.** The Paseo card is now Agent Connect (opendesign-paseo-plugin 0.3.0, official Paseo 0.17.5,
  up from 0.11.2). The plugin id, the `/paseo/setup/` path, the provider homes and the workspaces are
  unchanged. The setup page offers three fixed client targets: the official Paseo app, woowtech smart and
  apporo smart. Each has its own App origin, relay (`relay.paseo.sh`, `relay.woowtech.io`, `relay.apporo.ai`)
  and host brand; choosing a target only stores the choice, so stop and start the service to apply it.
- The managed runtime is built into the image (`/opt/opendesign-paseo/managed-runtime`): `node-pty` is
  rebuilt for musl and must pass a real PTY spawn before the runtime is marked ready, so enabling Paseo
  downloads nothing and writes no packages to the data volume.
- CI now starts the baked runtime offline under tini (UID 1001, read-only image, no network) and runs the
  product entrypoint under rootless podman, including the managed daemon and its normal stop.
- `paseo/` is a copy of the published `v0.3.0` release (see `paseo/SOURCE.md`).
- Going back to 4.2.1 is a data-format rollback for Agent Connect: Paseo 0.11.2 refuses the relay setting
  `requireProtectedSecurity` that 0.17.5 writes to `paseo/daemon/config.json` in the data volume (for every
  client target). After `upgrade.sh` restores the old units on its own, or after a manual checkout of 4.2.1,
  the Paseo service stays in an error state until the pre-upgrade archive is restored with
  `scripts/restore.sh`, or until that one key is removed from the file (keep mode 0600); the rest of
  OpenDesign keeps working, and the conversations stay readable. Extra listeners added on the Devices page of
  Paseo 0.17.5 also need the manual steps in the plugin's Agent Connect guide.

- **The MCP server leaves keep-id.** `open-design-mcp` still runs as uid 10001, now in podman's default
  rootless mapping: on the host that is a subordinate uid (110000 with the usual `/etc/subuid` start of
  100000), no longer this account. Rootless podman keeps a chowned copy of the whole image for every
  keep-id mapping, so the MCP server's own mapping cost a second copy (5.5 GB for 4.2.1); the daemon and
  the terminal keep sharing the first. The copy an existing install already has is freed when its image
  is removed.
- Both MCP volumes are mounted with `:U`: the first start takes over the state of an existing install
  (the token and the tool switches stay as they are), and every start takes over a restore made by any
  tool. `restore.sh` gives the restored MCP state to the uid of the installed MCP unit, and the automatic
  rollback of `upgrade.sh` gives both volumes back to this account when it restores keep-id units.
- Going back to an older checkout by hand: stop `open-design.service`, run
  `podman unshare chown -R 0:0` on the mountpoints of `open-design_mcp_data` and `open-design_mcp_run`
  (`podman volume inspect --format '{{.Mountpoint}}' <volume>`), then that checkout's `install.sh`.

## 4.2.1 — 2026-11-06

Findings from testing 4.2.0 through a Cloudflare tunnel with the official Paseo web app and woowtech smart.

- `install.sh --set` no longer warns that the env file lacks the keys this same run is setting.
- `install.sh` no longer warns that an `https://` origin has no port: it is a TLS front on 443.
- README: pairing with the official Paseo app and with woowtech smart, switching agents and models, and
  what to expect behind a Cloudflare tunnel (Access, the 1010 user-agent check).

## 4.2.0 — 2026-11-06

Phase 3 of aligning with the PaaS service and the Home Assistant add-on.

- **Paseo, off by default.** With `WOOW_OD_PASEO=on` the Paseo bridge (remote control of Claude Code,
  Codex and Pi from the Paseo phone app) runs beside the daemon, in its container, under the PaaS
  chart's supervisor. `paseo/` is a pinned copy of the PaaS image's runtime, and `@getpaseo/cli` 0.11.2
  is built into the image, so turning it on downloads nothing.
  - The routes `/paseo/setup/`, `/paseo/assets/` and `/api/paseo-bridge` are behind the same Basic auth
    as the UI. A change must come with the Paseo origin as its `Origin`. Nothing is logged for them.
  - It needs an HTTPS origin: set `OPENDESIGN_PASEO_ORIGIN` (also listed in `OD_ALLOWED_ORIGINS`).
    `install.sh` refuses `on` without one, or with `WOOW_OD_AUTH=off`.
  - The bridge gets an allowlisted environment without `OD_API_TOKEN`. Its state, the phone pairing
    included, is in the data volume, so backups contain it.
  - Off, `/paseo/setup/` answers that Paseo is off instead of the app's page.
- **Omnigent**: the core's host already ran here (Settings → Omnigent). The stop timeout goes from
  15 s to 45 s so a stop does not cut it, or Paseo, off mid-shutdown. The smoke test checks it.
- New settings in `open-design.env`: `WOOW_OD_PASEO` and `OPENDESIGN_PASEO_ORIGIN`. `install.sh` warns
  that they are missing from an existing file; missing means off.

## 4.1.2 — 2026-11-06

- **Fix: Codex answered but wrote no file.** Its own sandbox (bubblewrap) cannot mount `/proc` in a
  rootless container. `OD_CODEX_SANDBOX` now defaults to `danger-full-access`, so the container is
  Codex's sandbox, as it already is for Claude, Pi and OpenCode: uid 1001, read-only root filesystem,
  writes only to the data volume. Set `OD_CODEX_SANDBOX` in `open-design.env` to override.
  `codex` started by hand in `/console/` still uses its own sandbox; pass `--sandbox danger-full-access`.

## 4.1.1 — 2026-11-05

Fixes from a full test in a real Firefox.

- **Security-relevant: reading a project's files no longer needs the password.** `GET` and `HEAD` of
  `/api/projects/<uuid>/raw/` and `/preview/` are open to anyone who can reach the port and knows the
  project's UUID. The UUID is not listed anywhere without signing in. Without this, a design with images
  or a stylesheet asked for a second sign-in in Firefox, because a sandboxed preview has no Basic
  credentials. `WOOW_OD_AUTH=off` is unaffected.
- A design's asset that still arrives without credentials now fails quietly instead of opening a dialog,
  and a thumbnail's relative asset loads the file instead of the app's HTML.
- The web terminal accepts 4 tabs. A second tab used to show only "Press to Reconnect".
- The MCP admin page no longer talks about Home Assistant, and no longer says tools are read-only by
  default. All 15 are on by default.
- `install.sh --rebuild` now restarts the containers when the image changed.
- `tests/nginx-auth.sh` checks what nginx leaves open against the real nginx image, and CI runs it.

## 4.1.0 — 2026-11-05

Phase 2 of aligning with the PaaS service and the Home Assistant add-on.

- **Built-in MCP server** in its own container (`open-design-mcp`, uid 10001): the same runtime and 15
  tools as the PaaS service and the add-on (`mcp-runtime/`). Clients use `/mcp` with a Bearer token, or
  `/private_<token>/mcp`; both go through nginx on the published port, and port 8081 is not on the host.
  The token and tool switches are at `/mcp-admin/`, behind the Basic auth sign-in.
  **All 15 tools are on by default, including `create_project`, `delete_project` and `send_message`.**
- **Web terminal** at `/console/` in its own container (`open-design-terminal`), behind the Basic auth
  sign-in. It is a shell as the agents' uid, so the sign-in password now also gives a shell.
- `backup.sh` and `restore.sh` include the MCP state. A backup therefore contains the MCP token.
- **Fix: a failed upgrade could not roll back past added units.** The rollback removed their files but left
  them running, and a sidecar in the daemon's network namespace keeps the daemon's container from being
  replaced. It now stops such units first, and its health check no longer uses the new version's smoke test.

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
