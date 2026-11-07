/**
 * Google 健康：授权（state、PKCE、换 token）、拉取活动能量与睡眠、与手机上传的数据合并、失败与断开。Google 一侧用假的 fetch。
 */
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

import { CreateDeviceResponse, ErrorResponse, GoogleHealthAuthorizeResponse, GoogleHealthStatus, HealthSnapshot } from '@vita/contract'
import { describe, expect, it } from 'vitest'

import { createApp } from '../app.ts'
import { openDatabase } from '../db.ts'
import { GoogleHealthClient } from '../google/client.ts'
import { DAY, NOW, ORIGIN, referenceCatalog, SHANGHAI, TestClock } from '../test/support.ts'
import { sleepHoursFor } from './googleHealth.ts'
import { createServices } from './index.ts'

const SERVICE_TOKEN = 'test-service-token-0123456789abcdef'
const REDIRECT = 'https://vita-api.example.test/oauth/google-health/callback'

interface FakeGoogle {
  calls: { url: string; body: string }[]
  /** 每天的活动能量；没列出的日子 Google 不返回。 */
  kcal: Record<string, number>
  sleep: { start: string; end: string; minutesAsleep: number; nap?: boolean }[]
  refreshFails: boolean
  apiDown: boolean
}

function fakeGoogle(): { google: FakeGoogle; fetch: typeof fetch } {
  const google: FakeGoogle = { calls: [], kcal: {}, sleep: [], refreshFails: false, apiDown: false }
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
  const fetchImpl = async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input)
    const body = init?.body === undefined || init.body === null ? '' : String(init.body)
    google.calls.push({ url, body })
    if (url.startsWith('https://oauth2.googleapis.com/token')) {
      const params = new URLSearchParams(body)
      if (params.get('grant_type') === 'authorization_code') {
        if (params.get('code') !== 'good-code' || !params.get('code_verifier')) return json({ error: 'invalid_grant' }, 400)
        return json({ access_token: 'access-1', expires_in: 3599, refresh_token: 'refresh-1', scope: 'a b' })
      }
      if (google.refreshFails) return json({ error: 'invalid_grant' }, 400)
      return json({ access_token: 'access-2', expires_in: 3599, scope: 'a b' })
    }
    if (url.startsWith('https://oauth2.googleapis.com/revoke')) return new Response('', { status: 200 })
    if (google.apiDown) throw new TypeError('fetch failed')
    if (url.includes('active-energy-burned/dataPoints:dailyRollUp')) {
      return json({
        rollupDataPoints: Object.entries(google.kcal).map(([date, kcalSum]) => {
          const [year, month, day] = date.split('-').map(Number)
          return { civilStartTime: { date: { year, month, day } }, activeEnergyBurned: { kcalSum } }
        }),
      })
    }
    if (url.includes('/sleep/dataPoints')) {
      return json({
        dataPoints: google.sleep.map((s) => ({
          sleep: { interval: { startTime: s.start, endTime: s.end }, summary: { minutesAsleep: String(s.minutesAsleep) }, metadata: { nap: s.nap ?? false } },
        })),
      })
    }
    return json({ error: 'unexpected' }, 404)
  }
  return { google, fetch: fetchImpl as typeof fetch }
}

function setupGoogle(configured = true) {
  const clock = new TestClock()
  const database = openDatabase(':memory:')
  const { google, fetch } = fakeGoogle()
  const client = new GoogleHealthClient({ clientId: 'client', clientSecret: 'secret', redirectUri: REDIRECT }, fetch)
  const services = createServices(
    { database, reference: referenceCatalog(), now: () => clock.now, timeZone: () => SHANGHAI },
    mkdtempSync(path.join(tmpdir(), 'vita-files-')),
    configured ? { client, secret: SERVICE_TOKEN } : null,
  )
  return { clock, database, services, google }
}

/** 走一遍授权：要地址、从地址里取 state、模拟 Google 回调。 */
async function connect(services: ReturnType<typeof setupGoogle>['services'], code = 'good-code') {
  const url = new URL(services.googleHealth.startAuthorization(ORIGIN))
  return services.googleHealth.completeAuthorization({ code, state: url.searchParams.get('state') ?? undefined })
}

const noData = { status: 'noData' } as const
const phoneUpload = {
  bodyMassKg: { status: 'value', value: 70, source: 'healthKit', measuredAt: '2026-10-30T00:00:00.000Z' },
  heightCm: noData,
  bodyFatFraction: noData,
  dateOfBirth: noData,
  sex: noData,
  sleepHours: { status: 'value', value: 5, source: 'healthKit', measuredAt: null },
  authorizationRequested: true,
  writeDenied: false,
} as const

