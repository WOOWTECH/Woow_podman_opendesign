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

`scripts/migrate-legacy.sh` 會把執行中的 podman-compose／docker-compose `open-design` 專案（容器
`open-design` 與 `open-design-nginx`，兩者都在 **host** 網路上，volume
`open-design_open_design_data`，以及從建置目錄 bind-mount 進去的 `nginx.conf` 與
`od-export-bridge.js`）搬到本倉庫的 Quadlet 單元。

volume 名稱不變（`VolumeName=open-design_open_design_data`），所以專案、`app.sqlite` 與 OpenCode 憑證
是**原地沿用**，不做任何複製。舊容器會保留給 `--rollback`。

```bash
scripts/migrate-legacy.sh --dry-run                  # 只做檢查與產生單元，不改任何東西
scripts/migrate-legacy.sh --prepare-only             # 再加上 secrets 與「映像建置」；不停機
scripts/migrate-legacy.sh                            # 正式切換
scripts/migrate-legacy.sh --status                   # 顯示記錄下來的狀態
scripts/migrate-legacy.sh --rollback                 # 回到舊的 compose 堆疊
```

常用選項：`--legacy-dir DIR` 把舊建置目錄的 compose 檔與 `.env` 封存進備份；`--bind ADDR`／`--port N`／
`--auth basic|off` 可覆寫自動推導出來的曝光方式；`--suffix S` 指定保留容器的名字；`--force-capture` 讓
本來可以改名的主機改走 capture 路徑；`--no-cold-copy` 略過冷 `podman volume export`；
`--allow-version-change` 允許 OpenDesign 次版本不同。

**有兩件事是刻意改變的**，因為那正是本倉庫做 Quadlet 轉換的理由；腳本在切換前與結束時都會說明：

| | compose（host 網路） | Quadlet |
|---|---|---|
| 前端 | 監聽**所有**介面 | 發布在 `127.0.0.1`（`--bind all` 可維持原本的可及範圍） |
| daemon | 在主機上佔用 `127.0.0.1:7457` | 在容器自己的網路命名空間裡；主機上的那個埠消失 |
| 憑證 | **完全沒有** | HTTP Basic，使用者 `open-design`，密碼為 API token |

`--auth off` 只有在前端維持 loopback 時才會被接受：`/api/models-config` 會回傳已設定的供應商金鑰。舊的
`OD_DISABLE_API_AUTH=1` **不會**被沿用——Quadlet 的 daemon 對 loopback 來源免驗（nginx 永遠只是
loopback），其餘一律檢查 token。

**映像在準備階段建置，不在切換期間。** 建置 `localhost/woow-open-design:<VERSION>` 在小型主機上需要
10–20 分鐘；趁舊堆疊還在服務時先建好，才能把停機縮短到一次容器重啟的長度，之後 `install.sh` 會以
`--no-build` 呼叫。

**資料從哪裡讀。** 全部取自**執行中的容器**：在 `woowtechopenclaw` 上，實際部署的目錄
（`~/od-podman-align`）根本不是 git 倉庫，也不是本倉庫描述的那一份。`OD_ALLOWED_ORIGINS`、
`NODE_OPTIONS`、`OD_CODEX_SANDBOX`、BYOK 供應商金鑰與 `OD_API_TOKEN` 取自 daemon 的環境變數；
`WOOW_OD_MEMORY` 與 `WOOW_OD_CPUS` 取自它的 `HostConfig`。**主機連接埠取自 bind-mount 進去的
`nginx.conf` 裡的 `listen` 指令**：使用 host 網路時 podman 完全不會記錄任何連接埠對應，那個檔案是這個
堆疊究竟服務在哪個埠的唯一依據。若來源清單裡沒有 `http://127.0.0.1:<port>` 會自動補上，否則 daemon 會
對每一條資料路由回 403。

**API token 會被沿用**到 `open-design-api-token` secret（只要舊堆疊有一個可用的），讓 API 客戶端繼續
可用；它同時也是瀏覽器登入密碼。可用
`podman secret inspect --showsecret --format '{{.SecretData}}' open-design-api-token` 讀出。

