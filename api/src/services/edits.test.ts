/**
 * 用户直接编辑（M4，PRD v2.0 §4.1）：不走确认卡，但校验、revision、审计、健康同步与确认卡相同。
 */
import { describe, expect, it } from 'vitest'

import type { FoodVersionDraft } from '../domain/changes.ts'
import { makeEventTime } from '../domain/eventTime.ts'
import { DAY, estimate, lunch, ORIGIN, reference, setup, SHANGHAI } from '../test/support.ts'

const APP = { actor: 'device:test' }

function changes(database: ReturnType<typeof setup>['database']) {
  return (database.prepare("SELECT count(*) AS n FROM health_changes WHERE entity = 'record'").get() as { n: number }).n
}

function audit(database: ReturnType<typeof setup>['database'], action: string) {
  return database.prepare('SELECT actor, result, error_code FROM audit_events WHERE action = ? ORDER BY id').all(action)
}

describe('改用量', () => {
  it('按这一项自己的快照重算，revision 递增、登记健康变更、审计记下设备', () => {
    const { services, database } = setup()
    const recordId = services.records.apply({ kind: 'create', draft: lunch([reference('vita.reference.chicken-breast.cooked', 150, '鸡胸肉')]) }, DAY, 0, ORIGIN)
    const itemId = services.days.day(DAY).records[0].items[0].id
    const before = changes(database)

    services.records.rescaleItem(DAY, 1, recordId, itemId, { quantity: { amount: 200, unit: 'g' } }, APP)

    const day = services.days.day(DAY)
    const item = day.records[0].items[0]
    expect(day.revision).toBe(2)
    expect(item.snapshot.values.proteinG).toBe(62)
    expect(item.quantity).toEqual({ amount: 200, unit: 'g' })
    expect(item.originalAmountText).toBe('200 g')
    expect(item.amountSource).toBe('userStated')
    expect(changes(database)).toBe(before + 1)
    expect(audit(database, 'record.editAmount')).toEqual([{ actor: 'device:test', result: 'success', error_code: null }])
  })

  it('没有克数的估算按份数改；按克数改会被拒绝', () => {
    const { services } = setup()
    const recordId = services.records.apply({ kind: 'create', draft: lunch([estimate(600, 30)]) }, DAY, 0, ORIGIN)
    const itemId = services.days.day(DAY).records[0].items[0].id

    expect(() => services.records.rescaleItem(DAY, 1, recordId, itemId, { quantity: { amount: 300, unit: 'g' } }, APP)).toThrow('record.cannotRescale')
    services.records.rescaleItem(DAY, 1, recordId, itemId, { factor: 0.5 }, APP)

    const item = services.days.day(DAY).records[0].items[0]
    expect(item.snapshot.values).toMatchObject({ energyKcal: 300, proteinG: 15 })
    expect(item.originalAmountText).toBe('一份 ×0.5')
    expect(item.snapshot.nutritionSource).toBe('aiEstimated')
  })

  it('食品出了新版本后，旧记录改用量仍按记录时的基准', () => {
    const { services } = setup()
    const manual = (kcal: number): FoodVersionDraft => ({
      basis: { quantity: { amount: 100, unit: 'ml' }, nutrients: { energyKcal: kcal, proteinG: 3, fatG: 3, carbohydrateG: 5 } },
      sourceKind: 'manualEntry', labelScanId: null, derivedFromReferenceId: null, sourceNote: null,
    })
    const productId = services.foods.apply({ kind: 'createProduct', product: { name: '牛奶', brandOrSupplier: null, package: null, note: null }, version: manual(60) }, ORIGIN)
    const versionId = services.foods.product(productId).activeVersion!.id
    const draft = { ...estimate(0), displayName: '牛奶', originalAmountText: '250ml', quantity: { amount: 250, unit: 'ml' as const }, amountSource: 'userStated' as const,
      nutrition: { source: 'personalFoodVersion' as const, foodVersionId: versionId } }
    const recordId = services.records.apply({ kind: 'create', draft: lunch([draft]) }, DAY, 0, ORIGIN)
    services.foods.addManualVersion(productId, versionId, manual(80).basis, null, APP)

    const itemId = services.days.day(DAY).records[0].items[0].id
    services.records.rescaleItem(DAY, 1, recordId, itemId, { quantity: { amount: 500, unit: 'ml' } }, APP)
    expect(services.days.day(DAY).records[0].items[0].snapshot.values.energyKcal).toBe(300)
  })

  it('当天数据变了（revision 不对）时拒绝', () => {
    const { services } = setup()
    const recordId = services.records.apply({ kind: 'create', draft: lunch([estimate(600)]) }, DAY, 0, ORIGIN)
    const itemId = services.days.day(DAY).records[0].items[0].id
    expect(() => services.records.rescaleItem(DAY, 0, recordId, itemId, { factor: 2 }, APP)).toThrow('record.revisionConflict')
  })
})

