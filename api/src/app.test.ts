import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import type { DatabaseSync } from 'node:sqlite'

import { CreateDeviceResponse, Device, ErrorResponse, ListDevicesResponse, MeResponse } from '@vita/contract'
import { beforeEach, describe, expect, it } from 'vitest'

import { createApp } from './app.ts'
import { openDatabase } from './db.ts'

const SERVICE_TOKEN = 'test-service-token-0123456789abcdef'

let database: DatabaseSync
let app: ReturnType<typeof createApp>

beforeEach(() => {
  database = openDatabase(':memory:')
  app = createApp({ database, serviceToken: SERVICE_TOKEN, version: 'test', now: () => new Date('2026-11-04T08:00:00Z') })
})

function request(path: string, init: { token?: string; method?: string; body?: unknown } = {}) {
  const headers: Record<string, string> = {}
  if (init.token) headers.authorization = `Bearer ${init.token}`
  if (init.body !== undefined) headers['content-type'] = 'application/json'
  return app.request(path, {
    method: init.method ?? 'GET',
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  })
}

async function issueDevice(name = 'iPhone') {
  const response = await request('/v1/admin/devices', { token: SERVICE_TOKEN, method: 'POST', body: { name } })
  expect(response.status).toBe(201)
  return CreateDeviceResponse.parse(await response.json())
}

describe('health', () => {
  it('不需要令牌', async () => {
    const response = await request('/v1/health')
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true, version: 'test' })
  })
})

describe('鉴权', () => {
  it('没有令牌或令牌不对时返回 401', async () => {
    for (const token of [undefined, 'wrong']) {
      const response = await request('/v1/me', { token })
      expect(response.status).toBe(401)
      expect(ErrorResponse.parse(await response.json()).error.code).toBe('unauthorized')
    }
  })

  it('设备令牌不能调 Admin 接口', async () => {
    const { token } = await issueDevice()
    const response = await request('/v1/admin/devices', { token })
    expect(response.status).toBe(403)
  })

  it('未知路径返回统一的错误格式', async () => {
    const response = await request('/v1/nothing', { token: SERVICE_TOKEN })
    expect(response.status).toBe(404)
    expect(ErrorResponse.parse(await response.json()).error.code).toBe('notFound')
  })
})

describe('设备令牌', () => {
  it('签发后能用，库里只存哈希', async () => {
    const { device, token } = await issueDevice('Leonardo 的 iPhone')
    expect(token).toMatch(/^vita_[A-Za-z0-9_-]{43}$/)

    const response = await request('/v1/me', { token })
    expect(response.status).toBe(200)
    const me = MeResponse.parse(await response.json())
    expect(me.device).toMatchObject({ id: device.id, name: 'Leonardo 的 iPhone', lastUsedAt: '2026-11-04T08:00:00.000Z' })

    const stored = database.prepare('SELECT token_hash FROM devices').get() as { token_hash: string }
    expect(stored.token_hash).not.toContain(token)
    expect(stored.token_hash).toHaveLength(64)
  })

  it('名字不合法时返回 400', async () => {
    for (const body of [{}, { name: '  ' }, { name: 'x'.repeat(65) }]) {
      const response = await request('/v1/admin/devices', { token: SERVICE_TOKEN, method: 'POST', body })
      expect(response.status).toBe(400)
    }
  })

  it('吊销后立即失效，并记审计', async () => {
    const { device, token } = await issueDevice()
    expect((await request(`/v1/admin/devices/${device.id}`, { token: SERVICE_TOKEN, method: 'DELETE' })).status).toBe(204)
    expect((await request('/v1/me', { token })).status).toBe(401)

    const list = ListDevicesResponse.parse(await (await request('/v1/admin/devices', { token: SERVICE_TOKEN })).json())
    expect(Device.parse(list.devices[0]).revokedAt).toBe('2026-11-04T08:00:00.000Z')

    const actions = database.prepare('SELECT action FROM audit_events ORDER BY id').all().map((row) => row.action)
    expect(actions).toEqual(['device.create', 'device.revoke'])
  })

  it('吊销不存在的设备返回 404', async () => {
    const response = await request('/v1/admin/devices/00000000-0000-4000-8000-000000000000', { token: SERVICE_TOKEN, method: 'DELETE' })
    expect(response.status).toBe(404)
  })
})

describe('数据库迁移', () => {
  it('重新打开已有的库不会重复迁移，数据还在', () => {
    const file = path.join(mkdtempSync(path.join(tmpdir(), 'vita-api-')), 'vita-api.db')
    const first = openDatabase(file)
    first.prepare("INSERT INTO devices (id, name, token_hash, created_at) VALUES ('a', 'iPhone', 'h', 'now')").run()
    const version = (first.prepare('PRAGMA user_version').get() as { user_version: number }).user_version
    first.close()

    const second = openDatabase(file)
    expect((second.prepare('PRAGMA user_version').get() as { user_version: number }).user_version).toBe(version)
    expect(second.prepare('SELECT count(*) AS n FROM devices').get()).toEqual({ n: 1 })
    second.close()
  })
})
