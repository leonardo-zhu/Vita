/**
 * Vita API 的 HTTP 层（《Vita 2.0 架构设计》§3、§8）。
 *
 * 鉴权：`Authorization: Bearer <令牌>`。手机用设备令牌，Admin 用服务令牌（只放在两个容器的 .env 里）。
 * `/v1/health` 不需要鉴权；`/v1/admin/*` 只认服务令牌。错误一律返回 `{ error: { code, message } }`。
 */
import { createHash, timingSafeEqual } from 'node:crypto'

import {
  type ActivePendingResponse,
  ActivityUpload,
  CreateDeviceRequest,
  type CreateDeviceResponse,
  type DayResponse,
  type Device,
  type ErrorResponse,
  type FoodsResponse,
  GoalRecommendationRequest,
  type GoalRecommendationResponse,
  type GoalResponse,
  type HealthResponse,
  type HealthSnapshot,
  HealthUpload,
  ManualBodyMetrics,
  type ListDevicesResponse,
  type MeResponse,
  type PendingResponse,
  type ReferenceSearchResponse,
  ScaleReadingRequest,
  type ScaleReadingResponse,
  type WeighingResponse,
  type WeighingsResponse,
  WeighingUpload,
} from '@vita/contract'
import { Hono, type Context } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import type { z } from 'zod'

import { audit } from './db.ts'
import { authenticateDevice, createDevice, listDevices, revokeDevice } from './devices.ts'
import { recommendGoals } from './domain/recommendation.ts'
import { isLocalDate } from './domain/time.ts'
import { ServiceError } from './services/context.ts'
import type { Services } from './services/index.ts'

export interface AppOptions {
  services: Services
  serviceToken: string
  version: string
}

type Actor = { kind: 'admin' } | { kind: 'device'; device: Device }

type AppEnv = { Variables: { actor: Actor } }

function failure(c: Context, status: ContentfulStatusCode, code: string, message: string) {
  return c.json({ error: { code, message } } satisfies ErrorResponse, status)
}

/** 业务规则的拒绝：不存在 404，状态不允许（过期、已结束、数据已变）409，其余 422。 */
const SERVICE_FAILURES: Record<string, [ContentfulStatusCode, string]> = {
  notFound: [404, '没有这张卡片。'],
  weighingNotFound: [404, '没有这次称重。'],
  invalidMetrics: [422, '读数超出合理范围，没有保存。'],
  expired: [409, '这张卡片已过期，没有写入任何数据。'],
  notActive: [409, '这张卡片已经结束了。'],
  revisionConflict: [409, '当天数据在提案后有变化，这张卡片已作废，请重新提出。'],
  payloadTampered: [409, '这张卡片的内容校验不通过，已作废。'],
}

