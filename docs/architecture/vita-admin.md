# Vita Admin 设计（草案）：远程配置与诊断日志

**状态：草案，待评审。** 客户端已实现 §2 的三层合并（`ConfigResolver` / `LayeredConfigProvider`）与 §9 的本地调试覆盖；§5 的拉取、§7 的验签与 Admin 本身尚未开始，待 §12 第 1、2、9 条定下。  
**关联：** [ADR](ADR.md)（拟新增 ADR-012）、[TDD](TDD-v0.1.md) §2 / §5 / §8、[模型 Provider 集成规范](../contracts/llm-provider.md)、[Agent 工具契约](../contracts/agent-tools.md)、[Conduit（LLM Gateway）项目设计](llm-gateway-project.md)

## 1. 背景与目标

Vita 的 Agent 行为高度依赖 prompt、工具描述、模型 ID 和少量运行参数。这些内容在真实使用前很难一次调对；如果全部写死在客户端，每次调整都要改源码、重新构建并重新安装，迭代成本过高。

目标：

1. 无需重新安装 App，即可调整 prompt、工具描述、模型 ID、超时与重试等参数，并可回退。
2. 配置失效、不兼容或被篡改时，App 仍可安全使用（回退到上一次可用配置或内置默认值）。
3. 不放松任何安全边界：确认门、工具参数格式、密钥处理不受远程配置影响。
4. 配置由 **Vita Admin** 编辑、校验、签名并发布；客户端拉取的**分发面始终是已签名的静态文件**，Admin 不在客户端的请求路径上，Admin 故障不影响 App 使用。
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
| L3 本地调试覆盖 | 设置页隐藏的调试入口，存本机 | 马上试一个模型 ID 或一段 prompt，不等发布。 |
| L2 远程配置 | 静态托管的已签名 JSON，缓存到本机 | 日常调整 prompt、模型与参数。 |
| L1 内置默认值 | 打包进 App 的 JSON | 首次启动、离线、远程失效时的最终兜底。 |

生效值 = 按字段逐项取优先级最高且有效的一层，而不是整份替换。

实际解析顺序：`本地覆盖 > 已校验的远程配置（新拉取或本地缓存的最近一份） > 内置默认值`。

## 3. 配置内容边界

### 3.1 可以远程下发

| 分组 | 字段 | 说明 |
| --- | --- | --- |
| `llm` | `modelId`、`timeoutSeconds`、`maxRetries`、`streaming` | 对应 Provider 规范 §3 的用户偏好。所有模型调用统一经 Conduit，`modelId` 填 Conduit 的逻辑别名（§3.3）。 |
| `context` | `maxRecentMessages`、`includePersonalFoodSummary` | 对应 TDD §3.4 的上下文裁剪窗口。 |
| `prompts` | 系统 prompt、各工具的 `description` 文本 | 每项带 `id` 与 `version`。 |
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
    "streaming": true
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
启动 / 回到前台（距上次成功检查 ≥ 6 小时）
  → GET config.json 与 config.json.sig（带 If-None-Match / ETag）
  → 304：不变，结束
  → 验签 → 解析 → 校验（§6）
  → 通过：原子写入缓存，记录 configVersion
  → 失败：保留旧缓存，记录 AuditEvent（错误码），不打扰用户
