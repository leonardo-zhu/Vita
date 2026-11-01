/**
 * 接收客户端诊断日志（vita-admin.md §11.4）。
 *
 * - 先按共用 schema 校验，任何多余字段整批拒绝：客户端发送前已经过滤，这里兜底。
 * - 鉴权现阶段只有匿名安装 ID：按 IP 与安装 ID 限流，被封禁的安装 ID 拒收；分发前改为 App Attest。
 * - eventId 去重，客户端重传不会重复计数。
 * - 时间明显不对（早于保留期或晚于现在一天）的事件丢弃。
 * - 保留 30 天，接收时顺带清理（每小时最多一次）。
 */
import Ajv2020 from 'ajv/dist/2020'
import addFormats from 'ajv-formats'

import schema from '@/generated/diagnostics-batch.schema.json'

import { db, nowSeconds, transaction } from '../db'

export const RETENTION_DAYS = 30
export const MAX_BODY_BYTES = 64 * 1024

const ajv = new Ajv2020({ allErrors: false, strict: false })
addFormats(ajv)
const validateBatch = ajv.compile(schema)

interface EventBase {
  eventId: string
  occurredAt: string
  dataClass: 'diagnostic'
  configVersion?: string
  requestId?: string
}

export type DiagnosticEvent =
  | (EventBase & {
      type: 'chat_turn'
      outcome: 'ok' | 'error' | 'cancelled'
      errorCode?: string
      modelAlias?: string
      systemPromptVersion?: number
      latencyMs: number
      rounds?: number
      toolCalls?: number
      tokensIn?: number
      tokensOut?: number
      createdPending?: boolean
      claimedCardWithoutTool?: boolean
      hitMaxRounds?: boolean
    })
  | (EventBase & {
      type: 'tool_call'
      tool: string
      toolDescriptionVersion?: number
      resultCode: string
      latencyMs: number
    })
  | (EventBase & {
      type: 'config_fetch'
      outcome: 'updated' | 'unchanged' | 'failed'
      errorCode?: string
      latencyMs: number
    })

export interface DiagnosticsBatch {
  installId: string
  appVersion: string
  osVersion?: string
  events: DiagnosticEvent[]
}

export type IngestResult =
  | { status: 200; accepted: number; duplicates: number; dropped: number }
  | { status: 400 | 403 | 413 | 429; error: string }

// ---------------------------------------------------------------------------
// 限流：每个 IP、每个安装 ID 10 分钟内最多 60 批（单进程，存内存）
// ---------------------------------------------------------------------------

const WINDOW_MS = 10 * 60 * 1000
const MAX_BATCHES = 60
const buckets = new Map<string, { count: number; resetAt: number }>()

function allow(key: string): boolean {
  const now = Date.now()
  const bucket = buckets.get(key)
  if (!bucket || bucket.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + WINDOW_MS })
    if (buckets.size > 10_000) {
      for (const [k, b] of buckets) if (b.resetAt <= now) buckets.delete(k)
    }
    return true
  }
  bucket.count += 1
  return bucket.count <= MAX_BATCHES
}

export function resetRateLimitForTests() {
  buckets.clear()
}

// ---------------------------------------------------------------------------

export function validate(body: unknown): body is DiagnosticsBatch {
  return validateBatch(body) as boolean
}

let lastPurge = 0

export function purgeExpired(now = nowSeconds()) {
  db().prepare('DELETE FROM diagnostic_events WHERE occurred_at < ?').run(now - RETENTION_DAYS * 86400)
  db().prepare('DELETE FROM installs WHERE last_seen < ? AND revoked = 0').run(now - RETENTION_DAYS * 86400)
}

export function ingest(body: unknown, ip: string): IngestResult {
  if (!allow(`ip:${ip}`)) return { status: 429, error: 'too many requests' }
  if (!validate(body)) return { status: 400, error: 'invalid batch' }
  const batch = body
  const installId = batch.installId.toUpperCase()
  if (!allow(`install:${installId}`)) return { status: 429, error: 'too many requests' }

  const now = nowSeconds()
  const install = db().prepare('SELECT revoked FROM installs WHERE install_id = ?').get(installId) as
    | { revoked: number }
    | undefined
  if (install?.revoked) return { status: 403, error: 'install revoked' }

  if (now - lastPurge > 3600) {
    purgeExpired(now)
    lastPurge = now
  }

  const insert = db().prepare(
    `INSERT OR IGNORE INTO diagnostic_events (
       event_id, received_at, occurred_at, install_id, data_class, event_type, outcome, error_code,
       result_code, tool, tool_description_version, config_version, system_prompt_version, model_alias,
       request_id, latency_ms, rounds, tool_calls, tokens_in, tokens_out, created_pending,
       claimed_card_without_tool, hit_max_rounds, app_version, os_version)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
  const flag = (value: boolean | undefined) => (value === undefined ? null : value ? 1 : 0)
  let accepted = 0
  let dropped = 0
  transaction(() => {
    db()
      .prepare(
        `INSERT INTO installs (install_id, first_seen, last_seen, app_version, os_version) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (install_id) DO UPDATE SET last_seen = excluded.last_seen,
           app_version = excluded.app_version, os_version = excluded.os_version`
      )
      .run(installId, now, now, batch.appVersion, batch.osVersion ?? null)
    for (const event of batch.events) {
      const occurred = Math.floor(Date.parse(event.occurredAt) / 1000)
      if (!Number.isFinite(occurred) || occurred < now - RETENTION_DAYS * 86400 || occurred > now + 86400) {
        dropped += 1
        continue
      }
      const chat = event.type === 'chat_turn' ? event : null
      const tool = event.type === 'tool_call' ? event : null
      const result = insert.run(
        event.eventId.toUpperCase(),
        now,
        occurred,
        installId,
        event.dataClass,
        event.type,
        'outcome' in event ? event.outcome : null,
        'errorCode' in event ? (event.errorCode ?? null) : null,
        tool?.resultCode ?? null,
        tool?.tool ?? null,
        tool?.toolDescriptionVersion ?? null,
        event.configVersion ?? null,
        chat?.systemPromptVersion ?? null,
        chat?.modelAlias ?? null,
        event.requestId?.toUpperCase() ?? null,
        event.latencyMs,
        chat?.rounds ?? null,
        chat?.toolCalls ?? null,
        chat?.tokensIn ?? null,
        chat?.tokensOut ?? null,
        flag(chat?.createdPending),
        flag(chat?.claimedCardWithoutTool),
        flag(chat?.hitMaxRounds),
        batch.appVersion,
        batch.osVersion ?? null
      )
      accepted += Number(result.changes)
    }
  })
  return { status: 200, accepted, duplicates: batch.events.length - accepted - dropped, dropped }
}
