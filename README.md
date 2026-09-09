# Woow Podman Open Design

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![OD](https://img.shields.io/badge/upstream-ghcr.io%2Fnexu--io%2Fod-blue)](https://github.com/nexu-io/od)
[![OpenCode](https://img.shields.io/badge/opencode--ai-1.18.29-blue)](https://www.npmjs.com/package/opencode-ai)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

Upstream Open Design (`ghcr.io/nexu-io/od`, digest-pinned at 0.21.1) with a
headless export pipeline (Chromium + Playwright + CJK fonts) and the
**OpenCode** coding agent baked in, packaged to run on **rootless Podman**
with an **nginx sidecar** in front for gzip + cache + WebSocket/SSE
passthrough.

**Standalone.** It shares no volume, no credentials and no agent binary with
any other deployment, and mounts nothing from the host filesystem. This is the
same shape as the Home Assistant add-on and the k3s chart, all three pinned to
the same upstream digest.

---

## What you get

| | |
|---|---|
| **UI** | `http://<host>:7456` — served by the nginx sidecar (gzip + `immutable` cache on `/_next/static/`, `/static/`, plugin assets) |
| **Daemon** | `ghcr.io/nexu-io/od:0.21.1` on `127.0.0.1:7457` (loopback only; nginx is the only public entry). Started through `headless-entry.mjs`, which injects the Playwright slide renderer the stock entrypoint has no way to supply |
| **Coding agent** | `opencode-ai@1.18.29` baked into the image at `/opt/woow-opendesign/opencode`, on `PATH`. Its BYOK credentials live in `$HOME` = `/app/.od/home`, inside the data volume, so they survive a restart |
| **Export pipeline** | Alpine's Chromium + `playwright-core` 1.55.0 + Noto CJK/emoji fonts. `/api/version` reports `capabilities.slideRenderer: true` and the PPTX / PDF / PNG / JPEG routes return real bytes instead of 501 |
| **Rootless** | `userns_mode: keep-id:uid=1001,gid=1001` — the container's `open-design` user maps to your host uid, so the named volume is writable with no chown in the entrypoint. Nothing is bind-mounted from your home directory |
| **Read-only rootfs** | Base image's `/` is immutable; writable paths are the tmpfs `/tmp` + `/home/open-design`, plus the single `open_design_data` volume |

---

## Prerequisites

- **Podman ≥ 4.4** with `podman-compose` 1.0.6+
- Rootless user account, `loginctl enable-linger $(whoami)` recommended so the stack survives logout
- Roughly 2 GB of RAM for the container. Chromium does not start inside the
  old 384 MB ceiling, which is why `OPEN_DESIGN_MEM_LIMIT` now defaults to `2g`.

No sibling deployment, host glibc mount or host agent CLI is required any more.

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

`--purge` deletes the projects **and** the OpenCode credentials in `$HOME`,
both of which live in `open_design_data`. There is no second volume any more.

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

## Coding agent

`opencode-ai@1.18.29` is installed into the image at
`/opt/woow-opendesign/opencode` and put on `PATH`. Nothing is spawned from the
host and no wrapper script scopes its `HOME`: the whole daemon runs with
`HOME=/app/.od/home`, inside the data volume, so OpenCode's BYOK credentials
and session state survive `podman restart`.

That last part is the reason `HOME` moved. It used to be `/home/open-design`,
which this stack mounts as a **tmpfs** — every restart silently signed the user
out of their own agent.

Check it is live:

```bash
curl -s http://127.0.0.1:7456/api/agents \
  | python3 -c 'import json,sys; [print(a["id"], a["available"]) for a in json.load(sys.stdin)["agents"] if a["available"]]'
# opencode True
# byok-opencode True
```

If a run fails with `No API key found`, set one of `DEEPSEEK_API_KEY` /
`OPENAI_API_KEY` / `ANTHROPIC_API_KEY` in `.env` and recreate the container, or
add the key from the UI's Models page — it is written to `$HOME` and persists.

---

## Layout

```
Dockerfile.full              pinned OD 0.21.1 + Chromium + Playwright + OpenCode
docker-compose.podman.yml    the two-service stack (daemon + nginx), host network mode
nginx.conf                   gzip, immutable cache, Host+Origin preservation, SSE passthrough
runtime/                     lockfiles pinning playwright-core and opencode-ai
rootfs/                      headless-entry.mjs + headless-renderer.mjs + the launcher
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
  that shaped this stack
- [Upstream Open Design](https://github.com/nexu-io/od)
- [Sibling: Woow_podman_pi_agent_package](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
- [繁體中文說明](README_zh-TW.md)

## License

MIT
