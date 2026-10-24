# 可选华为后台通道

代码已实现并已部署：自有应用获取 Token、TLS 登记及其他视频应用前台期间的系统通知中心到达已实测。横幅开启后的展示、点击直达和真实微信仍待验收。服务不搜索 AGC、浏览器登录态或上游客户端的凭据。未配置 `push` 不访问云推送服务；只有显式配置、TV 登记和新事件到达后才排队发送。本次真实通道已在用户接受 Push 协议并同意来源、标题、正文经华为转发后启用；新部署仍须确认对应用户的数据转发意愿。

## 配置

自有项目开通 Push Kit、重新签名并准备好服务账号后，在本地完整配置中合入以下调试片段：

```json
{
  "statePath": "notification-state.sqlite",
  "push": {
    "serviceAccount": "huawei-push-service-account.json",
    "category": "MARKETING",
    "testMessage": true
  }
}
```

这是配置片段，也对应当前已验证的调试类别。正式自分类权益尚未申请；`WORK` 或 `IM` 必须实际获批，不能由配置字段替代审核。当前支持显式选择 WORK、IM 或 MARKETING。`testMessage:true` 使用官方测试频控，不代表正式权益。服务账号文件需 0600，字段包含 `project_id/key_id/sub_account/private_key`，仅存 `local/`；其中私钥为 PEM 格式。

PS256 通过系统 `/usr/bin/openssl` 签名，无全局 Python 包依赖。私钥只临时写入 0600 文件签名后删除，不进入命令参数或日志。JWT 使用 `kid=key_id`、`iss=sub_account`、官方 aud 和 3600 秒有效期，直接作为 V3 Bearer。启动或 `cli check` 只验证本地签名；使用固定 HTTPS 华为端点、系统 CA、禁止重定向，不跟随环境代理。

## TV 协议

接口均沿用独立 TV Bearer 和已有 TLS 证书校验：

| 接口 | JSON 请求 | 成功响应 |
| --- | --- | --- |
| `POST /v1/push/register` | `installationId,pushToken,previewMode,scope` | `registered:true,cloudConfigured:boolean` |
| `POST /v1/push/revoke` | `installationId` | `revoked:true` |
| `POST /v1/push/resolve` | `installationId,clickNonce,scope` | `event:<完整事件含cursor>,streamId,scope` |

`installationId` 为该 TV 安装持久化的随机 ID；`scope` 为当前账户作用域。register 可省略 scope，默认为 local；resolve 必须明确传入。服务仅支持一个 TV 登记、一个 TV 凭据作用域，不是多租户系统。第二个安装不能覆盖第一个，返回 409；须先撤销旧登记。scope 是导航约束，不是独立授权来源，TV 切换账户应撤销旧登记。

`previewMode=full` 向华为提交来源和截断后的标题/正文；完整原文在中转，点击后经已配对 TLS 查询。`source` 仅推送来源及固定提醒。两者都经过华为服务，不能称为纯局域网后台通知。`cloudConfigured:false` 表示仅保存登记、不会发送，不应显示已成功启用后台提醒。没有 statePath 时 register 返回 503，不保存易失的后台登记。

相同登记幂等；更换 Token、scope 或预览模式会生成新登记代次并清除旧 nonce/待发队列。停用撤销后不再排队，旧点击查询失败；撤销完成前已提交的在途云请求无法撤回，但其点击映射不能恢复。

## 投递、点击与持久化

云消息 `clickAction.data` 仅含 `screenLinkPushNonce` 和 `screenLinkInstallationId`，不含地址、hostId 或远控凭据。nonce 为 256 位随机值，绑定安装、scope、登记代次与事件期限。resolve 要求 TV Bearer，重新验证期限和现存电脑/来源绑定；重复解析在期限内幂等，TV 再验证本机卡片映射并串行释放原会话。

使用 `foregroundShow:false`，前台继续 TLS 轮询，避免主动制造双提醒；TV 实际抑制行为仍须验收。消息体按 UTF-8 限制在 4096 字节以内（不计 Token），只把官方 `code=80000000` 且标准响应字段齐全视为接受成功。不把 API 接受等同于 TV 展示或可点击。

每条队列最多三次尝试，失败退避 10/20 秒，重启不会无限重试；事件使用稳定 notifyId。若服务端已接受但响应丢失，重试可能重复投递，由 notifyId 与 TV 事件去重共同处理。新增事件、游标、登记、nonce 和待发队列共同保存到私有 SQLite；发送前先持久化尝试次数，过期清理。配置中删除电脑/来源或改变 hostId，旧事件点击失效。TV Bearer 轮换使旧登记和 nonce 失效。

服务重启保留未过期队列；不向新登记重放以前的历史事件。未配置发送器时只保留前台事件，不悄悄积累未来待发云通知。云失败不会阻断前台事件接收；当前没有面向用户的逐条投递诊断界面，因此无法据服务启动成功推断云端健康。

## 已验证与未验证

离线测试覆盖事件/nonce 重启恢复、安装与 scope 绑定、鉴权、撤销、过期、配对移除、凭据轮换、有限重试、PS256 本地签验和 V3 JSON 结构。测试密钥由临时生成器创建，不读取真实服务账号，不监听端口，不请求云端。

实际部署已验证：

- 自有 HarmonyOS 智慧屏应用及项目已注册，Push 已开通；新 Profile 含 `com.huawei.service.push.base_service`。
- 专用项目开发角色服务账号经用户授权创建，文件权限 0600，实际凭据的 PS256 本地签验通过；未将凭据提交到仓库。
- 用户批准备份后的签名身份迁移，新 HAP 已构建并安装；数据库检查通过，4 台电脑和 4 份已保存密码仅按计数核验，数据库与 12 个偏好文件回读哈希一致，首页四卡截图确认。
- TV `getToken()` 成功并经 TLS 登记，状态为 `hasToken=true`，未输出 Token。项目数据处理位置为中国，当前采用 `MARKETING`、`testMessage:true`。
- 用户确认在其他视频应用期间通知中心收到合成云通知。此前系统横幅未开启，用户现已开启；第二条测试的横幅及点击结果待确认。

待实测：横幅、前台去重、进程未运行时冷启动、点击切换已有远控会话、离线与撤销的系统展示行为。微信独立助手已获完全磁盘访问授权并正在监听，但尚未完成真实微信到电视验收。正式自分类权益尚未申请，需在用户授权申请须知及申请内容后继续；当前测试通道不代表不限量正式推送。

官方依据见 [后台能力核验](../docs/notification-background-research.md)。发送结构采用 Huawei V3 的 `payload.notification`、`target.token`、`pushOptions`；`clickAction.data` 是对象。成功响应依据 [场景化消息响应](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/push-scenariozed-api-response)，页面更新 2026-09-30。
