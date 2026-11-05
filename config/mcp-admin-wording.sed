# The MCP admin page's words on this stack, applied to the vendored sources by Dockerfile.full.
# The build fails if a Home Assistant term is left, so a re-synced copy cannot bring one back unseen.
s/請由 Home Assistant 重新開啟。/請重新開啟此頁。/
s/請從 Home Assistant 開啟，並允許/請允許/
s/after HA authorization/after authorization/
s/請從 Home Assistant 重新開啟。/請重新開啟此頁。/
s/請由 Home Assistant 管理員重新開啟；/請重新開啟此頁；/
s/此頁只接受 Home Assistant 的伺服器端管理員授權，/此頁只接受 OpenDesign 的登入授權，/
s/預設唯讀，逐項確認寫入授權。/所有工具預設開啟，可逐項關閉。/
s/不由 HA Add-on options 覆寫。/不由外部設定覆寫。/
s/不是 Ingress 網址/不是此管理頁的網址/
s/Add-on 權杖/MCP 權杖/
s/每個 Add-on 使用一把獨立 Bearer 權杖。權杖不是 HA 管理員密碼/此服務使用一把獨立 Bearer 權杖。權杖不是 OpenDesign 登入密碼/
s/本 Add-on 的權限/本服務的權限/
s/chip('HA 管理介面')/chip('管理介面')/
s/HA 管理員授權/OpenDesign 登入授權/
