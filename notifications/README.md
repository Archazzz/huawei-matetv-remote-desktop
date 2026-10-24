# 通知中转原型

这是独立的 TLS 消息中转及手工样例工具，中转本体不采集应用内容。Codex 原生完成事件由独立的 `codex_hook.py` 接入，参见 [配置说明](../docs/codex-notification-hook.md)。电视端已有前台接收、收件箱和点击连接。服务新增可选 [华为后台推送适配器](background-push.md)，尚待自有项目权益、密钥和电视后台实测，不能当作后台已可用。它不修改 RustDesk 转发，也不会在导入时启动服务。普通微信采集由独立 Mac 助手负责。

## 配置与操作

将 `config.example.json` 复制到被忽略的 `local/` 目录。填写 TLS 证书/私钥、独立随机设备写入密钥和 TV 读取密钥，每个至少 32 个 ASCII 字符；示例占位值会被拒绝。不要使用远控密码。证书需要匹配访问服务的主机名/IP，并让客户端显式信任其签发 CA。配置中的证书路径相对配置文件解析，私钥/配置文件仅应允许本机用户读取。

`listenHost` 必须是明确的本地、私有或 Tailscale 地址，不接受 `0.0.0.0`/`::`。默认示例仅为 localhost。`apps` 是来源标识到可信软件名称的显式映射，当前 `codex`/`wechat` 是协议适配器标识，不声称是系统 bundle ID。`hostId` 必须绑定 TV 已有电脑卡片，由同一物理电脑的 LAN/Tailscale 卡片中选一个默认目标。此服务不读取 TV 的电脑凭据，也不检查卡片是否确实存在，TV 必须再次验证映射与作用域。

以下命令均需由操作者明确运行：

```sh
# 只在本地检查配置及证书私钥配对，不联网或监听。
python3 -m notifications.cli --config local/notifications.json check

# 启动独立 TLS 服务。证书失效或缺失时直接失败，无 HTTP 降级。
python3 -m notifications.server --config local/notifications.json

# 向该服务提交固定合成样例；不读取真实通知。
python3 -m notifications.cli --config local/notifications.json syntheticpublish \
  --device-id example-mac --app-id codex \
  --url https://localhost:24443 --ca local/notification-ca.pem
```

`syntheticpublish` 明确产生一条测试事件，只有操作者主动运行才发送；接入 TV 前请与用户协调测试时机。不要把手工样例成功称为 Codex/微信自动同步已完成。

## HTTP 协议 v1

所有请求使用 HTTPS 和 `Authorization: Bearer <token>`。设备凭据只可 POST 事件；TV 凭据可 GET 事件，并登记/撤销自己的 Push Token 和解析点击。不提供 CORS，不支持明文、压缩或 chunked 请求体。

`POST /v1/events` 使用 `Content-Type: application/json`，只允许以下字段：

```json
{
  "eventId": "example-task-1",
  "appId": "codex",
  "appName": "Codex",
  "title": "任务完成",
  "body": "合成样例正文",
  "createdAt": 1792886400000,
  "expiresAt": 1792886700000,
  "contentState": "complete"
}
```

示例时间不是待发送的实时事件。时间为 UTC epoch 毫秒整数；过期事件拒绝，最长 TTL 24 小时，创建时间最多允许向前偏差 60 秒。`contentState` 为 `complete`、`truncated`、`hidden` 或 `unknown`。正文最多 8000 Unicode 字符，标题最多 256，HTTP 请求最多 49152 字节。普通文本不执行，保留换行和 tab，拒绝其他控制字符、重复 JSON 键及未知字段。客户端应将内容按纯文本展示。

服务端按凭据添加 `deviceId`、`deviceName`、`hostId` 和整数 `cursor`；payload 不允许携带这些字段。`appId/appName` 必须同时匹配设备 allowlist。新事件返回 `201 {"accepted":true,"duplicate":false,"cursor":1}`，同一设备相同事件 ID 和相同内容重试返回 `200` 且 `duplicate:true`；同 ID 不同内容返回 `409 event_id_conflict`。不同设备可使用相同事件 ID。

`GET /v1/events?after=0` 使用独立 TV 读取凭据，返回：

```json
{"events":[],"nextCursor":0,"resetRequired":false,"streamId":"per-process-uuid"}
```

`events` 每条包含服务端补充字段与完整提交内容，按 cursor 递增，最多 100 条。客户端读取后使用 `nextCursor` 继续，不要把请求时间当作游标。服务端保留尚未到期事件，超过容量拒收 `429 inbox_full`，不会静默挤掉未过期消息。过期清理造成非零读取水位缺口或请求游标超过当前序列时返回 `resetRequired:true`；`after=0` 是明确的全量基线读取，不再报告过期历史缺口。客户端必须与游标一起记住 `streamId`。发现 streamId 改变或 resetRequired 后，以 `after=0` 重新读取，并以 `(deviceId,eventId)` 去重，不能将 cursor 当全局永久事件 ID。

示例新增可选 `statePath`，指向 `local/` 内权限为 0600 的 SQLite 文件，事件、游标、streamId、Token 登记、点击凭据和发送队列在同一事务持久化。重启保留未过期事件；删除电脑或改变卡片/来源绑定后，旧事件及对应点击被清理。SQLite 启用 secure_delete；磁盘/系统备份不由本服务管理。没有 statePath 的旧配置继续以内存模式工作，重启丢失事件，且后台登记返回 `503 persistent_state_required`。

错误返回 `{"error":"稳定错误码"}`，不附正文、密钥或请求细节。服务不记内容日志，最多 16 个并发连接，每连接 5 秒超时。上游短时停止或容量满时，采集端应有界重试并遵守 `expiresAt`，不可无限存储敏感通知。

## 验证边界

`python3 -m unittest discover -s tests -p 'test_notification*.py'` 使用内存 HTTP、临时 SQLite、合成 RSA 密钥和假发送器验证，不打开监听端口、不访问云端、不接触电视。真实云凭据、权益、TV Token、原生视频应用前台与冷启动点击仍需独立实机验收。

## Mac 登录启动

`deployment/io.github.archazzz.screenlink-notifications.plist.example` 提供独立 LaunchAgent 模板。替换 Python、项目和配置的绝对路径，安装到当前用户的 `~/Library/LaunchAgents/` 后，用 `launchctl bootstrap gui/$(id -u) <plist绝对路径>` 加载。先停止同一端口的手动服务，避免两个进程争用端口；无需管理员权限。

该服务只在用户登录期间运行，休眠／离线时不会提交新推送。启用 statePath 后重启保留未过期事件与待发队列；旧内存模式重启为空，电视通过 streamId 变化重新同步。电视本地已有的未过期记录继续保留。登录启动本身不是 TV 后台 Push Kit 的替代品。
