# Woow Podman Open Design

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![OD](https://img.shields.io/badge/upstream-ghcr.io%2Fnexu--io%2Fod-blue)](https://github.com/nexu-io/od)
[![pi-agent](https://img.shields.io/badge/pi--coding--agent-0.83.0-blue)](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

上游 Open Design（`ghcr.io/nexu-io/od`）加上 headless 媒體工具鏈（Chromium + Playwright + CJK 字型）與 Pi coding agent（0.83.0），封裝成在 **rootless Podman** 上運行，前面掛 **nginx sidecar** 做 gzip、cache、WebSocket/SSE passthrough。

跟 [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) 是同族——兩套共用 `pi-agent-data` volume，Pi web UI 開的 session 在這裡看得到，反之亦然。

---

## 提供什麼

| | |
|---|---|
| **UI** | `http://<host>:7456` — 由 nginx sidecar 服務（`/_next/static/`、`/static/`、plugin assets 有 `immutable` cache）|
| **Daemon** | 上游 `ghcr.io/nexu-io/od` 在 `127.0.0.1:7457`（loopback 限定；只有 nginx 對外）|
| **Pi runtime** | 容器內 PATH 上有 `@earendil-works/pi-coding-agent@0.83.0`，`pi-od` wrapper 把 HOME 指到 `/data/pi-agent/home` 跟 pi-web 部署共用狀態 |
| **媒體工具鏈** | Alpine 的 Chromium + Playwright + Noto CJK/emoji 字型，讓 OD 的 `/api/export/*` 真的能出 PDF/PPTX/Image，不再回 501 |
| **Rootless** | `userns_mode: keep-id:uid=1001,gid=1001`——容器內的 `open-design` user 對應到你主機的 uid，bind-mount 的 `~/.claude`、`~/.claude.json`、`~/.local/bin` 寫回主機都是你的權限 |
| **Read-only rootfs** | 基底映像的 `/` 不可寫；可寫路徑只有 tmpfs `/tmp` + `/home/open-design` + 兩個 named volume |

---

## 先決條件

- **Podman ≥ 4.4** + `podman-compose` 1.0.6+
- Rootless 帳號、建議 `loginctl enable-linger $(whoami)` 讓 stack 登出後仍活著
- **同機 `pi-agent-data` volume** 才吃得到 Pi runtime 整合（先裝 [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)，或 `install.sh` 會建一個空的）
- 主機的 glibc 要在 `/lib/x86_64-linux-gnu` 和 `/lib64`——映像 bind-mount 這兩個，讓 Alpine musl + gcompat 蓋不到的 binary 也能跑。arm64 的話改成 `/lib/aarch64-linux-gnu`。

---

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_opendesign.git
cd Woow_podman_opendesign

# 複製 env 樣板，正式啟動前先編輯
cp .env.example .env

# 把 OPEN_DESIGN_ALLOWED_ORIGINS 填成「所有會從瀏覽器開 UI 的 hostname」
# 沒列到的 origin 會被 OD 的 guard 回 403、UI 渲染出來但所有 data route 都爛。
# 詳見下方「CORS 大坑」章節。
$EDITOR .env

# 建 image + 起 stack
./scripts/install.sh
```

第一次啟動會拉上游 OD image（`ghcr.io/nexu-io/od:latest`，約 1.2 GB），再疊 ~1 GB 給 Chromium + Playwright + 字型。最終本地映像約 **2.3 GB**。之後啟動吃快取。

### 移除

```bash
./scripts/uninstall.sh           # 停 stack、保留 open_design_data
./scripts/uninstall.sh --purge   # 連 open_design_data 也刪
```

`pi-agent-data` 是 **external**——這個 script 不會碰，因為它跟 pi-web 部署共用。

---

## 大家第一次都會踩的 CORS 坑

OD 的 origin-validation middleware 會拒絕任何**不在 `OD_ALLOWED_ORIGINS` 白名單裡**的瀏覽器 origin。失敗模式很好認：UI HTML 載進來、然後每個 data route 都回

```
HTTP 403 {"error":"Cross-origin requests are not allowed"}
```

在 compose 裡這變數叫 `OPEN_DESIGN_ALLOWED_ORIGINS`（會自動 map 到容器內的 `OD_ALLOWED_ORIGINS`）。**把每一組 scheme+host+port 都填齊**——LAN IP、tailnet IP、tailnet MagicDNS 名、Cloudflare Tunnel 域名、開發用 `127.0.0.1`。改完要 recreate container：

```bash
podman rm -f open-design && podman-compose -f docker-compose.podman.yml up -d
```

`.env` reload 對 running container **沒效**。

---

## Nginx sidecar 為什麼在這

四件事，按重要性排：

1. **Gzip** — OD 的 Express cold load 送 ~9 MB 未壓縮 JS/CSS，gzip 壓到 ~2 MB。單一最大 UX 提升。
2. **`immutable` cache** on 有 hash 的路徑（`/_next/static/`、`/static/`、`/agent-icons/`、`/api/plugins/*/asset/`）。OD 本身給這些檔 `Cache-Control: max-age=0` 逼 browser 每次 revalidate 20+ 個 chunk，改成 `max-age=31536000, immutable` 之後每次載頁只要重打第一次以外的 0 個 request。
3. **`Host: $http_host` 保留** — OD 的 origin 檢查會拒絕被剝 port 的 Host。用 nginx 預設常見範例的 `$host` 會把 port 丟掉、daemon 就 403 所有 guarded route。見 [nginx.conf](nginx.conf) 第 78 行。
4. **WebSocket + SSE passthrough** — Next.js HMR、chat streams、MCP over SSE、`/api/agents?stream=1`、`/api/memory/events`、`/api/integrations/vela/*`。整個 `/api/` 樹 buffering 關掉；一個個列 SSE endpoint 是自己給自己挖坑。

Daemon 只 bind `127.0.0.1:7457`。直接發佈 daemon 會讓 sidecar 這四件事都失效；架構設計就是 browser 只跟 `:7456` 說話。

---

## Pi runtime 整合

映像內建 `@earendil-works/pi-coding-agent@0.83.0` 在 `/usr/local/bin/pi`。另有一個 shell wrapper `/usr/local/bin/pi-od`：

```sh
export HOME="${PI_AGENT_DATA_DIR}/home"
export PI_CODING_AGENT_DIR="${PI_AGENT_DATA_DIR}"
exec /usr/local/bin/pi "$@"
```

OD daemon 透過 `PI_BIN=/usr/local/bin/pi-od` 呼叫它。**只在 Pi subprocess 範圍內覆蓋 HOME**、不動 OD daemon 本身的 HOME 是刻意的：OD 其他 runtime adapter（Claude Code、Codex…）還保持 `HOME=/home/open-design` 與 bind-mount 的 `~/.claude` / `~/.claude.json`。Pi 落在共用 volume、其他不動。

Session state 存在 external volume `pi-agent-data`，跟 [`Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) 共用。Pi web UI 開的 session 這邊看得到、反之亦然。

Pi 回 `{"kind":"agent_spawn_failed","detail":"No API key found…"}` 的話，`.env` 填一個 `DEEPSEEK_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`（**要 recreate container**），或 `podman exec -it open-design pi-od /login` 走 Claude Pro / Max OAuth 訂閱流程——token 存在 `pi-agent-data`。

---

## 目錄結構

```
Dockerfile.full              上游 OD + libc6-compat + Chromium + Playwright + Pi CLI
docker-compose.podman.yml    2 個 service（daemon + nginx）、host network mode
nginx.conf                   gzip、immutable cache、Host+Origin 保留、SSE passthrough
pi-od                        HOME/PI_CODING_AGENT_DIR wrapper 把狀態指到共用 volume
.env.example                 環境樣板，複製成 .env 再編輯
scripts/install.sh           build image、up -d、等 healthy
scripts/uninstall.sh         down；--purge 會刪 open_design_data
docs/plans/                  塑造這個部署的設計筆記
```

---

## 安全性現況

- Daemon container **read-only rootfs**。可寫路徑只有 `/tmp` (tmpfs)、`/home/open-design` (tmpfs)、兩個 named volume。
- **`no-new-privileges`** + rootless — daemon 以無特權主機 user 執行。
- **`OD_API_TOKEN`** 是共用密鑰；只有 `OPEN_DESIGN_DISABLE_API_AUTH` 沒設或設 0 時才強制。部署到 UI 前面已經有一層有身分驗證的 reverse proxy（nginx Basic auth、CF Access…）的話，把 auth 關掉是合理的，也是參考 `.197` 部署的做法。**如果 stack 直接對 internet 或不信任 LAN 開放，不要關 auth**。
- **`/api/models-config`** 過了 origin guard 加 auth（若有）之後就會把已設定的 provider key 明文回傳。信任邊界就是 `:7456` 前面那層；daemon 本身不做遮罩。

---

## 文件

- [設計筆記](docs/plans/) — 塑造本 stack 每次變更的實作 plan（Pi runtime 遷移、OpenCode 退場等）
- [上游 Open Design](https://github.com/nexu-io/od)
- [同族: Woow_podman_pi_agent_package](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
- [English README](README.md)

## 授權

MIT
