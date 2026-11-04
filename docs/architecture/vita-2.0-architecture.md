# Vita 2.0 架构设计

**状态：已评审（2026-11-04），M1 进行中。** 标了"已定"的是已经达成一致的结论（ADR-019 至 022 已采纳）；标了"建议"的是给出的推荐方案，等评审确认；§14 是还没定的问题。2026-11-04 第一轮评审的结论已写进各节。  
**关联：** [Vita PRD v2.0 草案](../product/Vita-PRD-v2.0.md)、[ADR](ADR.md)（ADR-019 至 022）、[TDD v0.1](TDD-v0.1.md)（1.0 基线）、[Vita Admin 设计](vita-admin.md)、[Agent 工具契约](../contracts/agent-tools.md)

## 1. 背景

1.0 的全部业务数据存在手机上的 SwiftData 里（14 张表，另有标签照片文件、Keychain 里的 Conduit 令牌），Agent 的工具循环也在手机上跑。问题与 2.0 的产品目标见 PRD v2.0 §1–§2。本文回答：服务端怎么搭、手机端剩下什么、数据怎么迁过去。

## 2. 总体结构

```text
                         R4S（Caddy 反代，HTTPS）
iPhone ── HTTPS ──▶ ┌──────────────────────────────┐
  │                 │ Vita API（新，api/）            │ ── Conduit ──▶ 模型
  │                 │   数据、Agent 循环、确认门        │
  │                 │   SQLite + 照片文件              │
  │                 ├──────────────────────────────┤
  │                 │ Vita Admin（已有，admin/）       │
  │                 │   配置发布、诊断、Prompt 调试      │
  │                 │   数据管理页 ──经 API──▶          │
  │                 └──────────────────────────────┘
  └── 本机：Apple 健康读写、体脂秤蓝牙、相机
```

| 组件 | 职责 | 变化 |
| --- | --- | --- |
| Vita API | 业务数据的唯一入口；Agent 工具循环、确认门、审计 | 新建 |
| Vita Admin | 远程配置、诊断、Prompt 调试；新增数据管理与对话追踪页 | 数据相关功能都调 API |
| Conduit | 模型网关 | 调用方从手机变成 API |
| iOS App | 界面；Apple 健康、体脂秤、相机；健康写入的执行方 | 去掉本地业务库，改为调 API |

## 3. 服务形态（已定，ADR-020）

API 单独一个服务、单独一个容器，不并进 Admin。

- **安全面**：API 对手机全天开放并存健康数据；Admin 只给本人用，暴露面越小越好。
- **稳定性**：API 挂了就没法记饭，要少动；Admin 改界面频繁部署，挂几分钟无所谓。
- **资源**：Agent 循环、SSE 长连接、照片上传不该挤在 Admin 的 256 MB 内存上限里。
- **规则只有一套**：Admin 的数据管理页经 API 读写，不直接打开 API 的数据库。App 里改和 Admin 里改走同一套校验、审计与健康同步。

Admin 调 API 用单独的服务令牌，走本机回环地址（两个容器都是 `network_mode: host`），不经过公网。

## 4. 技术栈（已定，ADR-021）

| 项 | 选择 | 说明 |
| --- | --- | --- |
| 运行时 | Node 24 | 与 Admin 一致；不用 Bun（理由见 ADR-021） |
| 语言 | TypeScript | |
| Web 框架 | Hono + `@hono/node-server` | `streamSSE` 推 Agent 进度；Web 标准接口 |
| 校验 | zod | 请求参数与工具参数校验 |
| 存储 | `node:sqlite` | 与 Admin、Conduit 相同做法，不引入原生依赖，ARM 镜像不用编译 |
| 测试 | vitest | 1.0 Swift 测试里的业务场景逐条移植 |
| 包管理 | pnpm | |

Admin 调 API 时可以用 Hono 的类型化客户端拿到类型提示；iOS 按接口契约手写 Swift 模型。

## 5. 仓库与部署（已定，ADR-022；细节为建议）

