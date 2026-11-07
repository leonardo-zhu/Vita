/**
 * 移植自 1.0 的 EnergyTargetTests、HealthTests（目标建议、手动补录、目标历史）与 GoalServiceTests。
 * 例子同设计讨论：BMR 1700、平时活动 500、减脂 85%。
 */
import { randomUUID } from 'node:crypto'

import type { EnergyPlan, HealthSnapshot, HealthUpload } from '@vita/contract'
import { describe, expect, it } from 'vitest'

import { energyBalance, energyTarget, type EnergyDay } from '../domain/energy.ts'
import { ageOn, recommendGoals } from '../domain/recommendation.ts'
import { addDays } from '../domain/time.ts'
import { DAY, NOW, ORIGIN, setup } from '../test/support.ts'
import { NO_TARGETS } from './goals.ts'

const plan: EnergyPlan = { kind: 'lose', adjustment: { type: 'fraction', value: 0.85 }, bmrKcal: 1700, baselineActivityKcal: 500, baselineEstimated: false }
const hours = (h: number): EnergyDay => ({ kind: 'today', elapsedSeconds: h * 3600 })

describe('能量目标随活动计算', () => {
  it('早上按平时活动', () => {
    const target = energyTarget(plan, { activeKcal: 0, dailyAverageKcal: 500 }, hours(7))
    expect(target).toMatchObject({ projectedActivityKcal: 500, tdeeKcal: 2200, targetKcal: 1870, adjustmentKcal: -330 })
  })

  it('超出平时的活动只计一半', () => {
    // 18 点已消耗 1000，剩余时段还有 500 × 5/16：预估 1156.25，超出平时 656.25，计入一半。
    const target = energyTarget(plan, { activeKcal: 1000, dailyAverageKcal: 500 }, hours(18))
    expect(target).toMatchObject({ projectedActivityKcal: 1156.25, countedActivityKcal: 828.125, targetKcal: 2150 })
  })

  it('活动少的日子目标降低，但不低于 BMR', () => {
    const quiet = energyTarget(plan, { activeKcal: 400, dailyAverageKcal: 500 }, { kind: 'past' })
    expect(quiet).toMatchObject({ countedActivityKcal: 400, targetKcal: 1790, raisedToBMR: false })
    const still = energyTarget(plan, { activeKcal: 100, dailyAverageKcal: 500 }, { kind: 'past' })
    expect(still).toMatchObject({ targetKcal: 1700, raisedToBMR: true })
    const steep = energyTarget({ ...plan, adjustment: { type: 'kcal', value: -1000 } }, { activeKcal: 0, dailyAverageKcal: 500 }, { kind: 'past' })
    expect(steep).toMatchObject({ targetKcal: 1700, raisedToBMR: true })
  })

  it('按千卡调整；没有活动数据时按平时活动并标为估算', () => {
    const byKcal = { ...plan, adjustment: { type: 'kcal' as const, value: -400 } }
    expect(energyTarget(byKcal, null, hours(23))).toMatchObject({ projectedActivityKcal: 500, targetKcal: 1800, activityEstimated: true })
    expect(energyTarget(byKcal, null, { kind: 'future' })).toMatchObject({ targetKcal: 1800, activityEstimated: false })
  })

  it('收支按当天已过的时间折算 BMR', () => {
    expect(energyBalance(1700, { activeKcal: 300, dailyAverageKcal: null }, hours(12), 900)).toEqual({ burnedKcal: 1150, consumedKcal: 900, balanceKcal: -250 })
    expect(energyBalance(1700, null, { kind: 'past' }, 900)).toBeNull()
  })
})

