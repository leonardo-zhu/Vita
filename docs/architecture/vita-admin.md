# Vita Admin 设计：远程配置与诊断日志

**状态：M1–M3 已实现并部署到 R4S（2026-11-02），实现见 §14–§16。** §12 的待确认项已全部定下，结论写进了各节。实现见 §14。  
**2.0 变化（2026-11-04）：** 配置的使用方从 App 变成 Vita API（每轮对话读 Admin 发布到 `/opt/vita-admin/published` 的 `stable.json`，三层合并与校验规则不变）；App 不再拉配置（2026-11-05 删除了 iOS 的远程配置与诊断上报代码，内置默认值挪到 `shared/config/DefaultConfig.json`）。L3 本地调试覆盖随 App 设置页的调试卡片删除，试 prompt 用 Admin 的 Prompt 调试。诊断日志里的对话与工具事件 iOS 不再上报，对话追踪由 API 记录。Admin 新增“设备”页，经 API（服务令牌、本机回环地址）签发与吊销手机的设备令牌；“Admin 不存储、不展示业务数据”在 2.0 改为：Admin 自己不存业务数据，数据管理页（M4）经 API 读写。详见《Vita 2.0 架构设计》§3、§10.2。  
**Google 健康（2026-11-07）：** 新增“Google 健康”页，经 API 发起 Google 授权（浏览器跳 Google，回调到 API 后跳回本页）、立即同步与断开；服务端拉活动能量与睡眠，详见《Vita 2.0 架构设计》§9a。  
**目标变更（2026-11-08）：** 新增“目标变更”页（只读），列出基础代谢的变化（原因、当时的体重身高年龄性别、前后数值）与目标设置的历史（生效日、来源、发起方、能量规则），数据来自 API 的 `GET /v1/admin/goal-changes`。  
**2026-11-01 的主要决定：** Admin 与 Conduit 一样部署在 R4S，用 SQLite；配置文件也由 R4S 上的 Caddy 直接提供，不另找静态托管；现阶段不签名，只认固定的 HTTPS 地址；每次回到前台都检查配置；首期只有 `stable` 渠道；诊断日志默认开。  
**关联：** [ADR](ADR.md)（拟新增 ADR-012）、[TDD](TDD-v0.1.md) §2 / §5 / §8、[模型 Provider 集成规范](../contracts/llm-provider.md)、[Agent 工具契约](../contracts/agent-tools.md)、[Conduit（LLM Gateway）项目设计](llm-gateway-project.md)

## 1. 背景与目标

Vita 的 Agent 行为高度依赖 prompt、工具描述、模型 ID 和少量运行参数。这些内容在真实使用前很难一次调对；如果全部写死在客户端，每次调整都要改源码、重新构建并重新安装，迭代成本过高。

目标：

1. 无需重新安装 App，即可调整 prompt、工具描述、模型 ID、超时与重试等参数，并可回退。
2. 配置失效、不兼容或被篡改时，App 仍可安全使用（回退到上一次可用配置或内置默认值）。
3. 不放松任何安全边界：确认门、工具参数格式、密钥处理不受远程配置影响。
4. 配置由 **Vita Admin** 编辑、校验并发布；客户端拉取的**分发面始终是静态文件**（现阶段不签名，见 §7），Admin 进程不在客户端的请求路径上，Admin 故障不影响 App 使用。
5. Admin 同时承担客户端**诊断日志**的接收与查看（§11）。

非目标：

- 远程配置本身是**单向下发**，拉取请求不携带用户标识。日志上报是独立的通道，见 §11。
- 当前阶段不上传用户内容（饮食、健康、对话、图片）。将来若要做备份或数据收集，须另立 ADR，并经用户显式同意，见 §7 / §11。
- 不做按用户定向下发、A/B 实验。
- Admin 不存储、不展示业务数据（记录、健康数据、对话）。
- 模型调用网关（Key 托管、配额、Provider 路由）不在 Admin 内，由独立项目 Conduit 承担，见 §3.3。

## 2. 三层配置模型

优先级从高到低，前者覆盖后者：

| 层 | 来源 | 用途 |
| --- | --- | --- |
| L3 本地调试覆盖 | 设置页隐藏的调试入口，存本机（2.0 已删除） | 马上试一个模型 ID 或一段 prompt，不等发布。 |
| L2 远程配置 | R4S 上提供的静态 JSON，缓存到本机 | 日常调整 prompt、模型与参数。 |
| L1 内置默认值 | 打包进 App 的 JSON | 首次启动、离线、远程失效时的最终兜底。 |

生效值 = 按字段逐项取优先级最高且有效的一层，而不是整份替换。

实际解析顺序：`本地覆盖 > 已校验的远程配置（新拉取或本地缓存的最近一份） > 内置默认值`。

## 3. 配置内容边界

### 3.1 可以远程下发

