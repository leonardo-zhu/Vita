# Vita API

2.0 的业务服务：数据、Agent 工具循环与确认门都在这里（ADR-019、020）。Node 24 + TypeScript + Hono + `node:sqlite`（ADR-021），部署在 R4S，与 Admin 分开。设计见 [Vita 2.0 架构设计](../docs/architecture/vita-2.0-architecture.md)。

约定：

- 包管理器使用 pnpm，仓库根目录是 workspace（ADR-022）；在根目录 `pnpm install` 一次即可。
- 请求 / 响应的定义在 `../packages/contract`（zod），API 用它校验，Admin 用它调用。
- 开发时 Node 直接跑 `.ts`；部署时用 esbuild 打成单个 `dist/server.js`，镜像里不需要 `node_modules`。

## 本地开发

```bash
cp .env.example .env.local   # 填 VITA_API_SERVICE_TOKEN（至少 32 个字符）与 VITA_API_REFERENCE_FILE
pnpm dev                      # http://127.0.0.1:3014/v1/health
pnpm test
```

SQLite 在 `.data/vita-api.db`。签发一个设备令牌：

```bash
curl -X POST http://127.0.0.1:3014/v1/admin/devices \
  -H "authorization: Bearer $VITA_API_SERVICE_TOKEN" -H 'content-type: application/json' -d '{"name":"iPhone"}'
```

## 结构

| 路径 | 内容 |
| --- | --- |
| `src/server.ts` | 入口：环境变量、打开数据库、监听端口 |
| `src/app.ts` | 路由与鉴权：设备令牌给手机，服务令牌给 Admin，`/v1/admin/*` 只认服务令牌 |
| `src/db.ts` | SQLite 打开与迁移（`user_version`，只追加）、审计 |
| `src/devices.ts` | 设备令牌的签发、校验、吊销；库里只存 sha256 |
| `src/domain/` | 纯领域逻辑：本地日期与时区、摄入时间、单位换算与营养计算（十进制）、参考库、变更的类型 |
| `src/services/` | 记录、食品库、确认卡、一天的数据；每个写操作一个事务，成功失败都记审计（移植自 1.0 的同名 Swift 服务） |
| `src/test/` | 测试夹具：与 1.0 相同的日期、时刻、时区与小型参考库 |
| `scripts/build.mjs` | esbuild 打包 |
| `deploy/` | R4S 上的 compose 与 Caddy 配置 |

## 部署

推到 `main` 且改到 `api/`、`packages/contract/` 或根目录的 workspace 文件时，`.github/workflows/vita-api-deploy.yml` 会：测试 → 在 GitHub 的 arm64 runner 上构建镜像推到 `ghcr.io/leonardo-zhu/vita-api` → 在 R4S 的 self-hosted runner 上把 `deploy/compose.yaml` 拷到 `/opt/stacks/vita-api/` 并 `docker compose pull && up -d`。

### 首次准备（在 R4S 上，只做一次）

1. **部署目录**：`mkdir -p /opt/stacks/vita-api`，属组与 `/opt/stacks/vita-admin` 一致，runner 要能写。
2. **数据目录**：`mkdir -p /opt/vita-api/data /opt/vita-api/reference && chown 1000:1000 /opt/vita-api/data`（容器里以 node 用户运行）。
3. **参考库**：本地 `python3 -I tools/reference-food/build.py` 构建后，把 `ios/Resources/ReferenceFood/reference-foods.json` 拷到 R4S 的 `/opt/vita-api/reference/`。只放在服务器上，不进仓库、不进镜像（ADR-006）；更新后重启容器生效。
4. **`.env`**：`/opt/stacks/vita-api/.env`，填 `VITA_API_SERVICE_TOKEN`（`openssl rand -base64 32`）。值里不能有 `$`。
5. **Caddy**：`/opt/stacks/caddy/Caddyfile` 追加 `deploy/Caddyfile.snippet` 的内容，先 `validate` 再 `reload`。`vita-api.r4s.leonardo-zhu.me` 已被 `*.r4s` 通配覆盖，不用另加 DNS。
6. 推一次 `main`（或在 Actions 里手动运行）。

确认：`curl -s https://vita-api.r4s.leonardo-zhu.me/v1/health` 返回 `{"ok":true,"version":"<commit sha>"}`。
