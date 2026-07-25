# Woow Open-Design — `podman` branch

> **You are on the `podman` branch.** This branch represents a **hybrid
> host + podman deployment**:
>
> - **`od-runner`** (Playwright/Chromium + Python renderer) runs on the
>   Ubuntu host as a `systemd --user` service.
> - **`od-console`** (the web GUI) runs in a **rootless podman container**
>   on port `:4000`.
> - **No ttyd.** Container access is via host OpenSSH + `podman exec`.
>
> Looking for the Kubernetes / K3S flavor? See the [`main`](../../tree/main)
> or [`k3s`](../../tree/k3s) branches.

---

## Why hybrid?

Playwright + Chromium want direct GPU and filesystem access, and the Python
renderer wants host system libraries. Both perform noticeably better and
simpler when they run on the host. The web console, on the other hand, is
stateless and benefits from clean container lifecycle management — so it
stays in podman.

The host is also the sole access plane: the operator SSHs into the box and
uses `systemctl --user` for host services and `podman exec` for the
console container. This lets us remove the `ttyd` container that the
`main`/`k3s` branches shipped.

---

## Quick start (Ubuntu 24.04)

```bash
# 1) SSH into the target host
ssh user@your-n100-host

# 2) Clone this branch
git clone -b podman \
  https://github.com/WOOWTECH/Woow_opendesign_docker_compose_all.git
cd Woow_opendesign_docker_compose_all

# 3) Install the host-side runner (apt + nvm + Playwright + Python venv +
#    systemd --user unit).  Idempotent; safe to re-run.
./host-install/install.sh

# 4) Fill in real config
$EDITOR ~/.config/od/config.json

# 5) Start the host runner
systemctl --user start od
systemctl --user status od

# 6) Bring up the podman-side console
cd podman-stack
cp .env.example .env
$EDITOR .env
podman-compose up -d

# 7) Open the console
xdg-open "http://$(hostname -I | awk '{print $1}'):4000"
```

That's it. Total install time on a fresh N100 is ~5 minutes.

---

## Layout

```
.
├── host-install/           # Host-side (systemd --user)
│   ├── install.sh              # apt + nvm + Node 22 + Playwright + venv
│   ├── od.service              # systemd --user unit for od-runner
│   └── README.md
├── podman-stack/           # Podman-side (rootless podman-compose)
│   ├── compose.yml             # od-console service, port :4000
│   ├── Dockerfile.console      # image for od-console
│   └── .env.example
├── console/                # Web GUI source (built into od-console image)
├── headless-entry.mjs      # OD runner entrypoint (Node) — runs on host
├── headless-renderer.py    # OD Python renderer — runs on host
└── docs/                   # design docs
```

## Access plane

There is exactly **one** way in: the host `ssh.service`. Once inside:

| Task                             | Command                                    |
|----------------------------------|--------------------------------------------|
| Host service status              | `systemctl --user status od`               |
| Host service logs                | `journalctl --user -u od -f`               |
| Restart host runner              | `systemctl --user restart od`              |
| Podman stack status              | `cd podman-stack && podman-compose ps`     |
| Container logs                   | `podman logs -f od-console`                |
| Shell into container             | `podman exec -it od-console sh`            |
| Stop everything                  | `systemctl --user stop od` + `podman-compose down` |

No `ttyd`, no in-container SSH daemon, no exposed shells.

## Config

All config lives on the host under `~/.config/` — the containers only
consume it read-only:

- **OD's own config**: `~/.config/od/config.json` (mode `0600`). Created
  as a stub by `install.sh`. Bind-mounted read-only into `od-console` at
  `/config/od`.
- **Opencode / Claude Code auth** (shared with vk-host + openchamber, per
  the host-migration design doc): `~/.config/opencode/config.json`,
  `~/.local/share/opencode/auth.json` (mode `0600`), `~/.claude/`.
  These are populated by the sibling installers in the
  `Woow_ubuntu_version_control` repo.

No secrets live in this git repo. `.env` is git-ignored; `.env.example`
is the template.

## Ports

| Port  | Service     | Where       |
|-------|-------------|-------------|
| 4000  | od-console  | podman      |
| 7001  | od-runner control (loopback only, by default) | host |

## Troubleshooting

```bash
# Host runner not starting?
journalctl --user -u od -f
systemctl --user status od

# Console container not starting?
podman logs -f od-console
cd podman-stack && podman-compose config    # validate compose file

# Console can't reach host runner?
# From the container:
podman exec -it od-console sh -c 'wget -qO- http://host.containers.internal:7001/healthz'
```

## Related repos

- [`Woow_ubuntu_version_control`](https://github.com/WOOWTECH/Woow_ubuntu_version_control) — the umbrella recipe that pins this branch as a submodule.
- [`Woow_hermes_agent_docker_compose_all`](https://github.com/WOOWTECH/Woow_hermes_agent_docker_compose_all) — sibling `podman` branch (Hermes).
- [`Woow_vibekanban_docker_compose_all`](https://github.com/WOOWTECH/Woow_vibekanban_docker_compose_all) — sibling `podman-ubuntu` branch (VK).

## Non-goals of this branch

- Kubernetes / K3S manifests (they live on `main`).
- Cloudflare Tunnel setup (per-machine operator task).
- Container-side shells (`ttyd`, in-container `sshd`).
- Windows / macOS host support.

See `docs/plans/2026-07-25-hermes-vk-od-host-migration-design.md` in the
`Woow_ubuntu_version_control` repo for the full design rationale.
