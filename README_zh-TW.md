# Woow_podman_opendesign — Open-Design（host + podman 混合部署）

[English](README.md)

Ubuntu 主機的 Podman / systemd 部署。這是 **host + podman 混合架構**：

- **`od-runner`**（Playwright/Chromium + Python renderer）以 `systemd --user`
  服務的形式**跑在 Ubuntu 主機上**。
- **`od-console`**（Web GUI）以 **rootless podman container** 跑在 `:4000`。
- **沒有 ttyd。** 進入 container 一律走 host OpenSSH + `podman exec`。

> **找其他平台？**
> K3s / Kubernetes（已改為 Helm chart）→ [Woow_k3s_opendesign](https://github.com/WOOWTECH/Woow_k3s_opendesign)

---

## 為何採用混合架構？

Playwright + Chromium 需要直接存取 GPU 與檔案系統，Python renderer 需要主機
系統函式庫。兩者跑在 host 效能更好、也更單純。Web console 沒有這些需求，反
而受益於 container 生命週期管理，所以留在 podman。

Host 同時也是**唯一**的存取平面：操作者 SSH 進來後，用 `systemctl --user`
管理 host 服務、用 `podman exec` 進 container。因此 `ttyd` 完全移除。

---

## 快速開始（Ubuntu 24.04）

```bash
# 1) SSH 進目標主機
ssh user@your-n100-host

# 2) Clone 這個 repo
git clone https://github.com/WOOWTECH/Woow_podman_opendesign.git
cd Woow_podman_opendesign

# 3) 安裝 host 端（apt + nvm + Playwright + Python venv + systemd --user）
#    此腳本 idempotent，重複執行安全。
./host-install/install.sh

# 4) 填寫真實 config
$EDITOR ~/.config/od/config.json

# 5) 啟動 host runner
systemctl --user start od
systemctl --user status od

# 6) 啟動 podman 端 console
cd podman-stack
cp .env.example .env
$EDITOR .env
podman-compose up -d

# 7) 開啟 console
xdg-open "http://$(hostname -I | awk '{print $1}'):4000"
```

在乾淨的 N100 上約 5 分鐘即可完成。

---

## 目錄結構

```
.
├── host-install/           # Host 端（systemd --user）
│   ├── install.sh
│   ├── od.service
│   └── README.md
├── podman-stack/           # Podman 端（rootless podman-compose）
│   ├── compose.yml
│   ├── Dockerfile.console
│   └── .env.example
├── console/                # Web GUI 原始碼
├── headless-entry.mjs      # OD runner 進入點（Node）— 跑在 host
├── headless-renderer.py    # OD Python renderer — 跑在 host
└── docs/                   # 設計文件
```

## 存取平面

**唯一**入口是 host 的 `ssh.service`。進來之後：

| 用途                    | 指令                                       |
|------------------------|--------------------------------------------|
| Host 服務狀態          | `systemctl --user status od`               |
| Host 服務 log          | `journalctl --user -u od -f`               |
| 重啟 host runner       | `systemctl --user restart od`              |
| Podman stack 狀態      | `cd podman-stack && podman-compose ps`     |
| Container log          | `podman logs -f od-console`                |
| 進入 container         | `podman exec -it od-console sh`            |

無 `ttyd`、無 container 內 SSH daemon、不對外暴露 shell。

## 設定檔

設定檔都在 host 上的 `~/.config/`，container 只 read-only 掛載：

- **OD 自身設定**：`~/.config/od/config.json`（權限 `0600`），`install.sh`
  會建立一份 stub。
- **Opencode / Claude Code 共用認證**（依 host-migration 設計文件與 vk-host、
  openchamber 共用）：`~/.config/opencode/config.json`、
  `~/.local/share/opencode/auth.json`（`0600`）、`~/.claude/`。這些由
  `Woow_ubuntu_version_control` 的 sibling installer 建立。

不在 git repo 中儲存機密。`.env` 已在 `.gitignore`，`.env.example` 是範本。

## 連接埠

| 埠    | 服務        | 位置    |
|-------|-------------|---------|
| 4000  | od-console  | podman  |
| 7001  | od-runner control（預設僅 loopback） | host |

## 疑難排解

```bash
# Host runner 起不來？
journalctl --user -u od -f
systemctl --user status od

# Console container 起不來？
podman logs -f od-console
cd podman-stack && podman-compose config

# Console 連不到 host runner？
podman exec -it od-console sh -c 'wget -qO- http://host.containers.internal:7001/healthz'
```

## 相關 repo

- [`Woow_k3s_opendesign`](https://github.com/WOOWTECH/Woow_k3s_opendesign) — 同一支 daemon 的 Kubernetes / K3s Helm chart（含 `od-console` + `od-mcp`）。
- [`Woow_ubuntu_version_control`](https://github.com/WOOWTECH/Woow_ubuntu_version_control) — 上層 recipe，以 submodule 釘住本 repo。
- [`Woow_podman_hermes`](https://github.com/WOOWTECH/Woow_podman_hermes) — 姊妹 podman 部署（Hermes）。
- [`Woow_podman_vibekanban`](https://github.com/WOOWTECH/Woow_podman_vibekanban) — 姊妹 podman 部署（VK）。

## 本 repo 非目標

- Kubernetes / K3s manifests — 請見 [`Woow_k3s_opendesign`](https://github.com/WOOWTECH/Woow_k3s_opendesign)。
- Cloudflare Tunnel 實際佈建（每台機器由操作者處理）。
- Container 內 shell（`ttyd`、container 內 `sshd`）。
- Windows / macOS 主機。

完整設計理由請見 `Woow_ubuntu_version_control` repo 中的
`docs/plans/2026-07-25-hermes-vk-od-host-migration-design.md`。