describe('目标建议', () => {
  const value = <T>(v: T, source: 'healthKit' | 'manual' = 'healthKit') => ({ status: 'value' as const, value: v, source, measuredAt: null })
  const snapshot = (weight: number | null = 70, active: number | null = null): HealthSnapshot => ({
    bodyMassKg: weight === null ? { status: 'noData' } : value(weight),
    heightCm: value(175),
    bodyFatFraction: { status: 'noData' },
    dateOfBirth: value('1996-05-20', 'manual'),
    sex: value('male' as const),
    sleepHours: { status: 'noData' },
    activeEnergyKcal: { status: 'noData' },
    averageActiveEnergyKcal: active === null ? { status: 'noData' } : value(active),
    authorizationRequested: true,
    writeDenied: false,
    uploadedAt: null,
  })

  it('Mifflin–St Jeor 加轻度活动系数', () => {
    // 30 岁男性，70kg、175cm：BMR = 700 + 1093.75 − 150 + 5 = 1648.75。
    const result = recommendGoals(snapshot(), DAY, NOW)
    if (result.status !== 'ready') throw new Error('expected recommendation')
    const { recommendation } = result
    expect(recommendation.input.ageYears).toBe(30)
    expect(recommendation.bmrKcal).toBe(1648.8)
    expect(recommendation.tdeeEstimated).toBe(true)
    // 平时消耗 = 1648.75 × 1.375 = 2267.03；默认减脂 85% ≈ 1930，蛋白 1.8 × 70 = 126。
    expect(recommendation.targets).toEqual({ energyKcal: 1930, proteinG: 126, fatG: null, carbohydrateG: null })
    expect(recommendation.energyPlan).toMatchObject({ kind: 'lose', adjustment: { type: 'fraction', value: 0.85 }, baselineEstimated: true })
    expect(recommendation.input.ageSource).toBe('manual')
  })

  it('有活动数据时取代估算', () => {
    const result = recommendGoals(snapshot(70, 500), DAY, NOW)
    if (result.status !== 'ready') throw new Error('expected recommendation')
    expect(result.recommendation).toMatchObject({ tdeeEstimated: false, tdeeKcal: 2148.8, targets: { energyKcal: 1830 }, energyPlan: { baselineActivityKcal: 500 } })
  })

  it('体重是硬门槛', () => {
    expect(recommendGoals(snapshot(null), DAY, NOW)).toEqual({ status: 'missing', missing: ['bodyMass'] })
  })

  it('年龄按生日算', () => {
    expect(ageOn('1996-10-31', '2026-10-30')).toBe(29)
    expect(ageOn('1996-10-31', '2026-10-31')).toBe(30)
  })
})

describe('目标历史', () => {
  it('只追加，按日期生效；同一天再改时 revision 更高者生效', () => {
    const { services } = setup()
    const { goals } = services
    goals.append({ ...NO_TARGETS, proteinG: 150 }, null, 'initialRecommendation', '2026-10-01', ORIGIN)
    const { previous, current } = goals.append({ ...NO_TARGETS, proteinG: 180 }, null, 'explicitUserCommand', '2026-10-20', ORIGIN)
    expect(previous?.targets.proteinG).toBe(150)
    expect(current).toMatchObject({ targets: { proteinG: 180 }, revision: 2 })
    expect(goals.active('2026-09-30')).toBeNull()
    expect(goals.active('2026-10-19')?.targets.proteinG).toBe(150)
    expect(goals.active(DAY)?.targets.proteinG).toBe(180)

    goals.append({ ...NO_TARGETS, proteinG: 150 }, null, 'explicitUserCommand', '2026-10-20', ORIGIN)
    expect(goals.active(DAY)).toMatchObject({ revision: 3, targets: { proteinG: 150 } })
  })

  it('拒绝空的或非正的目标', () => {
    const { services } = setup()
    expect(() => services.goals.append(NO_TARGETS, null, 'manualOnboarding', DAY, ORIGIN)).toThrow('goal.invalidTargets')
    expect(() => services.goals.append({ ...NO_TARGETS, proteinG: 0 }, null, 'manualOnboarding', DAY, ORIGIN)).toThrow('goal.invalidTargets')
  })

  it('确认建议后生成；只改给出的项，旧值与新值都返回', () => {
    const { services } = setup()
    const result = recommendGoals(
      {
        bodyMassKg: { status: 'value', value: 70, source: 'manual', measuredAt: null },
        heightCm: { status: 'value', value: 175, source: 'manual', measuredAt: null },
        dateOfBirth: { status: 'value', value: '1996-05-20', source: 'manual', measuredAt: null },
        sex: { status: 'value', value: 'male', source: 'manual', measuredAt: null },
        bodyFatFraction: { status: 'noData' },
        sleepHours: { status: 'noData' },
        activeEnergyKcal: { status: 'noData' },
        averageActiveEnergyKcal: { status: 'noData' },
        authorizationRequested: false,
        writeDenied: false,
        uploadedAt: null,
      },
      DAY,
      NOW,
    )
    if (result.status !== 'ready') throw new Error('expected recommendation')
    const first = services.goals.commitInitial(result.recommendation, DAY, ORIGIN)
    expect(first.origin).toBe('initialRecommendation')

    // "把蛋白质目标改成 150g"：只改蛋白，能量与规则沿用。
    const { previous, current } = services.goals.update({ proteinG: 150 }, null, DAY, ORIGIN)
    expect(previous?.targets.proteinG).toBe(126)
    expect(current.targets).toMatchObject({ proteinG: 150, energyKcal: 1930 })
    expect(current.energyPlan).toEqual(first.energyPlan)
    expect(current.origin).toBe('explicitUserCommand')
    services.goals.update({ proteinG: 126 }, null, DAY, ORIGIN)
    expect(services.goals.active(DAY)?.revision).toBe(3)
  })

  it('在固定与随活动计算之间切换', () => {
    const { services } = setup()
    services.goals.append({ ...NO_TARGETS, energyKcal: 1870, proteinG: 120 }, plan, 'initialRecommendation', DAY, ORIGIN)
    // "热量目标改成 2000"：固定。
    expect(services.goals.update({ energyKcal: 2000 }, null, DAY, ORIGIN).current).toMatchObject({ energyPlan: null, targets: { energyKcal: 2000 } })
    expect(services.days.day(DAY).summary.goal?.targets.energyKcal).toBe(2000)
    // "缺口改成 500 千卡"：恢复随活动计算，沿用上次的 BMR 与平时活动。
    const auto = services.goals.update({}, { adjustment: { type: 'kcal', value: -500 } }, DAY, ORIGIN).current
    expect(auto.energyPlan).toMatchObject({ adjustment: { type: 'kcal', value: -500 }, bmrKcal: 1700 })
    // "改成增肌"：用这个类型的默认调整。
    expect(services.goals.update({}, { kind: 'gain' }, DAY, ORIGIN).current.energyPlan?.adjustment).toEqual({ type: 'fraction', value: 1.1 })
  })

  it('从没自动设定过时不能改回随活动计算', () => {
    const { services } = setup()
    services.goals.append({ ...NO_TARGETS, energyKcal: 2040, proteinG: 126 }, null, 'initialRecommendation', DAY, ORIGIN)
    const summary = services.days.day(DAY).summary
    expect(summary.goal?.targets.energyKcal).toBe(2040)
    expect(summary.energy).toBeNull()
    expect(() => services.goals.update({}, {}, DAY, ORIGIN)).toThrow('goal.noEnergyPlan')
  })
})

