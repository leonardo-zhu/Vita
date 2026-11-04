# Vita 2.0 架构设计

**状态：已评审（2026-11-04），M1–M3 已实现并部署（真机迁移待验证，见 §16），M4、M5 未开始。** 标了"已定"的是已经达成一致的结论（ADR-019 至 022 已采纳）；标了"建议"的是给出的推荐方案，等评审确认；§14 是还没定的问题。2026-11-04 第一轮评审的结论已写进各节。  
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

- **手机 → API**：在 Admin 的“设备”页（已有 Passkey 登录）为设备签发一个长期令牌，只显示一次，复制后粘贴进 App（没做二维码）；App 先调 `GET /v1/me` 确认有效再存进 Keychain，取代 1.0 手填的 Conduit 令牌。API 只存令牌的哈希，Admin 里可以吊销；设置页“断开”只清本机的令牌与同步状态。
- **Admin → API**：服务令牌，只放在两个容器的 `.env` 里。
- **API → Conduit**：API 持有 Conduit 密钥；手机上不再有模型相关的密钥。

## 9. Apple 健康同步（已实现）

思路：**有新数据就覆盖，旧数据不动**。服务端是准的，手机看到哪条变了就把健康里对应的那条换成最新版。

1. 服务端每次写入饮食记录或称重（包括在 Admin 里改的），都记一条变更：记录 ID + 新 revision，或已删除。
2. 手机在 App 启动、回到前台、确认卡片之后拉取"上次以来的变更"（游标就是"上次拉到哪了"的书签），没变的不用管。
3. 写入健康时用 HealthKit 自带的覆盖机制：每个 Sample 带上 `HKMetadataKeySyncIdentifier`（如 `vita:record:<记录 ID>:<营养项>`）和 `HKMetadataKeySyncVersion`（= revision）。同一个标识写入更高版本时，HealthKit 会自动替换旧的那条，不会重复。删除时按这个标识查出来再删。
4. 写入失败、没有权限时的处理照旧，状态只显示在本机。

和 1.0 的区别：1.0 写入时没带同步标识，替换和删除全靠本机的映射表（记录 ↔ Sample UUID）。带上标识以后，映射表就不是必需的了；换手机时健康数据经 iCloud 同步回来，新手机从头拉一遍变更也不会写出重复的数据。

Apple 健康本身经 iCloud 在同一 Apple ID 的设备间同步，这不是问题，反而是带标识的原因：数据跟着 iCloud 回到新手机，而 Vita 自己的映射表不一定跟着回来；有了标识，HealthKit 按标识就能认出是同一条。暂不考虑换手机，跨设备删除（新手机删旧手机写入的 Sample）不专门验证，真遇到再处理。1.0 已经写入的、没带标识的旧数据，迁移时补一次标识（删掉重写）。

实现与上面设想的差别（2026-11-04）：

- **变更流**：`GET /v1/health-sync/changes?after=<游标>`，每个对象只给最新状态，已算好要写的 Sample（饮食按营养项合计、称重含体重 / 体脂率 / 去脂体重）。`syncVersion` 是变更的序号（单调递增），不是记录的 revision。
- **写入**：标识为 `vita:record:<id>:<营养项>`、`vita:weighing:<id>:bodyMass|bodyFat|leanMass`（ID 小写）。不依赖“高版本自动替换”：每次先按标识删掉这个对象的全部 Sample 再写，这样某项变成 0 时旧的那条也会消失。
- **本机状态**：只有一个 JSON 文件（Application Support/`VitaState/health-sync.json`）：游标、已写入的对象、写失败的对象与原因。没有 outbox 和映射表。
- **失败与权限**：某个对象写失败时游标照样前移，失败的记下来，下次从游标 0 重拉（每个对象只给一次），只补失败的。膳食和体重写入都没允许时不拉取；被拒的对象标为“需要用户处理”，Data 页提示去健康 App 打开权限。设置页“重新同步”把游标清零、全部重写一遍（按标识覆盖，不重复）。
- **触发**：App 启动与回到前台、确认卡片之后、称重 / 记秤读数 / 删除称重之后、Data 页打开时。
- **称重**：上传时手机告诉服务端能不能写健康（`appleHealthWritable`）；不能时服务端把体重与体脂率记为手动补录，也不登记变更。

## 10. Agent 在服务端

### 10.1 一轮请求

