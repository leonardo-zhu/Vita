/**
 * 移植自 1.0 的 BodyScaleTests（蓝牙协议部分留在 iOS）：体脂率估算、指标换算与判定、校准拟合、称重的保存与校准。
 */
import { randomUUID } from 'node:crypto'

import type { BodyMetricKind, BodyRange, HealthUpload, WeighingUpload } from '@vita/contract'
import { describe, expect, it } from 'vitest'

import { bodyMetrics, bodyType, estimateBodyFat, fitBodyFat, isUsableModel, predictBodyFat, rate, type CalibrationSample } from '../domain/body.ts'
import { NOW, ORIGIN, setup } from '../test/support.ts'

describe('体脂率估算', () => {
  it('与 AFUScale 的公式一致', () => {
    // BMI 24.08（69.6 kg / 170 cm），30 岁男性：1.2×24.08 + 6.9 − 10.8 − 5.4 + 1.5 = 21.10%。
    expect(estimateBodyFat(69.6, 170, 30, 'male')).toBe(0.211)
  })

  it('需要身高、年龄和性别', () => {
    expect(estimateBodyFat(60, null, 30, 'female')).toBeNull()
    expect(estimateBodyFat(60, 165, null, 'female')).toBeNull()
    expect(estimateBodyFat(60, 165, 30, 'other')).toBeNull()
  })
})

describe('指标换算与判定（官方样本 A：76.80 kg、体脂 21.4%、男）', () => {
  const metrics = (fat: number | null = 0.214, sex: 'male' | 'female' = 'male') =>
    Object.fromEntries(bodyMetrics(76.8, 24.8, fat, sex).map((metric) => [metric.kind, metric])) as Partial<Record<BodyMetricKind, ReturnType<typeof bodyMetrics>[number]>>

  it('换算结果在官方样本的误差范围内', () => {
    const m = metrics()
    const close = (kind: BodyMetricKind, expected: number, tolerance = 0.35) => expect(Math.abs(m[kind]!.value - expected)).toBeLessThanOrEqual(tolerance)
    close('fatMass', 16.4, 0.05)
    close('leanMass', 60.4, 0.05)
    close('boneMass', 3.3, 0.05)
    close('muscleMass', 57.1, 0.05)
    close('basalMetabolism', 1674, 1)
    close('waterMass', 44.8)
    close('skeletalMuscleMass', 33.0)
    close('proteinMass', 11.6)
    close('subcutaneousFatMass', 11.8, 0.05)
  })

  it('成年男性的判定与官方一致', () => {
    const m = metrics()
    expect(m.bodyFat?.rating).toBe('high')
    expect(m.fatMass?.rating).toBe('high')
    expect(m.muscleRate?.rating).toBe('standard')
    expect(m.muscleMass?.rating).toBe('standard')
    expect(m.waterRate?.rating).toBe('standard')
    expect(m.bmi?.rating).toBe('high')
    expect(m.basalMetabolism?.rating).toBeNull()
  })

  it('等于边界时归入较高的一段', () => {
    const range: BodyRange = { bounds: [0.1, 0.2], ratings: ['low', 'standard', 'high'] }
    expect(rate(range, 0.0999)).toBe('low')
    expect(rate(range, 0.1)).toBe('standard')
    expect(rate(range, 0.2)).toBe('high')
  })

  it('没有体脂率时只有体重和 BMI；没有对应人群区间时不判定', () => {
    expect(Object.keys(metrics(null))).toEqual(['weight', 'bmi'])
    expect(bodyMetrics(76.8, 24.8, 0.214, 'female').every((metric) => metric.rating === null)).toBe(true)
  })

  it('按 BMI 与体脂率判断体型', () => {
    expect(bodyType(24.8, 0.214, 'male')?.name).toBe('偏胖')
    expect(bodyType(26, 0.15, 'male')?.name).toBe('结实')
    expect(bodyType(22, 0.26, 'male')?.name).toBe('隐形肥胖')
    expect(bodyType(22, 0.15, 'male')?.name).toBe('标准')
    expect(bodyType(22, 0.15, 'female')).toBeNull()
  })
})

