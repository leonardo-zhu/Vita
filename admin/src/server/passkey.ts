/**
 * Passkey（WebAuthn）登录，与 Conduit 同一套做法，校验用 @simplewebauthn/server。
 *
 * - 管理员可以注册多个 Passkey，凭据存在 SQLite 的 passkeys 表。
 * - 登录用可发现凭据，不需要先填用户名。
 * - challenge 放在签名的 flow token 里，服务端不存；用过的 token 记在内存里直到过期，
 *   防止同一份应答被重放。
 * - RP：生产用 PASSKEY_ORIGIN（如 https://vita.r4s.leonardo-zhu.me），RP ID 取它的主机名；
 *   开发时回退到请求的 origin。改域名后旧 Passkey 都会失效。
 */
import 'server-only'

import { createHash, randomUUID } from 'node:crypto'

import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
  type AuthenticationResponseJSON,
  type RegistrationResponseJSON,
} from '@simplewebauthn/server'
import type { NextRequest } from 'next/server'

import { adminUsername, signToken, verifyToken } from './auth'
import { getPasskey, insertPasskey, listPasskeys, touchPasskey, type PasskeyRow } from './db'

const FLOW_TTL_SECONDS = 5 * 60
const RP_NAME = 'Vita Admin'

export class PasskeyError extends Error {}

function relyingParty(req: NextRequest): { rpID: string; origin: string } {
  const configured = process.env.PASSKEY_ORIGIN
  if (!configured && process.env.NODE_ENV === 'production') {
    throw new PasskeyError('服务端未配置 PASSKEY_ORIGIN')
  }
  const origin = new URL(configured || req.nextUrl.origin).origin
  return { rpID: new URL(origin).hostname, origin }
}

// WebAuthn 的 user.id：同一账号必须固定，否则同一设备会存下多份凭据
function userID(): Uint8Array<ArrayBuffer> {
  return new Uint8Array(createHash('sha256').update(`vita-admin:${adminUsername()}`).digest())
}

// ---------------------------------------------------------------------------
// flow token
// ---------------------------------------------------------------------------

type FlowKind = 'passkey-login' | 'passkey-register'

interface FlowPayload {
  jti: string
  challenge: string
  rpID: string
  exp: number
  /** 注册流程绑定发起时的会话，换个会话不能完成 */
  sid?: string
}

const spentFlows = new Map<string, number>()

function issueFlow(kind: FlowKind, challenge: string, rpID: string, sid?: string) {
  const exp = Math.floor(Date.now() / 1000) + FLOW_TTL_SECONDS
  return signToken(kind, { jti: randomUUID(), challenge, rpID, exp, sid })
}

/** 校验并作废 flow token：每个 token 只能用一次 */
function spendFlow(kind: FlowKind, token: unknown): FlowPayload {
  const flow = typeof token === 'string' ? verifyToken<FlowPayload>(kind, token) : null
  if (!flow || spentFlows.has(flow.jti)) {
    throw new PasskeyError('验证已过期，请重试')
  }
  const now = Math.floor(Date.now() / 1000)
  for (const [jti, exp] of spentFlows) if (exp <= now) spentFlows.delete(jti)
  spentFlows.set(flow.jti, flow.exp)
  return flow
}

function parseTransports(row: PasskeyRow) {
  try {
    return JSON.parse(row.transports) as AuthenticatorTransportFuture[]
  } catch {
    return []
  }
}

type AuthenticatorTransportFuture = NonNullable<
  RegistrationResponseJSON['response']['transports']
>[number]

// ---------------------------------------------------------------------------
// 登录
// ---------------------------------------------------------------------------

export async function beginLogin(req: NextRequest) {
  const { rpID } = relyingParty(req)
  const options = await generateAuthenticationOptions({
    rpID,
    userVerification: 'required',
    timeout: FLOW_TTL_SECONDS * 1000,
  })
  return { flowToken: issueFlow('passkey-login', options.challenge, rpID), options }
}

export async function finishLogin(req: NextRequest, token: unknown, credential: unknown) {
  const flow = spendFlow('passkey-login', token)
  const response = credential as AuthenticationResponseJSON
  const row = typeof response?.id === 'string' ? getPasskey(response.id) : undefined
  if (!row) throw new PasskeyError('这个 Passkey 未在本站注册或已被删除')
  const { origin } = relyingParty(req)

  const result = await verifyAuthenticationResponse({
    response,
    expectedChallenge: flow.challenge,
    expectedOrigin: origin,
    expectedRPID: flow.rpID,
    credential: {
      id: row.id,
      publicKey: new Uint8Array(row.public_key),
      counter: row.counter,
      transports: parseTransports(row),
    },
    requireUserVerification: true,
  }).catch((error: Error) => {
    throw new PasskeyError(`Passkey 验证失败：${error.message}`)
  })
  if (!result.verified) throw new PasskeyError('Passkey 验证失败')

  const info = result.authenticationInfo
  touchPasskey(row.id, info.newCounter, info.credentialBackedUp, Math.floor(Date.now() / 1000))
  return row
}

// ---------------------------------------------------------------------------
// 注册
// ---------------------------------------------------------------------------

export async function beginRegistration(req: NextRequest, sid: string) {
  const { rpID } = relyingParty(req)
  const username = adminUsername()
  const options = await generateRegistrationOptions({
    rpName: RP_NAME,
    rpID,
    userName: username,
    userDisplayName: username,
    userID: userID(),
    attestationType: 'none',
    excludeCredentials: listPasskeys().map((row) => ({
      id: row.id,
      transports: parseTransports(row),
    })),
    authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
    timeout: FLOW_TTL_SECONDS * 1000,
  })
  return { flowToken: issueFlow('passkey-register', options.challenge, rpID, sid), options }
}

export async function finishRegistration(
  req: NextRequest,
  sid: string,
  token: unknown,
  credential: unknown,
  name: string
) {
  const flow = spendFlow('passkey-register', token)
  if (flow.sid !== sid) throw new PasskeyError('验证已过期，请重试')
  const { origin } = relyingParty(req)

  const result = await verifyRegistrationResponse({
    response: credential as RegistrationResponseJSON,
    expectedChallenge: flow.challenge,
    expectedOrigin: origin,
    expectedRPID: flow.rpID,
    requireUserVerification: true,
  }).catch((error: Error) => {
    throw new PasskeyError(`Passkey 注册失败：${error.message}`)
  })
  if (!result.verified) throw new PasskeyError('Passkey 注册失败')

  const info = result.registrationInfo
  if (getPasskey(info.credential.id)) throw new PasskeyError('这个 Passkey 已经注册过')
  insertPasskey({
    id: info.credential.id,
    public_key: info.credential.publicKey,
    counter: info.credential.counter,
    transports: JSON.stringify(info.credential.transports ?? []),
    name,
    device_type: info.credentialDeviceType,
    backed_up: info.credentialBackedUp ? 1 : 0,
    created_at: Math.floor(Date.now() / 1000),
  })
  return info.credential.id
}
