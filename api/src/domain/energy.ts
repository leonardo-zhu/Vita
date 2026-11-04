/**
 * 每日能量目标的计算（TDD §6.2、ADR-018，移植自 1.0 的 EnergyTargetPolicy）。系数都在这里。
 * 计算用十进制（big.js），舍入为"四舍五入、逢半远离零"，与 1.0 的 NSDecimalRound(.plain) 一致。
 */
import Big from 'big.js'

import type { EnergyAdjustment, EnergyBalance, EnergyPlan, EnergyTarget, GoalKind } from '@vita/contract'

export const DEFAULT_LOSE_FRACTION = 0.85
export const DEFAULT_GAIN_FRACTION = 1.1
/** 没有活动数据时的平时活动 = BMR × 0.375（即 TDEE = BMR × 1.375）。 */
export const ESTIMATED_ACTIVITY_SHARE_OF_BMR = 0.375
/** 超出平时的活动计入的比例。 */
const EXTRA_ACTIVITY_SHARE = 0.5
/** 活跃时段 7:00–23:00，用来估计今天剩下的活动。 */
const ACTIVE_START_HOUR = 7
const ACTIVE_END_HOUR = 23

/** 某天的活动：今天的是截至现在的累计，过去的日子是全天。 */
export interface DayActivity {
  /** 当天已消耗的活动能量；没有数据为 null。 */
  activeKcal: number | null
  /** 这一天之前 7 个完整日的日均活动；有数据的天数不足时为 null。 */
  dailyAverageKcal: number | null
}

/** 今天（`elapsedSeconds` 为从 0 点起已过的秒数）、过去或将来。 */
export type EnergyDay = { kind: 'today'; elapsedSeconds: number } | { kind: 'past' } | { kind: 'future' }

export function defaultAdjustment(kind: GoalKind): EnergyAdjustment {
  switch (kind) {
    case 'maintain':
      return { type: 'fraction', value: 1 }
    case 'lose':
      return { type: 'fraction', value: DEFAULT_LOSE_FRACTION }
    case 'gain':
      return { type: 'fraction', value: DEFAULT_GAIN_FRACTION }
  }
}

/** 比例 0.5–1.5，千卡 −1500…+1500。 */
export function isValidPlan(plan: EnergyPlan): boolean {
  const { type, value } = plan.adjustment
  return type === 'fraction' ? value >= 0.5 && value <= 1.5 : value >= -1500 && value <= 1500
}

/** 按 `step` 舍入（如 10 千卡、0.1 千卡），逢半远离零。 */
export function roundTo(value: Big | number, step: number | string): Big {
  return new Big(value).div(step).round(0, Big.roundHalfUp).times(step)
}

export function toNumber(value: Big): number {
  return Number(value.toString())
}

/** 活跃时段里还剩下的比例：7 点前为 1，23 点后为 0。 */
export function remainingActiveShare(elapsedSeconds: number): number {
  const start = ACTIVE_START_HOUR * 3600
  const end = ACTIVE_END_HOUR * 3600
  return Math.min(Math.max((end - elapsedSeconds) / (end - start), 0), 1)
}

export function energyTarget(plan: EnergyPlan, activity: DayActivity | null, day: EnergyDay): EnergyTarget {
  const baseline = new Big(activity?.dailyAverageKcal ?? plan.baselineActivityKcal)
  const measured = activity?.activeKcal ?? null
  let projected: Big
  switch (day.kind) {
    case 'future':
      projected = baseline
      break
    case 'past':
      projected = measured === null ? baseline : new Big(measured)
      break
    case 'today':
      // 一点活动数据都没有（没戴手表或没授权）时按平时活动，不当作 0。
      projected = measured === null ? baseline : new Big(measured).plus(baseline.times(remainingActiveShare(day.elapsedSeconds)))
      break
  }
  const counted = projected.lte(baseline) ? projected : baseline.plus(projected.minus(baseline).times(EXTRA_ACTIVITY_SHARE))
  const bmr = new Big(plan.bmrKcal)
  const tdee = bmr.plus(counted)
  const adjusted = plan.adjustment.type === 'fraction' ? tdee.times(plan.adjustment.value) : tdee.plus(plan.adjustment.value)
  const raised = adjusted.lt(bmr)
  const target = roundTo(raised ? bmr : adjusted, 10)
  return {
    targetKcal: toNumber(target),
    bmrKcal: plan.bmrKcal,
    baselineActivityKcal: toNumber(baseline),
    projectedActivityKcal: toNumber(projected),
    countedActivityKcal: toNumber(counted),
    tdeeKcal: toNumber(tdee),
    adjustmentKcal: toNumber(target.minus(tdee)),
    raisedToBMR: raised,
    activityEstimated: measured === null && day.kind !== 'future',
  }
}

/** 截至现在的收支：BMR 按当天已过的时间折算，加上已消耗的活动；过去的日子按全天。没有活动数据时为 null。 */
export function energyBalance(bmrKcal: number, activity: DayActivity | null, day: EnergyDay, consumedKcal: number): EnergyBalance | null {
  if (day.kind === 'future' || activity?.activeKcal == null) return null
  const share = day.kind === 'today' ? Math.min(Math.max(day.elapsedSeconds / 86_400, 0), 1) : 1
  const burned = roundTo(new Big(bmrKcal).times(share).plus(activity.activeKcal), 1)
  return { burnedKcal: toNumber(burned), consumedKcal, balanceKcal: toNumber(new Big(consumedKcal).minus(burned)) }
}
