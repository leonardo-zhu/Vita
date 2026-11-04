/**
 * 移植自 1.0 的 RecordServiceTests（目标进度部分随目标模块移植）。
 */
import { describe, expect, it } from 'vitest'

import type { ItemDraft, RecordDraft } from '../domain/changes.ts'
import { makeEventTime } from '../domain/eventTime.ts'
import { DAY, estimate, lunch, ORIGIN, reference, setup, SHANGHAI } from '../test/support.ts'
import type { FoodVersionDraft } from '../domain/changes.ts'

function audits(database: ReturnType<typeof setup>['database'], action: string) {
  return database.prepare('SELECT result, error_code FROM audit_events WHERE action = ? ORDER BY id').all(action) as {
    result: string
    error_code: string | null
  }[]
}

describe('记录的创建、修改、删除', () => {
  it('汇总随之更新，revision 每次递增', () => {
    const { services, database } = setup()
    const { records, days } = services
    const recordId = records.apply(
      { kind: 'create', draft: lunch([reference('vita.reference.chicken-breast.cooked', 150, '鸡胸肉')]) },
      DAY, 0, ORIGIN,
    )
    let day = days.day(DAY)
    expect(day.revision).toBe(1)
    expect(day.records).toHaveLength(1)
    expect(day.summary.totals.proteinG).toBe(46.5)

    records.apply({ kind: 'appendItems', recordId, items: [reference('vita.reference.rice.white.cooked', 200, '米饭')] }, DAY, 1, ORIGIN)
    day = days.day(DAY)
    expect(day.revision).toBe(2)
    expect(day.records[0].revision).toBe(1)
    expect(day.records[0].items.map((item) => item.displayName)).toEqual(['鸡胸肉', '米饭'])
    expect(day.summary.totals.energyKcal).toBe(507.5)

    const riceId = day.records[0].items[1].id
    records.apply({ kind: 'replaceItem', recordId, itemId: riceId, item: reference('vita.reference.rice.white.cooked', 100, '米饭') }, DAY, 2, ORIGIN)
    expect(days.day(DAY).summary.totals.energyKcal).toBe(377.5)

    records.apply({ kind: 'removeItem', recordId, itemId: riceId }, DAY, 3, ORIGIN)
    day = days.day(DAY)
    expect(day.records[0].items).toHaveLength(1)
    expect(day.summary.totals.energyKcal).toBe(247.5)

    records.apply({ kind: 'deleteRecord', recordId }, DAY, 4, ORIGIN)
    day = days.day(DAY)
    expect(day.records).toEqual([])
    expect(day.revision).toBe(5)
    expect(day.summary.totals).toEqual({ energyKcal: 0, proteinG: 0, fatG: 0, carbohydrateG: 0 })
    expect(database.prepare('SELECT count(*) AS n FROM consumption_items').get()).toEqual({ n: 0 })
    expect(audits(database, 'record.delete')[0].result).toBe('success')
  })
})

describe('revision 与日期隔离', () => {
  it('过期的 revision 被拒绝，什么都不写，并记失败审计', () => {
    const { services, database } = setup()
    services.records.apply({ kind: 'create', draft: lunch([estimate(500)]) }, DAY, 0, ORIGIN)
    expect(() => services.records.apply({ kind: 'create', draft: lunch([estimate(300)]) }, DAY, 0, ORIGIN)).toThrow('record.revisionConflict')
    expect(services.days.day(DAY).records).toHaveLength(1)
    expect(audits(database, 'record.create').map((row) => row.error_code)).toContain('record.revisionConflict')
  })

  it('不能借 ID 操作别的日期的记录', () => {
    const { services } = setup()
    const yesterday = '2026-10-29'
    const recordId = services.records.apply({ kind: 'create', draft: lunch([estimate(500)], yesterday) }, yesterday, 0, ORIGIN)
    services.records.apply({ kind: 'create', draft: lunch([estimate(100)]) }, DAY, 0, ORIGIN)
    expect(() => services.records.apply({ kind: 'deleteRecord', recordId }, DAY, 1, ORIGIN)).toThrow('record.recordNotInSession')
    expect(services.days.day(yesterday).records).toHaveLength(1)
  })

  it('摄入时间必须属于当前日期；读取不存在的日期不会创建会话', () => {
    const { services, database } = setup()
    expect(() => services.records.apply({ kind: 'create', draft: lunch([estimate(1)], '2026-10-29') }, DAY, 0, ORIGIN)).toThrow(
      'record.eventTimeOutsideSession',
    )
    services.days.day(DAY)
    expect(database.prepare('SELECT count(*) AS n FROM day_sessions').get()).toEqual({ n: 0 })
  })

  it('会话记下创建时的时区', () => {
    const { services, database } = setup()
    services.records.apply({ kind: 'create', draft: lunch([estimate(1)]) }, DAY, 0, ORIGIN)
    expect(database.prepare('SELECT time_zone FROM day_sessions').get()).toEqual({ time_zone: SHANGHAI })
  })
})