describe('改时间、删除', () => {
  it('只能在同一天里改时间，排序时间跟着变', () => {
    const { services } = setup()
    const recordId = services.records.apply({ kind: 'create', draft: lunch([estimate(600)]) }, DAY, 0, ORIGIN)
    const dinner = makeEventTime({ localDate: DAY, precision: 'mealPeriod', mealPeriod: 'dinner', timeZone: SHANGHAI })
    services.records.updateRecord(DAY, 1, recordId, { eventTime: dinner, mealLabel: '晚餐', note: '  ' }, APP)
    const record = services.days.day(DAY).records[0]
    expect(record.eventTime.mealPeriod).toBe('dinner')
    expect(record.mealLabel).toBe('晚餐')
    expect(record.note).toBeNull()

    const nextDay = makeEventTime({ localDate: '2026-10-31', precision: 'dateOnly', timeZone: SHANGHAI })
    expect(() => services.records.updateRecord(DAY, 2, recordId, { eventTime: nextDay }, APP)).toThrow('record.eventTimeOutsideSession')
  })

  it('删最后一项要删整条记录', () => {
    const { services } = setup()
    const recordId = services.records.apply({ kind: 'create', draft: lunch([estimate(600)]) }, DAY, 0, ORIGIN)
    const itemId = services.days.day(DAY).records[0].items[0].id
    expect(() => services.records.apply({ kind: 'removeItem', recordId, itemId }, DAY, 1, APP)).toThrow('record.emptyRecord')
    services.records.apply({ kind: 'deleteRecord', recordId }, DAY, 1, APP)
    expect(services.days.day(DAY).records).toHaveLength(0)
  })
})

describe('食品库编辑', () => {
  const manual = (kcal: number): FoodVersionDraft => ({
    basis: { quantity: { amount: 100, unit: 'g' }, nutrients: { energyKcal: kcal, proteinG: 10, fatG: 5, carbohydrateG: 60 } },
    sourceKind: 'manualEntry', labelScanId: null, derivedFromReferenceId: null, sourceNote: null,
  })

  it('改名称与包装；改营养存为新版本，旧版本保留', () => {
    const { services, database } = setup()
    const id = services.foods.apply({ kind: 'createProduct', product: { name: '燕麦脆', brandOrSupplier: null, package: null, note: null }, version: manual(400) }, ORIGIN)
    const updated = services.foods.updateProduct(id, { name: ' 燕麦脆（原味） ', brandOrSupplier: '小象超市', package: { amount: 300, unit: 'g' } }, APP)
    expect(updated).toMatchObject({ name: '燕麦脆（原味）', brandOrSupplier: '小象超市', package: { amount: 300, unit: 'g' } })
    expect(() => services.foods.updateProduct(id, { name: '' }, APP)).toThrow('food.emptyName')

    const first = updated.activeVersion!.id
    const after = services.foods.addManualVersion(id, first, manual(420).basis, null, APP)
    expect(after.activeVersion!.basis.nutrients.energyKcal).toBe(420)
    expect(after.versions).toHaveLength(2)
    expect(after.versions.find((v) => v.id === first)?.retiredAt).not.toBeNull()
    expect(() => services.foods.addManualVersion(id, first, manual(430).basis, null, APP)).toThrow('food.activeVersionChanged')
    expect(audit(database, 'food.edit')).toHaveLength(2)
  })

  it('删除后不再出现在食品库，也不能再记；已有记录不变', () => {
    const { services } = setup()
    const id = services.foods.apply({ kind: 'createProduct', product: { name: '燕麦脆', brandOrSupplier: null, package: null, note: null }, version: manual(400) }, ORIGIN)
    const versionId = services.foods.product(id).activeVersion!.id
    const item = { ...estimate(0), displayName: '燕麦脆', originalAmountText: '30g', quantity: { amount: 30, unit: 'g' as const }, amountSource: 'userStated' as const,
      nutrition: { source: 'personalFoodVersion' as const, foodVersionId: versionId } }
    services.records.apply({ kind: 'create', draft: lunch([item]) }, DAY, 0, ORIGIN)

    services.foods.deleteProduct(id, APP)
    expect(services.foods.products()).toHaveLength(0)
    expect(() => services.foods.product(id)).toThrow('food.productNotFound')
    expect(services.days.day(DAY).records[0].items[0]).toMatchObject({ sourceLabel: '燕麦脆', snapshot: { values: { energyKcal: 120 } } })
    expect(() => services.records.apply({ kind: 'create', draft: lunch([item]) }, DAY, 1, ORIGIN)).toThrow('record.invalidItem')
  })
})