describe('健康数据与每日能量目标', () => {
  const upload: HealthUpload = {
    bodyMassKg: { status: 'value', value: 72, source: 'healthKit', measuredAt: null },
    heightCm: { status: 'noData' },
    bodyFatFraction: { status: 'noData' },
    dateOfBirth: { status: 'noData' },
    sex: { status: 'failed', message: 'denied' },
    sleepHours: { status: 'value', value: 7.5, source: 'healthKit', measuredAt: null },
    authorizationRequested: true,
    writeDenied: false,
  }

  it('手动补录补上缺的项，Apple 健康有的以它为准；补录只覆盖给出的项', () => {
    const { services } = setup()
    services.health.upload(upload, ORIGIN)
    services.health.submitManualMetrics({ bodyMassKg: 80, heightCm: 170, sex: 'female' }, ORIGIN)
    const snapshot = services.health.snapshot(DAY)
    expect(snapshot.bodyMassKg).toMatchObject({ value: 72, source: 'healthKit' })
    expect(snapshot.heightCm).toMatchObject({ value: 170, source: 'manual' })
    expect(snapshot.sex).toMatchObject({ value: 'female', source: 'manual' })
    expect(snapshot.dateOfBirth).toEqual({ status: 'noData' })
    expect(snapshot.uploadedAt).toBe(NOW.toISOString())

    expect(services.health.submitManualMetrics({ dateOfBirth: '1990-01-01' }, ORIGIN)).toMatchObject({ heightCm: 170, dateOfBirth: '1990-01-01' })
  })

  it('7 日日均只算有数据的天，不足 3 天没有', () => {
    const { services } = setup()
    services.health.uploadActivity({ days: [1, 2].map((n) => ({ date: addDays(DAY, -n), activeKcal: 500 })) }, ORIGIN)
    expect(services.health.activity(DAY)).toEqual({ activeKcal: null, dailyAverageKcal: null })
    services.health.uploadActivity(
      { days: [{ date: addDays(DAY, -3), activeKcal: 800 }, { date: addDays(DAY, -4), activeKcal: 0 }, { date: addDays(DAY, -8), activeKcal: 9999 }, { date: DAY, activeKcal: 300 }] },
      ORIGIN,
    )
    expect(services.health.activity(DAY)).toEqual({ activeKcal: 300, dailyAverageKcal: 600 })
  })

  it('每日数据按上传的活动算能量目标与收支；没上传前用设定时的平时活动', () => {
    const { services } = setup()
    services.goals.append({ ...NO_TARGETS, energyKcal: 1870, proteinG: 120 }, { ...plan, baselineActivityKcal: 400 }, 'initialRecommendation', DAY, ORIGIN)
    expect(services.days.day(DAY).summary.energy?.baselineActivityKcal).toBe(400)

    // 前 7 天每天 500，今天到现在（20:00）800。
    services.health.uploadActivity({ days: [...[1, 2, 3, 4, 5, 6, 7].map((n) => ({ date: addDays(DAY, -n), activeKcal: 500 })), { date: DAY, activeKcal: 800 }] }, ORIGIN)
    const { summary } = services.days.day(DAY)
    expect(summary.energy?.baselineActivityKcal).toBe(500)
    expect(summary.goal?.targets.energyKcal).toBe(summary.energy?.targetKcal)
    expect(summary.goal?.targets.proteinG).toBe(120)
    expect(summary.balance).not.toBeNull()
  })
})

