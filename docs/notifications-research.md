# 屏间通知同步方案

更新日期：2026-10-25。当前范围仅为 Codex。用户因电视是公共屏幕而取消微信及个人消息同步，相关采集助手、系统通知库监听和辅助功能探针已撤除。

## 当前架构

1. Codex 原生 Stop hook 提交任务完成事件，不读取系统通知数据库或聊天内容。
2. 独立 TLS 中转按配对凭据绑定来源电脑，仅接受 `codex/Codex`。远端电脑可以经过 Tailscale 连接中转。
3. 电视前台通过认证轮询读取通知；后台由自有华为 Push Kit 项目投递。通知标题和正文经过华为服务，用户已同意此数据路径。
4. 点击通知先校验安装、事件期限与电脑映射，再复用保存的远控连接；已有会话先串行释放。推送不携带远控密码、任意地址或命令。
5. 事件、点击凭据和有限重试队列持久化并按期限清理。微信等非 Codex 的历史事件、队列和点击一并拒绝和清理。

## 已验证及边界

真实 Mac Desktop Codex 完成通知已经送达。自有应用 Push Token、TLS 登记、其他视频应用前台期间的通知中心到达与点击直达已实测。WORK 分类权益已获批。跨应用横幅仍未通过验收，不承诺覆盖全屏视频或强制唤醒电视。

Codex 完成回复来自原生 hook，不一定与桌面系统横幅文字完全一致。权限请求事件不等于用户此刻仍需审批；等待输入场景须独立验证。当前不提供系统级通用通知镜像，也不采集微信。

具体实现与部署记录见 [实施说明](notifications-implementation-plan.md)、[Codex 接入](codex-notification-hook.md)、[后台能力核验](notification-background-research.md)。

## 官方依据

- [Codex Stop 事件](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/events/stop.rs)：任务完成事件与最终回复字段。
- [Huawei 获取 Push Token](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-get-token)：TV 从 HarmonyOS 5.1.1/API 19 支持。
- [Huawei 发送通知消息](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-send-alert)：系统通知、点击动作和 V3 发送协议。

官方能力存在不替代实机验收。系统横幅长度、位置和展示策略由电视决定，完整内容保存在屏间收件箱。
