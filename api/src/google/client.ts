/**
 * Google Health API 与 Google OAuth 2.0 的最小客户端：换 token、刷新、撤销、活动能量的每日汇总、睡眠列表。
 * 只用 fetch，不引入 Google 的 SDK；fetch 可注入，测试用假的。
 *
 * 文档：https://developers.google.com/health/reference/rest （v4）。
 * OAuth 客户端是 Web Server 类型，带 client secret，另加 PKCE。
 */

export const GOOGLE_HEALTH_SCOPES = [
  'https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly',
  'https://www.googleapis.com/auth/googlehealth.sleep.readonly',
] as const

const AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth'
const TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'
const REVOKE_ENDPOINT = 'https://oauth2.googleapis.com/revoke'
const API_BASE = 'https://health.googleapis.com/v4/users/me/dataTypes'

/** 单次请求的超时。R4S 经 OpenClash 出境，偶尔会慢。 */
const REQUEST_TIMEOUT_MS = 15_000
/** 网络错误与 5xx 的重试次数（ghcr.io 也有类似的偶发 EOF）。 */
const RETRIES = 2

export interface GoogleOAuthConfig {
  clientId: string
  clientSecret: string
  /** 服务端的回调地址，要和 Google Cloud 里登记的一致。 */
  redirectUri: string
}

/**
 * - reauthorizationRequired：refresh token 失效（撤销、过期、Testing 状态 7 天到期），要重新连接
 * - network：连不上或超时
 * - googleError：Google 返回了其他错误
 */
export type GoogleErrorCode = 'reauthorizationRequired' | 'network' | 'googleError'

