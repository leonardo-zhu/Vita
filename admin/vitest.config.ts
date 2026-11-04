import path from 'node:path'

import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(import.meta.dirname, 'src'),
      // server-only 在 React Server 环境之外会直接抛错，测试里换成空模块
      'server-only': path.resolve(import.meta.dirname, 'src/test/empty.ts'),
    },
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
    // 本地几十毫秒的用例（写 SQLite、发布配置）在 GitHub 的 runner 上并行跑时偶尔要 7 秒，
    // 超过默认的 5 秒（2026-11-04 a8ec28d 那次部署）。放宽上限，不改测试本身。
    testTimeout: 20_000,
  },
})
