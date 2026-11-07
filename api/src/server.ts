/**
 * 入口：读环境变量、打开数据库、监听端口。环境变量见 .env.example。
 * 生产在 R4S 上只监听 127.0.0.1:3014，由同机的 Caddy 反代（《Vita 2.0 架构设计》§5）。
 */
import path from 'node:path'

import { serve } from '@hono/node-server'

import { PublishedConfigSource } from './agent/config.ts'
import { ResponsesClient } from './agent/llm.ts'
import { Orchestrator } from './agent/orchestrator.ts'
import { createApp } from './app.ts'
import { dataDir, openDatabase } from './db.ts'
import { ReferenceCatalog } from './domain/reference.ts'
import { isTimeZone } from './domain/time.ts'
import { GoogleHealthClient } from './google/client.ts'
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

// Google 健康（活动能量与睡眠）：三项都配了才启用，没配时连接接口返回 503，其余照常。
const googleClientId = process.env.GOOGLE_HEALTH_CLIENT_ID
const googleClientSecret = process.env.GOOGLE_HEALTH_CLIENT_SECRET
const googleRedirectUri = process.env.GOOGLE_HEALTH_REDIRECT_URI
const googleHealth =
  googleClientId && googleClientSecret && googleRedirectUri
    ? { client: new GoogleHealthClient({ clientId: googleClientId, clientSecret: googleClientSecret, redirectUri: googleRedirectUri }), secret: serviceToken }
    : null
if (!googleHealth) console.warn('没有配置 GOOGLE_HEALTH_CLIENT_ID / GOOGLE_HEALTH_CLIENT_SECRET / GOOGLE_HEALTH_REDIRECT_URI，不能连接 Google 健康')

const database = openDatabase()
// 标签照片等文件；默认在数据目录下的 files/。
const services = createServices({ database, reference, now: () => new Date(), timeZone: () => timeZone }, process.env.VITA_API_FILES_DIR, googleHealth)

// 连了 Google 健康时每 30 分钟拉一次；读数据时过了 10 分钟也会先拉（见 app.ts）。
const GOOGLE_SYNC_INTERVAL_MS = 30 * 60_000
const googleTimer = googleHealth ? setInterval(() => void services.googleHealth.sync({ actor: 'system' }), GOOGLE_SYNC_INTERVAL_MS) : null
googleTimer?.unref()
// 模型经 Conduit 调用，密钥只在服务端（架构设计 §8）。没配时对话接口返回 503，其余照常。
const conduitURL = process.env.CONDUIT_BASE_URL
const conduitKey = process.env.CONDUIT_API_KEY
const agent =
  conduitURL && conduitKey
    ? new Orchestrator({
        services,
        client: new ResponsesClient(conduitURL, conduitKey),
        // Admin 发布的 stable.json（只读挂载）；没有时用内置默认值。
        config: new PublishedConfigSource(process.env.VITA_API_PUBLISHED_CONFIG ?? null),
      })
    : null
if (!agent) console.warn('没有配置 CONDUIT_BASE_URL / CONDUIT_API_KEY，对话不可用')

const app = createApp({ services, agent, serviceToken, version: process.env.VITA_API_VERSION ?? 'dev', adminURL: process.env.VITA_ADMIN_PUBLIC_URL })
const port = Number(process.env.PORT ?? 3014)
// 不用 HOSTNAME：不少 shell 会把它设成机器名
const hostname = process.env.VITA_API_HOST ?? '127.0.0.1'

const server = serve({ fetch: app.fetch, port, hostname }, (info) => {
  console.log(`Vita API 监听 http://${hostname}:${info.port}`)
})

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    if (googleTimer) clearInterval(googleTimer)
    server.close(() => {
      database.close()
      process.exit(0)
    })
  })
}
