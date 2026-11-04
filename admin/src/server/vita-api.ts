/**
 * Admin 调 Vita API（ADR-020、《Vita 2.0 架构设计》§3）：用服务令牌，走本机回环地址，不经过公网。
 * 数据管理只经 API，不直接打开 API 的数据库，校验与审计只有一套。请求与响应的类型来自 @vita/contract。
 */
import 'server-only'

import { CreateDeviceResponse, ErrorResponse, ListDevicesResponse, type Device } from '@vita/contract'
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
