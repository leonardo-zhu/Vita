/**
 * Google 健康：Google 健康 App 不往 Apple 健康写活动能量与睡眠，手机读不到，改由服务端用 Google Health API 拉。
 *
 * - 授权：在 Admin 里发起，要一个授权地址（带 state 与 PKCE）在浏览器里打开；Google 回调到服务端，服务端换 token，
 *   refresh token 加密存库，再跳回 Admin。手机只看状态。
 * - 拉取：今天和前 7 天（服务端用前 7 天算日均）。活动能量用每日汇总；睡眠按手机上的口径：
 *   结束在前一天 18:00 到当天 12:00 之间的睡眠，加起“睡着”的分钟数。
 * - 拉到的存进 google_day_metrics，读健康数据时优先于手机上传的（HealthService）。只存每天的汇总，不存原始数据。
 */
import { createCipheriv, createDecipheriv, createHash, hkdfSync, randomBytes } from 'node:crypto'

import type { GoogleHealthStatus } from '@vita/contract'

import { audit, transaction } from '../db.ts'
import { addDays, localDateOf, zonedInstant } from '../domain/time.ts'
import { GoogleError, type GoogleHealthClient, type SleepSession } from '../google/client.ts'
import { ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'

/** 授权要在这么久之内完成。 */
const STATE_TTL_MS = 10 * 60_000
/** 拉几天：今天和前 7 天。 */
const SYNC_DAYS = 8
/** access token 提前这么久当作过期。 */
const TOKEN_MARGIN_MS = 60_000

export interface GoogleHealthOptions {
  client: GoogleHealthClient
  /** 加密 refresh token 的密钥来源（服务令牌）。换了就要重新连接。 */
  secret: string
}

interface AccountRow {
  refresh_token_enc: string
  scopes: string
  connected_at: string
  last_sync_at: string | null
  last_error: string | null
  last_error_at: string | null
}

export type AuthorizationResult = 'connected' | 'failed'

function base64url(bytes: Buffer): string {
  return bytes.toString('base64url')
}

/** 睡眠的口径与手机读 Apple 健康时一致：结束在 [前一天 18:00, 当天 12:00) 的睡眠，加起睡着的时长，保留一位小数。 */
export function sleepHoursFor(date: string, sessions: SleepSession[], timeZone: string): number | null {
  const from = zonedInstant(addDays(date, -1), 18, 0, 0, timeZone)
  const to = zonedInstant(date, 12, 0, 0, timeZone)
  const minutes = sessions
    .filter((session) => session.end >= from && session.end < to)
    .map((session) => session.minutesAsleep ?? (session.end.getTime() - session.start.getTime()) / 60_000)
  if (minutes.length === 0) return null
  const total = minutes.reduce((sum, value) => sum + value, 0)
  return Math.round((total / 60) * 10) / 10
}

export class GoogleHealthService {
  private readonly context: ServiceContext
  private readonly options: GoogleHealthOptions | null
  private readonly key: Buffer | null
  private accessToken: { value: string; expiresAt: number } | null = null
  private running: Promise<void> | null = null

  /** `options` 为 null：没配 OAuth 客户端，只能查状态。 */
  constructor(context: ServiceContext, options: GoogleHealthOptions | null) {
    this.context = context
    this.options = options
    this.key = options ? Buffer.from(hkdfSync('sha256', options.secret, 'vita-google-health', 'refresh-token', 32)) : null
  }

  get configured(): boolean {
    return this.options !== null
  }

  status(): GoogleHealthStatus {
    const row = this.account()
    return {
      configured: this.configured,
      connected: row !== null,
      connectedAt: row?.connected_at ?? null,
      lastSyncAt: row?.last_sync_at ?? null,
      lastError: row?.last_error ?? null,
      lastErrorAt: row?.last_error_at ?? null,
    }
  }

  /** 开始授权：记下 state 与 PKCE verifier，返回 Google 的授权页地址。 */
  startAuthorization(origin: WriteOrigin): string {
    const options = this.requireOptions()
    const { database, now } = this.context
    const at = now()
    const state = base64url(randomBytes(24))
    const verifier = base64url(randomBytes(48))
    const challenge = base64url(createHash('sha256').update(verifier).digest())
    transaction(database, () => {
      database.prepare('DELETE FROM google_health_oauth_states WHERE created_at < ?').run(new Date(at.getTime() - STATE_TTL_MS).toISOString())
      database.prepare('INSERT INTO google_health_oauth_states (state, code_verifier, created_at) VALUES (?, ?, ?)').run(state, verifier, at.toISOString())
      audit(database, { actor: origin.actor, action: 'googleHealth.authorize', result: 'success', at })
    })
    return options.client.authorizationURL(state, challenge)
  }

  /**
   * Google 回调：核对 state，换 token，存下 refresh token，接着拉一次。不抛错，失败时返回 failed 并记审计。
   * 回调不带设备令牌（是浏览器跳过来的），靠一次性的 state 认人。
   */
  async completeAuthorization(params: { code?: string; state?: string; error?: string }): Promise<AuthorizationResult> {
    const { database, now } = this.context
    const fail = (code: string): AuthorizationResult => {
      audit(database, { actor: 'google', action: 'googleHealth.connect', result: 'failure', errorCode: code, at: now() })
      return 'failed'
    }
    if (!this.options || !this.key) return fail('notConfigured')
    if (!params.state) return fail('missingState')
    const row = database.prepare('SELECT code_verifier, created_at FROM google_health_oauth_states WHERE state = ?').get(params.state) as
      | { code_verifier: string; created_at: string }
      | undefined
    database.prepare('DELETE FROM google_health_oauth_states WHERE state = ?').run(params.state)
    if (!row || now().getTime() - Date.parse(row.created_at) > STATE_TTL_MS) return fail('invalidState')
    if (params.error || !params.code) return fail(params.error === 'access_denied' ? 'accessDenied' : 'noCode')

    let token
    try {
      token = await this.options.client.exchangeCode(params.code, row.code_verifier)
    } catch (error) {
      return fail(error instanceof GoogleError ? error.code : 'exchangeFailed')
    }
    const refreshToken = token.refreshToken
    if (!refreshToken) return fail('noRefreshToken')
    const at = now()
    transaction(database, () => {
      database
        .prepare(
          `INSERT INTO google_health_account (id, refresh_token_enc, scopes, connected_at, last_sync_at, last_error, last_error_at) VALUES (1, ?, ?, ?, NULL, NULL, NULL)
           ON CONFLICT(id) DO UPDATE SET refresh_token_enc = excluded.refresh_token_enc, scopes = excluded.scopes, connected_at = excluded.connected_at, last_error = NULL, last_error_at = NULL`,
        )
        .run(this.encrypt(refreshToken), token.scopes.join(' '), at.toISOString())
      audit(database, { actor: 'google', action: 'googleHealth.connect', result: 'success', at })
    })
    this.accessToken = { value: token.accessToken, expiresAt: at.getTime() + token.expiresInSeconds * 1000 }
    await this.sync({ actor: 'google' })
    return 'connected'
  }

  /** 断开：尽力撤销 Google 那边的授权，删掉 token 和拉到的数据（之后回到用手机上传的 Apple 健康数据）。 */
  async disconnect(origin: WriteOrigin) {
    const { database, now } = this.context
    const row = this.account()
    if (row && this.options) {
      const refreshToken = this.decrypt(row.refresh_token_enc)
      if (refreshToken) await this.options.client.revoke(refreshToken)
    }
    this.accessToken = null
    const at = now()
    transaction(database, () => {
      database.exec('DELETE FROM google_health_account; DELETE FROM google_day_metrics;')
      audit(database, { actor: origin.actor, action: 'googleHealth.disconnect', result: 'success', at })
    })
  }

  /**
   * 拉今天和前 7 天。同一时间只跑一次，后来的等前面那次。失败记在账号上（status 里能看到），不抛错。
   * 没连接时什么也不做。
   */
  sync(origin: WriteOrigin): Promise<void> {
    if (!this.running) {
      this.running = this.runSync(origin).finally(() => {
        this.running = null
      })
    }
    return this.running
  }

  /** 距上次成功拉取超过 `maxAgeMs` 才拉；最多等 `timeoutMs`，超时就先用已有的，拉取在后台接着跑。 */
  async refreshIfStale(maxAgeMs: number, timeoutMs: number): Promise<void> {
    const row = this.account()
    if (!row || !this.options) return
    const last = row.last_sync_at ? Date.parse(row.last_sync_at) : 0
    const lastError = row.last_error_at ? Date.parse(row.last_error_at) : 0
    const now = this.context.now().getTime()
    // 刚失败过的也别每个请求都去试
    if (now - last < maxAgeMs || now - lastError < maxAgeMs) return
    let timer: NodeJS.Timeout | undefined
    await Promise.race([this.sync({ actor: 'system' }), new Promise<void>((resolve) => (timer = setTimeout(resolve, timeoutMs)))])
    clearTimeout(timer)
  }

  private async runSync(origin: WriteOrigin) {
    const row = this.account()
    if (!row || !this.options) return
    const { database, now, timeZone } = this.context
    const zone = timeZone()
    const today = localDateOf(now(), zone)
    const first = addDays(today, -(SYNC_DAYS - 1))
    try {
      const accessToken = await this.currentAccessToken(row)
      const energy = await this.options.client.dailyActiveEnergy(accessToken, first, addDays(today, 1))
      const sessions = await this.options.client.sleepSessions(accessToken, zonedInstant(addDays(first, -1), 18, 0, 0, zone), zonedInstant(today, 12, 0, 0, zone))
      const kcalByDate = new Map(energy.map((day) => [day.date, day.kcal]))
      const at = now()
      transaction(database, () => {
        const statement = database.prepare(
          `INSERT INTO google_day_metrics (local_date, active_kcal, sleep_hours, updated_at) VALUES (?, ?, ?, ?)
           ON CONFLICT(local_date) DO UPDATE SET active_kcal = excluded.active_kcal, sleep_hours = excluded.sleep_hours, updated_at = excluded.updated_at`,
        )
        for (let offset = 0; offset < SYNC_DAYS; offset++) {
          const date = addDays(first, offset)
          statement.run(date, kcalByDate.get(date) ?? null, sleepHoursFor(date, sessions, zone), at.toISOString())
        }
        database.prepare('UPDATE google_health_account SET last_sync_at = ?, last_error = NULL, last_error_at = NULL WHERE id = 1').run(at.toISOString())
        audit(database, { actor: origin.actor, action: 'googleHealth.sync', result: 'success', at })
      })
    } catch (error) {
      const code = error instanceof GoogleError ? error.code : 'internal'
      if (!(error instanceof GoogleError)) console.error(error)
      else console.warn(`Google 健康拉取失败（${code}）：${error.message}`)
      if (code === 'reauthorizationRequired') this.accessToken = null
      const at = now()
      database.prepare('UPDATE google_health_account SET last_error = ?, last_error_at = ? WHERE id = 1').run(code, at.toISOString())
      audit(database, { actor: origin.actor, action: 'googleHealth.sync', result: 'failure', errorCode: code, at })
    }
  }

  private async currentAccessToken(row: AccountRow): Promise<string> {
    const nowMs = this.context.now().getTime()
    if (this.accessToken && this.accessToken.expiresAt - TOKEN_MARGIN_MS > nowMs) return this.accessToken.value
    const refreshToken = this.decrypt(row.refresh_token_enc)
    // 解不开：多半是换了服务令牌
    if (!refreshToken) throw new GoogleError('reauthorizationRequired', '存的 refresh token 解不开（服务令牌换过？）')
    const token = await this.options!.client.refresh(refreshToken)
    this.accessToken = { value: token.accessToken, expiresAt: nowMs + token.expiresInSeconds * 1000 }
    // Google 偶尔会轮换 refresh token
    if (token.refreshToken && token.refreshToken !== refreshToken) {
      this.context.database.prepare('UPDATE google_health_account SET refresh_token_enc = ? WHERE id = 1').run(this.encrypt(token.refreshToken))
    }
    return token.accessToken
  }

  private account(): AccountRow | null {
    return (this.context.database.prepare('SELECT * FROM google_health_account WHERE id = 1').get() as AccountRow | undefined) ?? null
  }

  private requireOptions(): GoogleHealthOptions {
    if (!this.options) throw new ServiceError('googleHealth', 'googleHealthNotConfigured')
    return this.options
  }

  /** AES-256-GCM：iv(12) | tag(16) | 密文，base64。 */
  private encrypt(plain: string): string {
    const iv = randomBytes(12)
    const cipher = createCipheriv('aes-256-gcm', this.key!, iv)
    const encrypted = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()])
    return Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64')
  }

  private decrypt(stored: string): string | null {
    if (!this.key) return null
    try {
      const bytes = Buffer.from(stored, 'base64')
      const decipher = createDecipheriv('aes-256-gcm', this.key, bytes.subarray(0, 12))
      decipher.setAuthTag(bytes.subarray(12, 28))
      return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8')
    } catch {
      return null
    }
  }
}
