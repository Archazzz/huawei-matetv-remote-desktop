# 屏间通知同步可行性与接入方案

核验日期：2026-10-24。本文为调研方案，通知功能尚未开发、安装或通过电视实测。

## 结论

可以实现「电脑事件 → 电视通知 → 点击打开屏间并连接来源电脑」。需要新增电脑端通知助手和独立消息通道；RustDesk 继续负责画面、音频与输入，Tailscale 负责跨网络连通。两者都不提供本项目所需的通用通知同步。

不能承诺 Mac 上任意软件的全部系统通知都能完整复制。苹果公开的 UNUserNotificationCenter 只提供当前应用自身的通知管理；它不是跨软件的通知监听器。

| 环节 | 可行路径 | 边界 |
| --- | --- | --- |
| Mac 任务完成、需要操作 | 软件事件接口、hook、webhook 或命令调用屏间通知助手 | 每个来源单独核实支持；事件文字只有与原通知使用同一内容源时才能保证一致 |
| Mac 其他软件横幅 | 用户授权辅助功能后，实验性观察通知中心的可访问文本 | 需在当前 macOS 实测；隐藏预览、截断、聚合、勿扰、系统更新可能导致不完整或漏收 |
| Windows 系统通知 | UserNotificationListener，声明 capability 并请求用户访问授权 | 可读取 Toast 文字与 AppInfo；不覆盖软件自行绘制的提示窗，封装与后台监听仍须 Windows 10 实测 |
| 屏间前台通知 | 认证的局域网消息通道，应用内通知卡片 | 可以保留完整正文，在应用内展开查看 |
| 看其他 TV 应用时通知 | 华为 Push Kit 通知消息，系统展示并通过点击动作拉起屏间 | 官方从 HarmonyOS 5.1.1/API 19 支持 TV；需 AGC 项目、Push Token、签名配置、通知授权及消息类别权益 |
| 点击直达电脑 | 稳定 deviceId 映射本机已保存 hostId，再走现有连接流程 | 冷启动等待存储初始化；已有会话先释放；凭据缺失仍需认证，不绕过认证 |

## 用户看到的效果

通知来源行显示「Mac mini · 来源软件」，标题和正文保留收到的原文。系统发布者仍为「屏间」，不伪装成其他软件的系统身份。点击通知打开屏间并连接该电脑；可选的具体任务页跳转只能在来源软件提供可信链接时增加。

系统横幅受字数、布局和电视展示策略限制，不能承诺整条长通知不截断。应用内通知详情保留原始完整文字。读取到的只是系统隐藏提示时，显示隐藏提示，不猜测被遮盖的内容。

## 推荐架构

1. Mac/Windows 常驻助手采集已启用来源，输出 `eventId/deviceId/appId/appName/title/body/createdAt/expiresAt`。事件标识用于去重；电脑身份来自配对记录，不能由消息自行声明为另一台电脑。
2. 家中 Mac mini 运行消息中转，远端 MacBook 通过已有 Tailscale 到达中转。局域网 Windows 使用认证连接；无需为通知开放公网入站端口。
3. 屏间在前台通过加密、认证通道接收并展示；后台由中转调用华为 Push Kit 的 V3 接口发送系统通知。通知正文经华为推送服务传输，这是完整后台横幅方案的数据路径。
4. 推送携带事件标识和已配对设备标识，不携带远控密码、任意地址或可执行命令。电视验证映射后复用保存的连接信息；若正在连接另一台电脑，走已有串行断开流程，防止单连接冲突。
5. 消息记录去重、限量、带过期时间，断网补发时避免旧通知突然大量弹出。用户可按电脑、软件开关同步，并设置免打扰。

纯局域网方案可以先验证前台闭环；普通应用退到后台或被终止后，不能把常驻 WebSocket 当作可靠系统推送。电视待机、休眠、断网、通知权限关闭时的行为必须实测，不能保证强制唤醒或强制盖住所有内容。

## 实施顺序及验收门槛

1. 先做 TV 能力验证：人工样例通知在前台、另一视频应用前台、屏间冷启动三种情况下的展示与点击路由。开发通知功能前不向用户其他设备发送测试消息。
2. 核验 AGC 中该应用 Push Kit 的开通条件。正式通知需匹配「服务与通讯」用途及相应权益；未申请自分类时可能被归为营销通知，每设备每天仅 2 或 5 条，不适合任务提醒。调试测试消息每日每项目全网最多 1000 条，不当作正式方案。
3. 接入一个明确软件的任务事件，验证中文、长正文、来源名称、重复/过期通知及错设备拒绝。
4. Windows 增加系统 Toast 监听；Mac 做辅助功能采集原型，并明确报告覆盖范围。不要以读取通知数据库、私有 API 或关闭系统保护作为正式方案。
5. 验证跨网络 MacBook → 中转 → TV，再验证点击通知切换当前远控会话。

## 官方依据

- Apple [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)：管理 “your app or app extension”，getDeliveredNotifications 获取 “your app’s delivered notifications”。已读取官方正文。
- Microsoft [Notification listener](https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/notification-listener)：允许访问其他应用通知；需 User Notification Listener capability 和 RequestAccessAsync；通知提供 AppInfo、ToastGeneric 文本元素。已读取官方正文。
- Huawei [发送通知消息](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-send-alert)：TV 从 5.1.1(19) 支持；通知授权、V3 API、点击应用内页、消息分类及频控。已读取官方正文，页面更新日期 2026-09-09。

尚未证明的内容：当前电视后台横幅样式与到达率、当前 Mac 通知中心辅助功能读取覆盖率、具体桌面软件的事件接口、Windows 10 通知助手的实际授权与后台运行。这些应通过原型验证，不能由 SDK 存在或系统版本号直接推定已可用。
