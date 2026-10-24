# 微信系统通知增量监听

`wechat_listener.py` 是可显式启动和停止的自动监听器。它读取 **macOS 系统通知存储**中新增加的微信通知，并提交到现有屏间 TLS 中转。它不读取微信聊天数据库，不注入微信、不读聊天窗口，也不扫描／补传历史通知正文。

实现已通过合成 SQLite／二进制 plist 测试，独立启动器已构建并签名验证；**尚未通过真实微信通知到电视的端到端验收**。当前机器读取系统通知库头部即被 TCC 拒绝，尚未取得真实 schema 或正文样本。不能把合成格式测试称为当前 macOS 数据格式已验证。

## 数据与权限边界

当前只支持固定系统路径 `~/Library/Group Containers/group.com.apple.usernoted/db2/db`，不搜索其他数据库，也不提供绕过 TCC 的回退。需要运行助手的权限归属进程获得**完全磁盘访问**；已有辅助功能权限不够。

建议使用单独的 `ScreenLink WeChat.app`，仅给该助手授权，不给 Codex、终端或全局 Python 解释器额外权限。macOS 对子进程权限归属的实际结果需在这个已签名助手里确认；若系统仍拒绝，应停止并检查启动身份，不自动扩大授权范围。构建器不请求权限、不写 TCC 数据库、不启动监听。

## 本地配置

以下两个文件均放在仓库忽略的 `local/` 中，仅当前用户可读。不要把真实地址、token 或个人路径提交到 GitHub。

`local/wechat-listener.json`：

```json
{
  "relayConfig": "wechat-relay.json",
  "forwardContent": false,
  "pollSeconds": 1
}
```

`local/wechat-relay.json`：

```json
{
  "relayUrl": "https://localhost:24443",
  "token": "REPLACE_WITH_SEPARATE_WECHAT_WRITER_TOKEN",
  "caFile": "notification-ca.pem"
}
```

中转需要为这个助手配置独立设备写入 token，应用允许列表只开放 `"wechat": "微信"`，绑定要连接的那张电脑卡片。不要使用 TV 读取 token、远控密码或 Codex writer token。两个不同 writer 可以映射同一台真实电脑，但设备 ID 应不同。

`forwardContent=false` 是保守默认值：SQL 不选择通知 blob，仅发送“微信通知”，正文留空并标记 `hidden`，表示助手主动隐藏内容。用户要求同步原文时可显式设为 `true`，才读取启动水位之后的新微信通知展示字段；不解码 `usda` 或聊天元信息。

`forwardContent=true` 会保留 `req.titl` 标题以及 `req.subt`／`req.body` 原文，副标题和正文以换行连接。标题超过 256、正文超过 8000 Unicode 字符时截断并标 `truncated`；未截断也标 `unknown`，**不标 complete**，因为系统数据库字段不能证明最终横幅显示了哪些内容，也不能证明隐藏预览后的实际可见文本。没有可靠隐私标记时不把占位文本或空正文猜成“系统隐藏”。若要求严格遵守系统横幅隐藏预览，先保持 `forwardContent=false`。

## 独立助手

在仓库根目录运行：

```sh
python3 mac-assistant/build_wechat_app.py \
  --config local/wechat-listener.json \
  --output '.work/ScreenLink WeChat.app'
```

输出目录必须不存在；构建器不会覆盖已有 .app。默认为本地 ad-hoc 签名，可用 `--sign-identity` 指定自己的签名身份。启动器绑定构建时 Python 的绝对路径，需保留该 Python 安装；它不是内置 Python 的可分发发行包。应用内只包含程序和外部配置路径，不包含 token。

先将 .app 放到准备长期保留的位置，再打开系统设置 → 隐私与安全性 → 完全磁盘访问，添加并开启这个助手。打开助手，点击“开始监听”。“停止”或关闭助手会停止监听，没有 LaunchAgent 或开机自启。修改签名／重新构建后，系统可能要求重新授权，不能假定旧授权仍有效。

为了避免授权过宽，日常推荐通过独立助手操作。开发检查也提供显式命令，但其权限属于实际运行终端／宿主，不应为此扩大宿主授权：

```sh
# 只读库头/schema/MAX(rowid)，不读历史正文。
python3 mac-assistant/wechat_listener.py check

# 明确启动；Ctrl-C / SIGTERM 停止，也可限制运行秒数。
python3 mac-assistant/wechat_listener.py listen \
  --config local/wechat-listener.json --duration 120
```

## 水位和可靠性

- `mode=ro` 加 `PRAGMA query_only=ON`，不更改系统数据、不复制数据库、不清理通知。
- 启动只查询 schema 和 `MAX(rowid)` 作为水位；之前的正文从不读取。重启也重新建立水位，因此停机期间的通知不会补传。
- 只查询水位之后、精确二进制匹配 `com.tencent.xinWeChat` 的行；非微信行不读取正文。还要求系统投递时间不早于本次监听开始，且距离当前最多 120 秒、未来最多 60 秒，拒绝旧通知延迟写入。
- 不信任正文里的软件名称，也不使用通知标题猜来源。每批最多 20 条，单个 plist 最多 1 MiB。只适配已知 `record/app` 字段及 `req` 展示字段；缺字段、schema 改变、未知 payload 均不猜测。
- 数据库 inode 变化或水位倒退时只重新建立基线，不回放旧记录。系统若复用记录 ID 且最大值未下降，可能漏收；原记录的就地更新也不重新读取。这包括某些聚合通知更新，需真实样例验证。本实现偏向不重放历史。
- TLS 使用系统验证及指定 CA，检查主机名、不接受重定向、不使用环境代理；独立 worker 限时四秒。未配置关闭证书验证的选项。
- 每条只尝试一次，无正文磁盘队列、无历史补传。中转不可用或超时会丢失该条，日志只报计数，不含正文、联系人、地址或 token。关闭时最多等待当前有界投递结束。
- `hidden`、`unknown`、`truncated` 是内容边界，不代表已经看到真实微信消息。界面“中转已接收”也不代表 TV 已实际展示。

## 验证

```sh
python3 -m unittest discover -s mac-assistant/Tests -p 'test_wechat_listener.py' -v
swift test --package-path mac-assistant
```

测试只创建临时合成数据库，不访问个人通知库。覆盖启动不回放、非微信排除、只读写入拒绝、无正文模式、未知 schema、过旧／超大内容、分批水位、截断与 TCC 拒绝。共享 TLS 发送器由 `tests/test_codex_hook.py` 的本地 HTTPS 测试验证。

真实验收仍需：独立助手实际获得最小权限、当前 schema 被接受、之后收到一次真实微信系统通知、电视展示来源和内容并点击进入对应电脑。不需要为验收读取已有微信消息或借用历史通知。

## 依据

通过阅读公开实现确认系统通知库常见 `record → app` 关联和二进制 plist 的展示字段；本监听器为原创实现，未复制其历史扫描或聊天数据处理代码：

- [weiji NotificationSource](https://github.com/zen-xu/weiji/blob/main/Sources/WeChatListener/Features/Notifications/NotificationSource.swift)
- [weiji NotificationDecoder](https://github.com/zen-xu/weiji/blob/main/Sources/WeChatListener/Features/Notifications/NotificationDecoder.swift)

这是对非公开系统数据格式的适配，不是 Apple 的跨应用通知订阅 API。macOS 升级可能需要更新；未知格式应停止，不能静默扩大读取范围。