describe('Item 校验：任一项不合格则整条不写', () => {
  it('一项不合格，整条记录不写', () => {
    const { services, database } = setup()
    const draft = lunch([reference('vita.reference.egg.whole.raw', 50), reference('vita.reference.does-not-exist', 50)])
    try {
      services.records.apply({ kind: 'create', draft }, DAY, 0, ORIGIN)
      expect.unreachable()
    } catch (error) {
      expect(error).toMatchObject({ code: 'invalidItem', details: { index: 1, reason: 'unknownReferenceFood' } })
    }
    expect(database.prepare('SELECT count(*) AS n FROM consumption_items').get()).toEqual({ n: 0 })
    expect(database.prepare('SELECT count(*) AS n FROM day_sessions').get()).toEqual({ n: 0 })
    expect(audits(database, 'record.create')[0].error_code).toBe('record.invalidItem.unknownReferenceFood')
  })

  it('各条规则', () => {
    const { services } = setup()
    // 用 preview：校验规则与写入相同，但不写，各条之间互不影响。
    const reject = (item: ItemDraft) => {
      try {
        services.records.preview({ kind: 'create', draft: lunch([item]) }, DAY, 0)
        return null
      } catch (error) {
        return (error as { details?: { reason?: string } }).details?.reason ?? null
      }
    }
    const noQuantity = { ...reference('vita.reference.egg.whole.raw', 1), quantity: null }
    expect(reject(noQuantity)).toBe('amountSourceInconsistent')
    expect(reject({ ...noQuantity, amountSource: 'aiEstimated' })).toBe('quantityRequired')
    // 牛奶有密度，可按 ml 计算；鸡蛋没有，不能按 1ml = 1g 猜。
    expect(reject({ ...reference('vita.reference.egg.whole.raw', 1), quantity: { amount: 50, unit: 'ml' } })).toBe('unitMismatch')
    expect(reject({ ...reference('vita.reference.milk.whole', 1), quantity: { amount: 250, unit: 'ml' } })).toBeNull()
    const noBasis = estimate(100)
    expect(reject({ ...noBasis, nutrition: { source: 'aiEstimated', values: { energyKcal: 0, proteinG: 0, fatG: 0, carbohydrateG: 0 }, estimateBasis: '  ' } })).toBe('invalidEstimate')
    expect(reject({ ...estimate(100), displayName: ' ' })).toBe('emptyName')
    expect(reject({ ...estimate(100), originalAmountText: '' })).toBe('emptyAmountText')
  })

  it('移除最后一项须改为删除整条记录', () => {
    const { services } = setup()
    const recordId = services.records.apply({ kind: 'create', draft: lunch([estimate(1)]) }, DAY, 0, ORIGIN)
    const itemId = services.days.day(DAY).records[0].items[0].id
    expect(() => services.records.apply({ kind: 'removeItem', recordId, itemId }, DAY, 1, ORIGIN)).toThrow('record.emptyRecord')
  })
})

