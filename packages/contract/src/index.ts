/**
 * Vita API 的接口定义（《Vita 2.0 架构设计》§5）。
 *
 * API 用这里的 schema 校验请求、组装响应；Admin 引用同一份类型调 API，接口一改两边编译时就会报错。
 * iOS 按这里手写 Swift 模型。只放跨服务的定义，API 内部用的类型留在 api/。
 */
import { z } from 'zod'

/** 所有错误响应的格式：机器码 + 一句说明，不含内部细节。 */
export const ErrorResponse = z.object({
  error: z.object({
    code: z.string(),
    message: z.string(),
  }),
})
export type ErrorResponse = z.infer<typeof ErrorResponse>

/** GET /v1/health：不需要鉴权，给 Caddy、Docker 健康检查和部署脚本用。 */
export const HealthResponse = z.object({
  ok: z.literal(true),
  version: z.string(),
})
export type HealthResponse = z.infer<typeof HealthResponse>

// MARK: - 设备令牌（架构设计 §8）

/** 手机的设备令牌。只有 Admin（服务令牌）能签发、列出和吊销。 */
export const Device = z.object({
  id: z.uuid(),
  name: z.string(),
  createdAt: z.iso.datetime(),
  lastUsedAt: z.iso.datetime().nullable(),
  revokedAt: z.iso.datetime().nullable(),
})
export type Device = z.infer<typeof Device>

/** POST /v1/admin/devices */
export const CreateDeviceRequest = z.object({
  name: z.string().trim().min(1).max(64),
})
export type CreateDeviceRequest = z.infer<typeof CreateDeviceRequest>

/** 令牌明文只在签发时返回这一次，API 只存哈希。 */
export const CreateDeviceResponse = z.object({
  device: Device,
  token: z.string(),
})
export type CreateDeviceResponse = z.infer<typeof CreateDeviceResponse>

/** GET /v1/admin/devices */
export const ListDevicesResponse = z.object({
  devices: z.array(Device),
})
export type ListDevicesResponse = z.infer<typeof ListDevicesResponse>

/** GET /v1/me：设备令牌验证用，手机填完令牌后调一次确认能连上。 */
export const MeResponse = z.object({
  device: Device,
})
export type MeResponse = z.infer<typeof MeResponse>
