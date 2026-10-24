# Mac 通知接入与 AX 探测原型

新增自动接入实现见 [微信系统通知增量监听](wechat-listener.md)：独立可授权助手、启动水位、只读新通知与 TLS 中转。已完成代码和合成测试；真实系统通知库目前被 TCC 拒绝，未完成微信端到端验收。以下说明专门针对 AX 探针。

**当前交付是受控通知探测工具，不是自动微信通知同步助手。** 已检查本机辅助功能授权并运行有时限的新节点结构探测；尚未捕获到可验证的微信系统横幅。没有读取聊天数据库或发送微信通知。本工具不安装 LaunchAgent，不开机运行，不把通知中心旧记录发往网络。

Codex 接入已改为优先使用官方 Stop hooks，参见 `../docs/notifications-implementation-plan.md`。本工具仅保留给普通微信等无已确认事件接口的软件做结构探测，不作为 Codex 的首选路径。

## 已核实与尚未核实

macOS 公共 ApplicationServices API 提供 `AXIsProcessTrustedWithOptions`、`AXUIElementCreateApplication`、`AXObserverCreate`、`AXObserverAddNotification` 和元素属性读取。当前 SDK 头文件明确说明，元素可能不支持观察事件并返回 `kAXErrorNotificationUnsupported`。这些 API 不承诺通知中心的层级、软件来源字段、完整通知正文或每条通知的出现事件。`UNUserNotificationCenter` 也不是跨应用通知监听接口。

本地已用 Swift 6.4 编译并运行纯数据测试，目标最低 macOS 13；已在实际通知中心进程验证观察器注册和结构遍历；尚未在真实微信横幅上建立字段映射。Codex 已采用独立原生 hook，不使用本工具抓取。

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

探测开始后测试微信通知，勿打开通知中心历史列表：

让另一账号或联系人发一条“屏间微信通知测试”，确保微信不在该聊天前台，并观察真正的系统横幅。不要为测试发送敏感聊天内容。文件传输助手或当前前台聊天未必会产生横幅，需以实际系统横幅为准。

需要用户确认：是否出现横幅，所属软件名称是什么；终端报告是否出现新节点、角色和属性名。第一轮输出没有正文，可以提供结构结果。若没有新节点、仅旧节点文本更新或观察事件不支持，记录该限制，不认定采集成功。

最长运行 120 秒，Ctrl-C 可立即退出。不保存正文，不持久化 AX 节点，不尝试点击、展开、清除通知，也不扫描其他应用窗口。首次看到的节点仅记身份作为基线，不输出其文字；此基线是避免历史回放的实验保护，不能证明后来出现的节点一定属于新通知。

## 来源和文本边界

源码允许列表为 `com.openai.codex` 和 `com.tencent.xinWeChat`；本机已从已安装桌面宿主（应用显示名 ChatGPT）和微信的 Info.plist 核实这两个 bundle ID。但应用 bundle ID 不等于通知中心已提供可信的逐条来源字段；不能据此宣称已识别 Codex 通知。

当前唯一接受的身份依据是 **AX 节点所属进程的精确 bundle ID**，不扫描正文中的“Codex”或“微信”，不以通知标题推断来源，不接受 helper 后缀的模糊匹配。通知中心代理节点通常属于 `com.apple.notificationcenterui`，此时只能报告 `source=unknown`。本版本不会猜测通知卡片内标签属于哪款软件，因此很可能全部来源未知；这是明确的未解决门槛。

用于固定无敏感样例的 `--fixture-test` 会读取新节点的 Identifier／Title／Value／Description，但只输出精确测试文案、已知结构标识、精确微信 bundle ID 或标签。其他内容只输出长度与布尔分类，绝不输出联系人、正文等任意文本。它报告系统 Description 是否存在精确微信前缀作为待验证线索，**不把这个线索当成已验证来源**。基线节点仍不读文本。

```sh
mac-assistant/.build/debug/screenlink-mac-probe probe 120 --fixture-test
```

可选 `--show-allowed-text` 仅对身份已精确匹配的节点输出系统暴露的 Title／Value／Description 原文，仍不把它们推定为一条完整通知。未知来源不读取文字。单项超过 4096 字符时省略该项并标记 `truncated`；其他情况标记 `unknown`，没有 `complete` 状态。正常探测模式只输出角色、层级和已知属性名称，不输出 Identifier／Description 的具体值。

后续必须用真实无敏感样例验证一个稳定的“来源节点＋通知卡片边界＋标题正文映射＋时间/事件身份”适配器，验证隐藏预览、中文长文、聚合和更新，再连接传输。不能直接把此结构探测工具当作自动转发器。

## 传输接口原型

`ScreenLinkMacCore.EventSender` 是独立可测试组件，**未接到探测命令**，没有默认凭据或网络地址。它使用系统 TLS 信任校验向 `https://<server>/v1/events` POST，设备 token 放在 Authorization Bearer；不跟随重定向、不写 Cookie 或 HTTP 缓存。没有忽略证书验证的选项。

`appId` 使用中转协议标识 `wechat`／`codex`；来源识别仍使用单独保存的精确 bundle ID，两者不混用。标题限制 256、正文限制 8000 个 Unicode 标量，拒绝协议不接受的控制字符，token 要求 32–256 个可打印 ASCII 字符。

事件只有 `eventId, appId, appName, title, body, createdAt, expiresAt, contentState`，时间为 Unix 毫秒；`deviceId` 和 `hostId` 应由服务端根据配对 token 绑定，客户端不能通过正文冒报目标。验证过期时间、文本大小和来源；过长原文会拒绝发送，不默默截断。默认 `contentState=unknown`。

该组件尚未连接真实中转服务，测试只构建内存请求并检查内容，未发任何网络请求。真实来源采集、服务端认证兼容性、电视到达与点击均未实测。

## 同类项目的实现边界

- [mac-notification-bark-bridge](https://github.com/anohaca/mac-notification-bark-bridge) 使用 AX 获取可见通知，从横幅的系统描述推断软件来源。其正文关键词过滤和兜底来源推断不适用于屏间的严格应用允许列表，未照搬代码。
- [macos-notification-cli](https://github.com/coryfklein/macos-notification-cli) 记录 Tahoe 的 `AXNotificationCenterAlert`／`AXNotificationCenterAlertStack` 结构，能操作通知中心历史；屏间只参考结构，不打开历史或调用点击／展开。
- [weiji](https://github.com/zen-xu/weiji) 从系统通知数据库关联 `app.identifier` 取得微信来源；这不是微信聊天数据库，但仍为非公开数据库格式，且该项目扫描历史记录。独立增量监听器仅参考字段结构，不采用其历史扫描；本机只读库头检查被 TCC 拒绝，尚未取得 schema 或内容。

因此 AX 路线需要先证明真实横幅确实出现，再验证软件来源、标题／正文、隐藏预览、聚合／重复与系统升级兼容性。观察器注册成功并不证明每一条通知都会触发或暴露内容；普通微信也没有在此次调查中找到可直接订阅系统通知原文的官方公开 API。