describe('睡眠的口径', () => {
  // 2026-10-30 的窗口：上海 10-30 00:00 到 10-31 00:00，即 UTC 10-29 16:00 到 10-30 16:00
  it('按醒来的日期算：当天结束的每一段都加起来，中午以后才醒的那一觉也算', () => {
    const sessions = [
      // 上海 10-29 23:00 到 10-30 07:00
      { start: new Date('2026-10-29T15:00:00Z'), end: new Date('2026-10-29T23:00:00Z'), minutesAsleep: 420, nap: false },
      // 上海 11:31 到 15:08，补觉
      { start: new Date('2026-10-30T03:31:00Z'), end: new Date('2026-10-30T07:08:00Z'), minutesAsleep: 199, nap: false },
      // 上海 10-29 22:00 结束的那一觉算 10-29
      { start: new Date('2026-10-29T12:00:00Z'), end: new Date('2026-10-29T14:00:00Z'), minutesAsleep: 110, nap: true },
    ]
    expect(sleepHoursFor(DAY, sessions, SHANGHAI)).toBe(10.3)
    expect(sleepHoursFor('2026-10-29', sessions, SHANGHAI)).toBe(1.8)
    expect(sleepHoursFor('2026-10-28', sessions, SHANGHAI)).toBeNull()
  })

  it('没有 minutesAsleep 时按起止时长算', () => {
    const sessions = [{ start: new Date('2026-10-29T16:00:00Z'), end: new Date('2026-10-29T22:30:00Z'), minutesAsleep: null, nap: false }]
    expect(sleepHoursFor(DAY, sessions, SHANGHAI)).toBe(6.5)
  })
})