**目录**：仓库根目录新增 `api/`，结构与 `admin/` 对齐（自己的 `package.json`、`Dockerfile`、`deploy/compose.yaml`）。

**CI**：新增 `.github/workflows/vita-api-deploy.yml`，流程照抄 Admin：test（typecheck、lint、vitest）→ 在 ARM runner 上构建 `linux/arm64` 镜像推到 GHCR → R4S 上的 self-hosted runner 拉取并 `docker compose up -d`。`paths` 只包含：

- `api/**`（不含 `.md`）
- API 用到的 `shared/` 文件（工具参数等）
- workflow 文件本身

**R4S 上的部署**（建议）：

- 容器名 `vita-api`，端口 3014（3000、3012、3013、4000 已被占用），只监听 127.0.0.1。
- 数据卷：`/opt/vita-api/data`（数据库）、`/opt/vita-api/files`（标签照片）、`/opt/vita-api/reference`（公共营养参考库，见 §6.3）。
- 域名（建议）：沿用 `*.r4s.leonardo-zhu.me` 这套命名，和 `conduit.r4s` 一致，不换 Admin 的域名。
  - `vita-api.r4s.leonardo-zhu.me` → API。
  - `vita.r4s.leonardo-zhu.me` 照旧 → Admin 与 `/config/*`。Admin 的 Passkey（RP ID 绑定主机名）和 1.0 App 里写死的配置、诊断地址都不用动。
  - `*.r4s` 的 DNS 是泛解析，新名字不用加记录。只用一级（`vita-api.r4s`）而不是两级（`api.vita.r4s`）：DNS 两种都能解析，但如果证书用的是 `*.r4s` 泛域名证书，它只覆盖一级。
  - 不用"一个域名按路径分"：Admin 已经占了 `/api/passkey`、`/api/status`、`/api/ingest`，会撞路径；同域下 Admin 的登录 cookie 也会被带到 API 请求里。
  - 名字里带机器名的代价：以后迁走时 App 要改地址重新构建一次。App 本来就是用脚本自己装的，这个代价可以接受。

**共享代码（已定：pnpm workspace）**：

```text
pnpm-workspace.yaml      # packages: admin, api, packages/*
pnpm-lock.yaml           # 全仓库一份，取代 admin/ 里的 lockfile
admin/  api/
packages/contract/       # @vita/contract：API 的请求 / 响应定义（zod schema + 推导出的类型）
```

- API 用 `@vita/contract` 里的 zod schema 校验请求，Admin 引用同一份类型和 schema 调 API。接口一改，两边编译时就会报错。iOS 仍按契约文档手写 Swift 模型。
- `admin/pnpm-workspace.yaml` 里的 `ignoredBuiltDependencies` 移到根目录；两个 Dockerfile 的构建上下文本来就是仓库根目录，改为复制根目录的 manifest 与 `packages/contract`，用 `pnpm --filter` 只装自己需要的依赖。
- 两个 workflow 的 `paths` 都加上 `packages/contract/**`、`pnpm-lock.yaml`、`pnpm-workspace.yaml`。
- `shared/` 里的 JSON（工具参数、配置 schema、诊断格式）iOS 也要读，保持原样不进包。

## 6. 存储

### 6.1 数据库（建议）

- 一个 SQLite 文件 `vita-api.db`，开启 WAL、外键约束和 `busy_timeout`，与 Admin 的 `db.ts` 做法相同。迁移用 `PRAGMA user_version` 递增。
- 表大体对应 1.0 的 SwiftData 模型（`DaySession`、`ChatMessage`、`ConsumptionRecord` / `ConsumptionItem`、`FoodProduct` / `FoodVersion`、`DailyGoal`、`PendingAction`、`NutritionLabelScan`、`ScaleWeighing`、`AuditEvent`），并按 §11 调整。
- `HealthSyncOperation` / `HealthSyncMapping` **不上服务端**，见 §9。
- **ID 沿用 1.0 的 UUID**。迁移时保持不变，这样手机上的健康同步映射还能对上。