function serviceFailure(c: Context, error: ServiceError) {
  const [status, message] = SERVICE_FAILURES[error.code] ?? [422, '这次操作不符合规则，没有写入任何数据。']
  return failure(c, status, error.code, message)
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

export function createApp({ services, serviceToken, version }: AppOptions) {
  const { database, now } = services.context
  const app = new Hono<AppEnv>()

  app.onError((error, c) => {
    if (error instanceof ServiceError) return serviceFailure(c, error)
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

  // MARK: - 饮食数据

  const invalidDate = (c: Context) => failure(c, 400, 'invalidDate', '日期格式应为 YYYY-MM-DD。')
  app.get('/v1/days/:date', (c) => {
    const date = c.req.param('date')
    return isLocalDate(date) ? c.json(services.days.day(date) satisfies DayResponse) : invalidDate(c)
  })
  app.get('/v1/days/:date/pending', (c) => {
    const date = c.req.param('date')
    return isLocalDate(date) ? c.json({ pending: services.pending.active(date) } satisfies ActivePendingResponse) : invalidDate(c)
  })

  // 确认卡只能由用户在卡片上确认或取消；提案由 Agent 在服务端生成（M2），不对外开放。
  app.post('/v1/pending/:id/confirm', (c) =>
    c.json({ pending: services.pending.confirm(c.req.param('id'), { actor: actorName(c.get('actor')) }) } satisfies PendingResponse),
  )
  app.post('/v1/pending/:id/cancel', (c) =>
    c.json({ pending: services.pending.cancel(c.req.param('id'), { actor: actorName(c.get('actor')) }) } satisfies PendingResponse),
  )

  app.get('/v1/foods', (c) => {
    const query = c.req.query('q')
    return c.json({ products: query ? services.foods.search(query) : services.foods.products() } satisfies FoodsResponse)
  })
  app.get('/v1/reference-foods', (c) => c.json(services.context.reference.browse(c.req.query('q') ?? '') satisfies ReferenceSearchResponse))

  // MARK: - 健康数据：手机读 Apple 健康后上传

  const invalidBody = (c: Context, what: string) => failure(c, 400, 'invalidRequest', `请求内容不合格：${what}。`)
  const queryDate = (c: Context) => {
    const date = c.req.query('date') ?? ''
    return isLocalDate(date) ? date : null
  }

  app.put('/v1/health/snapshot', async (c) => {
    const body = await parseBody(c, HealthUpload)
    if (!body) return invalidBody(c, '身体数据')
    services.health.upload(body, { actor: actorName(c.get('actor')) })
    return c.body(null, 204)
  })
  app.put('/v1/health/activity', async (c) => {
    const body = await parseBody(c, ActivityUpload)
    if (!body) return invalidBody(c, '活动能量（1 到 31 天，每天不为负）')
    services.health.uploadActivity(body, { actor: actorName(c.get('actor')) })
    return c.body(null, 204)
  })
  app.put('/v1/health/manual-metrics', async (c) => {
    const body = await parseBody(c, ManualBodyMetrics)
    if (!body) return invalidBody(c, '身体数据超出合理范围')
    return c.json(services.health.submitManualMetrics(body, { actor: actorName(c.get('actor')) }) satisfies ManualBodyMetrics)
  })
  app.get('/v1/health/snapshot', (c) => {
    const date = queryDate(c)
    return date ? c.json(services.health.snapshot(date) satisfies HealthSnapshot) : invalidDate(c)
  })

  // MARK: - 目标

  app.get('/v1/goals/active', (c) => {
    const date = queryDate(c)
    return date ? c.json({ goal: services.goals.active(date) } satisfies GoalResponse) : invalidDate(c)
  })
  /** 只算不存：按服务端存的健康数据给出建议，客户端只选类型和调整。 */
  app.post('/v1/goals/recommendation', async (c) => {
    const body = await parseBody(c, GoalRecommendationRequest)
    if (!body) return invalidBody(c, '日期、目标类型或调整幅度')
    const result = recommendGoals(services.health.snapshot(body.date), body.date, now(), body.kind, body.adjustment)
    return c.json(result satisfies GoalRecommendationResponse)
  })
  /** 用户确认建议后生成目标。服务端重新计算，不采用客户端给的数值。 */
  app.post('/v1/goals/initial', async (c) => {
    const body = await parseBody(c, GoalRecommendationRequest)
    if (!body) return invalidBody(c, '日期、目标类型或调整幅度')
    const result = recommendGoals(services.health.snapshot(body.date), body.date, now(), body.kind, body.adjustment)
    if (result.status === 'missing') return failure(c, 422, 'missingMetrics', `缺少身体数据：${result.missing.join('、')}。`)
    const goal = services.goals.commitInitial(result.recommendation, body.date, { actor: actorName(c.get('actor')) })
    return c.json({ goal } satisfies GoalResponse, 201)
  })

  // MARK: - 身体成分：手机连秤后上传称重

  app.post('/v1/weighings', async (c) => {
    const body = await parseBody(c, WeighingUpload)
    if (!body) return invalidBody(c, '称重数据')
    const weighing = services.body.record(body, { actor: actorName(c.get('actor')) })
    return c.json({ weighing } satisfies WeighingResponse, 201)
  })
  app.get('/v1/weighings', (c) =>
    c.json({ weighings: services.body.weighings(), calibration: services.body.calibration() } satisfies WeighingsResponse),
  )
  app.put('/v1/weighings/:id/scale-reading', async (c) => {
    const body = await parseBody(c, ScaleReadingRequest)
    if (!body) return invalidBody(c, '体脂率应在 2% 到 70% 之间')
    const result = services.body.setScaleReading(c.req.param('id'), body.bodyFatFraction, { actor: actorName(c.get('actor')) })
    return c.json(result satisfies ScaleReadingResponse)
  })
  app.delete('/v1/weighings/:id', (c) => {
    services.body.delete(c.req.param('id'), { actor: actorName(c.get('actor')) })
    return c.body(null, 204)
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
