/**
 * 入口：读环境变量、打开数据库、监听端口。环境变量见 .env.example。
 * 生产在 R4S 上只监听 127.0.0.1:3014，由同机的 Caddy 反代（《Vita 2.0 架构设计》§5）。
 */
import { serve } from '@hono/node-server'

import { createApp } from './app.ts'
import { openDatabase } from './db.ts'

const serviceToken = process.env.VITA_API_SERVICE_TOKEN ?? ''
if (serviceToken.length < 32) {
  console.error('VITA_API_SERVICE_TOKEN 未设置或太短（至少 32 个字符），拒绝启动')
  process.exit(1)
}

const database = openDatabase()
const app = createApp({ database, serviceToken, version: process.env.VITA_API_VERSION ?? 'dev' })
const port = Number(process.env.PORT ?? 3014)
// 不用 HOSTNAME：不少 shell 会把它设成机器名
const hostname = process.env.VITA_API_HOST ?? '127.0.0.1'

const server = serve({ fetch: app.fetch, port, hostname }, (info) => {
  console.log(`Vita API 监听 http://${hostname}:${info.port}`)
})

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    server.close(() => {
      database.close()
      process.exit(0)
    })
  })
}
