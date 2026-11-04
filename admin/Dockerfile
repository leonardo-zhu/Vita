# Vita Admin：一个 Next.js standalone 服务。CI 在 ARM runner 上构建 linux/arm64。
#
# 构建上下文是仓库根目录（docker build -f admin/Dockerfile .）：除了 admin/，还要根目录的 pnpm workspace 与 lockfile，
# 以及 shared/config-schema/、shared/agent-tools/、shared/diagnostics/ 与 shared/config/DefaultConfig.json，由 scripts/sync-shared.mjs 拷进 src/generated/。
# 上下文只放这几样，见 Dockerfile.dockerignore。
#
# 运行时需要的环境变量见 .env.example。SQLite 在 /data，发布目录在 /published，都要挂成卷。
# 默认只监听 127.0.0.1，由同机的 Caddy 反代（R4S 上用 network_mode: host）。

FROM node:24.15.0-alpine AS build
WORKDIR /repo
RUN corepack enable && corepack prepare pnpm@10.33.2 --activate
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY admin/package.json admin/
COPY api/package.json api/
COPY packages/contract/package.json packages/contract/
RUN pnpm install --frozen-lockfile --filter vita-admin...
WORKDIR /repo/admin
COPY shared/config-schema /repo/shared/config-schema
COPY shared/agent-tools /repo/shared/agent-tools
COPY shared/diagnostics /repo/shared/diagnostics
COPY shared/config/DefaultConfig.json /repo/shared/config/DefaultConfig.json
COPY packages/contract /repo/packages/contract
COPY admin ./
ENV NEXT_TELEMETRY_DISABLED=1
RUN pnpm build

FROM node:24.15.0-alpine
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3013 \
    HOSTNAME=127.0.0.1 \
    TZ=Asia/Shanghai \
    VITA_ADMIN_DATA_DIR=/data \
    VITA_PUBLISH_DIR=/published
COPY --from=build --chown=node:node /repo/admin/.next/standalone ./
COPY --from=build --chown=node:node /repo/admin/.next/static ./admin/.next/static
RUN mkdir -p /data /published && chown node:node /data /published
USER node
EXPOSE 3013
HEALTHCHECK --interval=60s --timeout=10s --start-period=20s --retries=3 \
  CMD wget -q -O - "http://127.0.0.1:${PORT}/api/status" | grep -q '"success":true' || exit 1
CMD ["node", "admin/server.js"]
