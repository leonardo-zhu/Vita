/**
 * 饮食数据、确认卡、食品库与参考库接口：响应符合 @vita/contract，业务错误映射到 HTTP 状态码。
 */
import { randomUUID } from 'node:crypto'

import {
  ActivePendingResponse,
  CreateDeviceResponse,
  DayResponse,
  ErrorResponse,
  FoodsResponse,
  PendingResponse,
  ReferenceSearchResponse,
} from '@vita/contract'
import { describe, expect, it } from 'vitest'

import { createApp } from './app.ts'
import { DAY, estimate, lunch, ORIGIN, setup } from './test/support.ts'

const SERVICE_TOKEN = 'test-service-token-0123456789abcdef'

async function withDevice() {
  const context = setup()
  const app = createApp({ services: context.services, serviceToken: SERVICE_TOKEN, version: 'test' })
  const created = await app.request('/v1/admin/devices', {
    method: 'POST',
    headers: { authorization: `Bearer ${SERVICE_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'iPhone' }),
  })
  const { token, device } = CreateDeviceResponse.parse(await created.json())
  const call = (path: string, method = 'GET') => app.request(path, { method, headers: { authorization: `Bearer ${token}` } })
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
