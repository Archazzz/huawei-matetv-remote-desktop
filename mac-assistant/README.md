# Mac 通知来源已收敛为 Codex

用户因电视是公共屏幕而取消全部微信通知同步。原微信监听器、辅助功能探针、Swift 传输原型、助手启动器、安装脚本及其测试已移除。此目录不再提供任何个人消息采集入口，也不需要完全磁盘访问或辅助功能权限。

Codex 使用独立的原生 Stop hook，源码为 [`notifications/codex_hook.py`](../notifications/codex_hook.py)，配置与验收见 [Codex 通知接入](../docs/codex-notification-hook.md)。它不读取系统通知库或微信内容。

升级时应停止并移除旧屏间微信助手及其本地配置，撤销该助手的完全磁盘访问授权；不要删除微信本体或清理用户微信通知。中转与电视仅允许 Codex，旧来源消息及点击映射由各自的升级清理逻辑移除，详见 [通知中转](../notifications/README.md)。
