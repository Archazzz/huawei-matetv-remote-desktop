# 通知中转原型

这是独立的 TLS 消息中转及手工样例工具，不采集 Codex、微信或系统通知。它不修改 RustDesk 转发，不自启、不主动向电视发送消息。电视接收客户端、真实通知来源、系统后台推送是独立部分；本目录不能单独满足完整通知同步需求。

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

所有请求使用 HTTPS 和 `Authorization: Bearer <token>`。设备凭据只能 POST，TV 凭据只能 GET。不提供 CORS，不支持明文、压缩或 chunked 请求体。

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

`events` 每条包含服务端补充字段与完整提交内容，按 cursor 递增，最多 100 条。客户端读取后使用 `nextCursor` 继续，不要把请求时间当作游标。服务端只在内存保留尚未到期事件，超过容量拒收 `429 inbox_full`，不会静默挤掉未过期消息。过期清理造成非零读取水位缺口或请求游标超过当前序列时返回 `resetRequired:true`；`after=0` 是明确的全量基线读取，不再报告过期历史缺口。服务重启会丢失内存、改变 `streamId` 并重置游标；客户端必须与游标一起记住 `streamId`。发现 streamId 改变或 resetRequired 后，以 `after=0` 重新读取，并以 `(deviceId,eventId)` 去重，不能将 cursor 当全局永久事件 ID。当前未使用磁盘持久化，重启前的未读事件无法恢复。

错误返回 `{"error":"稳定错误码"}`，不附正文、密钥或请求细节。服务没有正文持久化或内容日志，最多 16 个并发连接，每连接 5 秒超时。上游短时停止或容量满时，采集端应有界重试并遵守 `expiresAt`，不可无限存储敏感通知。

## 验证边界

`python3 -m unittest discover -s tests -p 'test_notifications.py'` 在内存验证请求，不打开监听端口、不接触电视。TLS 服务配置检查、真实证书信任、实机部署及端到端通知交互需要后续独立验收。
