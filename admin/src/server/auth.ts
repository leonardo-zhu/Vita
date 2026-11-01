/**
 * 管理员认证，与 Conduit 同一套方案（docs/architecture/vita-admin.md §11.6）：只有一个管理员账号，不建用户表。
 *
 * - 账号和密码哈希来自环境变量（ADMIN_USERNAME / ADMIN_PASSWORD_HASH），不进仓库。
 *   哈希用 `node scripts/hash-password.mjs` 生成。
 * - 登录后发 HMAC 签名的 HttpOnly cookie（SESSION_SECRET 签名）。服务端不存会话：
 *   改 SESSION_SECRET 或密码哈希后重启，所有会话立即失效。
 * - 登录失败按 IP 限速。
 */
import 'server-only'

import { createHmac, randomUUID, scryptSync, timingSafeEqual } from 'node:crypto'

import { cookies, headers } from 'next/headers'
import { redirect } from 'next/navigation'

export const SESSION_COOKIE = 'vita_admin_session'
const SESSION_TTL_SECONDS = 7 * 86400

interface AuthConfig {
  username: string
  passwordHash: string
  secret: string
}

export class AuthConfigError extends Error {}

function getConfig(): AuthConfig {
  const username = process.env.ADMIN_USERNAME
  const passwordHash = process.env.ADMIN_PASSWORD_HASH
  const secret = process.env.SESSION_SECRET
  if (!username || !passwordHash || !secret) {
    throw new AuthConfigError('ADMIN_USERNAME, ADMIN_PASSWORD_HASH and SESSION_SECRET are required')
  }
  if (secret.length < 32) {
    throw new AuthConfigError('SESSION_SECRET must be at least 32 characters')
  }
  return { username, passwordHash, secret }
}

// ---------------------------------------------------------------------------
// 密码：scrypt:N:r:p:salt:hash（salt / hash 为 base64）。
// 不用 $ 分隔：Next.js 和 docker compose 读 env 文件时都会把 $xxx 当变量展开
// ---------------------------------------------------------------------------

function verifyPassword(password: string, encoded: string): boolean {
  const [scheme, n, r, p, salt, hash] = encoded.split(':')
  if (scheme !== 'scrypt' || !salt || !hash) return false
  const expected = Buffer.from(hash, 'base64')
  const actual = scryptSync(password, Buffer.from(salt, 'base64'), expected.length, {
    N: Number(n),
    r: Number(r),
    p: Number(p),
  })
  return timingSafeEqual(actual, expected)
}

function safeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a)
  const bb = Buffer.from(b)
  return ba.length === bb.length && timingSafeEqual(ba, bb)
}

/** 校验账号密码；用户名不对时也跑一次 scrypt，避免靠耗时区分用户名是否存在 */
export function checkCredentials(username: string, password: string): boolean {
  const config = getConfig()
  const passwordOk = verifyPassword(password, config.passwordHash)
  return safeEqual(username, config.username) && passwordOk
}

/** 已登录后的二次确认（如注册 Passkey）只校验密码 */
export function checkPassword(password: string): boolean {
  return verifyPassword(password, getConfig().passwordHash)
}

export function adminUsername(): string {
  return getConfig().username
}

// ---------------------------------------------------------------------------
// 签名令牌：base64url(JSON).hmac，用 SESSION_SECRET 签名。
// 会话 cookie 和 Passkey 的 flow token 都用它，靠 kind 区分，不能互相冒用
// ---------------------------------------------------------------------------

function sign(data: string, secret: string) {
  return createHmac('sha256', secret).update(data).digest('base64url')
}

export function signToken<T extends { exp: number }>(kind: string, payload: T): string {
  const { secret } = getConfig()
  const data = Buffer.from(JSON.stringify({ ...payload, kind })).toString('base64url')
  return `${data}.${sign(data, secret)}`
}

/** 签名不对、kind 不符或已过期都返回 null */
export function verifyToken<T extends { exp: number }>(kind: string, token: string): T | null {
  let config: AuthConfig
  try {
    config = getConfig()
  } catch {
    return null
  }
  const [data, mac] = token.split('.')
  if (!data || !mac || !safeEqual(mac, sign(data, config.secret))) return null
  try {
    const payload = JSON.parse(Buffer.from(data, 'base64url').toString()) as T & { kind?: string }
    if (payload.kind !== kind) return null
    if (payload.exp <= Math.floor(Date.now() / 1000)) return null
    return payload
  } catch {
    return null
  }
}

// ---------------------------------------------------------------------------
// 会话 cookie
// ---------------------------------------------------------------------------

export type LoginMethod = 'password' | 'passkey'

export interface SessionPayload {
  sid: string
  iat: number
  exp: number
  method?: LoginMethod
}

/** 签发会话并写入 cookie。只能在 Server Action 或 Route Handler 里调用 */
export async function startSession(method: LoginMethod) {
  const now = Math.floor(Date.now() / 1000)
  const payload: SessionPayload = { sid: randomUUID(), iat: now, exp: now + SESSION_TTL_SECONDS, method }
  const store = await cookies()
  store.set(SESSION_COOKIE, signToken('session', payload), {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    path: '/',
    maxAge: SESSION_TTL_SECONDS,
  })
  return payload
}

export async function endSession() {
  ;(await cookies()).delete(SESSION_COOKIE)
}

export async function currentSession(): Promise<SessionPayload | null> {
  const token = (await cookies()).get(SESSION_COOKIE)?.value
  return token ? verifyToken<SessionPayload>('session', token) : null
}

/** 页面与 Server Action 用：没登录就跳到登录页 */
export async function requireSession(): Promise<SessionPayload> {
  const session = await currentSession()
  if (!session) redirect('/admin/login')
  return session
}

// ---------------------------------------------------------------------------
// 登录限速：每个 IP 15 分钟内最多失败 5 次（单进程，存内存）
// ---------------------------------------------------------------------------

const FAIL_WINDOW_MS = 15 * 60 * 1000
const MAX_FAILURES = 5
const failures = new Map<string, { count: number; resetAt: number }>()

export async function clientIp(): Promise<string> {
  // Caddy 反代时带 X-Forwarded-For；本机直连时没有。Next.js 只监听 127.0.0.1，外部连不到，所以可以信任它
  return (await headers()).get('x-forwarded-for')?.split(',')[0]?.trim() || 'local'
}

export function isLockedOut(ip: string): boolean {
  const entry = failures.get(ip)
  if (!entry) return false
  if (entry.resetAt <= Date.now()) {
    failures.delete(ip)
    return false
  }
  return entry.count >= MAX_FAILURES
}

export function recordFailure(ip: string) {
  const now = Date.now()
  const entry = failures.get(ip)
  if (!entry || entry.resetAt <= now) {
    failures.set(ip, { count: 1, resetAt: now + FAIL_WINDOW_MS })
  } else {
    entry.count += 1
  }
}

export function clearFailures(ip: string) {
  failures.delete(ip)
}