| 分组 | 字段 | 说明 |
| --- | --- | --- |
| `llm` | `modelId`、`timeoutSeconds`、`maxRetries`、`streaming`、`reasoningEffort`、`extraBody` | 对应 Provider 规范 §3 的用户偏好。所有模型调用统一经 Conduit，`modelId` 填 Conduit 的逻辑别名（§3.3）。`reasoningEffort` 是 Responses 的 `reasoning.effort`，`extraBody` 原样合并进请求体（ADR-017）。 |
| `context` | `maxRecentMessages`、`includePersonalFoodSummary` | 对应 TDD §3.4 的上下文裁剪窗口。 |
| `prompts` | 系统 prompt、各工具的 `description` 文本 | 每项带 `id` 与 `version`。 |
| `labelImage` | `maxDimension`、`jpegQuality`、`detail` | 营养标签照片发给模型前的缩放、压缩与 `input_image` 精度（ADR-016）。 |
| `features` | 布尔开关 | 例如灰度新工具；开关只能**关闭或启用已随客户端发布的能力**。 |

### 3.2 不可远程下发（必须留在代码里）

| 项目 | 原因 |
| --- | --- |
| 确认门与 Pending 规则 | “模型只提案、用户确认后客户端写入”是安全边界（ADR-004）。强制执行在代码中，与 prompt 内容无关。 |
| 工具的参数 schema 与可用工具清单 | 改 schema 需要客户端同时能解析与校验；远程只能改**描述文字**，不能新增或改变工具。 |
| 上游模型 Key | 客户端不持有任何上游模型 Key，由 Conduit 托管。客户端只持有 Conduit 颁发的访问令牌（Keychain）：现阶段是手动创建的固定令牌，有效期、额度和吊销都由 Conduit 控制；分发前改为设备注册换取的令牌。 |
| Conduit 地址与任意 URL | 请求带有用户令牌与对话内容，配置源一旦被污染（托管账号被盗、私钥泄露、Admin 被入侵），改 URL 即可把令牌和对话送给第三方。Conduit 地址只写在客户端构建配置里（Debug / Release 区分环境），不可远程改。 |
| HealthKit 权限、写入规则、营养计算 | 属于业务规则，不由配置决定。 |

原则：**配置只能改变模型“怎么说、用哪个模型、多久超时”，不能改变“能写什么、写到哪里”，也不能改变“请求发往哪里”（只能在内置目的地中选择）。**

### 3.3 模型调用统一经 Conduit

客户端**所有**模型调用都发往 [Conduit](llm-gateway-project.md)，不内置任何 Provider 档案，不直连上游，也不在本机保存上游 Key。

- `llm.modelId` 是 Conduit 的**逻辑别名**（如 `vita-chat`）。别名到真实模型与 Provider 的映射、降级链、超时与配额都在 Conduit 维护，所以换模型、换 Provider 都不需要客户端发版，多数情况下也不需要发配置。
- Conduit 地址由构建配置决定：Debug 指向开发或测试实例，Release 指向生产实例。
- 客户端 LLM 层仍通过 Provider 协议抽象调用（便于测试替身与将来变更），但生产代码里只有 Conduit 一个实现。
- 取舍：没有直连逃生口，**Conduit 的可用性就是 Agent 的可用性**。对应要求见 Conduit 项目文档 §14。

## 4. 配置文件格式

文件为 UTF-8 JSON，使用 `schemaVersion` 管理结构，`configVersion` 管理内容。

```json
{
  "schemaVersion": 1,
  "configVersion": "2026-10-24.1",
  "minClientVersion": "0.1.0",
  "channel": "stable",
  "llm": {
    "modelId": "<Conduit 逻辑别名，如 vita-chat>",
    "timeoutSeconds": 60,
    "maxRetries": 1,
    "streaming": true,
    "reasoningEffort": "low",
    "extraBody": { "max_tool_calls": 8 }
  },
  "context": {
    "maxRecentMessages": 20,
    "includePersonalFoodSummary": true
  },
  "prompts": {
    "system": { "id": "agent.system", "version": 3, "text": "..." },
    "tools": {
      "searchReferenceFoods": { "version": 2, "description": "..." },
      "proposeRecordChange": { "version": 1, "description": "..." }
    }
  },
  "labelImage": { "maxDimension": 1600, "jpegQuality": 0.8, "detail": "high" },
  "features": {
    "exampleFlag": false
  }
}
```

约定：

- `schemaVersion`：客户端支持的最高结构版本；更高版本整份忽略。
- `configVersion`：单调递增的可排序字符串（`YYYY-MM-DD.n`），用于缓存比较与审计。
- `minClientVersion`：低于该版本的客户端忽略此配置。
- `channel`：`stable` / `dev`，见 §8。
- 未知字段忽略，缺失字段回落到下一层，保证向前兼容。
- 配置中**不得出现任何密钥或个人数据**。

## 5. 拉取与生效流程

```text
启动 / 每次回到前台 / 设置页“立即刷新”
  → GET https://vita.r4s.leonardo-zhu.me/config/stable.json（带 If-None-Match / ETag）
  → 304：不变，结束
  → 解析 → 校验（§6）
  → 通过：原子写入缓存，记录 configVersion
  → 失败：保留旧缓存，记录 AuditEvent（错误码），不打扰用户
下一次“开始新一轮对话”时读取最新生效配置
```