/** 假设秤按这个公式算，显示取到 0.1%。 */
function scaleFormula(weightKg: number, heightCm: number, impedance: number): number {
  const feature = ((heightCm / 100) * (heightCm / 100)) / impedance
  return Math.round((-32 * feature + 0.0035 * weightKg + 0.17) * 1000) / 1000
}

const READINGS = [
  { weight: 73.2, impedance: 560 },
  { weight: 73.9, impedance: 540 },
  { weight: 74.5, impedance: 522 },
  { weight: 75.1, impedance: 505 },
  { weight: 75.8, impedance: 498 },
  { weight: 76.4, impedance: 481 },
]

describe('校准', () => {
  const samples = (readings = READINGS): CalibrationSample[] =>
    readings.map((r) => ({ weightKg: r.weight, heightCm: 175, impedance: { a: r.impedance + 60, b: r.impedance }, observed: scaleFormula(r.weight, 175, r.impedance) }))

  it('六组读数就能还原秤的公式', () => {
    const model = fitBodyFat(samples())!
    expect(model.channel).toBe('b')
    expect(isUsableModel(model)).toBe(true)
    const predicted = predictBodyFat(model, 74.8, 175, { a: 575, b: 515 })!
    expect(Math.abs(predicted - scaleFormula(74.8, 175, 515))).toBeLessThan(0.002)
  })

  it('少于六组不拟合', () => {
    expect(fitBodyFat(samples().slice(0, 5))).toBeNull()
  })

  it('读数和公式对不上时不采用', () => {
    const noisy = samples().map((sample, index) => ({ ...sample, observed: sample.observed + (index % 2 === 0 ? 0.03 : -0.03) }))
    const model = fitBodyFat(noisy)!
    expect(isUsableModel(model)).toBe(false)
  })
})

