/**
 * Vita API 的 HTTP 层（《Vita 2.0 架构设计》§3、§8）。
 *
 * 鉴权：`Authorization: Bearer <令牌>`。手机用设备令牌，Admin 用服务令牌（只放在两个容器的 .env 里）。
 * `/v1/health` 不需要鉴权；`/v1/admin/*` 只认服务令牌。错误一律返回 `{ error: { code, message } }`。
 */
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto'

import {
  FoodProductUpdate,
  FoodVersionRequest,
  ItemAmountRequest,
  RecordUpdateRequest,
  type FoodProductResponse,
  type ActivePendingResponse,
  ActivityUpload,
  type ChatEvent,
  ChatRequest,
  MAX_LABELS_PER_MESSAGE,
  CreateDeviceRequest,
  type CreateDeviceResponse,
  type DayResponse,
  type Device,
  type ErrorResponse,
  type FoodsResponse,
  GoalRecommendationRequest,
  type GoalRecommendationResponse,
  type GoalResponse,
  type HealthChangesResponse,
  type HealthResponse,
  type HealthSnapshot,
  HealthUpload,
  ImportBundle,
  type ImportResponse,
  type LabelScanResponse,
  ManualBodyMetrics,
  type MessagesResponse,
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
import { streamSSE } from 'hono/streaming'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import type { z } from 'zod'

import { LLMError } from './agent/llm.ts'
import type { Orchestrator, Turn } from './agent/orchestrator.ts'
import { audit } from './db.ts'
import { authenticateDevice, createDevice, listDevices, revokeDevice } from './devices.ts'
import { recommendGoals } from './domain/recommendation.ts'
import { isLocalDate } from './domain/time.ts'
import { MAX_LABEL_BYTES } from './services/chat.ts'
import { ServiceError } from './services/context.ts'
import type { Services } from './services/index.ts'

export interface AppOptions {
  services: Services
  /** 没配 Conduit 时为 null：对话接口返回 503，其余照常。 */
  agent: Orchestrator | null
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
  notConfirmed: [409, '这张卡片还没有确认。'],
  noFollowUp: [409, '这张卡片没有要接着做的事。'],
  alreadyContinued: [409, '这张卡片已经接着做过了。'],
  notEmpty: [409, '服务端已经有数据了，只能导入到空库。'],
  brokenReference: [422, '导入数据里有对不上的引用，什么都没有写入。'],
  unsupportedImage: [415, '只支持 JPEG、PNG 或 HEIC 照片。'],
  imageTooLarge: [413, '照片太大了，请压缩后再传。'],
  invalidMetrics: [422, '读数超出合理范围，没有保存。'],
  expired: [409, '这张卡片已过期，没有写入任何数据。'],
  notActive: [409, '这张卡片已经结束了。'],
  revisionConflict: [409, '当天的数据刚有变化，请刷新后再试；确认卡会因此作废，需要重新提出。'],
  recordNotFound: [404, '没有这条记录。'],
  recordNotInSession: [404, '这条记录不在这一天。'],
  itemNotFound: [404, '这条记录里没有这一项。'],
  emptyRecord: [422, '这是这条记录的最后一项，要删就删除整条记录。'],
  cannotRescale: [422, '这一项没有记克数，只能按份数改。'],
  invalidFactor: [422, '份数应在 0 到 20 之间。'],
  nothingToChange: [422, '没有要改的内容。'],
  eventTimeOutsideSession: [422, '时间只能在同一天里改；换日期请删除后在那一天重记。'],
  productNotFound: [404, '没有这个食品（可能已删除）。'],
  activeVersionChanged: [409, '这个食品刚被改过，请刷新后再改。'],
  emptyName: [422, '名称不能为空。'],
  invalidPackage: [422, '包装规格要大于 0。'],
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

export function createApp({ services, agent, serviceToken, version }: AppOptions) {
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

  /** 历史消息里卡片的结局（已确认、已取消、已过期）。 */
  app.get('/v1/pending/:id', (c) => c.json({ pending: services.pending.get(c.req.param('id')) } satisfies PendingResponse))
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
  // MARK: - 直接编辑（M4）。设备与 Admin 都能用，审计记下是谁

  const expectedRevision = (c: Context) => {
    const raw = c.req.query('expectedRevision')
    const value = raw === undefined ? NaN : Number(raw)
    return Number.isInteger(value) ? value : null
  }
  app.patch('/v1/days/:date/records/:id', async (c) => {
    const date = c.req.param('date')
    if (!isLocalDate(date)) return invalidDate(c)
    const body = await parseBody(c, RecordUpdateRequest)
    if (!body) return invalidBody(c, '时间、餐次名或备注')
    services.records.updateRecord(date, body.expectedRevision, c.req.param('id'), body, { actor: actorName(c.get('actor')) })
    return c.json(services.days.day(date) satisfies DayResponse)
  })
  app.patch('/v1/days/:date/records/:id/items/:itemId', async (c) => {
    const date = c.req.param('date')
    if (!isLocalDate(date)) return invalidDate(c)
    const body = await parseBody(c, ItemAmountRequest)
    if (!body) return invalidBody(c, '用量或份数（给且只给一个）')
    services.records.rescaleItem(date, body.expectedRevision, c.req.param('id'), c.req.param('itemId'), body, { actor: actorName(c.get('actor')) })
    return c.json(services.days.day(date) satisfies DayResponse)
  })
  app.delete('/v1/days/:date/records/:id/items/:itemId', (c) => {
    const date = c.req.param('date')
    if (!isLocalDate(date)) return invalidDate(c)
    const revision = expectedRevision(c)
    if (revision === null) return invalidBody(c, 'expectedRevision')
    services.records.apply({ kind: 'removeItem', recordId: c.req.param('id'), itemId: c.req.param('itemId') }, date, revision, { actor: actorName(c.get('actor')) })
    return c.json(services.days.day(date) satisfies DayResponse)
  })
  app.delete('/v1/days/:date/records/:id', (c) => {
    const date = c.req.param('date')
    if (!isLocalDate(date)) return invalidDate(c)
    const revision = expectedRevision(c)
    if (revision === null) return invalidBody(c, 'expectedRevision')
    services.records.apply({ kind: 'deleteRecord', recordId: c.req.param('id') }, date, revision, { actor: actorName(c.get('actor')) })
    return c.json(services.days.day(date) satisfies DayResponse)
  })
  app.get('/v1/foods/:id', (c) => c.json({ product: services.foods.product(c.req.param('id')) } satisfies FoodProductResponse))
  app.patch('/v1/foods/:id', async (c) => {
    const body = await parseBody(c, FoodProductUpdate)
    if (!body) return invalidBody(c, '名称、品牌、包装或备注')
    return c.json({ product: services.foods.updateProduct(c.req.param('id'), body, { actor: actorName(c.get('actor')) }) } satisfies FoodProductResponse)
  })
  app.post('/v1/foods/:id/versions', async (c) => {
    const body = await parseBody(c, FoodVersionRequest)
    if (!body) return invalidBody(c, '营养基准')
    const product = services.foods.addManualVersion(c.req.param('id'), body.expectedActiveVersionId, body.basis, body.sourceNote ?? null, {
      actor: actorName(c.get('actor')),
    })
    return c.json({ product } satisfies FoodProductResponse, 201)
  })
  app.delete('/v1/foods/:id', (c) => {
    services.foods.deleteProduct(c.req.param('id'), { actor: actorName(c.get('actor')) })
    return c.body(null, 204)
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

  /** Apple 健康同步：手机拉取 after 之后的变更，处理完把 cursor 存下。 */
  app.get('/v1/health-sync/changes', (c) => {
    const after = Number(c.req.query('after') ?? 0)
    if (!Number.isInteger(after) || after < 0) return invalidBody(c, 'after 应为非负整数')
    return c.json(services.healthSync.changes(after) satisfies HealthChangesResponse)
  })

  /** 从 1.0 迁移：只在业务库为空时接受，整体一个事务。 */
  app.post('/v1/import', async (c) => {
    const body = await parseBody(c, ImportBundle)
    if (!body) return invalidBody(c, '导入数据的格式')
    return c.json(services.importer.run(body, { actor: actorName(c.get('actor')) }) satisfies ImportResponse, 201)
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

  // MARK: - 对话（Agent 在服务端跑，进度以 SSE 推给手机）

  /** 进行中的轮次，用来响应"停止"。 */
  const turns = new Map<string, AbortController>()

  /**
   * 跑一轮并把进度推给客户端。客户端断线时这一轮照样跑完并保存（重连后读历史即可），只有调停止接口才会中止。
   * 失败或被停止时什么都不保存，最后一个事件是 error。
   */
  const runTurn = (c: Context, turn: Turn, date: string) => {
    if (!agent) return failure(c, 503, 'agentUnavailable', '服务端没有配置模型网关，暂时不能对话。')
    const controller = new AbortController()
    const requestId = randomUUID()
    const actor = actorName(c.get('actor'))
    turns.set(requestId, controller)
    return streamSSE(c, async (stream) => {
      let open = true
      stream.onAbort(() => {
        open = false
      })
      // 写入是异步的：串成一条链保证顺序，结束前等它写完，最后的 done / error 才不会丢。
      let writes = Promise.resolve()
      const emit = (event: ChatEvent) => {
        writes = writes.then(async () => {
          if (!open) return
          try {
            await stream.writeSSE({ event: event.type, data: JSON.stringify(event) })
          } catch {
            open = false
          }
        })
      }
      try {
        const result = await agent.run(turn, date, actor, emit, controller.signal, requestId)
        emit({ type: 'done', ...result })
      } catch (error) {
        if (controller.signal.aborted) {
          emit({ type: 'error', code: 'cancelled', message: '已停止，这一轮没有保存。' })
        } else if (error instanceof LLMError) {
          emit({ type: 'error', code: error.code, message: error.userMessage })
        } else {
          console.error(error)
          emit({ type: 'error', code: 'internal', message: '服务暂时无法处理这个请求。' })
        }
      } finally {
        turns.delete(requestId)
        await writes
      }
    })
  }

  app.get('/v1/days/:date/messages', (c) => {
    const date = c.req.param('date')
    return isLocalDate(date) ? c.json({ messages: services.chat.messages(date) } satisfies MessagesResponse) : invalidDate(c)
  })
  app.post('/v1/days/:date/chat', async (c) => {
    const date = c.req.param('date')
    if (!isLocalDate(date)) return invalidDate(c)
    const body = await parseBody(c, ChatRequest)
    if (!body) return invalidBody(c, '消息为空')
    const labelScanIds = [...new Set([...(body.labelScanIds ?? []), ...(body.labelScanId ? [body.labelScanId] : [])])]
    if (!body.text.trim() && labelScanIds.length === 0) return invalidBody(c, '消息为空')
    if (labelScanIds.length > MAX_LABELS_PER_MESSAGE) return invalidBody(c, `一条消息最多带 ${MAX_LABELS_PER_MESSAGE} 张照片`)
    if (labelScanIds.some((id) => !services.labels.exists(id))) return failure(c, 404, 'labelNotFound', '找不到这张标签照片，请重新上传。')
    return runTurn(c, { kind: 'message', text: body.text.trim(), labelScanIds }, date)
  })
  /** 确认了一张带 afterConfirm 的卡片后，接着跑一轮。每张卡片只能接续一次。 */
  app.post('/v1/pending/:id/continue', (c) => {
    const id = c.req.param('id')
    const { sessionDate, step } = services.pending.claimContinuation(id)
    return runTurn(c, { kind: 'continuation', pendingId: id, step }, sessionDate)
  })
  app.post('/v1/chat-turns/:requestId/cancel', (c) => {
    turns.get(c.req.param('requestId'))?.abort()
    return c.body(null, 204)
  })

  // MARK: - 标签照片

  app.post('/v1/label-scans', async (c) => {
    const declared = Number(c.req.header('content-length') ?? 0)
    if (declared > MAX_LABEL_BYTES) return serviceFailure(c, new ServiceError('label', 'imageTooLarge'))
    const bytes = new Uint8Array(await c.req.arrayBuffer())
    const contentType = (c.req.header('content-type') ?? '').split(';')[0].trim()
    const labelScanId = services.labels.save(bytes, contentType, { actor: actorName(c.get('actor')) })
    return c.json({ labelScanId } satisfies LabelScanResponse, 201)
  })
  app.get('/v1/label-scans/:id', (c) => {
    const file = services.labels.read(c.req.param('id'))
    if (!file) return failure(c, 404, 'labelNotFound', '找不到这张标签照片。')
    return c.body(new Uint8Array(file.bytes), 200, { 'content-type': file.contentType, 'cache-control': 'private, max-age=86400' })
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