下一次“开始新一轮对话”时读取最新生效配置
```

要点：

- **不在一轮对话中途切换配置**，也不在存在活跃 Pending 时切换 prompt，避免同一次提案前后行为不一致。新配置只在新一轮请求开始时生效。
- 拉取在后台进行，不阻塞启动与对话；超时 5 秒，失败不重试风暴（下次前台再试）。
- 缓存存于 App Support（非敏感），读取失败等同没有缓存。
- 回滚：发布方把上一个已知良好的内容以**更高的 `configVersion`** 重新发布即可；客户端不支持降版本，避免被旧文件回放。

## 6. 校验与回退

通过验签后，在生效前做结构与取值校验，任何一项失败则**整份拒绝**并继续使用当前生效配置：

| 字段 | 规则 |
| --- | --- |
| `schemaVersion` | ≤ 客户端支持版本。 |
| `minClientVersion` | ≤ 当前客户端版本。 |
| `configVersion` | 高于当前缓存。 |
| `llm.modelId` | 非空字符串，长度上限。 |
| `llm.timeoutSeconds` | 5–180。 |
| `llm.maxRetries` | 0–3。 |
| `context.maxRecentMessages` | 1–100。 |
| `prompts.*.text/description` | 非空，长度上限（防止异常膨胀导致请求超限）。 |
| `prompts.tools` 的键 | 必须是客户端已知工具；未知工具名忽略。 |

回退链：`新配置校验失败 → 上一份已校验缓存 → 内置默认值`。App 在任何层级失败时都必须可用。

## 7. 完整性与安全

prompt 会直接改变模型行为，因此配置的**来源可信**比传输加密更重要。

- 传输：仅 HTTPS。
- 签名：配置文件由发布方用私钥签名（建议 Ed25519），客户端内置公钥，**先验签再解析**。签名文件带 `keyId`，客户端可内置多把公钥以支持轮换。
- 签名私钥不进入仓库、不进入 App，也**不放在 Admin Web 进程里**：放在 KMS 或独立的签名步骤，Admin 发布时调用。Admin 被入侵不应等于可任意下发 prompt。
- 即使签名通过，强制规则（§3.2）仍由代码执行：恶意或错误的 prompt 最多让模型“说错话”，不能绕过确认门去写数据，也不能改变请求目的地。
- 配置内容不发送给任何第三方，除了作为请求的一部分发给已配置的模型 Provider（与现状一致）。
- 隐私：
  - 拉取配置的请求不携带用户标识；分发面是静态托管，看不到用户数据。
  - **当前阶段不上传任何用户内容**（饮食、健康、对话、图片）。诊断日志只含元数据（§11）。
  - 将来如需备份或收集用户内容，须：新 ADR、独立同意开关、独立存储与保留期、支持删除；不得复用诊断日志通道的默认开关。

## 8. 发布与托管

### 8.1 托管选择

| 选项 | 优点 | 风险 |
| --- | --- | --- |
| 国内可访问的对象存储 / 静态托管（如阿里云 OSS、腾讯云 COS、Cloudflare R2 + 自定义域名） | 访问稳定，可设 ETag/缓存头 | 需要一个账号与域名。 |
| GitHub Raw / Pages | 零成本，版本天然在 Git | **在中国大陆访问不稳定**；而 Ark 本身也在国内，网络环境需与之匹配。 |

建议：配置的编辑、历史与审计在 Admin 中完成（§11），**发布步骤把已签名文件推到一个国内可稳定访问的静态托管**；具体服务商待确认（§12）。管理面与分发面分离：Admin 不对客户端直接提供配置。

### 8.2 渠道

- `stable`：日常使用。
- `dev`：试验性 prompt。设置页隐藏入口可切换渠道，默认 `stable`。两个渠道各自一份文件与一对签名，互不影响。

### 8.3 发布流程（建议）

1. 在 Admin 中编辑草稿。
2. Admin 服务端校验（与客户端共用同一份 schema，复用 §6 规则）；可选对 prompt 做试跑。
3. 先发布到 `dev` 渠道，用真实对话验证。
4. 确认无误后晋升到 `stable`：`configVersion` 由服务端自增，签名后生成 `config.json` 与 `config.json.sig`，推送到静态托管。
5. 回滚即以更高 `configVersion` 重新发布旧内容（§5）。

## 9. 本地调试覆盖（L3）

- 位置：设置页的隐藏入口（例如连续点击版本号）。
- 范围：仅 `llm.modelId`、`llm.timeoutSeconds`、系统 prompt 文本、渠道选择；不提供对 §3.2 项目的覆盖。
- 存储：本机，非敏感；不上传。
- 界面显示当前每个覆盖项的来源（本地 / 远程 vX / 内置），避免“不知道现在到底用的哪份”。
- 一键清除全部覆盖。

实现（2026-10-31）：设置页连点版本号五次出现“调试覆盖”卡片，可覆盖模型别名、超时秒数（5–300）与系统 prompt，每项显示来源；存在 UserDefaults（`vita.config.override`），下一轮对话开始时生效。渠道选择随远程拉取一起做。

## 10. 可观测与测试

**审计：** 每次模型请求在 `AuditEvent`（或诊断元数据）中记录生效的 `configVersion`、各字段来源层级与 prompt 版本号，不记录 prompt 全文。配置拉取、验签失败、校验失败各有独立错误码。这些字段同时是诊断日志的关联维度（§11）。

**测试：**

- 验签：合法、签名被改、内容被改、缺签名。
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
| **Vita Admin**（Next.js） | 配置的编辑、校验、版本历史、签名发布、渠道晋升；接收并查看客户端诊断日志；Admin 操作审计 | 模型转发与 Key 托管；业务数据 |
| **分发面**（静态托管） | 提供已签名的 `config.json` / `.sig` | 一切动态逻辑 |
| **Conduit**（独立项目） | 模型调用网关：鉴权、Key 托管、路由、配额、调用日志 | 配置与客户端诊断 |

客户端的 `ConfigProvider` 协议不变，数据来源仍是分发面。

与 Conduit 的关系：
- Conduit 有自己的管理后台（面向多个应用的网关配置：上游、别名、配额）；Vita Admin 只管 Vita 自己的配置与诊断日志，两者不合并。
- Admin 的 Prompt 试跑通过 Conduit 发请求，使用 Admin 专用的 Conduit 令牌（限定别名与额度），不绕过网关。
- 配置里的 `modelId` 必须是 Conduit 上已存在的别名。Admin 发布前可调用 Conduit 的 `/v1/models` 校验别名是否存在。

### 11.2 Admin 配置功能

- 草稿 / 发布 / 历史 / 回滚；`configVersion` 服务端自增保证单调。
- 服务端校验，与客户端共用 schema。
- `dev` / `stable` 渠道与一键晋升。
- 任意两个版本的 diff，prompt 文本要有文本级 diff。
- Prompt 试跑：用样例输入对草稿跑一次模型，发布前验证。
- 发布二次确认；每次操作记录操作者、时间与 diff。
- Admin 登录：强密码加 TOTP 或 Passkey，必要时限制 IP。

### 11.3 日志分类

| 类别 | 内容 | 来源 | 当前状态 |
| --- | --- | --- | --- |
| **Admin 运维日志** | 访问、错误 | Admin 服务器本地日志文件 | 做 |
| **Admin 变更审计** | 谁在何时改了什么、发布了什么、diff | **数据库**（需要查询、diff、回滚，不放文件） | 做 |
| **客户端诊断日志** | 仅元数据：错误码、`configVersion`、prompt 版本、模型别名、耗时、token 数、App 版本、轮换的匿名安装 ID | 客户端上报 | 做 |
| **模型调用日志** | 请求元数据、成本、降级路径 | Conduit | 由 Conduit 负责 |
| **用户内容** | 对话、饮食、健康数据、图片 | 客户端上报 | **当前不做**，见 §7 |

### 11.4 诊断日志上报

- 客户端有设置页开关；默认值待定（§12）。关闭时不上报。
- 上报与配置拉取是独立通道，使用独立端点与独立鉴权，不复用配置请求。
- 上报内容只含上表“客户端诊断日志”字段，不含 prompt 全文、消息体与任何用户内容。客户端在发送前过滤，服务端再兜底校验 schema 并拒绝多余字段。
- 每条记录带 `dataClass` 字段（当前仅 `diagnostic`），为将来区分“用户内容”类预留，授权与保留期可按级别分开。
- 接口要求：设备级鉴权（可评估 App Attest）、限流、体积上限、schema 校验。
- 保留期默认 30 天自动清理；支持按安装 ID 删除。
- 查询：按时间、错误码、`configVersion`、App 版本筛选；聚合视图（错误率、P95 耗时）。
- 关联：请求带 `X-Request-Id`，与 Conduit 的调用日志可对应；日志带 `configVersion` 与 prompt 版本，用于判断某次发布前后的效果变化。
- 告警暂不做。

### 11.5 分期

| 阶段 | 内容 |
| --- | --- |
| M1 | 配置 CRUD、服务端校验、签名发布、变更审计 |
| M2 | Prompt 试跑、diff、渠道晋升 |
| M3 | 诊断日志上报与查看；补 ADR 与隐私说明 |
| 以后 | 告警、用户内容类数据（须新 ADR） |

模型网关相关里程碑见 Conduit 项目文档。

### 11.6 仓库位置与技术栈

Admin 与客户端同仓库，位于 `admin/`；配置的 JSON Schema 位于 `shared/config-schema/`，Admin 发布前校验与 iOS 测试夹具共用同一份。Conduit 是独立仓库。

| 部分 | 选择 | 说明 |
| --- | --- | --- |
| 框架 | Next.js（App Router），pnpm | 管理页面在 `/admin/*`，客户端诊断上报在 `/api/ingest/*`，两者路由与鉴权分开，首期同进程，保留拆分余地。 |
| 存储 | PostgreSQL | 配置版本、审计、诊断事件。ORM 待定。 |
| 签名 | 独立的签名步骤（KMS 或签名机） | Web 进程只提交待签内容，不持有私钥。 |
| 发布 | `Publisher` 接口，首个实现推送到静态托管（OSS / COS 等） | 托管商可替换，不影响 Admin 逻辑。 |
| 登录 | 强密码加 TOTP 或 Passkey | 个人使用阶段为单管理员。 |

### 11.7 数据模型（草案）

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `config_drafts` | `channel`、`content`(jsonb)、`base_release_id`、`updated_by`、`updated_at` | 每个渠道一份当前草稿。 |
| `config_releases` | `channel`、`config_version`、`content`(jsonb)、`content_hash`、`signature`、`key_id`、`published_by`、`published_at`、`rollback_of`、`note` | 不可变；`(channel, config_version)` 唯一。回滚是新增一条内容取自旧版本的 release。 |
| `channels` | `name`、`current_release_id` | 当前对外发布的版本指针。 |
| `admin_audit` | `actor`、`action`、`target_type`、`target_id`、`diff`(jsonb)、`ip`、`at` | 仅追加；不允许修改与删除。 |
| `admin_users` | 登录凭证、TOTP / Passkey 信息 | 首期单用户。 |
| `installs` | `install_id`、`first_seen`、`last_seen`、`revoked` | 匿名安装 ID，不含设备标识或用户信息。 |
| `diagnostic_events` | `received_at`、`install_id`、`data_class`、`event_type`、`error_code`、`config_version`、`prompt_versions`、`model_alias`、`latency_ms`、`tokens_in`、`tokens_out`、`request_id`、`app_version` | 只存白名单字段，不存自由文本；按保留期清理任务删除。 |

诊断事件的具体类型清单（配置拉取失败、验签失败、校验失败、模型请求失败等）与字段取值待在 M3 前补全，作为客户端与服务端共同的 schema 放入 `shared/`。

## 12. 待确认

1. 静态托管选哪家（需国内稳定访问）；是否已有域名。
2. 是否启用签名。建议启用；如暂缓，至少限定唯一可信域名并钉住 HTTPS。
3. 拉取间隔默认 6 小时是否合适，是否需要设置页“立即刷新”。
4. `dev` 渠道是否需要，或仅依赖本地调试覆盖。
5. 工具描述文字是否允许远程修改，还是只开放系统 prompt（更保守）。
6. 诊断日志开关默认开还是关；分发后是否需要首次启动时的告知与选择。
7. 客户端设备鉴权方式（匿名安装 ID 加 App Attest，或其他）。
8. 开发与测试环境：Debug 构建指向哪个 Conduit 实例；Conduit 不可用时 App 的降级体验与提示文案。
9. 签名私钥的存放方式（KMS 还是独立签名机）。
10. Admin 的部署位置、域名与备案（与 Conduit 可共用基础设施，但管理面需独立访问控制）。

## 13. 对现有文档的拟议改动

- ADR 新增 ADR-012：采用三层配置与静态签名远程配置，由 Vita Admin 编辑与发布，分发面保持静态。
- ADR 新增 ADR-013：客户端所有模型调用统一经独立网关 Conduit，客户端不直连上游、不持有上游 Key。
- ADR 新增 ADR-014：客户端诊断日志上报（仅元数据，可开关）；用户内容上传当前不做，将来须另立 ADR。
- TDD §2 / §8：加入 `ConfigProvider`、Conduit 调用与诊断日志的隐私说明。
- Provider 规范 §3：去掉用户自带 Key 与直连方舟，改为 Conduit 令牌鉴权；Model ID（别名）与超时来源改为“生效配置”。
- 实施计划：Phase 0 加入内置默认配置与 `ConfigProvider` 协议；Phase 5 前完成远程拉取、验签、校验与调试覆盖；诊断日志与 Admin 按 §11.5 分期。