要点：

- **不在一轮对话中途切换配置**，也不在存在活跃 Pending 时切换 prompt，避免同一次提案前后行为不一致。新配置只在新一轮请求开始时生效。
- 不轮询，也不设最小间隔：只在启动、回到前台和手动刷新时检查。iOS 上划走 App 多半只是挂起，所以触发点是“回到前台”而不只是冷启动。文件没变时服务器只回 304，成本可以忽略。同一时刻只跑一次拉取，进行中的再次触发直接忽略。
- 设置页显示当前生效的 `configVersion` 与上次检查时间，并提供“立即刷新”。
- 拉取在后台进行，不阻塞启动与对话；超时 5 秒，失败不重试风暴（下次前台再试）。
- 缓存存于 App Support（非敏感），读取失败等同没有缓存。
- 回滚：发布方把上一个已知良好的内容以**更高的 `configVersion`** 重新发布即可；客户端不支持降版本，避免被旧文件回放。

## 6. 校验与回退

拉取成功后（将来启用签名时为验签通过后），在生效前做结构与取值校验，任何一项失败则**整份拒绝**并继续使用当前生效配置：

| 字段 | 规则 |
| --- | --- |
| `schemaVersion` | ≤ 客户端支持版本。 |
| `minClientVersion` | ≤ 当前客户端版本。 |
| `configVersion` | 高于当前缓存。 |
| `llm.modelId` | 非空字符串，长度上限。 |
| `llm.timeoutSeconds` | 5–180。 |
| `llm.maxRetries` | 0–3。 |
| `llm.reasoningEffort` | `default` / `none` / `minimal` / `low` / `medium` / `high` / `xhigh` / `max`。 |
| `llm.extraBody` | 最多 20 项，不能含 `model`、`instructions`、`input`、`tools`、`stream`、`store`、`reasoning`、`previous_response_id`。 |
| `labelImage` | 长边 512–4096，JPEG 质量 0.3–1，`detail` 为 `low` / `high` / `xhigh`。 |
| `context.maxRecentMessages` | 1–100。 |
| `prompts.*.text/description` | 非空，长度上限（防止异常膨胀导致请求超限）。 |
| `prompts.tools` 的键 | 必须是客户端已知工具；未知工具名忽略。 |

回退链：`新配置校验失败 → 上一份已校验缓存 → 内置默认值`。App 在任何层级失败时都必须可用。

## 7. 完整性与安全

prompt 会直接改变模型行为，因此配置的**来源可信**比传输加密更重要。

- 传输：仅 HTTPS。配置地址写在客户端构建配置里，只认这一个地址，不跟随重定向到其他主机，不可远程改。
- **签名：现阶段不做**（2026-11-01 决定）。理由：
  - 分发面和 Admin 都在 R4S 上。私钥若也放在 R4S，拿下 R4S 的人可以同时改文件、重新签名，签了等于没签；要真正有效就得把私钥放到另一台机器或 KMS，对个人使用阶段过重。
  - 传输途中被改由 HTTPS 和固定地址挡住。
  - 远程配置能改的范围本来就有限（§3.2），最坏情况是 prompt 被改坏，令牌与对话不会被送到别处。
- **将来启用签名时**（分发给其他人之前重新评估）：发布方用 Ed25519 私钥对配置签名，生成 `config.json.sig`，带 `keyId`；客户端内置公钥（可多把以支持轮换），**先验签再解析**。私钥不进入仓库、不进入 App，也不放在 Admin Web 进程里。数据模型里的 `signature`、`key_id` 字段为此预留。
- 无论是否签名，强制规则（§3.2）都由代码执行：恶意或错误的 prompt 最多让模型“说错话”，不能绕过确认门去写数据，也不能改变请求目的地。
- 配置内容不发送给任何第三方，除了作为请求的一部分发给已配置的模型 Provider（与现状一致）。
- 隐私：
  - 拉取配置的请求不携带用户标识；分发面只是静态文件，看不到用户数据。
  - **当前阶段不上传任何用户内容**（饮食、健康、对话、图片）。诊断日志只含元数据（§11）。
  - 将来如需备份或收集用户内容，须：新 ADR、独立同意开关、独立存储与保留期、支持删除；不得复用诊断日志通道的默认开关。

## 8. 发布与托管

### 8.1 托管

**决定（2026-11-01）：不另找对象存储，配置文件放在 R4S 上，由 Caddy 直接提供。**

- 域名 `vita.r4s.leonardo-zhu.me`，一个域名按路径分：
  - `/config/*`：Caddy 的 `file_server` 直接提供发布目录里的文件，不经过 Next.js 进程。Admin 停机、重启或部署中，配置照样能取到。
  - `/admin/*`：管理后台，转给 Next.js。
  - `/api/ingest/*`：客户端诊断上报，转给 Next.js，鉴权与 `/admin/*` 分开。
