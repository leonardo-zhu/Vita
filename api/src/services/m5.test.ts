/**
 * M5（PRD v2.0 §4.2、§4.3）：食品的常用叫法与对话里改名；可选的钠、饱和脂肪、糖。
 */
import { describe, expect, it } from 'vitest'

import type { FoodVersionDraft } from '../domain/changes.ts'
import { computedSnapshot, estimatedSnapshot, missingExtras, sumNutrients } from '../domain/nutrition.ts'
import { DAY, estimate, lunch, ORIGIN, setup } from '../test/support.ts'

const milk = (extras: Record<string, number> = { sodiumMg: 60, saturatedFatG: 2.4, sugarG: 4.8 }): FoodVersionDraft => ({
  basis: { quantity: { amount: 100, unit: 'ml' }, nutrients: { energyKcal: 67, proteinG: 3.3, fatG: 3.9, carbohydrateG: 4.8, ...extras } },
  sourceKind: 'manualEntry',
  labelScanId: null,
  derivedFromReferenceId: null,
  sourceNote: null,
})

describe('扩展营养素', () => {
  it('随用量缩放；日合计只加有数据的，并数出缺的条数', () => {
    const snapshot = computedSnapshot({
      source: 'personalFoodVersion',
      sourceRef: 'v1',
      basisQuantity: { amount: 100, unit: 'ml' },
      basisNutrients: milk().basis.nutrients,
      quantity: { amount: 250, unit: 'ml' },
    })
    expect(snapshot.values).toMatchObject({ energyKcal: 167.5, sodiumMg: 150, saturatedFatG: 6, sugarG: 12 })
    const plain = { energyKcal: 100, proteinG: 1, fatG: 1, carbohydrateG: 1 }
    expect(sumNutrients([snapshot.values, plain])).toMatchObject({ energyKcal: 267.5, sodiumMg: 150 })
    expect(sumNutrients([plain]).sodiumMg).toBeUndefined()
    expect(missingExtras([snapshot.values, plain, plain])).toEqual({ sodiumMg: 2, saturatedFatG: 2, sugarG: 2 })
  })

  it('AI 估算不带扩展项', () => {
    const snapshot = estimatedSnapshot({ energyKcal: 500, proteinG: 20, fatG: 20, carbohydrateG: 50, sodiumMg: 900 }, '一碗面', null)
    expect(snapshot.values.sodiumMg).toBeUndefined()
  })

  it('记录与汇总带钠；健康变更流只在 extended 时给扩展项', () => {
    const { services } = setup()
    const productId = services.foods.apply({ kind: 'createProduct', product: { name: '牛奶', brandOrSupplier: null, package: null, note: null }, version: milk() }, ORIGIN)
    const versionId = services.foods.product(productId).activeVersion!.id
    const draft = {
      ...estimate(0),
      displayName: '牛奶',
      originalAmountText: '200ml',
      quantity: { amount: 200, unit: 'ml' as const },
      amountSource: 'userStated' as const,
      nutrition: { source: 'personalFoodVersion' as const, foodVersionId: versionId },
    }
    services.records.apply({ kind: 'create', draft: lunch([draft, estimate(300, 10)]) }, DAY, 0, ORIGIN)

    const summary = services.days.day(DAY).summary
    expect(summary.totals.sodiumMg).toBe(120)
    expect(summary.missingExtras).toEqual({ sodiumMg: 1, saturatedFatG: 1, sugarG: 1 })

    const samples = (extended: boolean) => {
      const change = services.healthSync.changes(0, 100, extended).changes[0]
      return change.entity === 'record' ? change.samples : []
    }
    expect(samples(false).map((sample) => sample.nutrient)).not.toContain('sodiumMg')
    expect(samples(true).find((sample) => sample.nutrient === 'sodiumMg')?.value).toBe(120)
  })
})

describe('常用叫法与改名', () => {
  it('新建时去掉空白、重复和与名称相同的叫法；搜索按叫法命中', () => {
    const { services } = setup()
    const id = services.foods.apply(
      { kind: 'createProduct', product: { name: '鲜牛奶', brandOrSupplier: '小象超市', package: null, note: null, aliases: [' 小象牛奶 ', '小象牛奶', '鲜牛奶', ''] }, version: milk({}) },
      ORIGIN,
    )
    expect(services.foods.product(id).aliases).toEqual(['小象牛奶'])
    expect(services.foods.search('小象牛奶').map((product) => product.id)).toEqual([id])
  })

  it('对话里改名、加叫法经确认卡；营养值不变，没有改动时拒绝', () => {
    const { services } = setup()
    const id = services.foods.apply({ kind: 'createProduct', product: { name: '巧克力蛋糕', brandOrSupplier: null, package: null, note: null }, version: milk({}) }, ORIGIN)
    const versionId = services.foods.product(id).activeVersion!.id

    const pending = services.pending.proposeFood(
      { kind: 'updateProduct', productId: id, name: '小象巧克力蛋糕', brandOrSupplier: undefined, aliases: ['巧克力蛋糕'] },
      DAY,
      { actor: 'agent', requestId: 'r1', afterConfirm: null },
    )
    expect(pending.preview).toMatchObject({
      type: 'food',
      food: { kind: 'updateProduct', productName: '小象巧克力蛋糕', aliases: ['巧克力蛋糕'], previous: { name: '巧克力蛋糕', aliases: [] } },
    })
    services.pending.confirm(pending.id, ORIGIN)

    const product = services.foods.product(id)
    expect(product).toMatchObject({ name: '小象巧克力蛋糕', aliases: ['巧克力蛋糕'] })
    expect(product.activeVersion!.id).toBe(versionId)
    expect(() => services.foods.preview({ kind: 'updateProduct', productId: id, name: null, brandOrSupplier: undefined, aliases: null })).toThrow('food.nothingToChange')
  })

  it('改名卡也能补上包装规格（“一袋是 288 g”）', () => {
    const { services } = setup()
    const id = services.foods.apply({ kind: 'createProduct', product: { name: '小笼汤包', brandOrSupplier: null, package: null, note: null }, version: milk({}) }, ORIGIN)
    const preview = services.foods.preview({ kind: 'updateProduct', productId: id, name: null, brandOrSupplier: undefined, aliases: null, package: { amount: 288, unit: 'g' } })
    expect(preview).toMatchObject({ kind: 'updateProduct', package: { amount: 288, unit: 'g' }, previous: { package: null } })
    services.foods.apply({ kind: 'updateProduct', productId: id, name: null, brandOrSupplier: undefined, aliases: null, package: { amount: 288, unit: 'g' } }, ORIGIN)
    expect(services.foods.product(id).package).toEqual({ amount: 288, unit: 'g' })
  })

  it('App 里直接改叫法', () => {
    const { services } = setup()
    const id = services.foods.apply({ kind: 'createProduct', product: { name: '燕麦奶', brandOrSupplier: null, package: null, note: null }, version: milk({}) }, ORIGIN)
    expect(services.foods.updateProduct(id, { aliases: ['OATLY', 'oatly', '咖啡大师'] }, ORIGIN).aliases).toEqual(['OATLY', '咖啡大师'])
  })
})