```text
手机 POST /v1/days/{date}/chat  { text, labelScanId? }
  └─ API：读生效配置 → 组装上下文（系统 prompt + 个人食品库 + 历史 + 当天状态）
         → 调 Conduit → 执行工具 → … → 保存消息
  ◀─ SSE：thinking / text / step / pending / done / error
```

- 1.0 `ChatOrchestrator`、`AgentToolRunner`、`ProposalToolHandler` 的逻辑整体移植，行为不变：最多 8 轮工具、`afterConfirm` 接续、历史里卡片结局的注记、客户端状态作为系统消息放在用户消息之前（便于缓存）。
- 确认 / 取消：`POST /v1/pending/{id}/confirm`、`/cancel`。`afterConfirm` 存进数据库，不再只放在内存里。实现上确认接口本身不接续：卡片带 `afterConfirm` 时，手机确认后再调 `POST /v1/pending/{id}/continue`（每张卡只能接续一次），进度同样用 SSE 推回。历史消息里卡片的结局用 `GET /v1/pending/{id}` 读。
- 手机断线：这一轮在服务端跑完并保存，手机重连后读取历史即可看到。手机点"停止"时用 `started` 事件里的 `requestId` 调 `POST /v1/chat-turns/{requestId}/cancel`，这一轮什么都不保存，原文放回输入框。

### 10.2 远程配置

- 系统 prompt、工具描述、模型参数、标签图片参数现在由 **API** 使用。API 读取 Admin 发布到 `/opt/vita-admin/published` 的 `stable.json`（只读挂载），沿用三层合并与校验规则。
- 手机端不再需要这些配置。`/config/*` 暂时保留，等真有客户端专用的开关再说。iOS 里拉取与缓存远程配置的代码（`Platform/Config`）还在、每次回到前台照常拉，但结果没有地方用；内置默认配置 `ios/Vita/Resources/DefaultConfig.json` 被 API 的镜像当作内置默认值使用，删 iOS 这部分之前要先把它挪到 `shared/`。
- 手机上的"本地调试覆盖"（模型别名、超时、系统 prompt）已随设置页的调试卡片删掉，没有改成请求参数；要试 prompt 用 Admin 的试跑。

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

| 1.0 | 2.0（已实现） |
| --- | --- |
| SwiftData 业务库 | 去掉；schema 代码只留给迁移读 1.0 的库。本机只有两个 JSON 文件：健康同步状态（§9）与称重队列 |
| `ChatOrchestrator` 等 Agent 代码、`LLMClient` | 删掉；`ChatService` 调 API 并解析 SSE |
| `RecordService` / `FoodService` / `PendingService` 等 | 同名服务改为调 API（`Platform/API` 里按契约手写的模型），界面沿用原来的数据模型 |
| Conduit 令牌（Keychain） | 换成 Vita 设备令牌；首次打开先进连接页 |
| 体脂秤 | 保留；连不上服务端时称重进本机队列（id 手机生成，服务端去重），打开称重页、回到前台时补传 |
| 标签照片 | 拍照压缩后上传 API，拿到 `labelScanId` 再发消息；历史与食品版本里的照片按 ID 从 API 读 |
| Data 页 | 调 API；暂不做离线缓存，没网时提示。体脂率等指标仍由手机按同一套公式算，校准公式用服务端拟合的 |
| 公共参考库 | 营养库页面浏览仍用随 App 打包的那份；Agent 查的是服务端那份 |
| 设置页 | 只剩设备令牌、重新同步健康、诊断日志开关与重看引导；调试覆盖、清空数据去掉（数据在服务端，改数据去 Admin） |

调试：Debug 构建允许连本机 HTTP 的 API（`VITA_API_BASE_URL=http://127.0.0.1:3014`），Release 只允许 HTTPS。

## 13. 迁移（已实现，真机待验证）

1. App 新增"导出全部数据"：生成一个 JSON 文件和标签照片，保留所有 UUID。
2. API 提供一次性导入接口（只在库为空时允许），导入后返回各表条数与每日合计，App 与本机数据对比。
3. 对比一致后，App 切换到 2.0 模式，删除本地业务库；按 §9 给健康里已有的 Vita 数据补上同步标识，游标设为导入完成时的位置。
4. 1.0 的导出文件留底，至少保留到 2.0 稳定使用一个月。

实现（2026-11-04）：新版 App 不保留 1.0 模式。连上设备令牌后，手机上有 1.0 的库就进迁移页（库里没有业务数据则直接删掉）：