- 发布时 Admin 把文件**原子写入**发布目录（先写临时文件再 rename），Caddy 自带 ETag，客户端用 If-None-Match 拿到 304。
- 理由：Conduit 也在这台 R4S 上，R4S 不可用时对话本来就用不了，把配置单独放到云上换不来多少可用性；取不到配置时客户端退回缓存或内置默认值，不影响使用。
- 原先考虑过的阿里云 OSS、腾讯云 COS、Cloudflare R2、GitHub Pages 均不采用。将来如需换托管，只需替换 `Publisher` 实现（§11.6），客户端改构建配置里的地址。

### 8.2 渠道

**首期只有 `stable`。** 试验性 prompt 用 Admin 的试跑（§11.2）和~~手机上的本地调试覆盖（§9）~~（2.0 已删除）验证。配置文件里保留 `channel` 字段，数据模型按渠道建表，以后需要时再加 `dev` 渠道（文件 `/config/dev.json`）、晋升按钮和客户端的渠道切换。

### 8.3 发布流程

1. 在 Admin 中编辑草稿。
2. Admin 服务端校验（与客户端共用同一份 schema，复用 §6 规则），并调用 Conduit `/v1/models` 确认 `modelId` 别名存在；可选对 prompt 做试跑。
3. 二次确认后发布：`configVersion` 由服务端自增，生成 `stable.json` 写入发布目录，新增一条 release 并记录审计。
4. 回滚即以更高 `configVersion` 重新发布旧内容（§5）。

## 9. 本地调试覆盖（L3，2.0 已删除）

- 位置：设置页的隐藏入口（例如连续点击版本号）。
- 范围：仅 `llm.modelId`、`llm.timeoutSeconds`、系统 prompt 文本（渠道选择等加 `dev` 渠道时再做）；不提供对 §3.2 项目的覆盖。
- 存储：本机，非敏感；不上传。
- 界面显示当前每个覆盖项的来源（本地 / 远程 vX / 内置），避免“不知道现在到底用的哪份”。
- 一键清除全部覆盖。

实现（2026-10-31）：设置页连点版本号五次出现“调试覆盖”卡片，可覆盖模型别名、超时秒数（5–300）与系统 prompt，每项显示来源；存在 UserDefaults（`vita.config.override`），下一轮对话开始时生效。

注意：本地覆盖的超时上限是 300 秒，比远程配置的 180 宽，便于调试慢模型。

## 10. 可观测与测试

**审计：** 每次模型请求在 `AuditEvent`（或诊断元数据）中记录生效的 `configVersion`、各字段来源层级与 prompt 版本号，不记录 prompt 全文。配置拉取失败、校验失败（以及将来的验签失败）各有独立错误码。这些字段同时是诊断日志的关联维度（§11）。

**测试：**

- 拉取：200、304、超时、非 2xx、重定向到其他主机被拒绝、进行中再次触发被忽略。
- 验签（启用签名时）：合法、签名被改、内容被改、缺签名。
- 校验：每条 §6 规则的越界与缺失用例。
- 回退链：远程失败回缓存、缓存损坏回内置、全部缺失仍可启动。
- 生效时机：对话中途与存在活跃 Pending 时拉到新配置，不立即生效。
- 版本：低 `schemaVersion`、高 `schemaVersion`、`minClientVersion` 不满足、`configVersion` 回退被拒绝。
- 优先级：本地覆盖 > 远程 > 缓存 > 内置，按字段合并。

建议在 Platform 层定义 `ConfigProvider` 协议，业务层只依赖它；测试使用内存实现。

## 11. Vita Admin 与日志

### 11.1 职责边界

| 系统 | 职责 | 不负责 |
| --- | --- | --- |
| **Vita Admin**（Next.js） | 配置的编辑、校验、版本历史、发布（将来加签名与渠道晋升）；接收并查看客户端诊断日志；Admin 操作审计 | 模型转发与 Key 托管；业务数据 |
| **分发面**（R4S 上 Caddy 的 `/config/*`） | 提供 `stable.json` 静态文件 | 一切动态逻辑 |
| **Conduit**（独立项目） | 模型调用网关：鉴权、Key 托管、路由、配额、调用日志 | 配置与客户端诊断 |

客户端的 `ConfigProvider` 协议不变，数据来源仍是分发面。

与 Conduit 的关系：
- Conduit 有自己的管理后台（面向多个应用的网关配置：上游、别名、配额）；Vita Admin 只管 Vita 自己的配置与诊断日志，两者不合并。
- Admin 的 Prompt 试跑通过 Conduit 发请求，使用 Admin 专用的 Conduit 令牌（限定别名与额度），不绕过网关。
- 配置里的 `modelId` 必须是 Conduit 上已存在的别名。Admin 发布前可调用 Conduit 的 `/v1/models` 校验别名是否存在。

### 11.2 Admin 配置功能

