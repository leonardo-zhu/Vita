// 把 API 打成单个 dist/server.js：依赖（Hono、zod、@vita/contract）全部打进去，镜像里不用 node_modules。
// Node 24 能直接跑 .ts，但不剥离 node_modules 里的类型，打包后部署最省事（《Vita 2.0 架构设计》§4）。
import { build } from 'esbuild'
import process from 'node:process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const api = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

await build({
  entryPoints: [path.join(api, 'src/server.ts')],
  outfile: path.join(api, 'dist/server.js'),
  bundle: true,
  platform: 'node',
  target: 'node24',
  format: 'esm',
  sourcemap: true,
  // 打包进来的 CommonJS 依赖会用到 require
  banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
  define: { 'process.env.VITA_API_VERSION': JSON.stringify(process.env.VITA_API_VERSION ?? 'dev') },
  logLevel: 'info',
})