### 6.2 文件

标签照片存在 `/opt/vita-api/files`，按 ID 命名，数据库只存引用。客户端经 API 上传和读取，不直接访问文件路径。

### 6.3 公共营养参考库

中国食物成分表的衍生数据**不能进仓库、不能打进镜像**（ADR-006，镜像在 GHCR 上）。做法：本地构建 `reference-foods.json`，手动拷到 R4S 的 `/opt/vita-api/reference`，容器只读挂载；API 启动时加载，文件缺失则拒绝启动并报错。这份数据只在本人的服务器上，不对外分发，仍在 ADR-006 的范围内。

构建脚本（建议）：现在的 `tools/reference-food/build.py`（Python 标准库，约 450 行）是 Phase 3 时为离线处理私有数据写的，不参与运行。2.0 里参考库的查询搬到 API（TypeScript），构建脚本里的名称规范化（全角转半角、小写、去空白）必须和查询时完全一致；M1 时把脚本改写成 TypeScript 放进 `api/scripts/`，和查询共用同一个函数，仓库里也就不再有 Python。

## 7. 备份（已定：2.0 暂不做异地备份）

以后把数据库迁到云数据库，备份交给云服务（§15）。在那之前数据只在 R4S 上，R4S 的存储坏掉就会丢数据。2.0 保留两样成本很低的东西：

- **全量 JSON 导出**：API 提供导出接口（迁移、换数据库本来也要用），需要时手动导一份。
- **数据库访问层与 SQL 方言隔离**：迁云时只换存储实现，不动业务代码（§15）。

## 8. 鉴权（已定）

单用户，不建账号体系。

- **手机 → API**：在 Admin 里（已有 Passkey 登录）为设备签发一个长期令牌，以二维码或一次性显示的方式交给手机，存进 Keychain，取代现在手填的 Conduit 令牌。API 只存令牌的哈希，Admin 里可以吊销。
- **Admin → API**：服务令牌，只放在两个容器的 `.env` 里。
- **API → Conduit**：API 持有 Conduit 密钥；手机上不再有模型相关的密钥。

## 9. Apple 健康同步（建议）

思路：**有新数据就覆盖，旧数据不动**。服务端是准的，手机看到哪条变了就把健康里对应的那条换成最新版。

1. 服务端每次写入饮食记录或称重（包括在 Admin 里改的），都记一条变更：记录 ID + 新 revision，或已删除。
2. 手机在 App 启动、回到前台、确认卡片之后拉取"上次以来的变更"（游标就是"上次拉到哪了"的书签），没变的不用管。
3. 写入健康时用 HealthKit 自带的覆盖机制：每个 Sample 带上 `HKMetadataKeySyncIdentifier`（如 `vita:record:<记录 ID>:<营养项>`）和 `HKMetadataKeySyncVersion`（= revision）。同一个标识写入更高版本时，HealthKit 会自动替换旧的那条，不会重复。删除时按这个标识查出来再删。
4. 写入失败、没有权限时的处理照旧，状态只显示在本机。

和 1.0 的区别：1.0 写入时没带同步标识，替换和删除全靠本机的映射表（记录 ↔ Sample UUID）。带上标识以后，映射表就不是必需的了；换手机时健康数据经 iCloud 同步回来，新手机从头拉一遍变更也不会写出重复的数据。

Apple 健康本身经 iCloud 在同一 Apple ID 的设备间同步，这不是问题，反而是带标识的原因：数据跟着 iCloud 回到新手机，而 Vita 自己的映射表不一定跟着回来；有了标识，HealthKit 按标识就能认出是同一条。暂不考虑换手机，跨设备删除（新手机删旧手机写入的 Sample）不专门验证，真遇到再处理。1.0 已经写入的、没带标识的旧数据，迁移时补一次标识（删掉重写）。

## 10. Agent 在服务端

### 10.1 一轮请求

