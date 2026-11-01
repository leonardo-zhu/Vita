# Vita Admin

Next.js 管理后台：远程配置的编辑、校验与发布（M1），以后加 Prompt 试跑、diff 与诊断日志（M2 / M3）。部署在 R4S（与 Conduit 同机），数据库为 SQLite。设计见 [Vita Admin 设计](../docs/architecture/vita-admin.md)。

约定：

- 包管理器使用 pnpm。
- 配置校验使用 `../shared/config-schema/` 中的 JSON Schema，与 iOS 端共用；工具清单与内置 prompt 取自 `../ios/Vita/Resources/DefaultConfig.json`。两者由 `scripts/sync-shared.mjs` 在 dev / build / test 前拷进 `src/generated/`（不进 git）。
- 模型网关不在此处，见独立项目 Conduit。

## 本地开发

```bash
cp .env.example .env.local   # 示例账号 admin / vita-admin-dev
pnpm install
pnpm dev                      # http://localhost:3030/admin
pnpm test                     # 发布、回滚、校验与版本号的测试
```

SQLite 在 `.data/vita-admin.db`，发布出来的文件在 `.data/published/stable.json`。

## 结构

| 路径 | 内容 |
| --- | --- |
| `src/server/auth.ts`、`passkey.ts` | 登录：单管理员（账号与密码哈希在环境变量）、签名会话 cookie、按 IP 限速、Passkey。与 Conduit 同一套 |
| `src/server/config/model.ts` | 草稿与发布文件的转换、prompt 版本号；与内置默认值相同的 prompt 不写进文件 |
| `src/server/config/validate.ts` | 发布前校验（共用 JSON Schema + 已知工具 + 版本号单调） |
| `src/server/config/service.ts` | 草稿、发布、回滚，一个事务里写 release、渠道指针、审计和发布文件 |
| `src/server/config/publisher.ts` | 原子写入发布目录，由 Caddy 以 `/config/*` 直接提供 |
| `src/app/admin/` | 页面：配置、发布历史、审计、设置（Passkey） |
| `deploy/` | R4S 上的 compose 与 Caddy 配置 |

## 部署

推到 `main` 且改到 `admin/`、`shared/config-schema/` 或 `DefaultConfig.json` 时，`.github/workflows/vita-admin-deploy.yml` 会：测试 → 在 GitHub 的 arm64 runner 上构建镜像推到 `ghcr.io/leonardo-zhu/vita-admin` → 在 R4S 的 self-hosted runner 上把 `deploy/compose.yaml` 拷到 `/opt/stacks/vita-admin/` 并 `docker compose pull && up -d`。

### 首次准备（在 R4S 上，只做一次）

1. **runner**：给 Vita 仓库在 `github-runners` stack 里注册一个带 `self-hosted, r4s` 标签的 runner（做法同 Conduit 的 `r4s-conduit`）。
2. **部署目录**：`mkdir -p /opt/stacks/vita-admin`，属组与 Conduit 的部署目录一致，runner 要能写。
3. **数据与发布目录**：`mkdir -p /opt/vita-admin/data /opt/vita-admin/published && chown 1000:1000 /opt/vita-admin/data /opt/vita-admin/published`（容器里以 node 用户运行）。
4. **`.env`**：`/opt/stacks/vita-admin/.env`，按 `.env.example` 填 `ADMIN_USERNAME`、`ADMIN_PASSWORD_HASH`（`node scripts/hash-password.mjs`，密码至少 12 位）、`SESSION_SECRET`（`openssl rand -base64 32`）、`PASSKEY_ORIGIN=https://vita.r4s.leonardo-zhu.me`。要在发布前检查模型别名，再填 `CONDUIT_BASE_URL` 和 `CONDUIT_API_KEY`（Conduit 后台给 Vita 应用另建一个密钥）。值里不能有 `$`。
5. **Caddy**：
   - `/opt/stacks/caddy` 的 compose 给 caddy 加只读卷 `/opt/vita-admin/published:/srv/vita-config:ro`，然后重建 caddy 容器（所有反代会断一下）。
   - `/opt/stacks/caddy/Caddyfile` 追加 `deploy/Caddyfile.snippet` 的内容，先 `validate` 再 `reload`。
   - `vita.r4s.leonardo-zhu.me` 已被 `*.r4s` 通配 AAAA 覆盖，不用另加 DNS。
6. 推一次 `main`（或在 Actions 里手动运行），然后登录 `https://vita.r4s.leonardo-zhu.me/admin`，在设置页注册 Passkey，发布第一版配置。

确认：`curl -sI https://vita.r4s.leonardo-zhu.me/config/stable.json` 返回 200 和 `ETag`。

### 改了 `.env` 之后重启

compose 里镜像 tag 默认是 `latest`，服务器上没有 GHCR 的拉取凭据，直接 `up` 会去拉 `latest` 并报 `unauthorized`。用当前运行的 sha，不拉取：

```bash
ssh istoreos 'cd /opt/stacks/vita-admin && ADMIN_TAG=<当前 sha> docker compose up -d --force-recreate --pull never admin'
```

当前 sha 看 `docker compose ps` 的镜像列。

### 回退到旧镜像

```bash
ssh istoreos 'cd /opt/stacks/vita-admin && ADMIN_TAG=<旧 sha> docker compose up -d admin'
```

配置内容的回滚在 Admin 的发布历史里做，不需要回退镜像。
