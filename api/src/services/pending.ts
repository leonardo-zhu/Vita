/**
 * 确认门（ADR-004、TDD §5，移植自 1.0 的 PendingService）。模型只能经 propose 创建提案；
 * confirm / cancel 只由用户在卡片上的操作调用。每个入口先清理过期项。
 */
import { createHash, randomUUID } from 'node:crypto'

import type { Pending, PendingStatus } from '@vita/contract'

import { audit, transaction } from '../db.ts'
import type { FoodChange, PendingChange, RecordChange } from '../domain/changes.ts'
import { addDays, localDateOf, zonedInstant } from '../domain/time.ts'
import { isServiceError, ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'
import type { FoodService } from './foods.ts'
import type { RecordService } from './records.ts'

/** 确认卡的有效期：创建后 30 分钟，或创建当天的本地午夜，取较早者。 */
const LIFETIME_MS = 30 * 60 * 1000

/**
 * 截止点取决于创建确认卡的真实时间，而不是会话日期，否则向历史日期补记会创建即过期。
 */
export function pendingExpiresAt(createdAt: Date, timeZone: string): Date {
  const nextMidnight = zonedInstant(addDays(localDateOf(createdAt, timeZone), 1), 0, 0, 0, timeZone)
  return new Date(Math.min(createdAt.getTime() + LIFETIME_MS, nextMidnight.getTime()))
}

interface PendingRow {
  id: string
  session_date: string
  expected_revision: number
  payload: string | null
  payload_hash: string
  preview: string | null
  status: PendingStatus
  created_at: string
  expires_at: string
  resolution_code: string | null
  result_id: string | null
  request_id: string | null
  after_confirm: string | null
}

export interface ProposeOptions extends WriteOrigin {
  /** 修正当前待确认卡片时填它的 ID；否则当天已有待确认卡片会拒绝新的提案。 */
  replacing?: string | null
  /** 这张卡片确认后要接着做的下一步。 */
  afterConfirm?: string | null
}

export class PendingService {
  private readonly context: ServiceContext
  private readonly records: RecordService
  private readonly foods: FoodService

  constructor(context: ServiceContext, records: RecordService, foods: FoodService) {
    this.context = context
    this.records = records
    this.foods = foods
  }

  /** 校验并保存记录变更的提案。校验与正式写入走同一套规则，校验不过不会产生确认卡。 */
  proposeRecord(change: RecordChange, date: string, expectedRevision: number, options: ProposeOptions): Pending {
    return this.store(date, expectedRevision, options, () => ({
      change: { type: 'record', change },
      preview: { type: 'record', record: this.records.preview(change, date, expectedRevision) },
    }))
  }

  /** 食品变更的提案，同样占用所在日期唯一的待确认名额。 */
  proposeFood(change: FoodChange, date: string, options: ProposeOptions): Pending {
    return this.store(date, 0, options, () => ({
      change: { type: 'food', change },
      preview: { type: 'food', food: this.foods.preview(change) },
    }))
  }

  /** 用户点确认：执行提案时保存的原始 payload，并在同一事务里把确认卡标为已确认。 */
  confirm(id: string, origin: WriteOrigin): Pending {
    this.expireDue()
    const row = this.find(id)
    if (row.status !== 'readyForConfirmation') {
      throw new ServiceError('pending', row.status === 'expired' ? 'expired' : 'notActive', { status: row.status })
    }
    let change: PendingChange
    try {
      if (!row.payload || hash(row.payload) !== row.payload_hash) throw new Error('hash')
      change = JSON.parse(row.payload) as PendingChange
    } catch {
      this.invalidate(row.id, 'payloadTampered')
      throw new ServiceError('pending', 'payloadTampered')
    }

    const markConfirmed = (resultId: string) => this.resolve(row.id, 'confirmed', null, resultId)
    const writeOrigin = { actor: origin.actor, requestId: row.request_id ?? origin.requestId }
    try {
      if (change.type === 'record') {
        this.records.apply(change.change, row.session_date, row.expected_revision, { ...writeOrigin, alongside: markConfirmed })
      } else {
        this.foods.apply(change.change, { ...writeOrigin, alongside: markConfirmed })
      }
    } catch (error) {
      if (isServiceError(error, 'revisionConflict') || isServiceError(error, 'activeVersionChanged')) {
        this.invalidate(row.id, 'revisionConflict')
        throw new ServiceError('pending', 'revisionConflict')
      }
      // 其他失败（如引用的食品版本已退役）保留确认卡，由用户取消或等待过期。
      throw error
    }
    return this.get(id)
  }

  cancel(id: string, origin: WriteOrigin): Pending {
    this.expireDue()
    const row = this.find(id)
    if (row.status !== 'readyForConfirmation') throw new ServiceError('pending', 'notActive', { status: row.status })
    transaction(this.context.database, () => {
      this.resolve(id, 'cancelled', 'userCancelled', null)
      audit(this.context.database, { actor: origin.actor, action: 'pending.cancel', targetId: id, result: 'success', at: this.context.now() })
    })
    return this.get(id)
  }

  /**
   * 确认后接着做下一步（afterConfirm）：只有已确认、带下一步、还没接续过的卡片可以，而且只给一次。
   * 返回会话日期和下一步，由调用方跑一轮接续。
   */
  claimContinuation(id: string): { sessionDate: string; step: string } {
    const row = this.find(id)
    if (row.status !== 'confirmed') throw new ServiceError('pending', 'notConfirmed', { status: row.status })
    if (!row.after_confirm) throw new ServiceError('pending', 'noFollowUp')
    const claimed = this.context.database
      .prepare('UPDATE pending_actions SET continued_at = ? WHERE id = ? AND continued_at IS NULL')
      .run(this.context.now().toISOString(), id)
    if (claimed.changes !== 1) throw new ServiceError('pending', 'alreadyContinued')
    return { sessionDate: row.session_date, step: row.after_confirm }
  }

  /** 每个入口都先调用：把到期的确认卡标为过期。 */
  expireDue() {
    const { database, now } = this.context
    const at = now()
    const due = database
      .prepare("SELECT id FROM pending_actions WHERE status = 'readyForConfirmation' AND expires_at <= ?")
      .all(at.toISOString()) as { id: string }[]
    if (due.length === 0) return
    transaction(database, () => {
      for (const { id } of due) {
        this.resolve(id, 'expired', null, null)
        audit(database, { actor: 'system', action: 'pending.expire', targetId: id, result: 'success', at })
      }
    })
  }

  /** 该日期当前可确认的卡片（最多一张）。 */
  active(date: string): Pending | null {
    this.expireDue()
    const row = this.activeRow(date)
    return row ? toPending(row) : null
  }

  get(id: string): Pending {
    this.expireDue()
    return toPending(this.find(id))
  }

  // MARK: - 私有

  private store(
    date: string,
    expectedRevision: number,
    options: ProposeOptions,
    validate: () => { change: PendingChange; preview: NonNullable<Pending['preview']> },
  ): Pending {
    this.expireDue()
    const { database, now } = this.context
    return transaction(database, () => {
      const active = this.activeRow(date)
      const replacing = options.replacing ?? null
      if (active && active.id !== replacing) throw new ServiceError('pending', 'anotherPendingActive', { pendingId: active.id })
      if (replacing && active?.id !== replacing) throw new ServiceError('pending', 'notFound')

      const { change, preview } = validate()
      const createdAt = now()
      const payload = JSON.stringify(change)
      const id = randomUUID()
      if (active) this.resolve(active.id, 'cancelled', 'replaced', null)
      database
        .prepare(
          `INSERT INTO pending_actions (id, session_date, expected_revision, payload, payload_hash, preview, status, created_at, expires_at, request_id, after_confirm)
           VALUES (?, ?, ?, ?, ?, ?, 'readyForConfirmation', ?, ?, ?, ?)`,
        )
        .run(
          id,
          date,
          expectedRevision,
          payload,
          hash(payload),
          JSON.stringify(preview),
          createdAt.toISOString(),
          pendingExpiresAt(createdAt, this.context.timeZone()).toISOString(),
          options.requestId ?? null,
          options.afterConfirm?.trim() || null,
        )
      audit(database, { actor: options.actor, action: 'pending.propose', targetId: id, result: 'success', requestId: options.requestId, at: createdAt })
      return toPending(this.find(id))
    })
  }

  private activeRow(date: string): PendingRow | null {
    return (
      (this.context.database
        .prepare("SELECT * FROM pending_actions WHERE session_date = ? AND status = 'readyForConfirmation'")
        .get(date) as PendingRow | undefined) ?? null
    )
  }

  private find(id: string): PendingRow {
    const row = this.context.database.prepare('SELECT * FROM pending_actions WHERE id = ?').get(id) as PendingRow | undefined
    if (!row) throw new ServiceError('pending', 'notFound')
    return row
  }

  /** 结束一张卡片：记下结局，清空确认卡内容。payload 保留用于审计。 */
  private resolve(id: string, status: PendingStatus, code: string | null, resultId: string | null) {
    this.context.database
      .prepare('UPDATE pending_actions SET status = ?, resolution_code = ?, result_id = ?, resolved_at = ?, preview = NULL WHERE id = ?')
      .run(status, code, resultId, this.context.now().toISOString(), id)
  }

  private invalidate(id: string, code: string) {
    const { database, now } = this.context
    transaction(database, () => {
      this.resolve(id, 'cancelled', code, null)
      audit(database, { actor: 'system', action: 'pending.invalidate', targetId: id, result: 'failure', errorCode: `pending.${code}`, at: now() })
    })
  }
}

function hash(payload: string): string {
  return createHash('sha256').update(payload).digest('hex')
}

function toPending(row: PendingRow): Pending {
  return {
    id: row.id,
    sessionDate: row.session_date,
    status: row.status,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    preview: row.preview ? JSON.parse(row.preview) : null,
    resolutionCode: row.resolution_code,
    resultId: row.result_id,
    afterConfirm: row.after_confirm,
  }
}
