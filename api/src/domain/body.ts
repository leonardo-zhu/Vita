/**
 * 身体成分的算法（身体成分模块 §4，移植自 1.0 的 BodyComposition、BodyFatEstimate、BodyFatCalibration）。
 * 秤只回传体重与阻抗：体脂率是核心估算，其余由体重、体脂率换算；换算关系与比例系数用蚂蚁阿福「身材管理」
 * 的两组样本核对过（误差约 ±0.3 kg）。这些都是估算，不是医疗诊断。
 */
import Big from 'big.js'

import type { BiologicalSex, BodyFatModel, BodyMetric, BodyMetricKind, BodyRange, BodyRating, Impedance } from '@vita/contract'

/** 合理的体脂率范围；超出多半是身高等资料有误，不采用。 */
const PLAUSIBLE_FAT = [0.02, 0.7] as const

function plausibleFat(value: number): boolean {
  return value >= PLAUSIBLE_FAT[0] && value <= PLAUSIBLE_FAT[1]
}

/**
 * 体脂率估算：Deurenberg 公式（由 BMI、年龄、性别推算）加秤的校正值 1.5，与 AFUScale 一致。
 * 0–1，取三位小数。缺身高、年龄或性别（含"其他"）时为 null。
 */
export function estimateBodyFat(weightKg: number, heightCm: number | null, ageYears: number | null, sex: BiologicalSex | null): number | null {
  if (!heightCm || heightCm <= 0 || ageYears === null || !sex || sex === 'other') return null
  const meters = new Big(heightCm).div(100)
  const bmi = new Big(weightKg).div(meters.times(meters))
  const percent = bmi.times('1.2').plus(new Big('0.23').times(ageYears)).minus(sex === 'male' ? '10.8' : 0).minus('5.4').plus('1.5')
  const fraction = Number(percent.div(100).round(3, Big.roundHalfUp).toString())
  return plausibleFat(fraction) ? fraction : null
}

export function bmiOf(weightKg: number, heightCm: number | null): number | null {
  if (!heightCm || heightCm <= 0) return null
  const meters = heightCm / 100
  return weightKg / (meters * meters)
}

export function rate(range: BodyRange, value: number): BodyRating {
  const index = range.bounds.findIndex((bound) => value < bound)
  return range.ratings[index === -1 ? range.bounds.length : index]
}

function scaled(range: BodyRange, factor: number): BodyRange {
  return { bounds: range.bounds.map((bound) => bound * factor), ratings: range.ratings }
}

/** 去脂体重中各成分的比例，取官方两组样本的平均。官方的具体公式拿不到，这些是近似。 */
const RATIOS = { boneOfLean: 0.0546, waterOfLean: 0.737, proteinOfLean: 0.1975, skeletalOfMuscle: 0.573, subcutaneousOfFat: 0.718 }

const MALE_BODY_FAT: BodyRange = { bounds: [0.1, 0.2, 0.25], ratings: ['low', 'standard', 'high', 'veryHigh'] }
const MALE_BMI: BodyRange = { bounds: [18.5, 24, 28], ratings: ['low', 'standard', 'high', 'veryHigh'] }

/** 成年男性的判定区间，取自官方「身材管理」；BMI 用中国成人标准。 */
function maleRanges(weight: number): Partial<Record<BodyMetricKind, BodyRange>> {
  const muscleRate: BodyRange = { bounds: [0.604, 0.754], ratings: ['low', 'standard', 'excellent'] }
  const waterRate: BodyRange = { bounds: [0.475, 0.592], ratings: ['low', 'standard', 'high'] }
  return {
    bmi: MALE_BMI,
    bodyFat: MALE_BODY_FAT,
    fatMass: scaled(MALE_BODY_FAT, weight),
    muscleRate,
    muscleMass: scaled(muscleRate, weight),
    waterRate,
    waterMass: scaled(waterRate, weight),
    boneMass: { bounds: [3.3, 4.2], ratings: ['low', 'standard', 'high'] },
  }
}

const METRIC_ORDER: BodyMetricKind[] = [
  'weight', 'bmi', 'bodyFat', 'leanMass', 'basalMetabolism',
  'fatMass', 'subcutaneousFatRate', 'subcutaneousFatMass',
  'muscleMass', 'muscleRate', 'skeletalMuscleMass', 'skeletalMuscleRate', 'waterRate', 'waterMass', 'proteinMass', 'proteinRate', 'boneMass',
]