- 草稿 / 发布 / 历史 / 回滚；`configVersion` 服务端自增保证单调。
- 服务端校验，与客户端共用 schema。
- 首期只有 `stable` 渠道；`dev` 渠道与一键晋升以后再加（§8.2）。
- 任意两个版本的 diff，prompt 文本要有文本级 diff。
- Prompt 试跑：用样例输入对草稿跑一次模型，发布前验证。
- 系统 prompt 与各工具的 `description` 都可编辑（§3.1）；工具清单与参数 schema 不可改。
- 发布二次确认；每次操作记录操作者、时间与 diff。
- Admin 登录：复用 Conduit 的方案（§11.6）。管理面在公网域名上，登录失败按 IP 限速。

### 11.3 日志分类

| 类别 | 内容 | 来源 | 当前状态 |
| --- | --- | --- | --- |
| **Admin 运维日志** | 访问、错误 | Admin 服务器本地日志文件 | 做 |
| **Admin 变更审计** | 谁在何时改了什么、发布了什么、diff | **数据库**（需要查询、diff、回滚，不放文件） | 做 |
| **客户端诊断日志** | 仅元数据：错误码、`configVersion`、prompt 版本、模型别名、耗时、token 数、App 版本、轮换的匿名安装 ID | 客户端上报 | 做 |
| **模型调用日志** | 请求元数据、成本、降级路径 | Conduit | 由 Conduit 负责 |
| **用户内容** | 对话、饮食、健康数据、图片 | 客户端上报 | **当前不做**，见 §7 |

### 11.4 诊断日志上报

- 客户端有设置页开关，**默认开**（2026-11-01 决定，现阶段只有开发者本人使用）。关闭时不上报。分发给其他人之前，加首次启动时的告知与选择，并重新评估默认值。
- 上报与配置拉取是独立通道，使用独立端点与独立鉴权，不复用配置请求。
- 上报内容只含上表“客户端诊断日志”字段，不含 prompt 全文、消息体与任何用户内容。客户端在发送前过滤，服务端再兜底校验 schema 并拒绝多余字段。
- 每条记录带 `dataClass` 字段（当前仅 `diagnostic`），为将来区分“用户内容”类预留，授权与保留期可按级别分开。
- 接口要求：限流、体积上限、schema 校验。鉴权现阶段只用匿名安装 ID 加服务端限流，`installs.revoked` 可封禁某个安装 ID；分发前与 Conduit 的设备注册一起改为 App Attest。
- 保留期默认 30 天自动清理；支持按安装 ID 删除。
- 查询：按时间、错误码、`configVersion`、App 版本筛选；聚合视图（错误率、P95 耗时）。
- 关联：请求带 `X-Request-Id`，与 Conduit 的调用日志可对应；日志带 `configVersion` 与 prompt 版本，用于判断某次发布前后的效果变化。
- 告警暂不做。

### 11.5 分期

| 阶段 | 内容 |
| --- | --- |
| M1 | 登录、配置 CRUD、服务端校验、发布到 `/config/stable.json`、变更审计；部署到 R4S；客户端拉取与设置页“立即刷新”（已完成，§14） |
| M2 | Prompt 试跑、diff（已完成，§15） |
| M3 | 诊断日志上报与查看；补 ADR 与隐私说明（已完成，§16） |
| 以后 | `dev` 渠道与晋升、配置签名（分发前评估）、告警、用户内容类数据（须新 ADR） |

模型网关相关里程碑见 Conduit 项目文档。

### 11.6 仓库位置与技术栈

Admin 与客户端同仓库，位于 `admin/`；配置的 JSON Schema 位于 `shared/config-schema/`，Admin 发布前校验与 iOS 测试夹具共用同一份。Conduit 是独立仓库。

| 部分 | 选择 | 说明 |
| --- | --- | --- |
| 框架 | Next.js（App Router），pnpm | 管理页面在 `/admin/*`，客户端诊断上报在 `/api/ingest/*`，两者路由与鉴权分开，首期同进程，保留拆分余地。 |
| 前端 | 与 Conduit 同款栈：shadcn/ui（Base UI）、Tailwind CSS 4、TanStack Query / Table、react-hook-form + zod | 界面风格与 Conduit 一致；从头搭，不搬 NewAPI 的前端代码，所以不带 AGPL。 |
| 部署 | R4S（与 Conduit 同机），容器化，经 Caddy 对外 | 域名 `vita.r4s.leonardo-zhu.me`；`/config/*` 由 Caddy 直接提供（§8.1）。CI 构建镜像并部署，方式与 Conduit 相同。 |
| 存储 | SQLite（`node:sqlite`），同机文件 | 与 Conduit 一致，不额外跑数据库服务。配置版本、审计、诊断事件；`jsonb` 字段存为 JSON 文本。 |
| 签名 | 现阶段不做（§7） | 启用时用独立的签名步骤，Web 进程不持有私钥。 |
| 发布 | `Publisher` 接口，首个实现原子写入 R4S 上的发布目录 | 发布目录以卷挂载给 Caddy；换托管只换实现。 |
| 登录 | 复用 Conduit：账号密码 + Passkey | 单管理员，账号与 scrypt 密码哈希来自环境变量（`ADMIN_USERNAME` / `ADMIN_PASSWORD_HASH`），不建用户表；登录后发 `SESSION_SECRET` 签名的 HttpOnly cookie，服务端不存会话；登录失败按 IP 限速；Passkey 用 `@simplewebauthn/server`。Next.js 只监听 127.0.0.1，限速信任 Caddy 的 `X-Forwarded-For`。 |