export class GoogleError extends Error {
  readonly code: GoogleErrorCode
  constructor(code: GoogleErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

export interface TokenResponse {
  accessToken: string
  expiresInSeconds: number
  /** 只有首次授权（prompt=consent）时给。 */
  refreshToken: string | null
  scopes: string[]
}

/** 公历日期，月份从 1 开始（google.type.Date）。 */
export interface CivilDate {
  year: number
  month: number
  day: number
}

export interface DailyActiveEnergy {
  date: string
  kcal: number | null
}

export interface SleepSession {
  start: Date
  end: Date
  minutesAsleep: number | null
  nap: boolean
}

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>

function civil(date: string): CivilDate {
  const [year, month, day] = date.split('-').map(Number)
  return { year, month, day }
}

function dateString(value: CivilDate): string {
  return `${String(value.year).padStart(4, '0')}-${String(value.month).padStart(2, '0')}-${String(value.day).padStart(2, '0')}`
}

export class GoogleHealthClient {
  private readonly config: GoogleOAuthConfig
  private readonly fetch: Fetch

  constructor(config: GoogleOAuthConfig, fetchImpl: Fetch = globalThis.fetch) {
    this.config = config
    this.fetch = fetchImpl
  }

  /** 授权页地址。access_type=offline + prompt=consent 才会给 refresh token。 */
  authorizationURL(state: string, codeChallenge: string): string {
    const params = new URLSearchParams({
      client_id: this.config.clientId,
      redirect_uri: this.config.redirectUri,
      response_type: 'code',
      scope: GOOGLE_HEALTH_SCOPES.join(' '),
      access_type: 'offline',
      prompt: 'consent',
      include_granted_scopes: 'true',
      state,
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
    })
    return `${AUTH_ENDPOINT}?${params}`
  }

  exchangeCode(code: string, codeVerifier: string): Promise<TokenResponse> {
    return this.token({
      grant_type: 'authorization_code',
      code,
      code_verifier: codeVerifier,
      redirect_uri: this.config.redirectUri,
    })
  }

  refresh(refreshToken: string): Promise<TokenResponse> {
    return this.token({ grant_type: 'refresh_token', refresh_token: refreshToken })
  }

  /** 尽力撤销；失败不影响本地断开。 */
  async revoke(token: string): Promise<void> {
    try {
      await this.request(REVOKE_ENDPOINT, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ token }) })
    } catch {
      // 忽略
    }
  }

  /** `[startDate, endDate)` 每天的活动能量（千卡），按用户在 Google 健康里的当地日期汇总。没有数据的日子为 null。 */
  async dailyActiveEnergy(accessToken: string, startDate: string, endDate: string): Promise<DailyActiveEnergy[]> {
    const byDate = new Map<string, number | null>()
    let pageToken: string | undefined
    do {
      const body = {
        range: { start: { date: civil(startDate) }, end: { date: civil(endDate) } },
        windowSizeDays: 1,
        ...(pageToken ? { pageToken } : {}),
      }
      const json = (await this.api(accessToken, `${API_BASE}/active-energy-burned/dataPoints:dailyRollUp`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      })) as {
        rollupDataPoints?: { civilStartTime?: { date?: CivilDate }; activeEnergyBurned?: { kcalSum?: number } }[]
        nextPageToken?: string
      }
      for (const point of json.rollupDataPoints ?? []) {
        const date = point.civilStartTime?.date
        if (!date) continue
        const kcal = point.activeEnergyBurned?.kcalSum
        byDate.set(dateString(date), typeof kcal === 'number' && Number.isFinite(kcal) ? kcal : null)
      }
      pageToken = json.nextPageToken || undefined
    } while (pageToken)
    return [...byDate].map(([date, kcal]) => ({ date, kcal }))
  }

  /** 结束时刻在 `[from, to)` 之间的睡眠。 */
  async sleepSessions(accessToken: string, from: Date, to: Date): Promise<SleepSession[]> {
    const sessions: SleepSession[] = []
    const filter = `sleep.interval.end_time >= "${from.toISOString()}" AND sleep.interval.end_time < "${to.toISOString()}"`
    let pageToken: string | undefined
    do {
      const params = new URLSearchParams({ filter, pageSize: '25', ...(pageToken ? { pageToken } : {}) })
      const json = (await this.api(accessToken, `${API_BASE}/sleep/dataPoints?${params}`, { method: 'GET' })) as {
        dataPoints?: {
          sleep?: {
            interval?: { startTime?: string; endTime?: string }
            summary?: { minutesAsleep?: number | string }
            metadata?: { nap?: boolean }
          }
        }[]
        nextPageToken?: string
      }
      for (const point of json.dataPoints ?? []) {
        const sleep = point.sleep
        if (!sleep?.interval?.startTime || !sleep.interval.endTime) continue
        // int64 在 JSON 里可能是字符串
        const minutes = sleep.summary?.minutesAsleep === undefined ? null : Number(sleep.summary.minutesAsleep)
        sessions.push({
          start: new Date(sleep.interval.startTime),
          end: new Date(sleep.interval.endTime),
          minutesAsleep: minutes !== null && Number.isFinite(minutes) ? minutes : null,
          nap: sleep.metadata?.nap === true,
        })
      }
      pageToken = json.nextPageToken || undefined
    } while (pageToken)
    return sessions
  }

  private async token(params: Record<string, string>): Promise<TokenResponse> {
    const body = new URLSearchParams({ client_id: this.config.clientId, client_secret: this.config.clientSecret, ...params })
    const response = await this.request(TOKEN_ENDPOINT, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body })
    const json = (await response.json().catch(() => ({}))) as {
      access_token?: string
      expires_in?: number
      refresh_token?: string
      scope?: string
      error?: string
    }
    if (!response.ok || !json.access_token) {
      // invalid_grant：refresh token 被撤销或过期，或授权码已用过
      if (json.error === 'invalid_grant') throw new GoogleError('reauthorizationRequired', 'Google 拒绝了授权，需要重新连接')
      throw new GoogleError('googleError', `token 接口返回 ${response.status} ${json.error ?? ''}`.trim())
    }
    return {
      accessToken: json.access_token,
      expiresInSeconds: json.expires_in ?? 3600,
      refreshToken: json.refresh_token ?? null,
      scopes: (json.scope ?? '').split(' ').filter(Boolean),
    }
  }

  private async api(accessToken: string, url: string, init: RequestInit): Promise<unknown> {
    const response = await this.request(url, { ...init, headers: { ...(init.headers as Record<string, string>), authorization: `Bearer ${accessToken}` } })
    if (response.status === 401) throw new GoogleError('reauthorizationRequired', 'Google 不认这个 access token')
    if (response.status === 403) {
      // 多半是少了权限（用户在授权页没勾某项）
      throw new GoogleError('reauthorizationRequired', `Google 拒绝访问：${(await response.text().catch(() => '')).slice(0, 200)}`)
    }
    if (!response.ok) throw new GoogleError('googleError', `${url.split('?')[0]} 返回 ${response.status}：${(await response.text().catch(() => '')).slice(0, 200)}`)
    return response.json()
  }

  /** 网络错误与 5xx 重试，其余原样返回。 */
  private async request(url: string, init: RequestInit): Promise<Response> {
    let lastError: unknown
    for (let attempt = 0; attempt <= RETRIES; attempt++) {
      try {
        const response = await this.fetch(url, { ...init, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) })
        if (response.status >= 500 && attempt < RETRIES) {
          lastError = new GoogleError('googleError', `${response.status}`)
          continue
        }
        return response
      } catch (error) {
        lastError = error
      }
    }
    if (lastError instanceof GoogleError) throw lastError
    throw new GoogleError('network', `连不上 Google：${lastError instanceof Error ? lastError.message : String(lastError)}`)
  }
}
