# Codex 完成事件接入

`notifications/codex_hook.py` 是原创的通知适配器，通过 Codex 原生 `Stop` hook 获取最终回复并发送到屏间 TLS 通知中转。它不读取聊天数据库、会话日志或屏幕，不要求新开 CLI 任务。Desktop 原生 hook 是否在当前版本触发，仍须完成真实一轮对话验收；单元测试与合成事件不能代替这一项。

## 本地配置

将以下内容保存到被 Git 忽略的 `local/codex-notifications.json`，只允许当前用户读取（macOS 可运行 `chmod 600 local/codex-notifications.json`）。使用中转配置中对应电脑的**写入 token**，不是电视读取 token，也不是远控密码。中转设备 allowlist 需包含 `"codex": "Codex"`。

```json
{
  "relayUrl": "https://localhost:24443",
  "token": "REPLACE_WITH_DEVICE_WRITE_TOKEN",
  "caFile": "notification-ca.pem",
  "permissionRequests": false
}
```

CA 路径相对该配置文件解析。访问地址必须匹配证书的 SAN；本机示例地址不是其他电脑的连接地址。始终验证证书与主机名，拒绝重定向，不使用环境代理。

## 保留现有配置的安装步骤

**不要修改或覆盖 `config.toml` 的 `notify`。** 它可能已由电脑操作工具占用；本适配器只增加 `Stop` hook。

先生成候选文件，不直接改全局配置：

```sh
# 已有 hooks.json 时：
python3 notifications/codex_hook.py prepare-hooks \
  --existing "$HOME/.codex/hooks.json" \
  --output local/codex-hooks.candidate.json \
  --config local/codex-notifications.json

# 没有 hooks.json 时：省略 --existing 参数。
```

生成器将当前 Python、适配器和配置路径转换为绝对路径，并保留所有已有事件、处理器和未知字段。重复生成相同命令不会增加第二条相同 hook；已有候选文件不会被覆盖。它既不触碰 `config.toml`，也不写信任记录。Windows 应使用能够直接运行 Python 的实际可执行文件路径，可用 `--python` 指定。

检查候选与现有文件的差异；备份原文件后，将候选内容安装为 `~/.codex/hooks.json`。如果检查后有其他进程修改原文件，应重新合并。随后在 Codex 的 Hooks 界面检查并信任这条命令；必要时重启应用使配置生效。不要手改 trust 数据。改动命令、解释器或超时后可能需要重新信任。

配置中的 token 只出现在本地文件中，hook 命令行只包含配置路径。请不要把候选中包含的个人绝对路径、真实配置、证书私钥提交到公开仓库。

## 行为与边界

- 默认只接收 `Stop`；`SubagentStop`、空回复、由阻止停止的 hook 引起的续跑不会转发。
- 标题为“Codex 回答完成”，正文保留 `last_assistant_message` 原文与换行；超过 8000 个 Unicode 字符只保留前 8000 字并标记 `contentState=truncated`，不假装完整。正常正文标为 `complete`。这表示事件所提供回复是否完整，**不是 macOS 系统横幅的逐字复制**。
- 不发送 prompt、工作目录、工具参数或 transcript 路径；原会话和轮次 ID 仅在内存中用于散列事件 ID。设备名称及要连接的电脑由中转 token 映射，事件不能指定任意电脑。
- 正文含协议不允许的控制字符时放弃该事件，不擅自改写正文。每条事件五分钟过期，没有磁盘正文队列、历史补传或正文日志。
- hook 的 stdout 始终为空，执行失败也返回 0，不输出任何批准、拒绝或阻止执行的结果。网络 worker 总时限四秒、单次网络操作两秒，外层 hook 超时六秒；超时终止 worker。每次只尝试一次；网络不通时允许丢失通知，避免拖住任务。读取 stdin 由 Codex 提供的 EOF／外层 hook 超时约束。
- 同一会话与轮次的 Stop 使用相同事件 ID，中转不会增加第二条；重放若时间戳不同，中转可能返回 409，适配器静默结束。没有“几秒内全局去重”，并发不同任务可分别通知。
- `PermissionRequest` 解析支持默认关闭。只有显式注册该事件且配置 `permissionRequests=true` 才会转发“Codex 权限请求”，正文仅含工具名称，`contentState=unknown`。此 hook 在自动审批和用户审批界面前触发，**不意味着仍需用户批准**。候选生成器不会注册它。
- 不用最终回答的问号猜测“需要你输入”。当前不保证覆盖交互提问、失败、异常退出或在其他 Stop handler 阻止后的最终状态。

## 验证

```sh
python3 -m unittest discover -s tests -p 'test_codex_hook.py' -v
```

测试包含 relay 实际校验、原文／截断／身份隔离、外国 hook 保留、失败静默、总时限终止和本地临时 TLS 服务。TLS 集成验证证书主机名失败时不发送凭据、307 重定向不跟随。测试只向临时回环服务提交合成事件，不发送给电视或读取真实对话。

上线验收需分别确认：真实 Desktop Stop 触发、中转接受、电视展示真实正文与电脑／应用来源、点击连回该电脑。不要用“脚本已测试”替代“已安装并实测”。

## 参考依据

协议实现参考官方公开行为，未复制第三方实现：

- [OpenAI Stop hook 源码](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/events/stop.rs)
- [OpenAI PermissionRequest 语义](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/events/permission_request.rs)
- [OpenAI hooks 配置发现](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/engine/discovery.rs)
- [CodexHookNotify 的 Desktop Stop 接入实例](https://github.com/Seacolour/CodexHookNotify)

## 本机验收记录（2026-10-25）

- 本机 Codex CLI 0.163.0-alpha.11：`features list` 中 hooks 为 stable、true。
- 已安装独立 Stop hook，原有电脑操作工具 notify 未改。用户在 Hooks 页面完成信任；通过官方 app-server `hooks/list` 只读查询得到 eventName=stop、enabled=true、trustStatus=trusted。该查询未创建会话、未读取聊天内容，也没有执行 hook。
- 中转已作为独立用户 LaunchAgent 运行，HTTPS 校验返回 200。
- 电视前台合成样例已由用户确认收到；点击“连接电脑”正确进入 Mac mini，截图结果一致。
- 用户随后明确确认收到真实 Codex 通知，验证当前 Mac Desktop Stop 自动触发并送达电视。后台通知中心到达与点击已独立验证；跨应用横幅仍待验收。微信功能已按用户隐私要求撤除，不在支持范围。