/** 一次称重的全部指标。没有体脂率（没测到阻抗或缺资料）时只有体重和 BMI。 */
export function bodyMetrics(weight: number, bmi: number | null, bodyFat: number | null, sex: BiologicalSex | null): BodyMetric[] {
  const ranges = sex === 'male' ? maleRanges(weight) : {}
  const values: Partial<Record<BodyMetricKind, number>> = { weight }
  if (bmi !== null) values.bmi = bmi
  if (bodyFat !== null) {
    const fatMass = weight * bodyFat
    const lean = weight - fatMass
    const bone = lean * RATIOS.boneOfLean
    const muscle = lean - bone
    const water = lean * RATIOS.waterOfLean
    const protein = lean * RATIOS.proteinOfLean
    const skeletal = muscle * RATIOS.skeletalOfMuscle
    const subcutaneous = fatMass * RATIOS.subcutaneousOfFat
    Object.assign(values, {
      bodyFat,
      leanMass: lean,
      basalMetabolism: 370 + 21.6 * lean,
      fatMass,
      subcutaneousFatMass: subcutaneous,
      subcutaneousFatRate: subcutaneous / weight,
      muscleMass: muscle,
      muscleRate: muscle / weight,
      skeletalMuscleMass: skeletal,
      skeletalMuscleRate: skeletal / weight,
      waterMass: water,
      waterRate: water / weight,
      proteinMass: protein,
      proteinRate: protein / weight,
      boneMass: bone,
    })
  }
  return METRIC_ORDER.flatMap((kind) => {
    const value = values[kind]
    if (value === undefined) return []
    const range = ranges[kind] ?? null
    return [{ kind, value, range, rating: range ? rate(range, value) : null }]
  })
}

const BODY_TYPES: [string, string][][] = [
  [['偏瘦', '体重和脂肪都偏少。'], ['偏瘦肌肉型', '体脂低，体重正常，肌肉比例较高。'], ['肌肉型', 'BMI 偏高但体脂低，多出的是肌肉。']],
  [['偏瘦', '体脂正常，但体重偏轻。'], ['标准', '体重和体脂都在标准范围。'], ['结实', 'BMI 偏高但体脂正常，肌肉较多。']],
  [['隐形肥胖', '体重偏轻，但脂肪比例偏高，肌肉偏少。'], ['脂肪偏多', 'BMI 正常，但脂肪比例略高。'], ['偏胖', 'BMI 和体脂都略高。']],
  [['隐形肥胖', '体重不重，但脂肪比例过高。'], ['隐形肥胖', 'BMI 正常，但脂肪比例过高。'], ['肥胖', 'BMI 和体脂都过高。']],
]

/** 体型：BMI 与体脂率的九宫格。不带来新信息，只是便于理解；只有已知区间的人群（成年男性）给出。 */
export function bodyType(bmi: number | null, bodyFat: number | null, sex: BiologicalSex | null): { name: string; explanation: string } | null {
  if (sex !== 'male' || bmi === null || bodyFat === null) return null
  const band = (range: BodyRange, value: number) => {
    const index = range.bounds.findIndex((bound) => value < bound)
    return index === -1 ? range.bounds.length : index
  }
  // 列：BMI 偏低 / 标准 / 偏高及以上；行：体脂偏低 / 标准 / 偏高 / 过高。
  const [name, explanation] = BODY_TYPES[band(MALE_BODY_FAT, bodyFat)][Math.min(band(MALE_BMI, bmi), 2)]
  return { name, explanation }
}

// MARK: - 校准（身体成分模块 §4.2）

/**
 * 用用户记下的"秤屏幕上的体脂率"反推秤的公式。目的不是更准，而是和秤显示同一个数：
 * 秤按体重、阻抗、身高用固定公式算，几组读数就能把系数拟合出来。
 * 形式取 BIA 秤的通用式：体脂率 = a · 身高² / 阻抗 + b · 体重 + c；年龄、性别对单一用户短期不变，并进常数。
 */
export const MINIMUM_CALIBRATION_SAMPLES = 6
/** 交叉验证误差超过 1% 说明形式不对或读数记错了，不采用。 */
const MAXIMUM_CALIBRATION_ERROR = 0.01

