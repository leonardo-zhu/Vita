import path from 'node:path'

import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  output: 'standalone',
  // 仓库根目录是 pnpm workspace（ADR-022）：依赖从根目录的 node_modules 追踪，standalone 产物里 server.js 在 admin/ 下
  outputFileTracingRoot: path.join(import.meta.dirname, '..'),
  // 本地的 SQLite 库、发布目录与环境变量文件不该进 standalone 产物
  outputFileTracingExcludes: {
    '*': ['.data/**', '.env*', 'scripts/**', 'src/**', 'deploy/**', '*.tsbuildinfo'],
  },
}

export default nextConfig
