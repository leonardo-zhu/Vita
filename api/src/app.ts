/**
 * Vita API 的 HTTP 层（《Vita 2.0 架构设计》§3、§8）。
 *
 * 鉴权：`Authorization: Bearer <令牌>`。手机用设备令牌，Admin 用服务令牌（只放在两个容器的 .env 里）。
 * `/v1/health` 不需要鉴权；`/v1/admin/*` 只认服务令牌。错误一律返回 `{ error: { code, message } }`。
 */
import { createHash, timingSafeEqual } from 'node:crypto'
import type { DatabaseSync } from 'node:sqlite'

import {
  CreateDeviceRequest,
  type CreateDeviceResponse,
  type Device,
  type ErrorResponse,
  type HealthResponse,
  type ListDevicesResponse,
  type MeResponse,
} from '@vita/contract'
import { Hono, type Context } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import type { z } from 'zod'

import { audit } from './db.ts'
import { authenticateDevice, createDevice, listDevices, revokeDevice } from './devices.ts'

export interface AppOptions {
  database: DatabaseSync
  serviceToken: string
  version: string
  now?: () => Date
}

type Actor = { kind: 'admin' } | { kind: 'device'; device: Device }

type AppEnv = { Variables: { actor: Actor } }

function failure(c: Context, status: ContentfulStatusCode, code: string, message: string) {
  return c.json({ error: { code, message } } satisfies ErrorResponse, status)
}

/** 比较前先各取 sha256，长度一致才能用 timingSafeEqual，也不泄露长度。 */
function sameSecret(a: string, b: string): boolean {
  const digest = (value: string) => createHash('sha256').update(value).digest()
  return timingSafeEqual(digest(a), digest(b))
}

function actorName(actor: Actor): string {
  return actor.kind === 'admin' ? 'admin' : `device:${actor.device.id}`
}

async function parseBody<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T> | null> {
  const body = await c.req.json().catch(() => undefined)
  const parsed = schema.safeParse(body)
  return parsed.success ? parsed.data : null
}

export function createApp({ database, serviceToken, version, now = () => new Date() }: AppOptions) {
  const app = new Hono<AppEnv>()

  app.onError((error, c) => {
    console.error(error)
    return failure(c, 500, 'internal', '服务暂时无法处理这个请求。')
  })
  app.notFound((c) => failure(c, 404, 'notFound', '没有这个接口。'))

  app.get('/v1/health', (c) => c.json({ ok: true, version } satisfies HealthResponse))

  app.use('/v1/*', async (c, next) => {
    const header = c.req.header('authorization') ?? ''
    const token = header.startsWith('Bearer ') ? header.slice('Bearer '.length).trim() : ''
    if (!token) return failure(c, 401, 'unauthorized', '缺少访问令牌。')
    if (sameSecret(token, serviceToken)) {
      c.set('actor', { kind: 'admin' })
    } else {
      const device = authenticateDevice(database, token, now())
      if (!device) return failure(c, 401, 'unauthorized', '访问令牌无效或已吊销。')
      c.set('actor', { kind: 'device', device })
    }
    await next()
  })

  app.use('/v1/admin/*', async (c, next) => {
    if (c.get('actor').kind !== 'admin') return failure(c, 403, 'forbidden', '只有 Admin 能调用这个接口。')
    await next()
  })

  app.get('/v1/me', (c) => {
    const actor = c.get('actor')
    if (actor.kind !== 'device') return failure(c, 403, 'forbidden', '这个接口只给设备令牌用。')
    return c.json({ device: actor.device } satisfies MeResponse)
  })

  // MARK: - 设备管理（只给 Admin）

  app.get('/v1/admin/devices', (c) => c.json({ devices: listDevices(database) } satisfies ListDevicesResponse))

  app.post('/v1/admin/devices', async (c) => {
    const body = await parseBody(c, CreateDeviceRequest)
    if (!body) return failure(c, 400, 'invalidRequest', '需要 name（1 到 64 个字符）。')
    const at = now()
    const created = createDevice(database, body.name, at)
    audit(database, { actor: actorName(c.get('actor')), action: 'device.create', targetId: created.device.id, result: 'success', at })
    return c.json(created satisfies CreateDeviceResponse, 201)
  })

  app.delete('/v1/admin/devices/:id', (c) => {
    const id = c.req.param('id')
    const at = now()
    const revoked = revokeDevice(database, id, at)
    if (revoked === null) return failure(c, 404, 'deviceNotFound', '没有这个设备。')
    if (revoked) audit(database, { actor: actorName(c.get('actor')), action: 'device.revoke', targetId: id, result: 'success', at })
    return c.body(null, 204)
  })

  return app
}
