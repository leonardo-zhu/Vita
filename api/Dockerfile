# Vita API：打包成单个 dist/server.js 的 Node 服务。CI 在 ARM runner 上构建 linux/arm64。
#
# 构建上下文是仓库根目录（docker build -f api/Dockerfile .）：要用根目录的 pnpm workspace 与 lockfile，
# 以及 packages/contract。上下文只放这几样，见 Dockerfile.dockerignore。
#
# 运行时需要的环境变量见 .env.example。SQLite 在 /data，要挂成卷。
# 默认只监听 127.0.0.1，由同机的 Caddy 反代（R4S 上用 network_mode: host）。

FROM node:24.15.0-alpine AS build
WORKDIR /repo
RUN corepack enable && corepack prepare pnpm@10.33.2 --activate
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY admin/package.json admin/
COPY api/package.json api/
COPY packages/contract/package.json packages/contract/
RUN pnpm install --frozen-lockfile --filter vita-api...
COPY packages/contract packages/contract
COPY api api
ARG VITA_API_VERSION=dev
RUN cd api && VITA_API_VERSION=$VITA_API_VERSION pnpm build

FROM node:24.15.0-alpine
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3014 \
    VITA_API_HOST=127.0.0.1 \
    TZ=Asia/Shanghai \
    VITA_API_DATA_DIR=/data
COPY --from=build --chown=node:node /repo/api/dist ./
RUN mkdir -p /data && chown node:node /data
USER node
EXPOSE 3014
HEALTHCHECK --interval=60s --timeout=10s --start-period=10s --retries=3 \
  CMD wget -q -O - "http://127.0.0.1:${PORT}/v1/health" | grep -q '"ok":true' || exit 1
CMD ["node", "--enable-source-maps", "server.js"]
