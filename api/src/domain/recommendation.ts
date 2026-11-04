/**
 * 默认目标建议（TDD §6.2，移植自 1.0 的 GoalRecommendationPolicy）。系数集中在这里，不散落在 prompt 中；
 * 这是可调的默认建议，不是医疗建议。
 */
import Big from 'big.js'

import type {
  BiologicalSex,
  EnergyAdjustment,
  GoalKind,
  GoalRecommendationResponse,
  HealthSnapshot,
  MissingMetric,
} from '@vita/contract'

import { defaultAdjustment, ESTIMATED_ACTIVITY_SHARE_OF_BMR, energyTarget, roundTo, toNumber } from './energy.ts'

export const POLICY_VERSION = 2
const PROTEIN_GRAMS_PER_KG = 1.8

/** Mifflin–St Jeor：10w + 6.25h − 5a + s，男 +5、女 −161；其他取两者平均 −78。 */
export function mifflinStJeor(weightKg: number, heightCm: number, ageYears: number, sex: BiologicalSex): Big {
  const offset = sex === 'male' ? 5 : sex === 'female' ? -161 : -78
  return new Big(weightKg).times(10).plus(new Big(heightCm).times(6.25)).minus(5 * ageYears).plus(offset)
}

export function ageOn(birth: string, date: string): number {
  const [by, bm, bd] = birth.split('-').map(Number)
  const [y, m, d] = date.split('-').map(Number)
  const age = y - by - (m < bm || (m === bm && d < bd) ? 1 : 0)
  return Math.max(age, 0)
}

/** 默认按减脂（85%）生成；类型与调整可以另选。体重、身高、出生日期、性别缺一项就返回缺哪些。 */
export function recommendGoals(
  snapshot: HealthSnapshot,
  date: string,
  now: Date,
  kind: GoalKind = 'lose',
  adjustment?: EnergyAdjustment,
): GoalRecommendationResponse {
  const { bodyMassKg: weight, heightCm: height, dateOfBirth: birth, sex } = snapshot
  const missing: MissingMetric[] = []
  if (weight.status !== 'value') missing.push('bodyMass')
  if (height.status !== 'value') missing.push('height')
  if (birth.status !== 'value') missing.push('dateOfBirth')
  if (sex.status !== 'value') missing.push('sex')
  if (weight.status !== 'value' || height.status !== 'value' || birth.status !== 'value' || sex.status !== 'value') {
    return { status: 'missing', missing }
  }

  const age = ageOn(birth.value, date)
  const bmr = mifflinStJeor(weight.value, height.value, age, sex.value)
  const active = snapshot.averageActiveEnergyKcal.status === 'value' ? snapshot.averageActiveEnergyKcal.value : null
  const baseline = active === null ? bmr.times(ESTIMATED_ACTIVITY_SHARE_OF_BMR) : new Big(active)
  const plan = {
    kind,
    adjustment: adjustment ?? defaultAdjustment(kind),
    bmrKcal: toNumber(roundTo(bmr, '0.1')),
    baselineActivityKcal: toNumber(roundTo(baseline, 1)),
    baselineEstimated: active === null,
  }
  return {
    status: 'ready',
    recommendation: {
      input: {
        bodyMassKg: weight.value,
        weightSource: weight.source,
        heightCm: height.value,
        heightSource: height.source,
        ageYears: age,
        ageSource: birth.source,
        sex: sex.value,
        sexSource: sex.source,
        activeEnergyKcal: active,
      },
      bmrKcal: toNumber(roundTo(bmr, '0.1')),
      tdeeKcal: toNumber(roundTo(bmr.plus(baseline), '0.1')),
      tdeeEstimated: active === null,
      targets: {
        energyKcal: energyTarget(plan, null, { kind: 'future' }).targetKcal,
        proteinG: toNumber(roundTo(new Big(weight.value).times(PROTEIN_GRAMS_PER_KG), 1)),
        fatG: null,
        carbohydrateG: null,
      },
      energyPlan: plan,
      generatedAt: now.toISOString(),
      policyVersion: POLICY_VERSION,
    },
  }
}
