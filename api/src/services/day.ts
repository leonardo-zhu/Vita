/**
 * 某一天的只读视图，给 Data 页与 Agent 的读工具用（移植自 1.0 的 DayDataService）。
 * 汇总每次由 Item 快照重算，不存储（TDD §4.2）。目标与能量收支随目标模块一起移植。
 */
import type { DayItem, DayRecord, DayResponse, DaySummary } from '@vita/contract'

import { sumNutrients } from '../domain/nutrition.ts'
import type { ServiceContext } from './context.ts'
import { sourceLabel } from './labels.ts'

interface RecordRow {
  id: string
  event_time: string
  meal_label: string | null
  note: string | null
  revision: number
}

interface ItemRow {
  id: string
  record_id: string
  display_name: string
  group_name: string | null
  original_amount_text: string
  quantity: string | null
  amount_source: DayItem['amountSource']
  include_in_summary: number
  snapshot: string
  food_version_id: string | null
  reference_food_id: string | null
}

export class DayService {
  private readonly context: ServiceContext

  constructor(context: ServiceContext) {
    this.context = context
  }

  /** 读取某日数据；没有会话时返回空日，不因读取而创建会话。 */
  day(date: string): DayResponse {
    const { database } = this.context
    const session = database.prepare('SELECT revision FROM day_sessions WHERE local_date = ?').get(date) as { revision: number } | undefined
    const recordRows = database
      .prepare('SELECT id, event_time, meal_label, note, revision FROM consumption_records WHERE session_date = ? ORDER BY sort_time, created_at')
      .all(date) as unknown as RecordRow[]
    const itemRows = database
      .prepare(
        `SELECT i.* FROM consumption_items i JOIN consumption_records r ON r.id = i.record_id WHERE r.session_date = ? ORDER BY i.position`,
      )
      .all(date) as unknown as ItemRow[]

    const records: DayRecord[] = recordRows.map((record) => {
      const items = itemRows.filter((item) => item.record_id === record.id).map((item) => this.toItem(item))
      return {
        id: record.id,
        eventTime: JSON.parse(record.event_time),
        mealLabel: record.meal_label,
        note: record.note,
        revision: record.revision,
        items,
        totals: sumNutrients(items.filter((item) => item.includeInSummary).map((item) => item.snapshot.values)),
      }
    })
    return { date, revision: session?.revision ?? 0, records, summary: summarize(records.flatMap((record) => record.items)) }
  }

  private toItem(row: ItemRow): DayItem {
    return {
      id: row.id,
      displayName: row.display_name,
      groupName: row.group_name,
      originalAmountText: row.original_amount_text,
      quantity: row.quantity ? JSON.parse(row.quantity) : null,
      amountSource: row.amount_source,
      includeInSummary: row.include_in_summary === 1,
      snapshot: JSON.parse(row.snapshot),
      sourceLabel: sourceLabel(this.context, row.reference_food_id, row.food_version_id),
    }
  }
}

export function summarize(items: DayItem[]): DaySummary {
  const included = items.filter((item) => item.includeInSummary)
  return {
    totals: sumNutrients(included.map((item) => item.snapshot.values)),
    includedItemCount: included.length,
    excludedItemCount: items.length - included.length,
    estimatedItemCount: included.filter((item) => item.snapshot.nutritionSource === 'aiEstimated').length,
  }
}