describe('必测场景', () => {
  it('场景 2："2 个鸡蛋、共 108g"以 108g 计算并保留原始表达', () => {
    const { services } = setup()
    const item: ItemDraft = {
      ...reference('vita.reference.egg.whole.raw', 108, '鸡蛋', '2 个鸡蛋、共 108g'),
      amountSource: 'userMeasured',
    }
    services.records.apply({ kind: 'create', draft: lunch([item]) }, DAY, 0, ORIGIN)
    const stored = services.days.day(DAY).records[0].items[0]
    expect(stored.originalAmountText).toBe('2 个鸡蛋、共 108g')
    expect(stored.snapshot.quantityUsed).toEqual({ amount: 108, unit: 'g' })
    expect(stored.snapshot.values.proteinG).toBe(13.608)
    expect(stored.amountSource).toBe('userMeasured')
    expect(stored.sourceLabel).toBe('鸡蛋（生） · Vita test fixture')
  })

  it('场景 6：个人食品出了新版本，旧记录保持原营养快照；退役版本不能再引用', () => {
    const { services } = setup()
    const version = (kcal: number, protein: number): FoodVersionDraft => ({
      basis: { quantity: { amount: 100, unit: 'ml' }, nutrients: { energyKcal: kcal, proteinG: protein, fatG: 3, carbohydrateG: 5 } },
      sourceKind: 'manualEntry',
      labelScanId: null,
      derivedFromReferenceId: null,
      sourceNote: null,
    })
    const productId = services.foods.apply(
      { kind: 'createProduct', product: { name: '纯牛奶', brandOrSupplier: null, package: { amount: 250, unit: 'ml' }, note: null }, version: version(60, 3) },
      ORIGIN,
    )
    const v1 = services.foods.products()[0].activeVersion!.id
    const milk: ItemDraft = {
      displayName: '纯牛奶',
      groupName: null,
      originalAmountText: '一盒',
      quantity: { amount: 250, unit: 'ml' },
      amountSource: 'packageConversion',
      nutrition: { source: 'personalFoodVersion', foodVersionId: v1 },
      includeInSummary: true,
    }
    services.records.apply({ kind: 'create', draft: lunch([milk]) }, DAY, 0, ORIGIN)
    services.foods.apply({ kind: 'addVersion', productId, expectedActiveVersionId: v1, version: version(70, 4) }, ORIGIN)

    const stored = services.days.day(DAY).records[0].items[0]
    expect(stored.snapshot.values.energyKcal).toBe(150)
    expect(stored.snapshot.values.proteinG).toBe(7.5)
    expect(stored.snapshot.sourceRef).toBe(v1)
    expect(stored.sourceLabel).toBe('纯牛奶')
    try {
      services.records.apply({ kind: 'create', draft: lunch([milk]) }, DAY, 1, ORIGIN)
      expect.unreachable()
    } catch (error) {
      expect(error).toMatchObject({ code: 'invalidItem', details: { index: 0, reason: 'retiredFoodVersion' } })
    }
  })

  it('按代表性时间排序：午餐在晚餐前', () => {
    const { services } = setup()
    const dinner: RecordDraft = {
      eventTime: makeEventTime({ localDate: DAY, precision: 'mealPeriod', mealPeriod: 'dinner', timeZone: SHANGHAI }),
      mealLabel: '晚餐',
      note: null,
      items: [estimate(1)],
    }
    services.records.apply({ kind: 'create', draft: dinner }, DAY, 0, ORIGIN)
    services.records.apply({ kind: 'create', draft: lunch([estimate(1)]) }, DAY, 1, ORIGIN)
    expect(services.days.day(DAY).records.map((record) => record.mealLabel)).toEqual(['午餐', '晚餐'])
  })

  it('不计入汇总的 Item 与估算项分别计数', () => {
    const { services } = setup()
    services.records.apply({ kind: 'create', draft: lunch([estimate(500), estimate(200, 0, false), reference('vita.reference.egg.whole.raw', 50)]) }, DAY, 0, ORIGIN)
    expect(services.days.day(DAY).summary).toMatchObject({
      totals: { energyKcal: 571.5 },
      includedItemCount: 2,
      excludedItemCount: 1,
      estimatedItemCount: 1,
    })
  })
})
