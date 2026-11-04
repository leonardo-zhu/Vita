/**
 * 饮食记录的正式写入（移植自 1.0 的 RecordService）。确认门与 App 里的编辑都经这里，模型不直接调用（ADR-004）。
 *
 * 每个操作是一个事务（TDD §4.1）：先全部校验，再修改、递增日期会话的 revision、写审计；
 * 任一步失败则回滚，并单独记一条失败审计。
 */
import { randomUUID } from 'node:crypto'

import type { DayItem, NutritionSnapshot, Quantity, RecordChangePreview } from '@vita/contract'

import { audit, recordHealthChange, transaction } from '../db.ts'
import { recordAuditAction, type ItemDraft, type RecordChange } from '../domain/changes.ts'
import { representativeTimestamp } from '../domain/eventTime.ts'
import {
  computedSnapshot,
  estimatedSnapshot,
  isValidNutrients,
  NutritionCalculationError,
  sumNutrients,
} from '../domain/nutrition.ts'
import { ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'
import { sourceLabel } from './labels.ts'

/** Item 被拒绝的原因（机器码），随 `invalidItem` 一起返回。 */
export type ItemRejection =
  | 'emptyName'
  | 'emptyAmountText'
  | 'quantityRequired'
  | 'amountSourceInconsistent'
  | 'unknownReferenceFood'
  | 'unknownFoodVersion'
  | 'retiredFoodVersion'
  | 'invalidEstimate'
  | 'packageUnavailable'
  | 'nonPositiveQuantity'
  | 'invalidBasis'
  | 'unitMismatch'

class Rejection extends Error {
  readonly reason: ItemRejection
  constructor(reason: ItemRejection) {
    super(reason)
    this.reason = reason
  }
}

interface SessionRow {
  local_date: string
  revision: number
}

interface RecordRow {
  id: string
  session_date: string
  event_time: string
  meal_label: string | null
  revision: number
}

interface ItemRow {
  id: string
  display_name: string
  position: number
}

interface ResolvedItem {
  draft: ItemDraft
  snapshot: NutritionSnapshot
  foodProductId: string | null
}

interface Prepared {
  preview: RecordChangePreview
  /** 只做已校验的修改，不再失败。返回受影响的 Record ID。 */
  commit: () => string
}

export interface ApplyOptions extends WriteOrigin {
  /** 与变更同一事务，确认卡用它一并更新自己的状态（TDD §4.1）。 */
  alongside?: (recordId: string) => void
}

export class RecordService {
  private readonly context: ServiceContext

  constructor(context: ServiceContext) {
    this.context = context
  }

  /** 只校验、不写入，返回变更后的预览。创建确认卡时用它确认提案可以执行。 */
  preview(change: RecordChange, date: string, expectedRevision: number): RecordChangePreview {
    return this.prepare(change, date, expectedRevision).preview
  }

  /** 执行变更，返回受影响的 Record ID（删除时为被删的 ID）。 */
  apply(change: RecordChange, date: string, expectedRevision: number, options: ApplyOptions): string {
    const { database, now } = this.context
    const action = recordAuditAction(change)
    const target = 'recordId' in change ? change.recordId : null
    try {
      return transaction(database, () => {
        const recordId = this.prepare(change, date, expectedRevision).commit()
        recordHealthChange(database, 'record', recordId, now())
        options.alongside?.(recordId)
        audit(database, { actor: options.actor, action, targetId: recordId, result: 'success', requestId: options.requestId, at: now() })
        return recordId
      })
    } catch (error) {
      const code = error instanceof ServiceError ? error.auditCode : 'record.persistence'
      audit(database, { actor: options.actor, action, targetId: target, result: 'failure', errorCode: code, requestId: options.requestId, at: now() })
      throw error
    }
  }

  // MARK: - 校验

  private prepare(change: RecordChange, date: string, expectedRevision: number): Prepared {
    const { database } = this.context
    switch (change.kind) {
      case 'create': {
        const { draft } = change
        const session = this.session(date)
        checkRevision(expectedRevision, session?.revision ?? 0)
        if (draft.eventTime.localDate !== date) throw new ServiceError('record', 'eventTimeOutsideSession')
        const items = this.resolveAll(draft.items)
        return {
          preview: makePreview('create', draft.mealLabel, draft.eventTime, items.map((item) => this.previewItem(item)), []),
          commit: () => {
            const at = this.now()
            if (!session) {
              database
                .prepare('INSERT INTO day_sessions (local_date, time_zone, revision, created_at, updated_at) VALUES (?, ?, 0, ?, ?)')
                .run(date, this.context.timeZone(), at, at)
            }
            const recordId = randomUUID()
            database
              .prepare(
                `INSERT INTO consumption_records (id, session_date, event_time, sort_time, meal_label, note, revision, created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`,
              )
              .run(recordId, date, JSON.stringify(draft.eventTime), representativeTimestamp(draft.eventTime).toISOString(), draft.mealLabel, draft.note, at, at)
            this.insertItems(items, recordId, 0, at)
            this.bump(date, at)
            return recordId
          },
        }
      }

      case 'appendItems': {
        const record = this.locate(change.recordId, date, expectedRevision)
        const items = this.resolveAll(change.items)
        return {
          preview: this.recordPreview('appendItems', record, items.map((item) => this.previewItem(item)), []),
          commit: () => {
            const at = this.now()
            const { next } = database.prepare('SELECT coalesce(max(position), -1) + 1 AS next FROM consumption_items WHERE record_id = ?').get(record.id) as { next: number }
            this.insertItems(items, record.id, next, at)
            this.touch(record.id, at)
            this.bump(date, at)
            return record.id
          },
        }
      }

      case 'replaceItem': {
        const record = this.locate(change.recordId, date, expectedRevision)
        const item = this.items(record.id).find((row) => row.id === change.itemId)
        if (!item) throw new ServiceError('record', 'itemNotFound')
        const [resolved] = this.resolveAll([change.item])
        return {
          preview: this.recordPreview('replaceItem', record, [this.previewItem(resolved)], [item.display_name]),
          commit: () => {
            const at = this.now()
            this.writeItem(item.id, resolved, at)
            this.touch(record.id, at)
            this.bump(date, at)
            return record.id
          },
        }
      }

      case 'removeItem': {
        const record = this.locate(change.recordId, date, expectedRevision)
        const items = this.items(record.id)
        const item = items.find((row) => row.id === change.itemId)
        if (!item) throw new ServiceError('record', 'itemNotFound')
        // 移除最后一项会留下空记录，须改用删除整条记录。
        if (items.length <= 1) throw new ServiceError('record', 'emptyRecord')
        return {
          preview: this.recordPreview('removeItem', record, [], [item.display_name]),
          commit: () => {
            const at = this.now()
            database.prepare('DELETE FROM consumption_items WHERE id = ?').run(item.id)
            this.touch(record.id, at)
            this.bump(date, at)
            return record.id
          },
        }
      }

      case 'deleteRecord': {
        const record = this.locate(change.recordId, date, expectedRevision)
        const names = this.items(record.id).map((row) => row.display_name)
        return {
          preview: this.recordPreview('deleteRecord', record, [], names),
          commit: () => {
            database.prepare('DELETE FROM consumption_records WHERE id = ?').run(record.id)
            this.bump(date, this.now())
            return record.id
          },
        }
      }
    }
  }

  private now(): string {
    return this.context.now().toISOString()
  }

  private session(date: string): SessionRow | null {
    return (this.context.database.prepare('SELECT local_date, revision FROM day_sessions WHERE local_date = ?').get(date) as SessionRow | undefined) ?? null
  }

  /** 取目标记录并确认它属于当前日期，模型不能借 ID 跨日期操作。 */
  private locate(recordId: string, date: string, expectedRevision: number): RecordRow {
    const session = this.session(date)
    if (!session) throw new ServiceError('record', 'recordNotFound')
    checkRevision(expectedRevision, session.revision)
    const record = this.context.database
      .prepare('SELECT id, session_date, event_time, meal_label, revision FROM consumption_records WHERE id = ?')
      .get(recordId) as RecordRow | undefined
    if (!record) throw new ServiceError('record', 'recordNotFound')
    if (record.session_date !== date) throw new ServiceError('record', 'recordNotInSession')
    return record
  }

  private items(recordId: string): ItemRow[] {
    return this.context.database
      .prepare('SELECT id, display_name, position FROM consumption_items WHERE record_id = ? ORDER BY position')
      .all(recordId) as unknown as ItemRow[]
  }

  private bump(date: string, at: string) {
    this.context.database.prepare('UPDATE day_sessions SET revision = revision + 1, updated_at = ? WHERE local_date = ?').run(at, date)
  }

  private touch(recordId: string, at: string) {
    this.context.database.prepare('UPDATE consumption_records SET revision = revision + 1, updated_at = ? WHERE id = ?').run(at, recordId)
  }

  private insertItems(items: ResolvedItem[], recordId: string, position: number, at: string) {
    items.forEach((item, offset) => {
      const id = randomUUID()
      this.context.database
        .prepare(
          `INSERT INTO consumption_items (id, record_id, position, display_name, original_amount_text, amount_source, snapshot, include_in_summary, created_at, updated_at)
           VALUES (?, ?, ?, '', '', 'aiEstimated', '{}', 1, ?, ?)`,
        )
        .run(id, recordId, position + offset, at, at)
      this.writeItem(id, item, at)
    })
  }

  /** 用已校验的草稿和算好的快照整体写入，修改与新建走同一条路径。 */
  private writeItem(itemId: string, item: ResolvedItem, at: string) {
    const { draft, snapshot } = item
    const { nutrition } = draft
    this.context.database
      .prepare(
        `UPDATE consumption_items SET group_name = ?, display_name = ?, original_amount_text = ?, quantity = ?, amount_source = ?,
           snapshot = ?, include_in_summary = ?, food_product_id = ?, food_version_id = ?, reference_food_id = ?, updated_at = ?
         WHERE id = ?`,
      )
      .run(
        draft.groupName,
        draft.displayName,
        draft.originalAmountText,
        draft.quantity ? JSON.stringify(draft.quantity) : null,
        draft.amountSource,
        JSON.stringify(snapshot),
        draft.includeInSummary ? 1 : 0,
        nutrition.source === 'personalFoodVersion' ? item.foodProductId : null,
        nutrition.source === 'personalFoodVersion' ? nutrition.foodVersionId : null,
        nutrition.source === 'referenceFood' ? nutrition.referenceFoodId : null,
        at,
        itemId,
      )
  }

  private recordPreview(kind: RecordChangePreview['kind'], record: RecordRow, items: DayItem[], removed: string[]): RecordChangePreview {
    return makePreview(kind, record.meal_label, JSON.parse(record.event_time), items, removed)
  }

  private previewItem(item: ResolvedItem): DayItem {
    const { draft } = item
    const { nutrition } = draft
    return {
      id: randomUUID(),
      displayName: draft.displayName,
      groupName: draft.groupName,
      originalAmountText: draft.originalAmountText,
      quantity: draft.quantity,
      amountSource: draft.amountSource,
      includeInSummary: draft.includeInSummary,
      snapshot: item.snapshot,
      sourceLabel: sourceLabel(
        this.context,
        nutrition.source === 'referenceFood' ? nutrition.referenceFoodId : null,
        nutrition.source === 'personalFoodVersion' ? nutrition.foodVersionId : null,
      ),
    }
  }

  // MARK: - Item 校验与营养计算

  private resolveAll(drafts: ItemDraft[]): ResolvedItem[] {
    if (drafts.length === 0) throw new ServiceError('record', 'emptyRecord')
    return drafts.map((draft, index) => {
      try {
        return this.resolve(draft)
      } catch (error) {
        if (error instanceof Rejection) {
          throw new ServiceError('record', 'invalidItem', { index, reason: error.reason }, error.reason)
        }
        throw error
      }
    })
  }

  private resolve(draft: ItemDraft): ResolvedItem {
    if (!draft.displayName.trim()) throw new Rejection('emptyName')
    if (!draft.originalAmountText.trim()) throw new Rejection('emptyAmountText')
    // 没有标准化用量时只能是 AI 估算，且用量来源也须标为估算（TDD §3.3）。
    if (!draft.quantity && draft.amountSource !== 'aiEstimated') throw new Rejection('amountSourceInconsistent')
    const { nutrition } = draft
    // "一盒、半瓶"只能按个人食品的包装规格换算（PRD §3.2.1）。
    if (draft.amountSource === 'packageConversion' && nutrition.source !== 'personalFoodVersion') throw new Rejection('packageUnavailable')

    try {
      switch (nutrition.source) {
        case 'referenceFood': {
          const quantity = requireQuantity(draft.quantity)
          const food = this.context.reference.food(nutrition.referenceFoodId)
          if (!food) throw new Rejection('unknownReferenceFood')
          const snapshot = computedSnapshot({
            source: 'referenceFood',
            sourceRef: food.id,
            basisQuantity: { amount: food.base.quantity, unit: food.base.unit },
            basisNutrients: food.nutrients,
            quantity,
            densityGPerMl: food.densityGPerMl,
          })
          return { draft, snapshot, foodProductId: null }
        }
        case 'personalFoodVersion': {
          const quantity = requireQuantity(draft.quantity)
          const version = this.context.database
            .prepare(
              `SELECT v.product_id, v.basis, v.retired_at, p.package FROM food_versions v JOIN food_products p ON p.id = v.product_id WHERE v.id = ?`,
            )
            .get(nutrition.foodVersionId) as { product_id: string; basis: string; retired_at: string | null; package: string | null } | undefined
          if (!version) throw new Rejection('unknownFoodVersion')
          if (version.retired_at) throw new Rejection('retiredFoodVersion')
          if (draft.amountSource === 'packageConversion') {
            const pack = version.package ? (JSON.parse(version.package) as Quantity) : null
            if (!pack || pack.unit !== quantity.unit) throw new Rejection('packageUnavailable')
          }
          const basis = JSON.parse(version.basis)
          const snapshot = computedSnapshot({
            source: 'personalFoodVersion',
            sourceRef: nutrition.foodVersionId,
            basisQuantity: basis.quantity,
            basisNutrients: basis.nutrients,
            quantity,
          })
          return { draft, snapshot, foodProductId: version.product_id }
        }
        case 'aiEstimated': {
          if (!isValidNutrients(nutrition.values) || !nutrition.estimateBasis.trim()) throw new Rejection('invalidEstimate')
          if (draft.quantity && !(draft.quantity.amount > 0)) throw new Rejection('nonPositiveQuantity')
          return { draft, snapshot: estimatedSnapshot(nutrition.values, nutrition.estimateBasis, draft.quantity), foodProductId: null }
        }
      }
    } catch (error) {
      if (error instanceof NutritionCalculationError) throw new Rejection(error.code)
      throw error
    }
  }
}

function requireQuantity(quantity: Quantity | null): Quantity {
  if (!quantity) throw new Rejection('quantityRequired')
  return quantity
}

function checkRevision(expected: number, actual: number) {
  if (expected !== actual) throw new ServiceError('record', 'revisionConflict', { expected, actual })
}

function makePreview(
  kind: RecordChangePreview['kind'],
  recordLabel: string | null,
  eventTime: RecordChangePreview['eventTime'],
  items: DayItem[],
  removedItemNames: string[],
): RecordChangePreview {
  const totals = sumNutrients(items.filter((item) => item.includeInSummary).map((item) => item.snapshot.values))
  return { kind, recordLabel, eventTime, items, removedItemNames, totals }
}