```text
手机 POST /v1/days/{date}/chat  { text, labelScanId? }
  └─ API：读生效配置 → 组装上下文（系统 prompt + 个人食品库 + 历史 + 当天状态）
         → 调 Conduit → 执行工具 → … → 保存消息
  ◀─ SSE：thinking / text / step / pending / done / error
```

- 1.0 `ChatOrchestrator`、`AgentToolRunner`、`ProposalToolHandler` 的逻辑整体移植，行为不变：最多 8 轮工具、`afterConfirm` 接续、历史里卡片结局的注记、客户端状态作为系统消息放在用户消息之前（便于缓存）。
- 确认 / 取消：`POST /v1/pending/{id}/confirm`、`/cancel`。确认后如果有 `afterConfirm`，由**服务端**直接接着跑一轮，结果同样用 SSE 推回，`afterConfirm` 存进数据库，不再只放在内存里。
- 手机断线：这一轮在服务端跑完并保存，手机重连后读取历史即可看到。手机点"停止"时调用取消接口。

### 10.2 远程配置

- 系统 prompt、工具描述、模型参数、标签图片参数现在由 **API** 使用。API 读取 Admin 发布到 `/opt/vita-admin/published` 的 `stable.json`（只读挂载），沿用三层合并与校验规则。
- 手机端不再需要这些配置。`/config/*` 暂时保留，等真有客户端专用的开关再说。
- 手机上的"本地调试覆盖"（模型别名、超时、系统 prompt）改为请求参数，只在调试构建里可用（建议）。

### 10.3 对话追踪

每一轮记录：原话、回复、推理摘要、每次工具调用的参数与结果、生成的卡片及确认 / 取消结局、配置版本、prompt 版本、token 数。只在 Admin 里看。取代 ADR-014 的"只有元数据"。

标签照片的去处：手机把照片上传到 **Vita API**，存在 R4S 的 `/opt/vita-api/files`（不是 Admin，Admin 只是经 API 读取显示）；API 再把它随请求发给模型（经 Conduit 到模型厂商，请求带 `store: false`，厂商不保留，事后也取不回来）。所以服务端这一份是唯一的存档，作为食品版本的来源依据，1.0 里这一份存在手机上。

对话追踪不额外存照片，只记 `labelScanId`，在 Admin 里按 ID 显示同一张图，额外开销只有一行记录。保留期（建议）：文字记录 90 天；照片跟着食品版本走，被引用就一直保留。

## 11. 数据模型相对 1.0 的变化

- **食品别名**：`FoodProduct` 增加 `aliases`（字符串数组）；品牌存用户认识的名字，工商名放进 `note`（PRD v2.0 §4.2）。
- **扩展营养素**：营养值增加可选的钠（mg）、饱和脂肪（g）、糖（g）；四项主营养素仍然必填。
- **修改来源**：审计记录区分 `agent`（经确认卡）、`app`（用户在 App 里编辑）、`admin`。
- **`afterConfirm`**：存进 `PendingAction`。
- **幂等**：创建类请求（称重上传、标签上传）由客户端生成 ID，服务端按 ID 去重，弱网重试不会重复写入。

## 12. iOS 端改造

| 1.0 | 2.0 |
| --- | --- |
| SwiftData 业务库 | 去掉；只保留健康同步的 outbox、映射与游标（SwiftData 或一个小 SQLite 文件） |
| `ChatOrchestrator` 等 Agent 代码 | 去掉；改为调 API 并解析 SSE |
| `RecordService` / `FoodService` / `PendingService` | 去掉；改为 API 客户端 |
| Conduit 令牌（Keychain） | 换成 Vita 设备令牌 |
| 体脂秤 | 保留；称重结果先存本地队列，有网时上传 |
| 标签照片 | 拍照后上传 API，拿到 `labelScanId` 再发消息 |
| Data 页 | 改为调 API；暂不做离线缓存，没网时提示 |

## 13. 迁移（建议）