1. **导出**：整理成 `ImportBundle`（ID 小写，可空字段显式写 null），写进“文稿”目录（`vita-1.0-export-<时间>.json`，“文件”App 里能看到）。1.0 的确认卡不迁，指向它们的卡片引用清掉；工具摘要消息按助手消息迁；食品版本的照片引用换成标签照片的 ID。
2. **导入与核对**：`POST /v1/import`，对比记录、条目、食品、版本、目标、称重的条数与每天计入汇总的能量（允许 0.01 千卡尾差）。不一致就停，本机什么都不删。
3. **健康**：按 1.0 的映射表删掉旧 Sample（没有写入权限的删不掉，会和新写的重复），然后游标从 0 开始拉变更流重写（不是从导入完成的位置）。服务端导入时给每次称重都登记了变更（导出里没有“当时是否写进了健康”），所以 1.0 里因为没权限没写进健康的称重，迁移后若已有权限也会补写进去。
4. **收尾**：删掉本机的库、标签照片与 1.0 的 Conduit 令牌。
5. **中途打断**：核对通过后记一个标记，之后被打断（App 被杀）下次从第 3 步接着做。若上传成功但没来得及核对，再导入会被拒（服务端已有数据），这时按天读回服务端的数据核对，一致就接着做，不一致照常报错。

iOS 的导出由测试生成 `shared/fixtures/ios-1.0-export.json`，API 的导入测试用它核对两端格式一致。服务端只在业务库为空时接受导入：迁移前要确认服务端没有用 curl 等方式留下的测试数据。

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

M1 进度（2026-11-04）：根目录 pnpm workspace（沿用 Admin 原来的 lockfile，依赖版本不变）、`packages/contract`、`api/` 骨架（健康检查、设备令牌的签发 / 校验 / 吊销、SQLite 迁移、审计）、Dockerfile、compose、Caddy 配置与 CI 已完成；Admin 的构建改为从根目录安装（standalone 产物里 `server.js` 移到 `admin/` 下）。业务数据（同日）：记录、食品库、确认卡、一天的数据已移植，表结构见 `api/src/db.ts` 第 2 版迁移；营养计算用 big.js 做十进制运算，对应 1.0 的 `Decimal`；1.0 的相关测试逐条移植（API 共 67 个测试），并用本地构建的真实参考库（1451 条）跑通加载与查询。接口：`GET /v1/days/:date`、`GET /v1/days/:date/pending`、`POST /v1/pending/:id/confirm` / `cancel`、`GET /v1/foods`、`GET /v1/reference-foods`；提案只由服务端的 Agent 生成（M2），不对外开放。新建日期会话与确认卡过期按服务端配置的时区（`VITA_API_TIME_ZONE`，默认上海）计算。目标与健康数据（同日）：目标只追加、按日期生效，固定与随活动计算可以互相切换；能量目标与收支在读取每日数据时按当天活动重算；1.0 的目标建议与能量测试数值全部对得上（API 共 89 个测试）。和 1.0 的分工不同：Apple 健康仍在手机上读，手机上传身体数据（`PUT /v1/health/snapshot`，只留最新一份）和每日活动能量（`PUT /v1/health/activity`），**7 日日均改由服务端按活动记录计算**；手动补录（`PUT /v1/health/manual-metrics`）存在服务端。目标建议由服务端按存的健康数据计算（`POST /v1/goals/recommendation`），生成目标（`POST /v1/goals/initial`）时服务端重新计算，客户端只选类型和调整，不能提交数值。`updateGoal`（对话里改目标）的服务已就位，工具接入随 M2。身体成分（同日）：蓝牙连秤（握手、解析、离线记录同步）和写 Apple 健康留在手机；称重存在服务端（`POST /v1/weighings`，手机生成 id，重传不重复），体脂率估算、校准拟合、各项指标与判定区间、体型都在读取时由服务端计算。手机不能写 Apple 健康时，上传带 `appleHealthWritable: false`，服务端把体重与体脂率记为手动补录（更旧的离线记录不覆盖更新的）。记秤读数（`PUT /v1/weighings/:id/scale-reading`）后若采用的校准公式变了，响应里 `calibrationChanged` 为 true，手机据此重写 Apple 健康里全部称重的体脂率。7 日均线是图表展示，留在客户端算。API 共 110 个测试。对话与 Agent（M2，同日）：工具循环、确认卡提案、`updateGoal`、上下文组装都在服务端跑，经 Conduit 调模型，密钥只在服务端；配置为内置默认值加 Admin 发布的 `stable.json`（只读挂载，每轮开始时读，按修改时间缓存）。接口：`POST /v1/days/:date/chat`（SSE，事件 started / reasoning / text / step / done / error，定义见 `@vita/contract` 的 `ChatEvent`）、`GET /v1/days/:date/messages`、`POST /v1/chat-turns/:requestId/cancel`（停止）、`POST /v1/pending/:id/continue`（确认后接续，每张卡片只一次，SSE）、`POST /v1/label-scans`（上传标签照片，请求体是图片本身）。与本文 §10 原设想的差别：确认接口本身不接续，带 `afterConfirm` 的卡片确认后由手机再调 `/continue`，这样确认仍是普通请求、接续的进度照样流式推送；照片由手机压缩后上传，服务端不缩放，配置里的 `labelImage.maxDimension` / `jpegQuality` 在服务端不起作用，只用 `detail`；客户端断线时这一轮照样跑完并保存，只有调停止接口才中止。对话追踪写入 `chat_traces`（每轮开始时清理 90 天前的），Admin 的查看页随 M2 后续做。用本地的模拟 Conduit 跑通了打包后的流式对话（工具调用、逐段推送文字、保存历史）；还没有接真实模型。API 共 135 个测试。