### 11.7 数据模型（草案）

SQLite 中 `jsonb` 字段存为 JSON 文本；`signature`、`key_id` 为将来签名预留，现阶段为空。

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `config_drafts` | `channel`、`content`(jsonb)、`base_release_id`、`updated_by`、`updated_at` | 每个渠道一份当前草稿。 |
| `config_releases` | `channel`、`config_version`、`content`(jsonb)、`content_hash`、`signature`、`key_id`、`published_by`、`published_at`、`rollback_of`、`note` | 不可变；`(channel, config_version)` 唯一。回滚是新增一条内容取自旧版本的 release。 |
| `channels` | `name`、`current_release_id` | 当前对外发布的版本指针。 |
| `admin_audit` | `actor`、`action`、`target_type`、`target_id`、`diff`(jsonb)、`ip`、`at` | 仅追加；不允许修改与删除。 |
| `passkeys` | 凭证 ID、公钥、计数器、名称、创建与最近使用时间 | 管理员账号本身在环境变量里，不建用户表（同 Conduit）。 |
| `installs` | `install_id`、`first_seen`、`last_seen`、`revoked` | 匿名安装 ID，不含设备标识或用户信息。 |
| `diagnostic_events` | `received_at`、`install_id`、`data_class`、`event_type`、`error_code`、`config_version`、`prompt_versions`、`model_alias`、`latency_ms`、`tokens_in`、`tokens_out`、`request_id`、`app_version` | 只存白名单字段，不存自由文本；按保留期清理任务删除。 |

诊断事件的具体类型清单（配置拉取失败、校验失败、模型请求失败等）与字段取值待在 M3 前补全，作为客户端与服务端共同的 schema 放入 `shared/`。

## 12. 已确认（2026-11-01）

原“待确认”各项的结论，编号不变：

1. **托管**：不另找静态托管，配置文件放在 R4S，由 Caddy 直接提供；域名 `vita.r4s.leonardo-zhu.me`，配置在 `/config/*`（§8.1）。
2. **签名**：现阶段不做；只认构建配置里的唯一 HTTPS 地址，不跟随跨主机重定向。分发给其他人之前重新评估（§7）。
3. **拉取时机**：不轮询，不设 6 小时间隔；启动、每次回到前台、设置页“立即刷新”时检查，靠 ETag 拿 304（§5）。
4. **`dev` 渠道**：首期不要，只有 `stable`；试验用 Admin 试跑~~与本地调试覆盖（§8.2）~~（2.0 起只有试跑）。
5. **工具描述**：允许远程修改（§3.1），工具清单与参数 schema 仍在代码里。
6. **诊断日志**：默认开，设置页可关；分发前加首次启动告知并重新评估默认值（§11.4）。（2026-11-05：iOS 的诊断上报已删除，Admin 诊断页只剩历史数据。）
7. **设备鉴权**：现阶段用匿名安装 ID 加服务端限流与封禁；分发前与 Conduit 的设备注册一起改为 App Attest（§11.4）。
8. **开发环境**：不单独建 Conduit 开发实例，Debug 与 Release 都指向 `https://conduit.r4s.leonardo-zhu.me`（`ios/project.yml`）；Conduit 不可用时沿用 Chat 页现有的错误提示。
9. **私钥存放**：不签名，暂无私钥；启用签名时私钥不放在 Admin Web 进程里（§7）。
10. **Admin 部署**：R4S，与 Conduit 同机、同样经 Caddy 和 CI 部署；SQLite；登录复用 Conduit 的账号密码 + Passkey（§11.6）。

## 13. 对现有文档的拟议改动

- ADR 新增 ADR-012：采用三层配置与静态远程配置（现阶段不签名），由 Vita Admin 编辑与发布，分发面保持静态。
- ADR 新增 ADR-013：客户端所有模型调用统一经独立网关 Conduit，客户端不直连上游、不持有上游 Key。
- ADR 新增 ADR-014：客户端诊断日志上报（仅元数据，可开关）；用户内容上传当前不做，将来须另立 ADR。
- TDD §2 / §8：加入 `ConfigProvider`、Conduit 调用与诊断日志的隐私说明。
- Provider 规范 §3：去掉用户自带 Key 与直连方舟，改为 Conduit 令牌鉴权；Model ID（别名）与超时来源改为“生效配置”。
- 实施计划：Phase 0 加入内置默认配置与 `ConfigProvider` 协议；Phase 5 前完成远程拉取、校验与调试覆盖；诊断日志与 Admin 按 §11.5 分期。

## 14. 实现现状（2026-11-01，M1）

> 历史记录：这里描述的 iOS 远程配置拉取与诊断上报已于 2026-11-05 删除（App 2.3.1），配置改由 Vita API 读取，见文首的 2.0 说明。

