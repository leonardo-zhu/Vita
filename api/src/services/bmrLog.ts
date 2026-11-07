/**
 * 基础代谢的变化记录（ADR-018 补充）。随活动计算的目标每天按最新的身体数据重算 BMR（HealthService.bmrOn），
 * 称一次体重目标就会变；这里在可能影响它的写入之后（称重、删称重、手机上传、补录、改目标）算一次今天的 BMR，
 * 和上一次记下的不同才追加一条，Admin 的目标变更页与 Data 页据此解释目标为什么变了。
 * 活动带来的变化一天里不停地有，是随活动计算的本意，不记。
 */
import type { BmrChange, BmrChangeReason } from '@vita/contract'

import { localDateOf } from '../domain/time.ts'
import type { ServiceContext } from './context.ts'
import type { GoalService } from './goals.ts'
import type { HealthService } from './health.ts'

interface Row {
  local_date: string
  changed_at: string
  previous_bmr: number
  bmr: number
  reason: BmrChangeReason
  weight_kg: number
  height_cm: number
  age_years: number
  sex: BmrChange['sex']
}

/** 小于这个差不算变化（BMR 保留一位小数）。 */
const EPSILON = 0.05

function toChange(row: Row): BmrChange {
  return {
    date: row.local_date,
    changedAt: row.changed_at,
    previousBmrKcal: row.previous_bmr,
    bmrKcal: row.bmr,
    reason: row.reason,
    weightKg: row.weight_kg,
    heightCm: row.height_cm,
    ageYears: row.age_years,
    sex: row.sex,
  }
}

export class BmrLog {
  private readonly context: ServiceContext
  private readonly health: HealthService
  private readonly goals: GoalService

  constructor(context: ServiceContext, health: HealthService, goals: GoalService) {
    this.context = context
    this.health = health
    this.goals = goals
  }

  /** 算一次今天的 BMR，变了就记。今天的目标不是随活动计算的就不记（固定目标不用 BMR）。不抛错，失败只打日志。 */
  check(reason: BmrChangeReason) {
    try {
      const { database, now, timeZone } = this.context
      const today = localDateOf(now(), timeZone())
      const plan = this.goals.active(today)?.energyPlan
      if (!plan) return
      const inputs = this.health.bmrInputsOn(today)
      if (!inputs) return
      const last = database.prepare('SELECT bmr FROM bmr_changes ORDER BY id DESC LIMIT 1').get() as { bmr: number } | undefined
      // 第一次：和设定目标时存的比
      const previous = last?.bmr ?? plan.bmrKcal
      if (Math.abs(previous - inputs.bmrKcal) < EPSILON) return
      database
        .prepare(
          'INSERT INTO bmr_changes (local_date, changed_at, previous_bmr, bmr, reason, weight_kg, height_cm, age_years, sex) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        )
        .run(today, now().toISOString(), previous, inputs.bmrKcal, reason, inputs.weightKg, inputs.heightCm, inputs.ageYears, inputs.sex)
    } catch (error) {
      console.error('记录基础代谢变化失败', error)
    }
  }

  /** 这一天最近的一次变化；没有为 null。 */
  latestOn(date: string): BmrChange | null {
    const row = this.context.database.prepare('SELECT * FROM bmr_changes WHERE local_date = ? ORDER BY id DESC LIMIT 1').get(date) as Row | undefined
    return row ? toChange(row) : null
  }

  /** 全部变化，新的在前。 */
  list(limit = 200): BmrChange[] {
    return (this.context.database.prepare('SELECT * FROM bmr_changes ORDER BY id DESC LIMIT ?').all(limit) as unknown as Row[]).map(toChange)
  }
}
