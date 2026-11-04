/**
 * 服务共用的依赖与错误类型。时钟和时区可注入，测试用固定值。
 */
import type { DatabaseSync } from 'node:sqlite'

import type { ReferenceCatalog } from '../domain/reference.ts'

export interface ServiceContext {
  database: DatabaseSync
  reference: ReferenceCatalog
  now: () => Date
  /** 新建日期会话与确认卡过期按这个时区算。单用户，取服务端配置（VITA_API_TIME_ZONE）。 */
  timeZone: () => string
}

/** 写入时附带的来历：谁发起的、属于哪次请求，记进审计。 */
export interface WriteOrigin {
  actor: string
  requestId?: string | null
}

/**
 * 业务规则拒绝了这次操作。`code` 给调用方（接口响应、模型的工具结果），
 * `auditCode` 写进审计日志（ADR-010），都不含自由文本。
 */
export class ServiceError extends Error {
  readonly code: string
  readonly auditCode: string
  readonly details: Record<string, unknown>

  /** `auditDetail` 细分审计码，如 invalidItem 的具体原因：record.invalidItem.unknownReferenceFood。 */
  constructor(domain: 'record' | 'food' | 'pending' | 'goal' | 'body' | 'label' | 'chat', code: string, details: Record<string, unknown> = {}, auditDetail?: string) {
    super(`${domain}.${code}`)
    this.code = code
    this.auditCode = auditDetail ? `${domain}.${code}.${auditDetail}` : `${domain}.${code}`
    this.details = details
  }
}

export function isServiceError(error: unknown, code?: string): error is ServiceError {
  return error instanceof ServiceError && (code === undefined || error.code === code)
}