**Admin（`admin/`）**：Next.js 16 + SQLite（`node:sqlite`），前端 shadcn/ui（Base UI）+ Tailwind 4，说明与首次部署步骤见 [`admin/README.md`](../../admin/README.md)。

- 登录：照搬 Conduit 的单管理员、签名会话 cookie、按 IP 限速与 Passkey；注册 Passkey 前再确认一次密码。
- 配置页：按字段编辑（模型与请求、系统 prompt、11 个工具描述、开关、最低客户端版本），保存草稿后显示校验结果与将要发布的文件；发布时二次确认并列出相对线上的改动。
- 与 App 内置默认值文字相同的 prompt 不写进发布文件，App 用自带的那份；改过的 prompt 版本号自动取（内置版本、历史最高）+1，文字不变就沿用。
- 发布在一个事务里写 release、移动渠道指针、写审计、原子写 `stable.json`；写文件失败整体回滚。回滚是以新版本号重新发布旧内容。
- `configVersion` 按北京时间的日期生成，序号按数字比较（`.10` 大于 `.9`），并且总比内置默认值的版本新。
- 审计表有触发器，禁止修改和删除。
- 发布前调 Conduit `/v1/models` 检查别名：别名不存在时拦截；没配置密钥或连不上 Conduit 时只提示。
- 部署：`admin/Dockerfile`（构建上下文是仓库根目录）、`admin/deploy/compose.yaml`（端口 3013）、`admin/deploy/Caddyfile.snippet`、`.github/workflows/vita-admin-deploy.yml`。Caddy 容器需要只读挂载 `/opt/vita-admin/published`，首次部署要重建一次 Caddy。

**内置默认值**：工具描述从 `AgentToolCatalog` 的 Swift 代码移到 `DefaultConfig.json` 的 `prompts.tools`（每个 v1），代码里只留名字和参数 schema。原因：`ConfigResolver` 只接受内置默认值里有的工具名，之前内置为空，远程下发的工具描述会被全部忽略；Admin 也要从这份文件读工具清单和默认文字。

**客户端**：

- `BuildEnvironment.remoteConfigURL`：`REMOTE_CONFIG_URL`（`project.yml`，Debug / Release 都是 `https://vita.r4s.leonardo-zhu.me/config/stable.json`），只允许 HTTPS。
- `RemoteConfigService`：启动和每次回到前台（`scenePhase == .active`）、设置页“立即刷新”时检查；带 ETag，5 秒超时，同一时刻只跑一次；拒绝跨主机重定向。
- `RemoteConfigValidator`：§6 的规则，再加上版本号不得比缓存旧（防回放）；版本相同按“没变化”处理。
- `FileRemoteConfigCache`：`Application Support/RemoteConfig/cache.json`，存原始字节与 ETag；启动时重新校验后交给 `LayeredConfigProvider`。
- 设置页“配置”一行显示生效版本、来源（内置 / 远程）、上次检查结果和“立即刷新”。

**部署（2026-11-01）**：CI 构建与部署成功，`vita-admin` 容器 healthy，内存约 40MB；`https://vita.r4s.leonardo-zhu.me/admin/login` 可访问。R4S 侧的改动记录在 HomeLab 的 `notes/2026-11-01-vita-admin-部署与-runner-入口脚本.md`。

**没验证的**：Passkey 注册与登录没有实测；还没发布过配置，App 拉到真实配置的整条链路还没走。

## 15. 实现现状（2026-11-02，M2）

**版本 diff**：

- 取值类字段列前后值；系统 prompt 与工具描述用 jsdiff 按词比较（`Intl.Segmenter` 中文分词），删掉的标红划线、新增的标绿。逻辑在 `admin/src/lib/config-diff.ts`。
- 出现在三处：发布详情（相对上一版）、版本对比页（任选两项：任一已发布版本、当前草稿、App 内置默认值）、配置页的发布预览（已保存的草稿相对线上）。

**Prompt 试跑**（`/admin/trial`）：

- 选“线上”“当前草稿（已保存的）”或“两边对比”，写一句用户消息，经 Conduit `/v1/responses`（非流式、`store: false`）跑一轮，并排显示文字回复、推理摘要、会调用的工具和参数、耗时、token 与 `X-Request-Id`。
- 请求和 App 一致：系统指令是配置里的系统 prompt 加“当前状态”一段，工具定义是同一份参数 schema 加配置里的描述。“当前状态”在 App 里按真实数据生成，试跑页给一段可改的样例（今天、空记录、空食品库）。
- 只跑第一步，工具不执行：用户数据都在手机上，Admin 拿不到。
- 每次试跑存进 `prompt_trials` 表，页面显示最近 40 条，并写一条审计（`trial`）。
- 需要 `.env` 里配置 `CONDUIT_BASE_URL` 和 `CONDUIT_API_KEY`（Admin 专用的 Conduit 密钥），没配时页面提示、按钮不可用。

