# MateTV 后台通知：Push Kit 接入核验

核验日期：2026-10-25。本文只记录官方能力和下一步实施条件；本轮未开通账号权益、读取服务密钥或发送云推送。现有前台通知原型的验收记录见 `notifications-implementation-plan.md`。

## 已确认的 TV 能力

华为官方明确列出 **TV 从 HarmonyOS 5.1.1/API 19 起支持通知消息与获取 Push Token**。本项目实机 HarmonyOS 6.1 满足该版本门槛。这证明有正式后台通知路线，但不代表当前安装包已具备推送权益或后台实测成功。

| 能力 | 官方依据与项目判断 |
| --- | --- |
| 系统投递通知消息 | Push Kit 直接下发通知，系统展示，用户点击拉起应用；无需把屏间进程一直保活 |
| TV 获取 Token | `pushService.getToken()` 明确支持 TV；必须先开通 Push Kit，并签入对应能力 |
| Token 更新 | 应在应用启动时获取并上报；官方 `tokenUpdate` 支持表未列出 TV，不把该回调作为 TV 唯一更新机制 |
| 点击启动应用 | `clickAction.actionType=0` 打开入口 Ability，`data` 通过 Want 传递；冷、热启动分别处理 |
| 前台重复提醒 | `foregroundShow=false` 可用于前台不显示云端系统通知，但 TV 回调与本地轮询的协作仍须实机验证 |
| 声音和震动 | 分类权益文档明确 TV 不支持通知铃声和震动，不承诺电视播出提示音 |
| 后台唤醒替代方案 | VoIP 应用内通话唤醒明确不支持 TV；不借用该权益给普通任务提醒保活 |

通知中心、横幅、实际排版与通知分类及系统策略有关。不能由“TV 支持通知消息”推导出所有类别都覆盖在视频上方。待机、断网和用户关闭通知时，也不承诺唤醒电视。

## 自有项目、签名与权益

必须使用屏间自己的 AGC 应用、包名、开发者团队与签名；不得复用上游客户端的项目、Client ID、密钥或推送身份。

官方「开通推送服务」文档说明：从 HarmonyOS NEXT Developer Beta2 起，**无需配置公钥指纹和 Client ID**。因此不应为了推送把上游 `client_id` 元数据加回工程。

### 推荐的自动签名路径

DevEco Studio **6.0.0 Beta5 及以上**支持关联注册应用的自动签名和 Push Kit 开通。具体步骤：

1. 在自有开发者团队确认 AGC 已有与屏间包名匹配的应用及项目。
2. 连接测试电视，在 `File → Project Structure → Project → Signing Configs` 勾选 `Associate with registered application`。确认团队和 Bundle name 指向自有应用。
3. 点击 `Enable open capabilities`，选择 Push Kit，保存后重新生成调试签名与 Profile。
4. 官方说明开通后约 5–10 分钟，AGC 的「项目设置 → 开放能力管理」及「增长 → 推送服务」同步生效。
5. 重新构建安装，以实际 `getToken()` 成功验证身份和能力，不以打包成功代替。

**官方自动签名文档明确写明：“Push Kit（推送服务）开放能力接入后不可取消。”** 此步骤会永久改变项目的能力状态；在执行前应将具体自有项目和这一属性告知用户，确认后再开通。本轮只完成了文档核查，没有执行开通。

自动签名的地区覆盖不等于 Push Kit 本身的地区覆盖。Push Kit 文档当前规定非 Wearable 设备仅支持中国境内，不包含中国香港、澳门和台湾；项目数据处理位置、服务器区域与设备用户区域必须匹配。此项以当前 Push Kit 文档约束为准。

如采用手动签名，需要在开通 Push Kit **之后重新生成** Debug Profile，包含调试证书和已注册电视；正式发布则重新生成 Release Profile。原先能安装远控 HAP 的签名不自动证明有推送能力。

## 服务端鉴权与消息分类

HarmonyOS 5 及以上使用 V3 接口：

```text
POST https://push-api.cloud.huawei.com/v3/{projectId}/messages:send
Authorization: Bearer {service-account-JWT}
push-type: 0
Content-Type: application/json
```

该接口不再使用旧 OAuth 2.0 开放鉴权方式。官方要求在 API Console 的对应项目创建「推送服务 API」服务账号密钥，使用 `PS256` 签发 JWT；`kid` 来自 `key_id`，`iss` 来自 `sub_account`，固定 `aud` 为 `https://oauth-login.cloud.huawei.com/oauth2/v3/token`，建议有效期 3600 秒。JWT 直接作为接口 Bearer 凭据。

服务账号 JSON 和私钥只保存在中转服务的受限本地目录，不进 Git、日志或电视 HAP。`project_id` 必须与屏间 AGC 项目一致。电视只登记自身 Push Token，不能获得项目的发送权限。

通知分类必须单独申请：

