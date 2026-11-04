/**
 * 饮食数据、确认卡、食品库与参考库接口：响应符合 @vita/contract，业务错误映射到 HTTP 状态码。
 */
import { randomUUID } from 'node:crypto'

import {
  ActivePendingResponse,
  ChatEvent,
  CreateDeviceResponse,
  DayResponse,
  ErrorResponse,
  FoodsResponse,
  GoalRecommendationResponse,
  GoalResponse,
  HealthSnapshot,
  LabelScanResponse,
  MessagesResponse,
  ScaleReadingResponse,
  WeighingResponse,
  WeighingsResponse,
  PendingResponse,
  ReferenceSearchResponse,
} from '@vita/contract'
import { describe, expect, it } from 'vitest'

import { StaticConfigSource } from './agent/config.ts'
import { LLMError, type LLMClient, type LLMEvent } from './agent/llm.ts'
import { Orchestrator } from './agent/orchestrator.ts'
import { createApp } from './app.ts'
import { DAY, estimate, lunch, ORIGIN, setup } from './test/support.ts'

const SERVICE_TOKEN = 'test-service-token-0123456789abcdef'

async function withDevice() {
  const context = setup()
  const app = createApp({ services: context.services, agent: null, serviceToken: SERVICE_TOKEN, version: 'test' })
  const created = await app.request('/v1/admin/devices', {
    method: 'POST',
    headers: { authorization: `Bearer ${SERVICE_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'iPhone' }),
  })
  const { token, device } = CreateDeviceResponse.parse(await created.json())
  const call = (path: string, method = 'GET', body?: unknown) =>
    app.request(path, {
      method,
      headers: { authorization: `Bearer ${token}`, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  return { ...context, call, device }
}

describe('一天的数据', () => {
  it('没有记录的日子返回空日，revision 为 0', async () => {
    const { call } = await withDevice()
    const response = await call(`/v1/days/${DAY}`)
    expect(response.status).toBe(200)
    expect(DayResponse.parse(await response.json())).toMatchObject({ date: DAY, revision: 0, records: [] })
  })

  it('日期不合法时返回 400', async () => {
    const { call } = await withDevice()
    for (const path of ['/v1/days/2026-02-30', '/v1/days/today/pending']) {
      const response = await call(path)
      expect(response.status).toBe(400)
      expect(ErrorResponse.parse(await response.json()).error.code).toBe('invalidDate')
    }
  })
})

describe('确认卡', () => {
  it('看到当天的卡片，确认后数据写入，审计记下是哪台设备', async () => {
    const { call, services, database, device } = await withDevice()
    const proposed = services.pending.proposeRecord({ kind: 'create', draft: lunch([estimate(500)]) }, DAY, 0, ORIGIN)

    const active = ActivePendingResponse.parse(await (await call(`/v1/days/${DAY}/pending`)).json())
    expect(active.pending?.id).toBe(proposed.id)

    const response = await call(`/v1/pending/${proposed.id}/confirm`, 'POST')
    expect(response.status).toBe(200)
    expect(PendingResponse.parse(await response.json()).pending.status).toBe('confirmed')
    expect(DayResponse.parse(await (await call(`/v1/days/${DAY}`)).json()).summary.totals.energyKcal).toBe(500)
    expect(database.prepare("SELECT actor FROM audit_events WHERE action = 'record.create'").get()).toEqual({ actor: `device:${device.id}` })
  })

  it('已结束的卡片返回 409，不存在的返回 404', async () => {
    const { call, services } = await withDevice()
    const proposed = services.pending.proposeRecord({ kind: 'create', draft: lunch([estimate(500)]) }, DAY, 0, ORIGIN)
    expect((await call(`/v1/pending/${proposed.id}/cancel`, 'POST')).status).toBe(200)

    const again = await call(`/v1/pending/${proposed.id}/confirm`, 'POST')
    expect(again.status).toBe(409)
    expect(ErrorResponse.parse(await again.json()).error.code).toBe('notActive')
    expect((await call(`/v1/pending/${randomUUID()}/confirm`, 'POST')).status).toBe(404)
  })

  it('按 ID 读卡片的结局，供历史消息显示', async () => {
    const { call, services } = await withDevice()
    const proposed = services.pending.proposeRecord({ kind: 'create', draft: lunch([estimate(500)]) }, DAY, 0, ORIGIN)
    await call(`/v1/pending/${proposed.id}/cancel`, 'POST')
    const read = PendingResponse.parse(await (await call(`/v1/pending/${proposed.id}`)).json())
    expect(read.pending.status).toBe('cancelled')
    expect((await call(`/v1/pending/${randomUUID()}`)).status).toBe(404)
  })

  it('过期的卡片返回 409 expired', async () => {
    const { call, services, clock } = await withDevice()
    const proposed = services.pending.proposeRecord({ kind: 'create', draft: lunch([estimate(500)]) }, DAY, 0, ORIGIN)
    clock.advance(31)
    const response = await call(`/v1/pending/${proposed.id}/confirm`, 'POST')
    expect(response.status).toBe(409)
    expect(ErrorResponse.parse(await response.json()).error.code).toBe('expired')
  })
})

describe('食品库与参考库', () => {
  it('列出与搜索个人食品', async () => {
    const { call, services } = await withDevice()
    services.foods.apply(
      {
        kind: 'createProduct',
        product: { name: '纯牛奶', brandOrSupplier: '某乳业', package: null, note: null },
        version: {
          basis: { quantity: { amount: 100, unit: 'ml' }, nutrients: { energyKcal: 60, proteinG: 3, fatG: 3, carbohydrateG: 5 } },
          sourceKind: 'manualEntry',
          labelScanId: null,
          derivedFromReferenceId: null,
          sourceNote: null,
        },
      },
      ORIGIN,
    )
    expect(FoodsResponse.parse(await (await call('/v1/foods')).json()).products).toHaveLength(1)
    expect(FoodsResponse.parse(await (await call('/v1/foods?q=乳业')).json()).products).toHaveLength(1)
    expect(FoodsResponse.parse(await (await call('/v1/foods?q=豆浆')).json()).products).toHaveLength(0)
  })

  it('参考库搜索分出精确候选与部分匹配', async () => {
    const { call } = await withDevice()
    const result = ReferenceSearchResponse.parse(await (await call(`/v1/reference-foods?q=${encodeURIComponent('鸡胸肉')}`)).json())
    expect(result.exact).toHaveLength(2)
  })
})

describe('健康数据与目标', () => {
  const noData = { status: 'noData' }
  const upload = {
    bodyMassKg: { status: 'value', value: 70, source: 'healthKit', measuredAt: '2026-10-30T00:00:00.000Z' },
    heightCm: noData,
    bodyFatFraction: noData,
    dateOfBirth: noData,
    sex: noData,
    sleepHours: noData,
    authorizationRequested: true,
    writeDenied: false,
  }

  it('上传身体数据与活动，读回合并后的快照', async () => {
    const { call } = await withDevice()
    expect((await call('/v1/health/snapshot', 'PUT', upload)).status).toBe(204)
    expect((await call('/v1/health/activity', 'PUT', { days: [{ date: DAY, activeKcal: 320 }] })).status).toBe(204)
    const snapshot = HealthSnapshot.parse(await (await call(`/v1/health/snapshot?date=${DAY}`)).json())
    expect(snapshot.bodyMassKg).toMatchObject({ value: 70 })
    expect(snapshot.activeEnergyKcal).toMatchObject({ value: 320 })
  })

  it('不合格的上传返回 400', async () => {
    const { call } = await withDevice()
    expect((await call('/v1/health/snapshot', 'PUT', { ...upload, bodyMassKg: { status: 'value', value: '70' } })).status).toBe(400)
    expect((await call('/v1/health/activity', 'PUT', { days: [{ date: DAY, activeKcal: -1 }] })).status).toBe(400)
    expect((await call('/v1/health/manual-metrics', 'PUT', { bodyMassKg: 5 })).status).toBe(400)
    expect((await call('/v1/health/snapshot?date=yesterday')).status).toBe(400)
  })

  it('缺身体数据时建议告诉缺什么，生成目标返回 422', async () => {
    const { call } = await withDevice()
    await call('/v1/health/snapshot', 'PUT', upload)
    const recommendation = GoalRecommendationResponse.parse(await (await call('/v1/goals/recommendation', 'POST', { date: DAY })).json())
    expect(recommendation).toEqual({ status: 'missing', missing: ['height', 'dateOfBirth', 'sex'] })
    const initial = await call('/v1/goals/initial', 'POST', { date: DAY })
    expect(initial.status).toBe(422)
    expect(ErrorResponse.parse(await initial.json()).error.code).toBe('missingMetrics')
  })

  it('补录后按服务端算出的建议生成目标，每日数据里能看到', async () => {
    const { call } = await withDevice()
    await call('/v1/health/snapshot', 'PUT', upload)
    await call('/v1/health/manual-metrics', 'PUT', { heightCm: 175, dateOfBirth: '1996-05-20', sex: 'male' })
    const created = await call('/v1/goals/initial', 'POST', { date: DAY, kind: 'maintain' })
    expect(created.status).toBe(201)
    const { goal } = GoalResponse.parse(await created.json())
    expect(goal).toMatchObject({ origin: 'initialRecommendation', targets: { proteinG: 126 }, energyPlan: { kind: 'maintain' } })

    expect(GoalResponse.parse(await (await call(`/v1/goals/active?date=${DAY}`)).json()).goal?.id).toBe(goal?.id)
    const day = DayResponse.parse(await (await call(`/v1/days/${DAY}`)).json())
    expect(day.summary.goal?.id).toBe(goal?.id)
    expect(day.summary.energy).not.toBeNull()
  })

  it('调整幅度超出范围返回 400', async () => {
    const { call } = await withDevice()
    expect((await call('/v1/goals/recommendation', 'POST', { date: DAY, adjustment: { type: 'fraction', value: 0.3 } })).status).toBe(400)
  })
})

describe('称重', () => {
  const weighing = () => ({ id: randomUUID(), weightKg: 69.6, impedance: { a: 482, b: 432 }, source: 'live', recordedAt: null, appleHealthWritable: true })

  it('上传、列出、记秤读数、删除', async () => {
    const { call } = await withDevice()
    const upload = weighing()
    const created = await call('/v1/weighings', 'POST', upload)
    expect(created.status).toBe(201)
    expect(WeighingResponse.parse(await created.json()).weighing.id).toBe(upload.id)

    const list = WeighingsResponse.parse(await (await call('/v1/weighings')).json())
    expect(list.weighings).toHaveLength(1)
    expect(list.calibration).toEqual({ readingCount: 0, model: null, applied: false })

    const reading = ScaleReadingResponse.parse(await (await call(`/v1/weighings/${upload.id}/scale-reading`, 'PUT', { bodyFatFraction: 0.214 })).json())
    expect(reading.weighing.bodyFat).toEqual({ value: 0.214, source: 'scaleReading' })

    expect((await call(`/v1/weighings/${upload.id}`, 'DELETE')).status).toBe(204)
    expect((await call(`/v1/weighings/${upload.id}`, 'DELETE')).status).toBe(404)
  })

  it('不合格的称重与读数被拒绝', async () => {
    const { call } = await withDevice()
    const tooLight = await call('/v1/weighings', 'POST', { ...weighing(), weightKg: 7.45 })
    expect(tooLight.status).toBe(422)
    expect(ErrorResponse.parse(await tooLight.json()).error.code).toBe('invalidMetrics')
    expect((await call('/v1/weighings', 'POST', { ...weighing(), id: 'not-a-uuid' })).status).toBe(400)
    expect((await call(`/v1/weighings/${randomUUID()}/scale-reading`, 'PUT', { bodyFatFraction: 0.9 })).status).toBe(400)
    expect((await call(`/v1/weighings/${randomUUID()}/scale-reading`, 'PUT', { bodyFatFraction: 0.2 })).status).toBe(404)
  })
})

describe('对话接口', () => {
  async function withAgent(rounds: Parameters<typeof scripted>[0]) {
    const context = setup()
    const app = createApp({
      services: context.services,
      agent: new Orchestrator({ services: context.services, client: scripted(rounds), config: new StaticConfigSource() }),
      serviceToken: SERVICE_TOKEN,
      version: 'test',
    })
    const call = (path: string, method = 'GET', body?: unknown, contentType = 'application/json') =>
      app.request(path, {
        method,
        headers: { authorization: `Bearer ${SERVICE_TOKEN}`, ...(body === undefined ? {} : { 'content-type': contentType }) },
        body: body === undefined ? undefined : body instanceof Uint8Array ? body : JSON.stringify(body),
      })
    return { ...context, call }
  }

  /** 读完 SSE，按 data 行解析成事件。 */
  async function events(response: Response) {
    const text = await response.text()
    return text
      .split('\n')
      .filter((line) => line.startsWith('data:'))
      .map((line) => ChatEvent.parse(JSON.parse(line.slice(5))))
  }

  const proposal = {
    sessionDate: DAY,
    afterConfirm: '再记一杯牛奶',
    payload: { intent: 'create', record: { items: [{ displayName: '外卖', originalAmountText: '一份', amountSource: 'aiEstimated', nutrition: { source: 'aiEstimated', values: { energyKcal: 600, proteinG: 20, fatG: 25, carbohydrateG: 70 }, estimateBasis: '按一份估算' } }] } },
  }
  const completed = { type: 'completed', info: { responseId: null, inputTokens: null, outputTokens: null, cachedTokens: null } } as const

  it('流式推送一轮：started → 文字 → done；历史里保存了两条', async () => {
    const { call } = await withAgent([[{ type: 'textDelta', delta: '你好' }, completed]])
    const response = await call(`/v1/days/${DAY}/chat`, 'POST', { text: '早' })
    expect(response.headers.get('content-type')).toContain('text/event-stream')
    const stream = await events(response)
    expect(stream.map((e) => e.type)).toEqual(['started', 'text', 'done'])
    expect(stream.at(-1)).toMatchObject({ type: 'done', reply: { text: '你好' }, pendingId: null })
    const history = MessagesResponse.parse(await (await call(`/v1/days/${DAY}/messages`)).json())
    expect(history.messages.map((m) => m.role)).toEqual(['user', 'assistant'])
  })

  it('模型失败时最后一个事件是 error，什么都不保存', async () => {
    const { call } = await withAgent([new LLMError('quotaExceeded')])
    const stream = await events(await call(`/v1/days/${DAY}/chat`, 'POST', { text: '早' }))
    expect(stream.at(-1)).toMatchObject({ type: 'error', code: 'quotaExceeded' })
    expect(MessagesResponse.parse(await (await call(`/v1/days/${DAY}/messages`)).json()).messages).toEqual([])
  })

  it('确认带下一步的卡片后接续一次；再接续返回 409', async () => {
    const { call } = await withAgent([
      [{ type: 'functionCall', call: { callId: 'c1', name: 'proposeRecordChange', arguments: JSON.stringify(proposal) } }, completed],
      [{ type: 'textDelta', delta: '确认后我再记牛奶。' }, completed],
      [{ type: 'textDelta', delta: '接着记牛奶。' }, completed],
    ])
    const first = await events(await call(`/v1/days/${DAY}/chat`, 'POST', { text: '中午吃了外卖，还喝了牛奶' }))
    const pendingId = (first.at(-1) as { pendingId: string }).pendingId
    expect((await call(`/v1/pending/${pendingId}/continue`, 'POST')).status).toBe(409)
    await call(`/v1/pending/${pendingId}/confirm`, 'POST')
    const next = await events(await call(`/v1/pending/${pendingId}/continue`, 'POST'))
    expect(next.at(-1)).toMatchObject({ type: 'done', reply: { text: '接着记牛奶。' } })
    const again = await call(`/v1/pending/${pendingId}/continue`, 'POST')
    expect(again.status).toBe(409)
    expect(ErrorResponse.parse(await again.json()).error.code).toBe('alreadyContinued')
  })

  it('空消息、未知照片返回错误；没配模型网关时 503', async () => {
    const { call } = await withAgent([])
    expect((await call(`/v1/days/${DAY}/chat`, 'POST', { text: '  ' })).status).toBe(400)
    expect((await call(`/v1/days/${DAY}/chat`, 'POST', { text: '看看', labelScanId: randomUUID() })).status).toBe(404)
    expect((await call(`/v1/days/${DAY}/chat`, 'POST', { text: '看看', labelScanIds: [randomUUID()] })).status).toBe(404)
    // 最多 6 张；labelScanId 与 labelScanIds 合并后也算在内。
    const seven = Array.from({ length: 7 }, () => randomUUID())
    expect((await call(`/v1/days/${DAY}/chat`, 'POST', { text: '', labelScanIds: seven })).status).toBe(400)
    expect((await call(`/v1/days/${DAY}/chat`, 'POST', { text: '', labelScanIds: seven.slice(0, 6), labelScanId: seven[6] })).status).toBe(400)
    const { call: noAgent } = await withDevice()
    expect((await noAgent(`/v1/days/${DAY}/chat`, 'POST', { text: '早' })).status).toBe(503)
  })

  it('上传与读取标签照片；不支持的格式返回 415', async () => {
    const { call } = await withAgent([])
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9])
    const created = await call('/v1/label-scans', 'POST', jpeg, 'image/jpeg')
    expect(created.status).toBe(201)
    const { labelScanId } = LabelScanResponse.parse(await created.json())
    const image = await call(`/v1/label-scans/${labelScanId}`)
    expect(image.headers.get('content-type')).toBe('image/jpeg')
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(jpeg)
    expect((await call('/v1/label-scans', 'POST', jpeg, 'image/gif')).status).toBe(415)
  })
})

function scripted(rounds: (LLMEvent[] | LLMError)[]): LLMClient {
  return {
    async *send() {
      const next = rounds.shift() ?? new LLMError('malformedResponse')
      if (next instanceof LLMError) throw next
      yield* next
    },
  }
}
