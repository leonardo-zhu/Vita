/**
 * 某一天的只读视图，给 Data 页与 Agent 的读工具用（移植自 1.0 的 DayDataService）。
 * 汇总、能量目标与收支每次重算，不存储（TDD §4.2、§6.2）。
 */
import type { DayItem, DayRecord, DayResponse, DaySummary, Goal } from '@vita/contract'

import { energyBalance, energyTarget, type EnergyDay } from '../domain/energy.ts'
import { missingExtras, sumNutrients } from '../domain/nutrition.ts'
import { localDateOf, zonedInstant } from '../domain/time.ts'
import type { ServiceContext } from './context.ts'
import type { GoalService } from './goals.ts'
import type { HealthService } from './health.ts'
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
  private readonly goals: GoalService
  private readonly health: HealthService

  constructor(context: ServiceContext, goals: GoalService, health: HealthService) {
    this.context = context
    this.goals = goals
    this.health = health
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
    return { date, revision: session?.revision ?? 0, records, summary: this.summarize(date, records.flatMap((record) => record.items)) }
  }

  /** 汇总加上目标。能量目标随活动计算时，按当天活动算出目标与收支，并把目标里的能量换成算出的值。 */
  private summarize(date: string, items: DayItem[]): DaySummary {
    const summary = summarize(items, this.goals.active(date))
    const plan = summary.goal?.energyPlan
    if (!summary.goal || !plan) return summary
    const day = this.energyDay(date)
    const activity = this.health.activity(date)
    const energy = energyTarget(plan, activity, day)
    return {
      ...summary,
      goal: { ...summary.goal, targets: { ...summary.goal.targets, energyKcal: energy.targetKcal } },
      energy,
      balance: energyBalance(plan.bmrKcal, activity, day, summary.totals.energyKcal),
    }
  }

  private energyDay(date: string): EnergyDay {
    const now = this.context.now()
    const zone = this.context.timeZone()
    const today = localDateOf(now, zone)
    if (date < today) return { kind: 'past' }
    if (date > today) return { kind: 'future' }
    return { kind: 'today', elapsedSeconds: (now.getTime() - zonedInstant(today, 0, 0, 0, zone).getTime()) / 1000 }
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

export function summarize(items: DayItem[], goal: Goal | null = null): DaySummary {
  const included = items.filter((item) => item.includeInSummary)
  return {
    totals: sumNutrients(included.map((item) => item.snapshot.values)),
    includedItemCount: included.length,
    missingExtras: missingExtras(included.map((item) => item.snapshot.values)),
    excludedItemCount: items.length - included.length,
    estimatedItemCount: included.filter((item) => item.snapshot.nutritionSource === 'aiEstimated').length,
    goal,
    energy: null,
    balance: null,
  }
}
