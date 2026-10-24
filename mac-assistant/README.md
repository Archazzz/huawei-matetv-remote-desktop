# Mac 通知采集探测原型

**当前交付是可编译探测工具，不是自动通知同步助手。** 没有运行真实通知采集、申请本机授权、读取聊天数据库或发送通知。本工具不安装 LaunchAgent，不开机运行，不把通知中心旧记录发往网络。

Codex 接入已改为优先使用官方 Stop hooks，参见 `../docs/notifications-implementation-plan.md`。本工具仅保留给普通微信等无已确认事件接口的软件做结构探测，不作为 Codex 的首选路径。

## 已核实与尚未核实

macOS 公共 ApplicationServices API 提供 `AXIsProcessTrustedWithOptions`、`AXUIElementCreateApplication`、`AXObserverCreate`、`AXObserverAddNotification` 和元素属性读取。当前 SDK 头文件明确说明，元素可能不支持观察事件并返回 `kAXErrorNotificationUnsupported`。这些 API 不承诺通知中心的层级、软件来源字段、完整通知正文或每条通知的出现事件。`UNUserNotificationCenter` 也不是跨应用通知监听接口。

本地已用 Swift 6.4 编译并运行纯数据测试，目标最低 macOS 13；尚未在 macOS 26 的真实通知树上验证。Codex 桌面版本的通知来源身份也需要实测，不能把 CLI hooks、ChatGPT 宿主或 Electron helper 的 bundle ID 自动当作 Codex 原生通知来源。

参考公共 API：

- [AXObserverCreate](https://developer.apple.com/documentation/applicationservices/1459139-axobservercreate)
- [AXObserverAddNotification](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)

## 显式启动步骤

在项目根目录执行构建和不涉及真实通知的测试：

```sh
swift test --package-path mac-assistant
```

只检查权限，不弹授权提示：

```sh
mac-assistant/.build/debug/screenlink-mac-probe permission-status
```

用户决定开始采集实验时，手动运行以下命令申请辅助功能权限。在系统设置中允许对应可执行程序或实际被系统标识的终端，重新检查权限后再运行探测。RustDesk 已有授权不能替代该助手授权。

```sh
mac-assistant/.build/debug/screenlink-mac-probe request-permission
mac-assistant/.build/debug/screenlink-mac-probe probe 60
```

探测开始后，分别测试以下两种通知，勿打开通知中心历史列表：

1. 在 Codex 中准备一个只输出“屏间通知测试完成”的短任务，切换到其他应用，让 Codex 按自身通知设置发出完成通知。若未产生系统横幅，先确认该 Codex 版本是否支持该提醒，不能用 AppleScript 冒充 Codex 来源。
2. 让另一账号或联系人发一条“屏间微信通知测试”，确保微信不在该聊天前台，并观察真正的系统横幅。不要为测试发送敏感聊天内容。

需要用户确认：是否出现横幅，所属软件名称是什么；终端报告是否出现新节点、角色和属性名。第一轮输出没有正文，可以提供结构结果。若没有新节点、仅旧节点文本更新或观察事件不支持，记录该限制，不认定采集成功。

最长运行 120 秒，Ctrl-C 可立即退出。不保存正文，不持久化 AX 节点，不尝试点击、展开、清除通知，也不扫描其他应用窗口。首次看到的节点仅记身份作为基线，不输出其文字；此基线是避免历史回放的实验保护，不能证明后来出现的节点一定属于新通知。

## 来源和文本边界

源码允许列表为 `com.openai.codex` 和 `com.tencent.xinWeChat`；本机已从已安装桌面宿主（应用显示名 ChatGPT）和微信的 Info.plist 核实这两个 bundle ID。但应用 bundle ID 不等于通知中心已提供可信的逐条来源字段；不能据此宣称已识别 Codex 通知。

当前唯一接受的身份依据是 **AX 节点所属进程的精确 bundle ID**，不扫描正文中的“Codex”或“微信”，不以通知标题推断来源，不接受 helper 后缀的模糊匹配。通知中心代理节点通常属于 `com.apple.notificationcenterui`，此时只能报告 `source=unknown`。本版本不会猜测通知卡片内标签属于哪款软件，因此很可能全部来源未知；这是明确的未解决门槛。

可选 `--show-allowed-text` 仅对身份已精确匹配的节点输出系统暴露的 Title／Value／Description 原文，仍不把它们推定为一条完整通知。未知来源不读取文字。单项超过 4096 字符时省略该项并标记 `truncated`；其他情况标记 `unknown`，没有 `complete` 状态。正常探测模式只输出角色、层级和已知属性名称，不输出 Identifier／Description 的具体值。

后续必须用真实无敏感样例验证一个稳定的“来源节点＋通知卡片边界＋标题正文映射＋时间/事件身份”适配器，验证隐藏预览、中文长文、聚合和更新，再连接传输。不能直接把此结构探测工具当作自动转发器。

## 传输接口原型

`ScreenLinkMacCore.EventSender` 是独立可测试组件，**未接到探测命令**，没有默认凭据或网络地址。它使用系统 TLS 信任校验向 `https://<server>/v1/events` POST，设备 token 放在 Authorization Bearer；不跟随重定向、不写 Cookie 或 HTTP 缓存。没有忽略证书验证的选项。

事件只有 `eventId, appId, appName, title, body, createdAt, expiresAt, contentState`，时间为 Unix 毫秒；`deviceId` 和 `hostId` 应由服务端根据配对 token 绑定，客户端不能通过正文冒报目标。验证过期时间、文本大小和来源；过长原文会拒绝发送，不默默截断。默认 `contentState=unknown`。

该组件尚未连接真实中转服务，测试只构建内存请求并检查内容，未发任何网络请求。真实来源采集、服务端认证兼容性、电视到达与点击均未实测。