export interface CalibrationSample {
  weightKg: number
  heightCm: number
  impedance: Impedance
  /** 秤屏幕上显示的体脂率，0–1。 */
  observed: number
}

export function isUsableModel(model: BodyFatModel): boolean {
  return model.meanAbsoluteError <= MAXIMUM_CALIBRATION_ERROR
}

function feature(heightCm: number, impedance: Impedance | null, channel: 'a' | 'b'): number | null {
  if (!impedance) return null
  const ohms = impedance[channel]
  if (!(ohms > 0)) return null
  const meters = heightCm / 100
  return (meters * meters) / ohms
}

/** 缺身高或阻抗、结果超出合理范围时为 null。取三位小数。 */
export function predictBodyFat(model: BodyFatModel, weightKg: number, heightCm: number | null, impedance: Impedance | null): number | null {
  const x = heightCm ? feature(heightCm, impedance, model.channel) : null
  if (x === null) return null
  const value = model.heightSquaredOverImpedance * x + model.weight * weightKg + model.constant
  if (!plausibleFat(value)) return null
  return Number(new Big(value).round(3, Big.roundHalfUp).toString())
}

/** 两路阻抗各拟合一次，取交叉验证误差小的那一路。样本不够、体重几乎没变化（系数分不开）时为 null。 */
export function fitBodyFat(samples: CalibrationSample[]): BodyFatModel | null {
  if (samples.length < MINIMUM_CALIBRATION_SAMPLES) return null
  const models = (['a', 'b'] as const).map((channel) => fitChannel(samples, channel)).filter((model) => model !== null)
  return models.reduce<BodyFatModel | null>((best, model) => (!best || model.meanAbsoluteError < best.meanAbsoluteError ? model : best), null)
}

type Row = { x: [number, number, number]; y: number }

function fitChannel(samples: CalibrationSample[], channel: 'a' | 'b'): BodyFatModel | null {
  const rows: Row[] = samples.flatMap((sample) => {
    const x = feature(sample.heightCm, sample.impedance, channel)
    return x === null ? [] : [{ x: [x, sample.weightKg, 1] as [number, number, number], y: sample.observed }]
  })
  if (rows.length < MINIMUM_CALIBRATION_SAMPLES) return null
  const coefficients = leastSquares(rows)
  if (!coefficients) return null
  // 留一法：每次拿掉一组拟合，再预测拿掉的那组。
  const errors: number[] = []
  for (let index = 0; index < rows.length; index++) {
    const partial = leastSquares(rows.filter((_, i) => i !== index))
    if (!partial) return null
    const held = rows[index]
    errors.push(Math.abs(partial[0] * held.x[0] + partial[1] * held.x[1] + partial[2] * held.x[2] - held.y))
  }
  return {
    channel,
    heightSquaredOverImpedance: coefficients[0],
    weight: coefficients[1],
    constant: coefficients[2],
    sampleCount: rows.length,
    meanAbsoluteError: errors.reduce((sum, error) => sum + error, 0) / errors.length,
  }
}

/** 解正规方程 (XᵀX)β = Xᵀy（3×3，高斯消元）。矩阵接近奇异（某个特征几乎不变）时为 null。 */
function leastSquares(rows: Row[]): [number, number, number] | null {
  const n = 3
  const m = Array.from({ length: n }, () => new Array<number>(n + 1).fill(0))
  for (const row of rows) {
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) m[i][j] += row.x[i] * row.x[j]
      m[i][n] += row.x[i] * row.y
    }
  }
  const scale = Math.max(...m.map((line) => Math.max(...line.slice(0, n).map(Math.abs))))
  for (let column = 0; column < n; column++) {
    let pivot = column
    for (let row = column + 1; row < n; row++) if (Math.abs(m[row][column]) > Math.abs(m[pivot][column])) pivot = row
    if (!(Math.abs(m[pivot][column]) > scale * 1e-12)) return null
    ;[m[column], m[pivot]] = [m[pivot], m[column]]
    for (let row = 0; row < n; row++) {
      if (row === column) continue
      const factor = m[row][column] / m[column][column]
      for (let k = column; k <= n; k++) m[row][k] -= factor * m[column][k]
    }
  }
  return [m[0][n] / m[0][0], m[1][n] / m[1][1], m[2][n] / m[2][2]]
}
