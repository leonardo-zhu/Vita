/**
 * 每日目标（移植自 1.0 的 GoalService）。更新不覆盖旧行，而是追加一行更高 revision 的记录（TDD §3.2）。
 * 目标修改不走确认卡：明确指令直接执行，首次生成由用户在预览上确认（agent-tools.md）。
 */
import { randomUUID } from 'node:crypto'

import type { EnergyAdjustment, EnergyPlan, Goal, GoalKind, GoalOrigin, GoalRecommendation, GoalTargets } from '@vita/contract'

import { audit, transaction } from '../db.ts'
import { defaultAdjustment, isValidPlan } from '../domain/energy.ts'
import { ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'

const NUTRIENTS = ['energyKcal', 'proteinG', 'fatG', 'carbohydrateG'] as const

export const NO_TARGETS: GoalTargets = { energyKcal: null, proteinG: null, fatG: null, carbohydrateG: null }

/** 至少一项，且每项为正数。 */
export function isValidTargets(targets: GoalTargets): boolean {
  const present = NUTRIENTS.map((key) => targets[key]).filter((value): value is number => value !== null)
  return present.length > 0 && present.every((value) => Number.isFinite(value) && value > 0)
}

/** `updateGoal` 对能量规则的修改：只改给出的部分。 */
export interface EnergyPlanChange {
  kind?: GoalKind
  adjustment?: EnergyAdjustment
}

interface GoalRow {
  id: string
  effective_from: string
  targets: string
  energy_plan: string | null
  origin: GoalOrigin
  revision: number
}

export class GoalService {
  private readonly context: ServiceContext
  private readonly listeners: (() => void)[] = []

  constructor(context: ServiceContext) {
    this.context = context
  }

  /** 目标变了（追加了一条）：通知监听者（BmrLog）。在事务提交之后调用。 */
  onChange(listener: () => void) {
    this.listeners.push(listener)
  }

  /** 全部目标，新的在前，带创建时间与审计里的发起方。给 Admin 的目标变更页。 */
  history(): { goal: Goal; createdAt: string; actor: string | null }[] {
    const rows = this.context.database
      .prepare(
        `SELECT g.*, (SELECT actor FROM audit_events a WHERE a.action = 'goal.append' AND a.target_id = g.id AND a.result = 'success' LIMIT 1) AS actor
         FROM daily_goals g ORDER BY g.revision DESC`,
      )
      .all() as unknown as (GoalRow & { created_at: string; actor: string | null })[]
    return rows.map((row) => ({ goal: toGoal(row), createdAt: row.created_at, actor: row.actor }))
  }

  /** 某日生效的目标：effectiveFrom 不晚于该日的行中，日期最晚、revision 最高的一行。 */
  active(date: string): Goal | null {
    const row = this.context.database
      .prepare('SELECT * FROM daily_goals WHERE effective_from <= ? ORDER BY effective_from DESC, revision DESC LIMIT 1')
      .get(date) as GoalRow | undefined
    return row ? toGoal(row) : null
  }

  /** 首次（或用户要求重新）生成目标：用户确认建议后调用。建议本身作为生成依据一并保存。 */
  commitInitial(recommendation: GoalRecommendation, effectiveFrom: string, origin: WriteOrigin): Goal {
    return this.append(recommendation.targets, recommendation.energyPlan, 'initialRecommendation', effectiveFrom, origin, recommendation).current
  }

  /**
   * 用户明确指令修改目标（updateGoal）：只改给出的项，其余沿用当前目标；返回旧值与新值供复述。
   * 给出能量数值时改为固定能量目标；`energyPlan` 改目标类型或调整幅度，并恢复随活动计算（ADR-018）。
   */
  update(changes: Partial<GoalTargets>, energyPlan: EnergyPlanChange | null, effectiveFrom: string, origin: WriteOrigin) {
    for (const key of NUTRIENTS) {
      const value = changes[key]
      if (value !== undefined && value !== null && !(value > 0)) throw new ServiceError('goal', 'invalidTargets')
    }
    const active = this.active(effectiveFrom)
    const current = active?.targets ?? NO_TARGETS
    const merged = Object.fromEntries(NUTRIENTS.map((key) => [key, changes[key] ?? current[key]])) as GoalTargets
    let plan = changes.energyKcal == null ? (active?.energyPlan ?? null) : null
    if (energyPlan) {
      // 恢复随活动计算需要设定时的 BMR 与平时活动；从没自动设定过的目标要先生成一次。
      const base = plan ?? this.latestEnergyPlan()
      if (!base) throw new ServiceError('goal', 'noEnergyPlan')
      const next: EnergyPlan = { ...base }
      if (energyPlan.kind) {
        next.kind = energyPlan.kind
        next.adjustment = defaultAdjustment(energyPlan.kind)
      }
      if (energyPlan.adjustment) next.adjustment = energyPlan.adjustment
      if (!isValidPlan(next)) throw new ServiceError('goal', 'invalidTargets')
      plan = next
    }
    return this.append(merged, plan, 'explicitUserCommand', effectiveFrom, origin)
  }

  /** 追加一条目标，返回该日期原先生效的目标与新目标。 */
  append(
    targets: GoalTargets,
    energyPlan: EnergyPlan | null,
    goalOrigin: GoalOrigin,
    effectiveFrom: string,
    origin: WriteOrigin,
    evidence: unknown = null,
  ): { previous: Goal | null; current: Goal } {
    const { database, now } = this.context
    if (!isValidTargets(targets)) {
      audit(database, { actor: origin.actor, action: 'goal.append', result: 'failure', errorCode: 'goal.invalidTargets', requestId: origin.requestId, at: now() })
      throw new ServiceError('goal', 'invalidTargets')
    }
    const result = transaction(database, () => {
      const previous = this.active(effectiveFrom)
      const { next } = database.prepare('SELECT coalesce(max(revision), 0) + 1 AS next FROM daily_goals').get() as { next: number }
      const id = randomUUID()
      const at = now()
      database
        .prepare('INSERT INTO daily_goals (id, effective_from, targets, energy_plan, origin, evidence, revision, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
        .run(id, effectiveFrom, JSON.stringify(targets), energyPlan ? JSON.stringify(energyPlan) : null, goalOrigin, evidence ? JSON.stringify(evidence) : null, next, at.toISOString())
      audit(database, { actor: origin.actor, action: 'goal.append', targetId: id, result: 'success', requestId: origin.requestId, at })
      const current = toGoal(database.prepare('SELECT * FROM daily_goals WHERE id = ?').get(id) as unknown as GoalRow)
      return { previous, current }
    })
    for (const listener of this.listeners) listener()
    return result
  }

  /** 最近一次自动设定的能量规则，用来从固定目标"改回自动"。 */
  private latestEnergyPlan(): EnergyPlan | null {
    const row = this.context.database
      .prepare('SELECT energy_plan FROM daily_goals WHERE energy_plan IS NOT NULL ORDER BY revision DESC LIMIT 1')
      .get() as { energy_plan: string } | undefined
    return row ? JSON.parse(row.energy_plan) : null
  }
}

function toGoal(row: GoalRow): Goal {
  return {
    id: row.id,
    effectiveFrom: row.effective_from,
    targets: JSON.parse(row.targets),
    energyPlan: row.energy_plan ? JSON.parse(row.energy_plan) : null,
    origin: row.origin,
    revision: row.revision,
  }
}