**工具参数 schema 移到 `shared/agent-tools/tool-parameters.json`**：原来写在 `AgentToolCatalog` 的 Swift 源码里，Admin 试跑拿不到。现在 iOS 打包这份 JSON 并从中读取（`project.yml` 把它列为资源），Admin 在构建时拷入。远程配置仍然改不了它，只随客户端发布；iOS 测试保证它覆盖全部工具。

**没验证的**：没有用真实的 Conduit 和模型跑过试跑（本地用模拟的 Conduit 走通了界面与存储）；生产环境要先配好 Conduit 密钥。

## 16. 实现现状（2026-11-02，M3）

> 历史记录：这里描述的 iOS 远程配置拉取与诊断上报已于 2026-11-05 删除（App 2.3.1），配置改由 Vita API 读取，见文首的 2.0 说明。

**事件与格式**：`shared/diagnostics/batch.schema.json`，示例 `example-batch.json`。iOS 测试检查编码与示例逐字段一致，Admin 测试用同一个示例校验 schema。三类事件：

| 事件 | 什么时候记 | 字段 |
| --- | --- | --- |
| `chat_turn` | 一轮对话保存、失败或取消 | 结果、错误码（`llm.*` 或 `app.unexpected`）、总耗时、模型来回轮数、工具调用数、token（入 / 出）、是否生成确认卡、是否“说生成了卡却没调提案工具”、是否超出步骤上限 |
| `tool_call` | 手机上执行完一个工具 | 工具名、结果码（`ok` 或工具返回的错误码）、耗时、工具描述版本 |
| `config_fetch` | 一次远程配置检查 | 结果（更新 / 没变 / 失败）、错误码、耗时 |

都带 `eventId`（去重）、发生时间、`dataClass: diagnostic`、生效的 `configVersion`，对话与工具事件带 `X-Request-Id`。批次带匿名安装 ID（30 天换一个）、App 版本与系统版本。错误码在客户端压成 `a-z0-9_.`，不会带出别的文字。

“说生成了卡却没调提案工具”是按回复文字判断的（含“确认卡”且含“生成 / 下面 / 下方”，并且这一轮没生成卡），用来跟踪 Phase 5 里观察到的模型问题，只记真假，不记回复。

**客户端**：`DiagnosticsService` 记到 `Application Support/Diagnostics/queue.json`（最多 500 条），攒够 20 条或回到前台时按 100 条一批 POST 到 `DIAGNOSTICS_URL`（`project.yml`，`https://vita.r4s.leonardo-zhu.me/api/ingest/events`），拒绝跨主机重定向。2xx 删除已发的；400 / 413 丢掉这批；403（被封禁）清空并停止本次运行的上报；其他失败留着下次再发。设置页“诊断日志”开关默认开，关掉时清空队列。

**服务端**：`POST /api/ingest/events`，不看登录 cookie。体积上限 64KB、每批最多 100 条；按 schema 校验，多余字段整批拒绝；每个 IP、每个安装 ID 10 分钟最多 60 批；被封禁的安装 ID 返回 403；`eventId` 去重；早于 30 天或晚于现在一天的事件丢弃；每小时最多清理一次 30 天前的数据。

**查看**（`/admin/diagnostics`）：按时间（24 小时 / 7 天 / 30 天）、配置版本、App 版本、错误码筛选；对话数、失败率、成功轮的 P50 / P95 耗时、“说有卡却没调工具”次数；按配置版本对比；错误码排行；每个工具的次数、失败率、P95 与结果码分布；最近 100 条事件；安装列表，可删除某个安装的全部数据或封禁它。删除与封禁写审计。

**部署（2026-11-02）**：已上线。模拟器上的 App 把配置拉取事件报到了生产环境（当时还没发布配置，记为 `config.http_404`），Admin 收到并入库。

**没验证的**：真实对话产生的 `chat_turn` / `tool_call` 还没在生产环境看到；真机没试过。

## 17. 实现现状（2026-11-05，2.0 M4）

新增三页，都经 Vita API（服务令牌、本机回环地址），Admin 自己不存业务数据；每次改动在 API 与 Admin 两边都记审计。

- **对话**（`/admin/conversations?date=`）：有对话的日期列表（条数、已排除数）；当天的消息，带标签照片；每条可设为“不再发给模型”，或“从这里开始都不再发给模型”（rewind），消息本身保留，可恢复。下面是每轮的追踪：输入、回复、工具调用的参数与结果、推理、轮数、输入 token、耗时、配置版本、生成的确认卡。
- **记录**（`/admin/records?date=`）：当天的记录与合计；改某一项的用量（有克数按新用量重算，否则按倍数）、删一项、删整条。带当天的 revision，期间手机上改过会提示刷新。
- **食品库**（`/admin/foods`）：个人食品与生效版本的营养值、标签照片。基本信息（名称、品牌、常用叫法、净含量、备注）直接改；营养值改动存为新版本（`POST /v1/foods/:id/versions`，带打开时的生效版本，期间被改过会拒绝），旧版本留在版本历史里，已有记录按当时的版本不变；删除只做标记。

标签照片经 `/admin/labels/:id` 转发：登录后才能看，浏览器拿不到服务令牌。

