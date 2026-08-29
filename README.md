# Woow Podman Open Design

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![OD](https://img.shields.io/badge/upstream-ghcr.io%2Fnexu--io%2Fod-blue)](https://github.com/nexu-io/od)
[![pi-agent](https://img.shields.io/badge/pi--coding--agent-0.83.0-blue)](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

Upstream Open Design (`ghcr.io/nexu-io/od`) with a headless media pipeline
(Chromium + Playwright + CJK fonts) and the Pi coding agent (0.83.0) baked
in, packaged to run on **rootless Podman** with an **nginx sidecar** in
front for gzip + cache + WebSocket/SSE passthrough.

Sibling to [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) — both stacks share the same
`pi-agent-data` volume so a session started in the Pi web UI is visible
inside Open Design's Pi runtime, and vice versa.

---

## What you get

| | |
|---|---|
| **UI** | `http://<host>:7456` — served by the nginx sidecar (gzip + `immutable` cache on `/_next/static/`, `/static/`, plugin assets) |
| **Daemon** | Upstream `ghcr.io/nexu-io/od` on `127.0.0.1:7457` (loopback only; nginx is the only public entry) |
| **Pi runtime** | `@earendil-works/pi-coding-agent@0.83.0` on `PATH` inside the container, with `pi-od` wrapper scoping HOME to `/data/pi-agent/home` so state is shared with the sibling `Woow_podman_pi_agent_package` deployment |
| **Media pipeline** | Alpine's Chromium + Playwright + Noto CJK/emoji fonts, wired so OD's `/api/export/*` routes actually render PDF/PPTX/Image instead of returning 501 |
| **Rootless** | `userns_mode: keep-id:uid=1001,gid=1001` — the container's `open-design` user maps to your host uid, so bind-mounted `~/.claude`, `~/.claude.json`, `~/.local/bin` land back on the host owned by you |
| **Read-only rootfs** | Base image's `/` is immutable; writable paths are the tmpfs `/tmp` + `/home/open-design`, plus two named volumes |

---

## Prerequisites

- **Podman ≥ 4.4** with `podman-compose` 1.0.6+
- Rootless user account, `loginctl enable-linger $(whoami)` recommended so the stack survives logout
- **Same-host `pi-agent-data` volume** for the Pi runtime integration to be useful (install [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) first, or `install.sh` will create an empty one)
- Host glibc at `/lib/x86_64-linux-gnu` and `/lib64` — the image bind-mounts these so binaries that Alpine's musl + gcompat cannot fully cover still run. On arm64 replace with `/lib/aarch64-linux-gnu`.

---

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_opendesign.git
cd Woow_podman_opendesign

# Copy env template; edit before starting for real
cp .env.example .env

# Fill in OPEN_DESIGN_ALLOWED_ORIGINS with every hostname the UI will be
# opened from. Missing origins fail with HTTP 403 from OD's origin guard
# and the UI renders but every data route breaks — see the CORS note
# below.
$EDITOR .env

# Build the image and bring the stack up
./scripts/install.sh
```

First boot pulls the upstream OD image (`ghcr.io/nexu-io/od:latest`, ~1.2 GB)
and adds a ~1 GB layer for Chromium + Playwright + fonts. The resulting local
image is `~2.3 GB`. Subsequent starts reuse the cached layer.

### Uninstall

```bash
./scripts/uninstall.sh           # stops the stack, keeps open_design_data
./scripts/uninstall.sh --purge   # also deletes open_design_data
```

`pi-agent-data` is **external** — this script never touches it, since it is
shared with the sibling pi-web deployment.

---

## The CORS rule that catches everyone

OD's origin-validation middleware rejects any browser origin that is not
explicitly listed in `OD_ALLOWED_ORIGINS`. The failure mode is
distinctive: the UI HTML loads, and then every data route returns

```
HTTP 403 {"error":"Cross-origin requests are not allowed"}
```

In compose the variable is spelled `OPEN_DESIGN_ALLOWED_ORIGINS` (mapped
to the container's `OD_ALLOWED_ORIGINS` automatically). Fill it with **every
scheme + host + port** combination a user might reach the UI from — LAN IP,
tailnet IP, tailnet MagicDNS name, Cloudflare Tunnel hostname, dev
`127.0.0.1`. After editing, recreate the container:

```bash
podman rm -f open-design && podman-compose -f docker-compose.podman.yml up -d
```

`.env` reload does **not** take effect on a running container.

---

## The nginx sidecar

Nginx is here for four things, in order of importance:

1. **Gzip** — OD's Express serves ~9 MB of JS/CSS uncompressed on cold load;
   gzip drops it to ~2 MB. Single biggest UX win.
2. **`immutable` cache** on hashed paths (`/_next/static/`, `/static/`,
   `/agent-icons/`, `/api/plugins/*/asset/`). OD sets `Cache-Control:
   max-age=0` on these, which forces browsers to re-validate 20+ chunks
   per page load. Overriding with `max-age=31536000, immutable` collapses
   that to zero requests after the first.
3. **`Host: $http_host` preservation** — OD's origin check rejects a Host
   that has been port-stripped. Using nginx's `$host` (the default
   suggested in many recipes) drops the port and the daemon then answers
   403 on every guarded route. See [nginx.conf](nginx.conf) line 78.
4. **WebSocket + SSE passthrough** — Next.js HMR, chat streams, MCP over
   SSE, `/api/agents?stream=1`, `/api/memory/events`, `/api/integrations/vela/*`.
   Buffering is off for the whole `/api/` tree; enumerating individual SSE
   endpoints is a footgun.

The daemon itself binds only to `127.0.0.1:7457`. Publishing it directly
would remove the sidecar's ability to enforce any of the above; the layout
assumes browsers only ever talk to `:7456`.

---

## Pi runtime integration

The image bakes `@earendil-works/pi-coding-agent@0.83.0` at
`/usr/local/bin/pi`. A shell wrapper at `/usr/local/bin/pi-od`:

```sh
export HOME="${PI_AGENT_DATA_DIR}/home"
export PI_CODING_AGENT_DIR="${PI_AGENT_DATA_DIR}"
exec /usr/local/bin/pi "$@"
```

is what the OD daemon spawns via `PI_BIN=/usr/local/bin/pi-od`. Scoping
`HOME` only inside Pi (not on the OD daemon itself) is deliberate: OD's
other runtime adapters (Claude Code, Codex, …) keep their existing
`HOME=/home/open-design` and their bind-mounted `~/.claude` /
`~/.claude.json` state. Pi lands on the shared volume, everything else
does not.

Session state lives in the external `pi-agent-data` volume shared with
[`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package).
A session started in the Pi web UI shows up here and vice versa.

If Pi returns `{"kind":"agent_spawn_failed","detail":"No API key found…"}`,
fill one of `DEEPSEEK_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` in
`.env` (**and recreate the container**), or run
`podman exec -it open-design pi-od /login` for a Claude Pro / Max / OAuth
subscription flow — the token lives on `pi-agent-data`.

---

## Layout

```
Dockerfile.full              upstream OD + libc6-compat + Chromium + Playwright + Pi CLI
docker-compose.podman.yml    the two-service stack (daemon + nginx), host network mode
nginx.conf                   gzip, immutable cache, Host+Origin preservation, SSE passthrough
pi-od                        HOME/PI_CODING_AGENT_DIR wrapper that scopes state to the shared volume
.env.example                 sample environment; copy to .env and edit
scripts/install.sh           build image, up -d, wait for healthy
scripts/uninstall.sh         down; --purge removes open_design_data
docs/plans/                  design notes for the changes that shaped this deployment
```

---

## Security posture

- **Read-only rootfs** on the daemon container. Writable paths are `/tmp`
  (tmpfs), `/home/open-design` (tmpfs), and the two named volumes.
- **`no-new-privileges`** + rootless — the daemon runs as an unprivileged
  host user.
- **`OD_API_TOKEN`** is a shared secret; only enforced when
  `OPEN_DESIGN_DISABLE_API_AUTH` is unset or 0. In deployments where the
  UI is reachable only through an authenticating reverse proxy (nginx
  Basic auth, CF Access, etc.), leaving auth off is a reasonable choice
  and matches the reference `.197` deployment. **Do not disable auth on
  a stack that is directly reachable from the internet or an untrusted
  LAN.**
- **`/api/models-config`** returns configured provider keys unredacted
  once you get past the origin guard + auth (if any). The trust boundary
  is whatever is in front of `:7456`; the daemon itself does not redact.

---

## Documentation

- [Design notes](docs/plans/) — dated implementation plans for the changes
  that shaped this stack (Pi runtime migration, OpenCode retirement, etc.)
- [Upstream Open Design](https://github.com/nexu-io/od)
- [Sibling: Woow_podman_pi_agent_package](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
- [繁體中文說明](README_zh-TW.md)

## License

MIT