describe('称重的保存', () => {
  const profile = (heightCm = 170): HealthUpload => ({
    bodyMassKg: { status: 'noData' },
    heightCm: { status: 'value', value: heightCm, source: 'healthKit', measuredAt: null },
    bodyFatFraction: { status: 'noData' },
    dateOfBirth: { status: 'value', value: '1990-01-01', source: 'healthKit', measuredAt: null },
    sex: { status: 'value', value: 'male', source: 'healthKit', measuredAt: null },
    sleepHours: { status: 'noData' },
    authorizationRequested: true,
    writeDenied: false,
  })

  function context(heightCm?: number) {
    const ctx = setup()
    ctx.services.health.upload(profile(heightCm), ORIGIN)
    const weigh = (overrides: Partial<WeighingUpload> = {}) =>
      ctx.services.body.record(
        { id: randomUUID(), weightKg: 69.6, impedance: { a: 482, b: 432 }, source: 'live', recordedAt: null, appleHealthWritable: true, ...overrides },
        ORIGIN,
      )
    return { ...ctx, weigh }
  }

  it('按称重当天的资料算出体脂率与指标；手机能写健康时不动手动补录', () => {
    const { services, weigh } = context()
    const weighing = weigh()
    expect(weighing.profile).toEqual({ heightCm: 170, ageYears: 36, sex: 'male' })
    expect(weighing.bodyFat).toEqual({ value: estimateBodyFat(69.6, 170, 36, 'male'), source: 'estimated' })
    expect(weighing.metrics.find((metric) => metric.kind === 'leanMass')).toBeDefined()
    expect(services.body.weighings()).toEqual([weighing])
    expect(services.health.snapshot('2026-10-30').bodyMassKg).toEqual({ status: 'noData' })
  })

  it('同一个 id 重传不会重复记录', () => {
    const { services, weigh } = context()
    const id = randomUUID()
    weigh({ id })
    weigh({ id, weightKg: 80 })
    expect(services.body.weighings()).toHaveLength(1)
    expect(services.body.weighings()[0].weightKg).toBe(69.6)
  })

  it('没测到阻抗时不给体脂率', () => {
    const weighing = context().weigh({ weightKg: 70, impedance: null })
    expect(weighing.bodyFat).toBeNull()
    expect(weighing.metrics.map((metric) => metric.kind)).toEqual(['weight', 'bmi'])
  })

  it('用离线记录的时间，除非它在将来', () => {
    const { services, weigh } = context()
    const earlier = new Date(NOW.getTime() - 3600_000).toISOString()
    const timed = weigh({ recordedAt: earlier, source: 'offline' })
    expect(timed).toMatchObject({ measuredAt: earlier, timeReliable: true })
    const future = weigh({ recordedAt: new Date(NOW.getTime() + 3600_000).toISOString(), source: 'offline' })
    expect(future).toMatchObject({ measuredAt: NOW.toISOString(), timeReliable: false })
    expect(services.body.weighings().map((w) => w.id)).toEqual([future.id, timed.id])
  })

  it('不能写健康时记为手动补录；更旧的离线记录不覆盖更新的体重', () => {
    const { services, weigh } = context()
    weigh({ appleHealthWritable: false })
    expect(services.health.snapshot('2026-10-30').bodyMassKg).toMatchObject({ value: 69.6, source: 'manual' })
    weigh({ weightKg: 72, impedance: null, appleHealthWritable: false, source: 'offline', recordedAt: new Date(NOW.getTime() - 86_400_000).toISOString() })
    expect(services.health.snapshot('2026-10-30').bodyMassKg).toMatchObject({ value: 69.6 })
    expect(services.body.weighings()).toHaveLength(2)
  })

  it('不合理的体重什么都不存', () => {
    const { services, weigh } = context()
    expect(() => weigh({ weightKg: 7.45 })).toThrow('body.invalidMetrics')
    expect(services.body.weighings()).toEqual([])
  })

  it('记下秤屏幕读数后取代估算，计入校准', () => {
    const { services, weigh } = context()
    const weighing = weigh()
    const result = services.body.setScaleReading(weighing.id, 0.214, ORIGIN)
    expect(result.weighing.bodyFat).toEqual({ value: 0.214, source: 'scaleReading' })
    expect(result.calibrationChanged).toBe(false)
    expect(services.body.calibration().readingCount).toBe(1)
  })

  it('拟合通过后，校准用到每一次称重；公式变化时告诉手机重写健康', () => {
    const { services, weigh } = context(175)
    const ids = READINGS.map((r) => weigh({ weightKg: r.weight, impedance: { a: r.impedance + 60, b: r.impedance } }).id)
    const extra = weigh({ weightKg: 74.8, impedance: { a: 575, b: 515 } })
    expect(extra.bodyFat?.source).toBe('estimated')

    const changes = READINGS.map((r, index) => services.body.setScaleReading(ids[index], scaleFormula(r.weight, 175, r.impedance), ORIGIN).calibrationChanged)
    // 第六组读数让拟合第一次可用。
    expect(changes).toEqual([false, false, false, false, false, true])
    expect(services.body.calibration().applied).toBe(true)

    const calibrated = services.body.get(extra.id)
    expect(calibrated.bodyFat?.source).toBe('calibrated')
    expect(Math.abs(calibrated.bodyFat!.value - scaleFormula(74.8, 175, 515))).toBeLessThan(0.002)
  })

  it('删除称重；没有这次称重时报错', () => {
    const { services, weigh } = context()
    const weighing = weigh()
    services.body.delete(weighing.id, ORIGIN)
    expect(services.body.weighings()).toEqual([])
    expect(() => services.body.delete(weighing.id, ORIGIN)).toThrow('body.weighingNotFound')
  })
})