describe('Google 健康', () => {
  it('授权地址带 state、PKCE 与只读的权限，要离线访问', () => {
    const { services } = setupGoogle()
    const url = new URL(services.googleHealth.startAuthorization(ORIGIN))
    expect(url.origin + url.pathname).toBe('https://accounts.google.com/o/oauth2/v2/auth')
    expect(url.searchParams.get('access_type')).toBe('offline')
    expect(url.searchParams.get('prompt')).toBe('consent')
    expect(url.searchParams.get('code_challenge_method')).toBe('S256')
    expect(url.searchParams.get('redirect_uri')).toBe(REDIRECT)
    expect(url.searchParams.get('scope')).toBe(
      'https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly https://www.googleapis.com/auth/googlehealth.sleep.readonly',
    )
    expect(url.searchParams.get('state')).toMatch(/^[\w-]{20,}$/)
  })

  it('连接后拉今天和前 7 天，活动能量与睡眠优先用 Google 的，没有的日子用手机上传的', async () => {
    const { services, google, database } = setupGoogle()
    services.health.upload(phoneUpload, ORIGIN)
    services.health.uploadActivity({ days: [{ date: DAY, activeKcal: 80 }, { date: '2026-10-29', activeKcal: 90 }, { date: '2026-10-28', activeKcal: 100 }] }, ORIGIN)
    google.kcal = { [DAY]: 450, '2026-10-29': 500, '2026-10-27': 400, '2026-10-26': 600 }
    google.sleep = [{ start: '2026-10-29T15:30:00Z', end: '2026-10-29T23:00:00Z', minutesAsleep: 408 }]

    expect(await connect(services)).toBe('connected')
    const status = services.googleHealth.status()
    expect(status).toMatchObject({ configured: true, connected: true, lastSyncAt: NOW.toISOString(), lastError: null })

    const snapshot = HealthSnapshot.parse(services.health.snapshot(DAY))
    expect(snapshot.activeEnergyKcal).toEqual({ status: 'value', value: 450, source: 'googleHealth', measuredAt: null })
    expect(snapshot.sleepHours).toEqual({ status: 'value', value: 6.8, source: 'googleHealth', measuredAt: null })
    // 前 7 天：29 号 500（Google）、28 号 100（手机）、27 号 400、26 号 600 → 400
    expect(snapshot.averageActiveEnergyKcal).toMatchObject({ value: 400, source: 'googleHealth' })
    // 体重等仍是手机读 Apple 健康上传的
    expect(snapshot.bodyMassKg).toMatchObject({ value: 70, source: 'healthKit' })
    expect(services.health.activity(DAY)).toEqual({ activeKcal: 450, dailyAverageKcal: 400 })

    // 8 天都写了一行，没数据的为 NULL
    const rows = database.prepare('SELECT COUNT(*) AS n FROM google_day_metrics').get() as { n: number }
    expect(rows.n).toBe(8)
    // 存的 refresh token 是加密的
    const stored = database.prepare('SELECT refresh_token_enc FROM google_health_account').get() as { refresh_token_enc: string }
    expect(stored.refresh_token_enc).not.toContain('refresh-1')
  })

  it('Google 那天没有睡眠数据时用手机上传的', async () => {
    const { services } = setupGoogle()
    services.health.upload(phoneUpload, ORIGIN)
    await connect(services)
    expect(services.health.snapshot(DAY).sleepHours).toMatchObject({ value: 5, source: 'healthKit' })
  })

  it('state 不对、过期、或用户拒绝时连接失败，什么都不存', async () => {
    const { services, clock } = setupGoogle()
    expect(await services.googleHealth.completeAuthorization({ code: 'good-code', state: 'forged' })).toBe('failed')

    const url = new URL(services.googleHealth.startAuthorization(ORIGIN))
    clock.advance(11)
    expect(await services.googleHealth.completeAuthorization({ code: 'good-code', state: url.searchParams.get('state')! })).toBe('failed')

    const denied = new URL(services.googleHealth.startAuthorization(ORIGIN))
    expect(await services.googleHealth.completeAuthorization({ error: 'access_denied', state: denied.searchParams.get('state')! })).toBe('failed')

    expect(await connect(services, 'bad-code')).toBe('failed')
    expect(services.googleHealth.status().connected).toBe(false)
  })

  it('state 只能用一次', async () => {
    const { services } = setupGoogle()
    const state = new URL(services.googleHealth.startAuthorization(ORIGIN)).searchParams.get('state')!
    expect(await services.googleHealth.completeAuthorization({ code: 'good-code', state })).toBe('connected')
    expect(await services.googleHealth.completeAuthorization({ code: 'good-code', state })).toBe('failed')
  })

  it('refresh token 失效时记为需要重新连接，已拉到的数据保留', async () => {
    const { services, google, clock } = setupGoogle()
    google.kcal = { [DAY]: 450 }
    await connect(services)
    clock.advance(120) // access token 过期
    google.refreshFails = true
    await services.googleHealth.sync(ORIGIN)
    expect(services.googleHealth.status()).toMatchObject({ connected: true, lastError: 'reauthorizationRequired', lastSyncAt: NOW.toISOString() })
    expect(services.health.snapshot(DAY).activeEnergyKcal).toMatchObject({ value: 450, source: 'googleHealth' })
  })

  it('连不上 Google 时重试后记为 network，下次成功就清掉', async () => {
    const { services, google, clock } = setupGoogle()
    await connect(services)
    google.apiDown = true
    clock.advance(1)
    await services.googleHealth.sync(ORIGIN)
    expect(services.googleHealth.status().lastError).toBe('network')
    google.apiDown = false
    await services.googleHealth.sync(ORIGIN)
    expect(services.googleHealth.status().lastError).toBeNull()
  })

  it('没过 10 分钟不重复拉', async () => {
    const { services, google, clock } = setupGoogle()
    await connect(services)
    const count = () => google.calls.filter((call) => call.url.includes('dailyRollUp')).length
    expect(count()).toBe(1)
    clock.advance(5)
    await services.googleHealth.refreshIfStale(10 * 60_000, 1000)
    expect(count()).toBe(1)
    clock.advance(6)
    await services.googleHealth.refreshIfStale(10 * 60_000, 1000)
    expect(count()).toBe(2)
  })

  it('断开后撤销授权、删掉拉到的数据，回到手机上传的', async () => {
    const { services, google } = setupGoogle()
    services.health.uploadActivity({ days: [{ date: DAY, activeKcal: 80 }] }, ORIGIN)
    google.kcal = { [DAY]: 450 }
    await connect(services)
    await services.googleHealth.disconnect(ORIGIN)
    expect(google.calls.some((call) => call.url.startsWith('https://oauth2.googleapis.com/revoke'))).toBe(true)
    expect(services.googleHealth.status().connected).toBe(false)
    expect(services.health.snapshot(DAY).activeEnergyKcal).toMatchObject({ value: 80, source: 'healthKit' })
  })

  it('换了服务令牌解不开 refresh token 时要求重新连接', async () => {
    const { services, database, clock } = setupGoogle()
    await connect(services)
    const other = createServices(
      { database, reference: referenceCatalog(), now: () => clock.now, timeZone: () => SHANGHAI },
      mkdtempSync(path.join(tmpdir(), 'vita-files-')),
      { client: new GoogleHealthClient({ clientId: 'client', clientSecret: 'secret', redirectUri: REDIRECT }, (() => Promise.reject(new Error('no'))) as typeof fetch), secret: 'another-service-token-0123456789abcdef' },
    )
    await other.googleHealth.sync(ORIGIN)
    expect(other.googleHealth.status().lastError).toBe('reauthorizationRequired')
  })
})