- 未获自分类权益的消息默认归为 `MARKETING`，每设备每应用每日仅 2 或 5 条，且不能据此承诺视频上方横幅。
- 调试可设置 `pushOptions.testMessage=true`，每项目每日全网最多 1000 条，单次最多 10 个 Token；这不是正式频控豁免方案。
- Codex 完成／待处理提醒可按真实场景评估 `WORK`。是否批准由华为审核决定。
- 微信由屏间转发，不能因为内容来自微信就默认屏间具有 `IM` 权益。申请必须说明本应用为用户配对电脑同步通知，不能冒充即时通讯应用。
- 官方申请入口为「增长 → 推送服务 → 配置 → 对应应用 → 自分类权益申请」。需提供实际用途及消息示例；文档标示约 3 个工作日审核，通过后约 5 分钟生效。

## 与现有实现的衔接

现有前台服务使用 TLS 轮询并持久化本地事件，系统通知点击携带安装内随机 nonce，验证本地映射后连接已保存电脑。这个保护不能为了云推送而移除。

云通知可能在屏间没有运行时到达，电视尚未接收对应事件，也没有该事件的本地 nonce。下一步应增加独立云点击流程：

1. 用户启用后台同步后，电视取得 Token，经现有认证 TLS 通道登记到该安装和配对作用域；停用、解绑、切换作用域时撤销对应服务器登记。
2. 中转为每条待推送事件产生不可猜测、带有效期、绑定电视安装的点击凭据，并持久化其事件映射。推送只附带该凭据，不附带远控密码、目标 IP 或可直接执行的 `hostId`。
3. 用户点击后，入口 Ability 暂存凭据，等待窗口及本机存储初始化，再向中转认证查询事件；服务器同时核验安装、事件期限与现存配对关系。
4. 查询成功后执行现有事件校验、去重、可信电脑映射和串行会话切换。无网络、已过期、配对已撤销或伪造 Want 时，不自动连接。
5. 本地接收和云接收按同一 `deviceId + eventId` 去重，避免前台通知重复；保留完整正文到收件箱。

这是建议的后续协议，尚未实现。现有中转事件只存内存，重启可能丢失点击映射，后台接入前必须补齐所需持久化和过期清理。

带正文的后台推送会经过华为云推送服务。若用户选择隐藏正文，可只推送来源与提醒，点击后经已配对通道取得内容；这两种模式的数据路径与展示效果不同。

## 验收顺序

先使用无敏感内容且明确标注的合成样例，再接真实来源。每项分别记录“已构建／已安装／已实测”，不能用服务端 HTTP 成功替代电视送达。

| 场景 | 必须观察到的结果 |
| --- | --- |
| 首次 Token 登记 | 自有身份成功，拒绝时只记错误码，不输出 Token |
| 屏间前台 | 一次展示，来源及正文正确，点击使用已有会话流程 |
| 原生视频应用前台 | 记录是否出现系统横幅／通知中心条目，遥控器能否选择并进入屏间 |
| 屏间进程不在运行 | 通知仍由系统送达；点击冷启动后验证事件，再连接正确电脑 |
| 已连接其他电脑 | 点击通知先可靠释放旧会话，无并发远控或输入失灵 |
| 重复、过期、撤销配对 | 去重，不回放过期消息，不连接已删除电脑 |
| 中转断网／重启 | 明确失败或恢复，不能使用未经验证的推送字段直接连接 |
| 停用后台同步 | 后续不再向该安装发云通知；已展示通知清理策略可验证 |

## 官方来源

均在 2026-10-25 读取官方正文，不从手机支持范围推定 TV 能力。

1. [发送通知消息](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-send-alert)，页面更新 2026-09-09：TV 版本门槛、V3、点击动作、通知权限、测试频控。
2. [获取 Push Token](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-get-token)，页面更新 2026-09-09：TV 支持表、开通条件、Token 更新建议。
3. [开通推送服务](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-config-setting)，页面更新 2026-09-14：无需旧 Client ID／指纹、地区限制、自动／手动签名条件。
4. [自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)，页面更新 2026-10-10：关联注册应用、开放能力入口、Push Kit 接入后不可取消。
5. [申请推送场景化消息权益](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-apply-right)，页面更新 2026-10-14：分类与审核、TV 铃声／震动限制、VoIP 不支持 TV。
6. [场景化消息请求体结构](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/push-scenariozed-api-request-struct#request-header)，页面更新 2026-09-09：V3 JWT 鉴权与消息类型。
7. [基于服务账号生成鉴权令牌](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-jwt-token)，页面更新 2026-09-09：项目服务账号密钥、PS256 与 JWT 字段。

本机 SDK 的 `@kit.PushKit` / `@hms.core.push.pushService.d.ts` 也存在 `getToken()` 与 `SystemCapability.Push.PushService` 声明；其中包含身份非法、权益未开通、设备不支持及跨地区错误码。SDK 文件只作编译接口证据，不替代 TV 运行时验证。