describe('BMR 按每天的身体数据重算', () => {
  // 30 岁男性、175 cm：70 kg 时 1648.75，68 kg 时 1628.75。目标设定时存的是 1700。
  function context(withProfile = true) {
    const ctx = setup()
    const { services } = ctx
    if (withProfile) services.health.submitManualMetrics({ heightCm: 175, dateOfBirth: '1996-05-20', sex: 'male' }, ORIGIN)
    services.goals.append({ ...NO_TARGETS, energyKcal: 1900, proteinG: 120 }, plan, 'initialRecommendation', addDays(DAY, -5), ORIGIN)
    return ctx
  }
  const bmr = (services: ReturnType<typeof setup>['services'], date: string) => services.days.day(date).summary.energy?.bmrKcal

  it('用这一天结束前最新的称重，体重变了目标跟着变；过去的日子不被后来的称重改掉', () => {
    const { services } = context()
    services.body.record({ id: randomUUID(), weightKg: 70, impedance: null, source: 'offline', recordedAt: '2026-10-28T01:00:00.000Z', appleHealthWritable: true }, ORIGIN)
    services.body.record({ id: randomUUID(), weightKg: 68, impedance: null, source: 'live', recordedAt: null, appleHealthWritable: true }, ORIGIN)
    expect(bmr(services, DAY)).toBe(1628.8)
    expect(bmr(services, addDays(DAY, -1))).toBe(1648.8)
    expect(bmr(services, addDays(DAY, -2))).toBe(1648.8)
    // 那之前没有称重：用设定目标时存的
    expect(bmr(services, addDays(DAY, -3))).toBe(1700)
    // 能量目标与收支都用重算的 BMR
    const { summary } = services.days.day(DAY)
    expect(summary.energy?.tdeeKcal).toBe(1628.8 + (summary.energy?.countedActivityKcal ?? 0))
  })

  it('缺身高、出生日期或性别时用设定目标时存的', () => {
    const { services } = context(false)
    services.body.record({ id: randomUUID(), weightKg: 68, impedance: null, source: 'live', recordedAt: null, appleHealthWritable: true }, ORIGIN)
    expect(bmr(services, DAY)).toBe(1700)
  })
})

describe('基础代谢变化的记录', () => {
  function context() {
    const ctx = setup()
    ctx.services.health.submitManualMetrics({ heightCm: 175, dateOfBirth: '1996-05-20', sex: 'male' }, ORIGIN)
    return ctx
  }
  const weigh = (services: ReturnType<typeof setup>['services'], kg: number) =>
    services.body.record({ id: randomUUID(), weightKg: kg, impedance: null, source: 'live', recordedAt: null, appleHealthWritable: true }, ORIGIN)

  it('固定目标时不记；随活动计算时称重让 BMR 变了才记一条，Data 页能看到这一天的变化', () => {
    const { services, clock } = context()
    weigh(services, 70)
    expect(services.bmrLog.list()).toHaveLength(0)

    // 设定目标时存的是 1700，按 70 kg 算是 1648.8：记一条，原因是设定目标
    services.goals.append({ ...NO_TARGETS, energyKcal: 1900 }, plan, 'initialRecommendation', DAY, ORIGIN)
    expect(services.bmrLog.list()).toMatchObject([{ previousBmrKcal: 1700, bmrKcal: 1648.8, reason: 'goal', weightKg: 70 }])

    // 同样的体重再称一次：不变，不记
    clock.advance(30)
    weigh(services, 70)
    expect(services.bmrLog.list()).toHaveLength(1)

    clock.advance(30)
    weigh(services, 68)
    const [latest] = services.bmrLog.list()
    expect(latest).toMatchObject({ date: DAY, previousBmrKcal: 1648.8, bmrKcal: 1628.8, reason: 'weighing', weightKg: 68, heightCm: 175, ageYears: 30, sex: 'male' })
    expect(services.days.day(DAY).summary.bmrChange).toEqual(latest)
    expect(services.days.day(addDays(DAY, 1)).summary.bmrChange).toBeNull()
  })

  it('目标历史带创建时间与发起方', () => {
    const { services } = context()
    services.goals.append({ ...NO_TARGETS, energyKcal: 1900 }, null, 'manualOnboarding', DAY, { actor: 'device:abc' })
    services.goals.append({ ...NO_TARGETS, energyKcal: 2000 }, null, 'explicitUserCommand', DAY, { actor: 'admin' })
    expect(services.goals.history().map((entry) => [entry.goal.targets.energyKcal, entry.actor])).toEqual([
      [2000, 'admin'],
      [1900, 'device:abc'],
    ])
    expect(services.goals.history()[0].createdAt).toBe(NOW.toISOString())
  })
})
