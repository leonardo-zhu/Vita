/**
 * Admin 调 Vita API（ADR-020、《Vita 2.0 架构设计》§3）：用服务令牌，走本机回环地址，不经过公网。
 * 数据管理只经 API，不直接打开 API 的数据库，校验与审计只有一套。请求与响应的类型来自 @vita/contract。
 */
import 'server-only'

import {
  ChatMessage,
  ConversationDaysResponse,
  CreateDeviceResponse,
  DayResponse,
  ErrorResponse,
  FoodProductResponse,
  FoodsResponse,
  GoogleHealthAuthorizeResponse,
  GoogleHealthStatus,
  ListDevicesResponse,
  MessagesResponse,
  TracesResponse,
  type Device,
  type FoodProduct,
  type FoodProductUpdate,
  type FoodVersionRequest,
  type ItemAmountRequest,
} from '@vita/contract'
import type { z } from 'zod'

export class VitaApiError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

export function vitaApiConfigured(): boolean {
  return Boolean(process.env.VITA_API_SERVICE_TOKEN)
}

/** 默认是同机的 API（两个容器都是 network_mode: host）。 */
function baseURL(): string {
  return process.env.VITA_API_BASE_URL ?? 'http://127.0.0.1:3014'
}

async function call<T extends z.ZodType>(path: string, schema: T | null, init: RequestInit = {}): Promise<z.infer<T>> {
  const token = process.env.VITA_API_SERVICE_TOKEN
  if (!token) throw new VitaApiError('notConfigured', 'VITA_API_SERVICE_TOKEN is not set')
  let res: Response
  try {
    res = await fetch(new URL(path, baseURL()), {
      ...init,
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...init.headers },
      cache: 'no-store',
      signal: AbortSignal.timeout(10_000),
    })
  } catch (error) {
    throw new VitaApiError('unreachable', (error as Error).message)
  }
  if (!res.ok) {
    const parsed = ErrorResponse.safeParse(await res.json().catch(() => null))
    throw new VitaApiError(parsed.success ? parsed.data.error.code : `http${res.status}`, parsed.success ? parsed.data.error.message : `HTTP ${res.status}`)
  }
  if (!schema) return undefined as z.infer<T>
  return schema.parse(await res.json())
}

export async function listDevices(): Promise<Device[]> {
  return (await call('/v1/admin/devices', ListDevicesResponse)).devices
}

/** 令牌明文只在这里返回一次，API 只存哈希。 */
export async function createDevice(name: string): Promise<{ device: Device; token: string }> {
  return call('/v1/admin/devices', CreateDeviceResponse, { method: 'POST', body: JSON.stringify({ name }) })
}

export async function revokeDevice(id: string): Promise<void> {
  await call(`/v1/admin/devices/${encodeURIComponent(id)}`, null, { method: 'DELETE' })
}

// MARK: - 对话（rewind）

export async function conversationDays() {
  return (await call('/v1/admin/conversation-days', ConversationDaysResponse)).days
}

export async function dayMessages(date: string) {
  return (await call(`/v1/days/${encodeURIComponent(date)}/messages`, MessagesResponse)).messages
}

export async function dayTraces(date: string) {
  return (await call(`/v1/admin/traces?date=${encodeURIComponent(date)}`, TracesResponse)).traces
}

/** 消息不再发给模型（或恢复）；消息本身保留。 */
export async function setMessageExcluded(id: string, excludedFromContext: boolean) {
  return call(`/v1/admin/messages/${encodeURIComponent(id)}`, ChatMessage, { method: 'PATCH', body: JSON.stringify({ excludedFromContext }) })
}

// MARK: - 记录

export async function day(date: string) {
  return call(`/v1/days/${encodeURIComponent(date)}`, DayResponse)
}

const recordPath = (date: string, recordId: string) => `/v1/days/${encodeURIComponent(date)}/records/${encodeURIComponent(recordId)}`

export async function deleteRecord(date: string, revision: number, recordId: string) {
  return call(`${recordPath(date, recordId)}?expectedRevision=${revision}`, DayResponse, { method: 'DELETE' })
}

export async function deleteItem(date: string, revision: number, recordId: string, itemId: string) {
  return call(`${recordPath(date, recordId)}/items/${encodeURIComponent(itemId)}?expectedRevision=${revision}`, DayResponse, { method: 'DELETE' })
}

export async function rescaleItem(date: string, recordId: string, itemId: string, body: ItemAmountRequest) {
  return call(`${recordPath(date, recordId)}/items/${encodeURIComponent(itemId)}`, DayResponse, { method: 'PATCH', body: JSON.stringify(body) })
}

// MARK: - 食品库

export async function foods(): Promise<FoodProduct[]> {
  return (await call('/v1/foods', FoodsResponse)).products
}

/** 名称、品牌、叫法、包装、备注：不影响已有记录的计算，直接改。 */
export async function updateFood(id: string, body: FoodProductUpdate) {
  return (await call(`/v1/foods/${encodeURIComponent(id)}`, FoodProductResponse, { method: 'PATCH', body: JSON.stringify(body) })).product
}

/** 营养值不能就地改：存为新版本并生效，旧版本保留，已有记录按当时的版本不变。 */
export async function addFoodVersion(id: string, body: FoodVersionRequest) {
  return (await call(`/v1/foods/${encodeURIComponent(id)}/versions`, FoodProductResponse, { method: 'POST', body: JSON.stringify(body) })).product
}

export async function deleteFood(id: string) {
  await call(`/v1/foods/${encodeURIComponent(id)}`, null, { method: 'DELETE' })
}

/** 标签照片的原始字节，经 Admin 转给浏览器（浏览器拿不到服务令牌）。 */
export async function labelImage(id: string): Promise<{ bytes: ArrayBuffer; contentType: string } | null> {
  const token = process.env.VITA_API_SERVICE_TOKEN
  if (!token) return null
  const res = await fetch(new URL(`/v1/label-scans/${encodeURIComponent(id)}`, baseURL()), {
    headers: { authorization: `Bearer ${token}` },
    cache: 'no-store',
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null)
  if (!res?.ok) return null
  return { bytes: await res.arrayBuffer(), contentType: res.headers.get('content-type') ?? 'image/jpeg' }
}

// MARK: - Google 健康（服务端拉活动能量与睡眠；连接在 Admin 里做）

export async function googleHealthStatus() {
  return call('/v1/google-health', GoogleHealthStatus)
}

/** Google 授权页地址；在浏览器里打开，授权后 Google 回调到 API，API 再跳回 /admin/google-health。 */
export async function startGoogleHealthAuthorization() {
  return (await call('/v1/admin/google-health/authorize', GoogleHealthAuthorizeResponse, { method: 'POST' })).url
}

export async function syncGoogleHealth() {
  return call('/v1/admin/google-health/sync', GoogleHealthStatus, { method: 'POST' })
}

export async function disconnectGoogleHealth() {
  await call('/v1/admin/google-health', null, { method: 'DELETE' })
}
