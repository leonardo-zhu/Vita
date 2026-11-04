/**
 * 入口：读环境变量、打开数据库、监听端口。环境变量见 .env.example。
 * 生产在 R4S 上只监听 127.0.0.1:3014，由同机的 Caddy 反代（《Vita 2.0 架构设计》§5）。
 */
import path from 'node:path'

import { serve } from '@hono/node-server'

import { createApp } from './app.ts'
import { dataDir, openDatabase } from './db.ts'
import { ReferenceCatalog } from './domain/reference.ts'
import { isTimeZone } from './domain/time.ts'
import { createServices } from './services/index.ts'

function fail(message: string): never {
  console.error(message + '，拒绝启动')
  process.exit(1)
}

const serviceToken = process.env.VITA_API_SERVICE_TOKEN ?? ''
if (serviceToken.length < 32) fail('VITA_API_SERVICE_TOKEN 未设置或太短（至少 32 个字符）')

const timeZone = process.env.VITA_API_TIME_ZONE ?? 'Asia/Shanghai'
if (!isTimeZone(timeZone)) fail(`VITA_API_TIME_ZONE=${timeZone} 不是有效的时区`)

// 参考库含私有来源，不进镜像（ADR-006），由服务器上的文件提供；缺了就不能算营养。
const referenceFile = process.env.VITA_API_REFERENCE_FILE ?? path.join(dataDir(), 'reference-foods.json')
let reference: ReferenceCatalog
try {
  reference = ReferenceCatalog.load(referenceFile)
} catch (error) {
  fail(`读不到公共营养参考库 ${referenceFile}：${error instanceof Error ? error.message : String(error)}`)
}
console.log(`公共营养参考库：${reference.count} 条`)

const database = openDatabase()
const services = createServices({ database, reference, now: () => new Date(), timeZone: () => timeZone })
const app = createApp({ services, serviceToken, version: process.env.VITA_API_VERSION ?? 'dev' })
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
