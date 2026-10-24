# MateTV 后台通知：Push Kit 接入核验

核验日期：2026-10-25。本文记录官方能力和实施条件。电视端登记／撤销与点击校验、中转持久化和 PS256 推送实现已完成，新电视包已构建、签名并安装。用户授权自有项目开通 Push 及通知全文经过华为转发后，Token 获取、TLS 登记和其他视频应用前台期间的通知中心到达已实测。通知中心点击后连接 Mac mini 已实测；用户开启横幅与置顶并在多个应用中测试后，仍未看到可靠的跨应用弹窗。分项记录见 `notifications-implementation-plan.md`。

## 已确认的 TV 能力

华为官方明确列出 **TV 从 HarmonyOS 5.1.1/API 19 起支持通知消息与获取 Push Token**。本项目实机 HarmonyOS 6.1 满足该版本门槛。本项目已用自有应用身份取得 Token，并实测系统通知中心后台到达；这不等于正式自分类权益已获批，也不替代横幅和点击验收。

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

**官方自动签名文档明确写明：“Push Kit（推送服务）开放能力接入后不可取消。”** 本项目已向用户说明并获得授权，自有应用的 Push 能力现已开通。新 Profile 已核实含 `com.huawei.service.push.base_service`，安装后 `getToken()` 与认证登记成功。后续新项目仍须在开通前说明此属性。

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

服务账号 JSON 和私钥只保存在中转服务的受限本地目录，不进 Git、日志或电视 HAP。`project_id` 必须与屏间 AGC 项目一致。电视只登记自身 Push Token，不能获得项目的发送权限。本项目专用服务账号已在用户授权后创建并以 0600 权限保存，本地 PS256 签验已通过；项目数据处理位置已配置为中国。

WORK 自分类权益已获批。用户取消微信后，华为控制台已删除 IM 权益并确认立即失效，列表仅保留 WORK。运行配置已设为 `WORK`、`testMessage:false`，本地检查通过并重启中转；正式类别下的横幅仍待实测。以下保留频控与分类规则供后续维护：

- 未获自分类权益的消息默认归为 `MARKETING`，每设备每应用每日仅 2 或 5 条。官方分类表明确该类为“静默通知，仅在通知中心（更多通知）里展示消息”；开启横幅开关不等于改变云端分类。
- 调试可设置 `pushOptions.testMessage=true`，每项目每日全网最多 1000 条，单次最多 10 个 Token；这不是正式频控豁免方案。
- Codex 完成／待处理提醒可按真实场景评估 `WORK`。是否批准由华为审核决定。
- 应用只接受 Codex 任务事件，不采集或转发微信；配置不再接受 IM，不能通过修改允许列表恢复个人消息。
- 官方申请入口为「增长 → 推送服务 → 配置 → 对应应用 → 自分类权益申请」。需提供实际用途及消息示例；文档标示约 3 个工作日审核，通过后约 5 分钟生效。

## 与现有实现的衔接

现有前台服务使用 TLS 轮询并持久化本地事件，系统通知点击携带安装内随机 nonce，验证本地映射后连接已保存电脑。这个保护不能为了云推送而移除。

云通知可能在屏间没有运行时到达，电视尚未接收对应事件，也没有该事件的本地 nonce。已实现独立云点击流程：

1. 用户启用后台同步后，电视取得 Token，经现有认证 TLS 通道登记到该安装和配对作用域；停用、解绑、切换作用域时撤销对应服务器登记。
2. 中转为每条待推送事件产生不可猜测、带有效期、绑定电视安装的点击凭据，并持久化其事件映射。推送只附带该凭据，不附带远控密码、目标 IP 或可直接执行的 `hostId`。
3. 用户点击后，入口 Ability 暂存凭据，等待窗口及本机存储初始化，再向中转认证查询事件；服务器同时核验安装、事件期限与现存配对关系。
4. 查询成功后执行现有事件校验、去重、可信电脑映射和串行会话切换。无网络、已过期、配对已撤销或伪造 Want 时，不自动连接。
5. 本地接收和云接收按同一 `deviceId + eventId` 去重，避免前台通知重复；保留完整正文到收件箱。

上述协议已实现。配置 `statePath` 后，事件、游标、安装登记、点击映射和有限重试队列保存在受限 SQLite 中，并清理过期与已解绑记录；未配置持久化时拒绝后台登记，不使用易失点击映射。重启恢复、过期、撤销和伪造请求已通过自动化测试，通知中心点击连接 Mac mini 已实测；进程终止后的冷启动仍须独立验收。

带正文的后台推送会经过华为云推送服务，用户已明确同意当前全文转发模式。若用户选择隐藏正文，可只推送来源与提醒，点击后经已配对通道取得内容；这两种模式的数据路径与展示效果不同。

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

## 当前实机记录

- 已构建、已安装：自有 Push 身份的电视 HAP；签名身份迁移经用户批准，备份和恢复校验后完成。
- 已实测：Token 获取、认证 TLS 登记、合成消息在其他视频应用前台时进入系统通知中心。
- 已实测：从通知中心点击云通知能打开屏间并连接 Mac mini。
- 当前未通过：用户已开启横幅及置顶，在多个应用和视频播放中仍看不到可靠弹窗。此前短暂出现／看到横幅的反馈已被用户纠正，不作为成功证据。
- 已停止：每分钟合成通知自动化，重复发送同类别消息不能验证修复。
- 待验收：屏间进程终止后的冷启动点击、前台去重和撤销等完整实机矩阵，以及 WORK 类别的横幅展示效果。微信已撤除，不再安排该来源验收。

通知中心收到合成消息不能据此承诺所有应用场景均有横幅。个人消息来源已移除；仅保留 Codex。

## 跨应用弹窗的处理结论

当前可以确认送达与点击链路正常；`MARKETING` 的官方静默展示规则是明确限制，尚不能据此认定这台电视的全部横幅行为只有这一项原因。不要把 `foregroundShow:false` 解释为“只要有其他应用在前台就禁止通知”；该字段用于接收应用自身前台展示策略，不能用开启它来保证覆盖其他视频应用。

WORK 已获批并用于 Codex 正式发送，下一步按真实任务场景复测。官方服务与通讯类说明没有承诺 TV 全屏视频必定显示横幅，因此审批成功也不等于验收成功。

另一路是应用自己创建跨应用悬浮窗。本机 SDK 存在 `TYPE_FLOAT`，`createWindow` 标注需要 `ohos.permission.SYSTEM_FLOAT_WINDOW`，但接口存在不证明当前 TV 允许该能力，更不保证后台进程持续接收事件。当前云通知由系统投递，并不为普通通知提供任意后台代码执行。故尚无已验证、无需额外后台机制的自绘弹窗替代方案；不把后台轮询或强行拉到前台作为本次修复。现阶段保留可靠的通知中心和点击连接。

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
