import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  output: 'standalone',
  // 本地的 SQLite 库、发布目录与环境变量文件不该进 standalone 产物
  outputFileTracingExcludes: {
    '*': ['.data/**', '.env*', 'scripts/**', 'src/**', 'deploy/**', '*.tsbuildinfo'],
  },
}

export default nextConfig