**你的 `nginx.conf` 與 `od-export-bridge.js` 會被本倉庫的版本取代。** 兩個舊檔案都會封存進備份；若內容
不同，會在旁邊寫出 unified diff 並提出警告。在建置目錄不是 git 倉庫的主機上，這是原本內容的唯一紀錄。

**它拒絕而不猜測的情況。** 舊容器不存在或沒在執行；舊容器已由本單元管理；Quadlet 單元已經安裝；volume
名稱與 `open-design-data.volume` 釘住的不同（沿用會安靜地開在空的 `app.sqlite` 上）；`nginx.conf` 讀不到
或其 `listen` 指令彼此不一致；有別的容器佔用同一個主機連接埠；舊堆疊停止後連接埠仍被綁住；OpenDesign
次版本不同；在可路由位址上使用 `--auth off`；以及已經記錄過切換後再跑第二次。

**舊容器如何保留**（STANDARD 7a）。要嘛改名為 `<name>-legacy-<suffix>` 並保持停止，要嘛——當
`podman-restart.service` 已啟用**且**某個舊容器的重啟策略剛好是 `always` 時——先 capture 進備份目錄再
移除。`ql_rollback_strategy` 依主機的真實狀態判斷，絕不看主機名稱。兩個容器目前都是 `unless-stopped`，
所以兩台主機都判定為 `rename`；`--force-capture` 用來演練另一條路徑。兩者都不使用 `--commit`：
`open-design` 以 `--read-only` 執行，根本沒有可寫層可失去，而 `open-design-nginx` 是原廠 nginx 映像。

**備份內容**（`~/.local/share/woow-backups/open-design/migrate-<時間戳>/`，0700）：`inspect.json`、舊的
`nginx.conf` 與 `od-export-bridge.js`（以及與本倉庫版本的 `.diff`）、舊的 compose 檔與 `.env`、資料
volume 的冷 `podman volume export`、`volume-fingerprints`、`precheck.txt` 與 `SHA256SUMS`；走 capture
路徑時另有 `legacy-container/`。

**沿用會被證明，而不是假設。** volume 的 `CreatedAt`，以及它的目錄與 `app.sqlite` 的磁碟 inode，會在切換
前記錄、在 `install.sh` 之後比對。不一致時遷移失敗並自動回復，而不是報告一個健康但坐在空資料庫上的
OpenDesign。

**停機時間**由腳本自行量測（從停止舊堆疊到 `install.sh` 返回），結束時印出，並記錄成 `--status` 裡的
`DOWNTIME_S`。

### 回復

```bash
scripts/migrate-legacy.sh --rollback
```

它會停止並移除 Quadlet 單元（資料 volume 與 secrets 都保留，因為兩邊共用），移除本倉庫單元留下的容器，
把舊容器帶回來——改名回去，或是從 capture 以原本的重啟策略與 host 網路重建——先啟動 daemon 再啟動前端，
然後等待舊連接埠的 `/api/health`。切換失敗時會自動回復，除非指定了 `--no-auto-rollback`。留下來的空
Quadlet 網路無害，可用 `podman network rm open-design` 移除。

### 觀察期結束後

Quadlet 堆疊穩定執行一段時間之後，移除舊容器——**先移除 nginx**，因為 `open-design-nginx` 建立時帶著
`--requires=open-design`，podman 會拒絕移除被別人依賴的容器：

```bash
podman rm open-design-nginx-legacy-<suffix> open-design-legacy-<suffix>
```

接著若沒有其他用途，移除舊建置目錄那個映像標籤。遷移備份請保留到確認無虞為止。

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
scripts/migrate-legacy.sh          沿用執行中的 compose 部署；含 --rollback、--status
scripts/legacy-helpers.sh          migrate-legacy.sh 專用的輔助函式（刻意不放進 common.sh，後者在四個
                                   倉庫之間的設定區塊以下是逐位元組相同的）
scripts/lib/                       內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh                    產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/smoke.sh                     主機上的安裝後檢查
tests/lint-repo.sh                 憑證掃描、VERSION 一致性、認證邊界不變條件（CI）
tests/migrate-model.sh             釘住遷移行為：兩條回復路徑、依賴順序、讀取 host 網路堆疊、沿用證明
                                   （podman 與 systemctl 皆為測試替身）
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