1. App 新增"导出全部数据"：生成一个 JSON 文件和标签照片，保留所有 UUID。
2. API 提供一次性导入接口（只在库为空时允许），导入后返回各表条数与每日合计，App 与本机数据对比。
3. 对比一致后，App 切换到 2.0 模式，删除本地业务库；按 §9 给健康里已有的 Vita 数据补上同步标识，游标设为导入完成时的位置。
4. 1.0 的导出文件留底，至少保留到 2.0 稳定使用一个月。

## 14. 待定问题与已接受的风险

2026-11-04 两轮评审后，§1–§13 的结论都已定下或给出了建议，没有待定问题。已接受的风险：

1. **没有异地备份**：迁到云数据库之前，数据只在 R4S 上（§7）。
2. **外网只能走 IPv6**：R4S 上做了分流 DNS，家里 `*.r4s.leonardo-zhu.me` 解析到局域网地址；在外面靠 Cloudflare 的 IPv6 DDNS 访问（没有公网 IPv4）。手机在只有 IPv4 的网络（部分酒店、公司 Wi-Fi）里就连不上；1.0 这种情况下只是对话用不了，2.0 会连数据都看不了。先接受：国内蜂窝网络基本都有 IPv6，碰到只有 IPv4 的 Wi-Fi 就切回蜂窝网络。以后真要解决，改动最小的做法是在 Cloudflare 上给 `vita-api.r4s` 开代理（橙色云朵），手机用 IPv4 连 Cloudflare、Cloudflare 用 IPv6 回源；代价是数据经过 Cloudflare、国内可能变慢，SSE 要确认不被缓冲或超时。Cloudflare Tunnel 效果类似。

## 15. 以后迁到云数据库

- **数据库**：业务代码只通过数据访问层读写，不在别处直接写 SQL。迁云时有两条路：换成兼容 SQLite 的云服务（如 Turso / libSQL、Cloudflare D1），改动最小；或换成托管 Postgres，需要改一遍 SQL 方言和迁移脚本。到时再选。
- **照片**：存储同样包一层接口，以后换成对象存储（如 R2、S3）只改实现。
- **iCloud 同步和这套架构的关系**：用 iCloud（CloudKit）同步业务数据，和"服务端是唯一数据源"是两条互斥的路，二者只能选一个，否则就有两份"准"的数据要互相对账。2.0 选了服务端，业务数据就不再走 iCloud。Apple 健康本身经 iCloud 在设备之间同步，这一点不冲突，§9 的同步标识正是为它准备的。

## 16. 分期

与 PRD v2.0 §7 对应：

M1 进度（2026-11-04）：根目录 pnpm workspace（沿用 Admin 原来的 lockfile，依赖版本不变）、`packages/contract`、`api/` 骨架（健康检查、设备令牌的签发 / 校验 / 吊销、SQLite 迁移、审计）、Dockerfile、compose、Caddy 配置与 CI 已完成；Admin 的构建改为从根目录安装（standalone 产物里 `server.js` 移到 `admin/` 下）。业务数据的表与接口尚未开始。部署地址的环境变量用 `VITA_API_HOST`，不用 `HOSTNAME`（很多 shell 会把它设成机器名）。

| 阶段 | 技术内容 |
| --- | --- |
| M0 | 评审本文与 ADR-019 至 022 |
| M1 | 根目录 pnpm workspace 与 `packages/contract`、`api/` 骨架、CI、部署（含新域名）、数据库与迁移机制、记录 / 食品库 / 确认卡 / 目标 API、业务测试移植、参考库构建脚本改写为 TypeScript、JSON 导出 |
| M2 | Agent 循环上服务端、SSE、配置读取、对话追踪进 Admin |
| M3 | iOS 改为调 API，健康同步改为拉取变更并带同步标识，体脂秤上传队列，1.0 数据导入 |
| M4 | App Data 页编辑、Admin 数据管理页 |
| M5 | 别名与改名的对话流程、扩展营养素的显示与健康写入 |
