# Woow OpenDesign：rootless Podman（Quadlet + systemd）部署

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.9%20rootless-892CA0)](https://podman.io)
[![OD](https://img.shields.io/badge/upstream-ghcr.io%2Fnexu--io%2Fod%200.21.1-blue)](https://github.com/nexu-io/od)
[![OpenCode](https://img.shields.io/badge/opencode--ai-1.18.29-blue)](https://www.npmjs.com/package/opencode-ai)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

上游 Open Design（`ghcr.io/nexu-io/od`，以 digest 釘在 0.21.1）加上 headless 匯出管線（Chromium +
Playwright + CJK 字型）與內建的 **OpenCode** agent，以 rootless Podman
[Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html) 單元在 `systemd --user`
下執行；前面有一個 **nginx** 負責 gzip、快取、SSE/WebSocket 轉發、PDF 匯出橋接，以及登入對話框。

**獨立運作。** 不與其他部署共用 volume、憑證或 agent 執行檔，除了自己的設定檔外不掛載你家目錄的任何東西。

> **Docker 或 podman-compose 使用者：** 3.0.0 已移除 compose 檔。最後一版保留在 tag
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_opendesign/tree/compose-final)，該 tag 不再
> 維護，且會在所有網路介面上、無任何憑證檢查地提供 UI。上游本身也有 `deploy/docker-compose.yml`。

## 安裝內容

| | |
|---|---|
| **UI** | 預設 `http://127.0.0.1:7456`，由 nginx 單元提供。**預設啟用 Basic 認證**：使用者 `open-design`，密碼為產生的 API token。 |
| **Daemon** | `open-design`（單元 `open-design.service`），本機建置的映像 `localhost/woow-open-design:<VERSION>`，在自己的網路 namespace 內監聽 `127.0.0.1:7457`。 |
| **nginx 前端** | `open-design-nginx`（單元 `open-design-nginx.service`），釘版 `nginx:1.30.4-alpine`，加入 daemon 的 namespace（`Network=container:open-design`），隨 daemon 一起啟停。 |
| **資料** | 單一 volume `open-design_open_design_data`（`/app/.od`）：專案、`app.sqlite` 以及位於 `$HOME=/app/.od/home` 的 OpenCode 憑證。 |
| **資源限制** | `PidsLimit` 512 / 128 與記憶體、CPU 限制現在真的生效。podman-compose 1.0.6 會默默忽略 `pids_limit`，所以 compose 部署其實跑在 2048 的預設值。 |
| **Rootless** | `UserNS=keep-id:uid=1001,gid=1001`、唯讀根檔案系統、`NoNewPrivileges`，`/tmp` 與 `/home/open-design` 為 tmpfs。 |

> **憑證檢查在哪裡。** 上游的 `OD_API_TOKEN` 只對**非 loopback** 來源強制
> （`apps/daemon/src/api-token-auth.ts`；桌面 UI 流程依賴此豁免）。nginx 永遠是從 loopback 連到 daemon，
> 所以單靠 token 從來就保護不了 `:7456` — 包含會回傳供應商金鑰的 `/api/models-config`。因此現在由 nginx
> 要求憑證（密碼就是同一個 token），而 `/api/health` 是唯一的豁免路徑。

## 需求

- 有 systemd 與 cgroup v2 的 Linux。已在 Ubuntu 24.04 測試。
- Podman 4.9 以上、rootless（`keep-id:uid=…` 需 4.3+），另需 `openssl` 與 `curl`。
- 擁有容器的使用者需以一般登入工作階段操作，並啟用 linger（install.sh 會處理）。
- 建置約需 6 GB 磁碟（上游基底約 1.2 GB、Chromium/字型/npm 層約 1 GB，加上 build cache），daemon 約
  2 GB 記憶體；PDF 匯出時會接近上限。
- 一個空閒埠，預設 7456。

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_opendesign.git
cd Woow_podman_opendesign
scripts/install.sh                           # 第一次：建立設定檔後停下讓你檢查
nano ~/.config/open-design/open-design.env   # 至少要填 OD_ALLOWED_ORIGINS
scripts/install.sh                           # 建置、產生單元、驗證、啟動、smoke
```

第一次會用 `Dockerfile.full` 建置 `localhost/woow-open-design:$(cat VERSION)`，在小型主機上約需 10-20
分鐘；`WOOW_OD_BUILD_CPUS`（以及 `nice`）可避免建置搶走其他服務的資源。接著在
`http://127.0.0.1:7456/` 登入：

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token   # 私人終端機
```

| 選項 | 作用 |
|---|---|
| `--accept-defaults` | 第一次執行時直接採用範例設定繼續。 |
| `--set KEY=VALUE` | 先寫入設定（可重複），例如 `--set WOOW_OD_PORT=27456`。 |
| `--no-build` / `--rebuild` | 略過建置（該 tag 必須已存在）／強制重新建置目前的 tag。 |
| `--rotate-token` | 產生新的 API token，重新推導瀏覽器密碼並重啟。 |
| `--dry-run` | 只產生與驗證、列出會變更的內容，不動任何東西。 |

重複執行 `install.sh` 是安全的：沒有變更時不會重啟任何東西。

## 設定

編輯 `~/.config/open-design/open-design.env`，再執行一次 `scripts/install.sh`。env 檔不是單元，因此安裝程式
會記錄它的雜湊，檔案有變時才重啟 daemon。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `OD_ALLOWED_ORIGINS` | `http://127.0.0.1:7456,http://localhost:7456` | 所有會用來開啟 UI 的 `scheme://host:port`。缺少的來源會在資料路由回 `403 {"error":"Cross-origin requests are not allowed"}`，但 UI 仍會顯示。`install.sh` 會檢查格式，且缺少本機來源時拒絕繼續。 |
| `WOOW_OD_BIND` | `127.0.0.1` | UI 埠發布的位址；`all` 同時涵蓋 IPv4 與 IPv6。 |
| `WOOW_OD_PORT` | `7456` | UI 的主機埠。 |
| `WOOW_OD_AUTH` | `basic` | `off` 會關閉 nginx 的憑證檢查。除非 `WOOW_OD_BIND` 是 loopback，否則 `install.sh` 會拒絕：`/api/models-config` 會回傳你的供應商金鑰。只適用於前面已有認證代理或 SSH 通道的情境。 |
| `WOOW_OD_MEMORY` / `WOOW_OD_CPUS` | `2g` / `2` | daemon 容器的限制。 |
| `WOOW_OD_BUILD_CPUS` | 空 | 映像建置的 `--cpuset-cpus`，例如 `0-2`。 |
| `NODE_OPTIONS` | `--max-old-space-size=1536` | Node heap，需低於 `WOOW_OD_MEMORY`。 |
| `DEEPSEEK_API_KEY`、`ANTHROPIC_API_KEY`、`OPENAI_API_KEY` | 空 | 選用的 BYOK 金鑰，也可在 Models 頁面設定。 |

### 憑證

| Podman secret | 內容 |
|---|---|
| `open-design-api-token` | API token，同時也是瀏覽器使用者 `open-design` 的密碼；安裝時產生。 |
| `open-design-htpasswd` | nginx 檢查用的 apr1 雜湊，由該 token 推導（salt 為決定性值，token 沒變就不會變）。 |

以 `scripts/install.sh --rotate-token` 同時輪替兩者。

## 驗證

```bash
tests/smoke.sh            # 單元、健康、埠、資源限制、rootless／唯讀、認證、來源檢查、
                          # 匯出橋接、gzip 與快取、namespace、密碼外洩檢查
tests/smoke.sh --quick    # 只檢查單元、健康、埠與 /api/health
```

從其他機器連線請用 `ssh -L 7456:127.0.0.1:7456 <host>`，再開啟 `http://127.0.0.1:7456/`。

## 升級

```bash
git pull
scripts/upgrade.sh
```

流程：備份 → 單元快照 → `install.sh`（建置新的 `VERSION` tag）→ smoke。失敗時放回原本的單元，也就回到
先前的映像 tag（每個 VERSION 都有自己的 tag，所以舊映像仍在）。daemon 會把 `app.sqlite` 向前遷移，
若要跨資料格式回復，還需要用 `scripts/restore.sh` 還原升級前的封存檔。

## 備份與還原

```bash
scripts/backup.sh                    # 停止 daemon、匯出資料 volume、計算校驗碼
scripts/backup.sh --hot              # 不停止（app.sqlite 可能寫到一半）
scripts/restore.sh --archive ~/.local/share/woow-backups/open-design/backup-<ts>/open-design_open_design_data-<ts>.tar --confirm-restore open-design
```

備份存於 `~/.local/share/woow-backups/open-design/`（檔案 0600、目錄 0700，附 `SHA256SUMS`）。還原會停止
整組服務、保留一份還原前副本、取代 volume，並重新做 smoke 檢查。

## 解除安裝

```bash
scripts/uninstall.sh                          # 移除單元；保留 volume、網路、secrets、設定
scripts/uninstall.sh --purge                  # 另外刪除它們（需輸入 "open-design" 確認），並先做最後備份
scripts/uninstall.sh --purge --purge-images   # 再移除本機建置的映像
```

`--purge` 是唯一會刪除資料的指令，而且會同時刪掉你的專案**與** OpenCode 憑證（兩者在同一個 volume）。

## 從 podman-compose 部署遷移

volume 名稱不變（`open-design_open_design_data`），所以專案、`app.sqlite` 與 OpenCode 憑證原地沿用。

1. **先決定曝光方式。** compose 版使用 host 網路，nginx 在所有介面上、無憑證地提供服務；現在預設是
   `127.0.0.1` 加 Basic 認證。若有區網或 tailnet 使用者，請設 `WOOW_OD_BIND=all`（同時會發布 IPv6，
   `[fd7a:…]` 這類 tailnet 來源需要），並保持認證開啟；或維持 loopback，改用 tailscale serve、NPM 或
   tunnel 前置。
2. **匯入既有 token**，讓 API 客戶端繼續可用，並複製來源清單：
   ```bash
   grep '^OD_API_TOKEN=' .env | cut -d= -f2- | tr -d '\n' | podman secret create open-design-api-token -
   ```
   把 `OPEN_DESIGN_ALLOWED_ORIGINS` 的值複製到 `OD_ALLOWED_ORIGINS`（值相同，只是去掉 compose 專用的
   `OPEN_DESIGN_` 前綴），BYOK 金鑰也搬到新的 env 檔。
3. **停止 compose 並把容器改名**，避免被 Quadlet 取代：`podman stop open-design open-design-nginx`，
   接著 `podman rename open-design open-design-legacy-$(date +%Y%m%d)`，nginx 容器亦同。它們是
   `unless-stopped`，所以 `podman-restart.service` 不會再啟動它們。
4. **安裝並驗證：** `scripts/install.sh`，接著 `tests/smoke.sh`。
5. **需要回復時**：停止 Quadlet 單元，把舊容器改回原名。請先執行 `scripts/backup.sh`：新版 daemon 可能
   已經把 `app.sqlite` 向前遷移。

## 檔案

```
Dockerfile.full runtime/ rootfs/   映像建置輸入（未變動）
VERSION                            本機映像 tag；單元與 CI 都以它為準
quadlet/                           帶 @@VAR@@ 標記的 Quadlet 單元；quadlet/render-vars 為白名單
config/nginx.conf                  前端：gzip、快取、SSE、認證 include、匯出橋接
config/nginx-auth.{basic,off}.conf 安裝為 ~/.config/open-design/nginx-auth.conf
config/od-export-bridge.js         注入 <head>，讓 UI 的 PDF 按鈕改打 headless 路由
config/open-design.env.example     ~/.config/open-design/open-design.env 的範本
scripts/                           install、upgrade、uninstall、backup、restore
scripts/lib/                       內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh                    產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/smoke.sh                     主機上的安裝後檢查
tests/lint-repo.sh                 憑證掃描、VERSION 一致性、認證邊界不變條件（CI）
docs/plans/                        設計歷史（host 網路的 compose 佈局已被取代）
```

## 疑難排解

| 症狀 | 檢查 |
|---|---|
| 瀏覽器要求密碼但你沒有 | `podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token`，使用者 `open-design`；或用 `scripts/install.sh --rotate-token` 輪替。 |
| UI 顯示得出來，但每個操作都 403 | 你開啟的來源不在 `OD_ALLOWED_ORIGINS`，補上後執行 `scripts/install.sh`。 |
| PDF 按鈕回 501 | 匯出橋接沒被注入：檢查 `config/nginx.conf` 與 `podman logs open-design-nginx`。 |
| nginx 一直重啟 | 它活在 daemon 的 namespace：`journalctl --user -u open-design-nginx.service -n 50`，並確認 `open-design.service` 是啟動的。 |
| 建置太慢或拖垮主機 | 設 `WOOW_OD_BUILD_CPUS=0-2`，或建置一次後把映像複製到其他主機。 |
| 登出或重開機後單元消失 | `loginctl show-user $USER -p Linger` 必須是 `yes`。 |