describe('Google 健康的接口', () => {
  async function withApp(configured = true) {
    const context = setupGoogle(configured)
    const app = createApp({ services: context.services, agent: null, serviceToken: SERVICE_TOKEN, version: 'test' })
    const created = await app.request('/v1/admin/devices', {
      method: 'POST',
      headers: { authorization: `Bearer ${SERVICE_TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'iPhone' }),
    })
    const { token } = CreateDeviceResponse.parse(await created.json())
    const call = (target: string, method = 'GET') => app.request(target, { method, headers: { authorization: `Bearer ${token}` } })
    const admin = (target: string, method = 'GET') => app.request(target, { method, headers: { authorization: `Bearer ${SERVICE_TOKEN}` } })
    return { ...context, app, call, admin }
  }

  it('Admin 授权、回调跳回 Admin、手机查状态、Admin 手动拉取与断开', async () => {
    const { app, call, admin, google } = await withApp()
    google.kcal = { [DAY]: 300 }
    const { url } = GoogleHealthAuthorizeResponse.parse(await (await admin('/v1/admin/google-health/authorize', 'POST')).json())
    const state = new URL(url).searchParams.get('state')!

    // 回调不带令牌
    const callback = await app.request(`/oauth/google-health/callback?code=good-code&state=${state}`)
    expect(callback.status).toBe(302)
    expect(callback.headers.get('location')).toBe('https://vita.r4s.leonardo-zhu.me/admin/google-health?result=connected')

    expect(GoogleHealthStatus.parse(await (await call('/v1/google-health')).json())).toMatchObject({ connected: true })
    expect(GoogleHealthStatus.parse(await (await admin('/v1/admin/google-health/sync', 'POST')).json())).toMatchObject({ lastError: null })
    const snapshot = HealthSnapshot.parse(await (await call(`/v1/health/snapshot?date=${DAY}`)).json())
    expect(snapshot.activeEnergyKcal).toMatchObject({ value: 300, source: 'googleHealth' })

    expect((await admin('/v1/admin/google-health', 'DELETE')).status).toBe(204)
    expect(GoogleHealthStatus.parse(await (await call('/v1/google-health')).json())).toMatchObject({ connected: false })
  })

  it('手机的设备令牌不能连接、同步或断开', async () => {
    const { call } = await withApp()
    expect((await call('/v1/admin/google-health/authorize', 'POST')).status).toBe(403)
    expect((await call('/v1/admin/google-health/sync', 'POST')).status).toBe(403)
    expect((await call('/v1/admin/google-health', 'DELETE')).status).toBe(403)
  })

  it('回调的 state 不对时跳回 Admin 并告知失败', async () => {
    const { app } = await withApp()
    const callback = await app.request('/oauth/google-health/callback?code=good-code&state=nope')
    expect(callback.headers.get('location')).toBe('https://vita.r4s.leonardo-zhu.me/admin/google-health?result=failed')
  })

  it('服务端没配 OAuth 客户端时状态里说明，授权返回 503', async () => {
    const { call, admin } = await withApp(false)
    expect(GoogleHealthStatus.parse(await (await call('/v1/google-health')).json())).toMatchObject({ configured: false, connected: false })
    const response = await admin('/v1/admin/google-health/authorize', 'POST')
    expect(response.status).toBe(503)
    expect(ErrorResponse.parse(await response.json()).error.code).toBe('googleHealthNotConfigured')
  })

  it('首页与隐私政策不要令牌（Google 发布应用要求）', async () => {
    const { app } = await withApp()
    for (const target of ['/', '/privacy']) {
      const response = await app.request(target)
      expect(response.status).toBe(200)
      expect(response.headers.get('content-type')).toContain('text/html')
    }
    expect(await (await app.request('/privacy')).text()).toContain('Limited Use')
  })

  it('没有令牌时不能查状态或授权', async () => {
    const { app } = await withApp()
    expect((await app.request('/v1/google-health')).status).toBe(401)
    expect((await app.request('/v1/admin/google-health/authorize', { method: 'POST' })).status).toBe(401)
  })
})