部署（2026-11-04）：`vita-api` 已部署到 R4S（`https://vita-api.r4s.leonardo-zhu.me`），经公网 HTTPS 自检通过（设备令牌、鉴权、读数据、真实参考库）；Admin 随 workspace 改造一起重新部署，正常。同日填入 Conduit 密钥（`CONDUIT_BASE_URL` 走本机 `http://127.0.0.1:3012`），用真实模型跑通了两轮：先澄清生熟与米饭用量（必测场景 1），再生成营养值由服务端计算的确认卡；流式文字分段到达，配置读的是 Admin 发布的版本，第二轮输入约 89% 命中缓存。R4S 侧的操作记录在 HomeLab 的 `notes/2026-11-04-vita-api-部署.md`。部署地址的环境变量用 `VITA_API_HOST`，不用 `HOSTNAME`（很多 shell 会把它设成机器名）。

M3（同日）：iOS 改为调 API。新增 `Platform/API`（按契约手写的模型、SSE 解析，发给 API 的 ID 一律小写）；Chat 经 SSE 跑服务端的 Agent，停止调取消接口，带 `afterConfirm` 的卡片确认后调 `/continue`；Data 页、食品库、目标、确认卡、标签照片都读写 API；本机的 Agent、LLM 客户端、Record / Pending / Food 服务删除。Apple 健康改为拉变更流，Sample 带 `vita:<entity>:<id>:<项>` 同步标识先删后写，本机只存游标与写入结果（`VitaState/health-sync.json`）；称重连不上时进本机队列，回到前台补传。API 新增 `GET /v1/pending/:id`（历史消息里卡片的结局）。迁移：有 1.0 库时连上设备令牌后进迁移页，导出（文件留在“文稿”）→ 导入 → 核对条数与每日能量 → 删 1.0 写进健康的旧 Sample、从头拉变更流重写 → 删本机库；导入核对通过后中途被打断，下次按天读回核对再接着做。iOS 的导出由测试生成 `shared/fixtures/ios-1.0-export.json`，API 的导入测试用它核对两端格式。用模拟器里真实的 1.0 库对本地 API 跑通了导出、导入与核对（4 条记录、10 次称重）；更新健康这一步在 iOS 27.1 模拟器上因 `healthd` 不响应没能跑完（1.0 同样卡住），要在真机上验证。iOS 116 个测试、API 143 个测试。

| 阶段 | 技术内容 |
| --- | --- |
| M0 | 评审本文与 ADR-019 至 022 |
| M1 | 根目录 pnpm workspace 与 `packages/contract`、`api/` 骨架、CI、部署（含新域名）、数据库与迁移机制、记录 / 食品库 / 确认卡 / 目标 API、业务测试移植、参考库构建脚本改写为 TypeScript、JSON 导出 |
| M2 | Agent 循环上服务端、SSE、配置读取、对话追踪进 Admin |
| M3 | iOS 改为调 API，健康同步改为拉取变更并带同步标识，体脂秤上传队列，1.0 数据导入 |
| M4 | App Data 页编辑、Admin 数据管理页 |
| M5 | 别名与改名的对话流程、扩展营养素的显示与健康写入 |
