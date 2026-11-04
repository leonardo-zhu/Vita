/**
 * 单位换算与营养计算（TDD §3.3、§4.2）。计算全程用十进制（big.js），避免 0.1 + 0.2 这类二进制误差；
 * 进出都是普通数字，存储与传输时由 JSON 原样保存。
 */
import Big from 'big.js'

import type { NutrientValues, NutritionSnapshot, Quantity, QuantityUnit } from '@vita/contract'

export class UnitNormalizationError extends Error {
  readonly code: 'unsupportedUnit' | 'nonPositiveAmount'
  constructor(code: 'unsupportedUnit' | 'nonPositiveAmount') {
    super(code)
    this.code = code
  }
}

const FACTORS: Record<string, [string, QuantityUnit]> = {
  g: ['1', 'g'], 克: ['1', 'g'], gram: ['1', 'g'], grams: ['1', 'g'],
  kg: ['1000', 'g'], 千克: ['1000', 'g'], 公斤: ['1000', 'g'],
  mg: ['0.001', 'g'], 毫克: ['0.001', 'g'],
  斤: ['500', 'g'],
  // 作为单位的"两"是 50g；"两个"里的"两"是数词，由调用方在拆出单位前处理。
  两: ['50', 'g'],
  ml: ['1', 'ml'], 毫升: ['1', 'ml'],
  l: ['1000', 'ml'], 升: ['1000', 'ml'],
}

/** 数值 + 单位写法换算为内部只用的 g / ml。"一个""一碗"这类计数单位不在这里猜。 */
export function normalizeQuantity(amount: number, unit: string): Quantity {
  if (!(amount > 0)) throw new UnitNormalizationError('nonPositiveAmount')
  const factor = FACTORS[unit.trim().toLowerCase()]
  if (!factor) throw new UnitNormalizationError('unsupportedUnit')
  return { amount: toNumber(new Big(amount).times(factor[0])), unit: factor[1] }
}

export class NutritionCalculationError extends Error {
  readonly code: 'nonPositiveQuantity' | 'invalidBasis' | 'unitMismatch'
  constructor(code: 'nonPositiveQuantity' | 'invalidBasis' | 'unitMismatch') {
    super(code)
    this.code = code
  }
}

const NUTRIENTS = ['energyKcal', 'proteinG', 'fatG', 'carbohydrateG'] as const

export const ZERO_NUTRIENTS: NutrientValues = { energyKcal: 0, proteinG: 0, fatG: 0, carbohydrateG: 0 }

/** 每项都是有限的非负数。 */
export function isValidNutrients(values: NutrientValues): boolean {
  return NUTRIENTS.every((key) => Number.isFinite(values[key]) && values[key] >= 0)
}

/** 十进制结果转回数字。营养值精度到小数点后几位，转回时不会丢失。 */
function toNumber(value: Big): number {
  return Number(value.toString())
}

export function sumNutrients(values: NutrientValues[]): NutrientValues {
  const totals = Object.fromEntries(NUTRIENTS.map((key) => [key, new Big(0)])) as Record<(typeof NUTRIENTS)[number], Big>
  for (const value of values) for (const key of NUTRIENTS) totals[key] = totals[key].plus(value[key])
  return Object.fromEntries(NUTRIENTS.map((key) => [key, toNumber(totals[key])])) as NutrientValues
}

/** 把用量换算到基准单位。只有给出密度时才在 g / ml 之间换算，不按 1ml = 1g 猜。 */
export function convertQuantity(quantity: Quantity, unit: QuantityUnit, densityGPerMl: number | null): Quantity {
  if (!(quantity.amount > 0)) throw new NutritionCalculationError('nonPositiveQuantity')
  if (quantity.unit === unit) return quantity
  if (!densityGPerMl || densityGPerMl <= 0) throw new NutritionCalculationError('unitMismatch')
  const amount = unit === 'g' ? new Big(quantity.amount).times(densityGPerMl) : new Big(quantity.amount).div(densityGPerMl)
  return { amount: toNumber(amount), unit }
}

/** 由数据源（个人食品版本或参考库）计算的快照：每基准营养 × 用量。 */
export function computedSnapshot(input: {
  source: 'personalFoodVersion' | 'referenceFood'
  sourceRef: string
  basisQuantity: Quantity
  basisNutrients: NutrientValues
  quantity: Quantity
  densityGPerMl?: number | null
}): NutritionSnapshot {
  const { basisQuantity, basisNutrients } = input
  if (!(basisQuantity.amount > 0) || !isValidNutrients(basisNutrients)) throw new NutritionCalculationError('invalidBasis')
  const used = convertQuantity(input.quantity, basisQuantity.unit, input.densityGPerMl ?? null)
  // 先乘后除，减少中间结果的截断。
  const scale = (value: number) => toNumber(new Big(value).times(used.amount).div(basisQuantity.amount))
  return {
    nutritionSource: input.source,
    sourceRef: input.sourceRef,
    basisQuantity,
    basisNutrients,
    quantityUsed: used,
    computedBy: 'client',
    estimateBasis: null,
    values: Object.fromEntries(NUTRIENTS.map((key) => [key, scale(basisNutrients[key])])) as NutrientValues,
  }
}

/** AI 估算的快照：采用模型给出的数值，必须带估算依据。 */
export function estimatedSnapshot(values: NutrientValues, estimateBasis: string, quantity: Quantity | null): NutritionSnapshot {
  return {
    nutritionSource: 'aiEstimated',
    sourceRef: null,
    basisQuantity: null,
    basisNutrients: null,
    quantityUsed: quantity,
    computedBy: 'model',
    estimateBasis,
    values,
  }
}
