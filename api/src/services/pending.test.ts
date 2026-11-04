/**
 * 移植自 1.0 的 PendingServiceTests 与 FoodServiceTests：确认门、每日一张、过期、revision 冲突、篡改、重启恢复，
 * 以及食品库只在确认后写入、新版本让旧版本退役。
 */
import { randomUUID } from 'node:crypto'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

import { describe, expect, it } from 'vitest'

import { openDatabase } from '../db.ts'
import type { FoodChange, FoodProductDraft, FoodVersionDraft, ItemDraft, RecordChange } from '../domain/changes.ts'
import { DAY, estimate, lunch, ORIGIN, referenceCatalog, setup, SHANGHAI, TestClock } from '../test/support.ts'
import { createServices } from './index.ts'

const lunchChange = (kcal = 500, date = DAY): RecordChange => ({ kind: 'create', draft: lunch([estimate(kcal)], date) })

function recordCount(database: ReturnType<typeof setup>['database']) {
  return (database.prepare('SELECT count(*) AS n FROM consumption_records').get() as { n: number }).n
}

describe('确认门', () => {
  it('提案不写正式数据，确认后才写', () => {
    const { services, database } = setup()
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    expect(pending.status).toBe('readyForConfirmation')
    expect(pending.preview).toMatchObject({ type: 'record', record: { totals: { energyKcal: 500 } } })
    expect(recordCount(database)).toBe(0)
    expect(services.days.day(DAY).summary.totals.energyKcal).toBe(0)

    const confirmed = services.pending.confirm(pending.id, ORIGIN)
    expect(recordCount(database)).toBe(1)
    expect(confirmed.status).toBe('confirmed')
    expect(confirmed.resultId).toBe(services.days.day(DAY).records[0].id)
    expect(confirmed.preview).toBeNull()
    expect(services.pending.active(DAY)).toBeNull()
  })

  it('不合格的提案不产生确认卡', () => {
    const { services } = setup()
    const bad: RecordChange = {
      kind: 'create',
      draft: lunch([{ ...estimate(1), nutrition: { source: 'referenceFood', referenceFoodId: 'vita.reference.nope' }, quantity: { amount: 10, unit: 'g' }, amountSource: 'userStated' }]),
    }
    expect(() => services.pending.proposeRecord(bad, DAY, 0, ORIGIN)).toThrow('record.invalidItem')
    expect(services.pending.active(DAY)).toBeNull()
  })

  it('取消后什么都不写，也不能再确认', () => {
    const { services, database } = setup()
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    expect(services.pending.cancel(pending.id, ORIGIN)).toMatchObject({ status: 'cancelled', resolutionCode: 'userCancelled' })
    expect(() => services.pending.confirm(pending.id, ORIGIN)).toThrow('pending.notActive')
    expect(recordCount(database)).toBe(0)
  })

  it('确认后要做的下一步随卡片保存', () => {
    const { services } = setup()
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, { ...ORIGIN, afterConfirm: ' 再记一杯牛奶 ' })
    expect(pending.afterConfirm).toBe('再记一杯牛奶')
    expect(services.pending.confirm(pending.id, ORIGIN).afterConfirm).toBe('再记一杯牛奶')
  })
})

describe('每个日期最多一张待确认卡片', () => {
  it('第二张被拒绝，明确替换才行；替换掉的不能再确认', () => {
    const { services } = setup()
    const first = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    try {
      services.pending.proposeRecord(lunchChange(300), DAY, 0, ORIGIN)
      expect.unreachable()
    } catch (error) {
      expect(error).toMatchObject({ code: 'anotherPendingActive', details: { pendingId: first.id } })
    }
    // 另一个日期不受影响。
    const yesterday = '2026-10-29'
    services.pending.proposeRecord(lunchChange(500, yesterday), yesterday, 0, ORIGIN)

    const corrected = services.pending.proposeRecord(lunchChange(300), DAY, 0, { ...ORIGIN, replacing: first.id })
    expect(services.pending.active(DAY)?.id).toBe(corrected.id)
    expect(services.pending.get(first.id).resolutionCode).toBe('replaced')
    expect(() => services.pending.confirm(first.id, ORIGIN)).toThrow('pending.notActive')

    services.pending.confirm(corrected.id, ORIGIN)
    expect(services.days.day(DAY).summary.totals.energyKcal).toBe(300)
  })

  it('要替换的卡片不是当前那张时拒绝', () => {
    const { services } = setup()
    expect(() => services.pending.proposeRecord(lunchChange(), DAY, 0, { ...ORIGIN, replacing: randomUUID() })).toThrow('pending.notFound')
  })
})

describe('过期（场景 5、7）', () => {
  it('创建后 30 分钟过期，过期后不能确认', () => {
    const { services, clock, database } = setup()
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    expect(pending.expiresAt).toBe('2026-10-30T12:30:00.000Z')
    clock.advance(29)
    expect(services.pending.active(DAY)?.id).toBe(pending.id)
    clock.advance(1)
    expect(() => services.pending.confirm(pending.id, ORIGIN)).toThrow('pending.expired')
    expect(recordCount(database)).toBe(0)
    expect(services.pending.get(pending.id).status).toBe('expired')
  })

  it('本地午夜更早时在午夜过期', () => {
    const { services, clock, database } = setup()
    clock.now = new Date('2026-10-30T15:50:00Z') // 23:50 上海
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    expect(pending.expiresAt).toBe('2026-10-30T16:00:00.000Z')
    clock.advance(10)
    expect(services.pending.active(DAY)).toBeNull()
    expect(recordCount(database)).toBe(0)
  })

  it('场景 7：在历史日期创建的卡片按创建时刻计算截止，不会创建即过期', () => {
    const { services } = setup()
    const lastWeek = '2026-10-23'
    const pending = services.pending.proposeRecord(lunchChange(500, lastWeek), lastWeek, 0, ORIGIN)
    expect(pending.expiresAt).toBe('2026-10-30T12:30:00.000Z')
    expect(services.pending.active(lastWeek)?.id).toBe(pending.id)
    services.pending.confirm(pending.id, ORIGIN)
    expect(services.days.day(lastWeek).records).toHaveLength(1)
  })

  it('过期记审计', () => {
    const { services, clock, database } = setup()
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    clock.advance(31)
    services.pending.expireDue()
    expect(database.prepare("SELECT target_id FROM audit_events WHERE action = 'pending.expire'").all()).toEqual([{ target_id: pending.id }])
  })
})

describe('revision 冲突与篡改（场景 5）', () => {
  it('提案后当天数据变了：确认作废，没有幽灵写入', () => {
    const { services, database } = setup()
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    services.records.apply({ kind: 'create', draft: lunch([estimate(100)]) }, DAY, 0, ORIGIN)
    expect(() => services.pending.confirm(pending.id, ORIGIN)).toThrow('pending.revisionConflict')
    expect(recordCount(database)).toBe(1)
    expect(services.pending.get(pending.id).resolutionCode).toBe('revisionConflict')
    expect(services.pending.active(DAY)).toBeNull()
  })

  it('被篡改的 payload 不会被执行', () => {
    const { services, database } = setup()
    const pending = services.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    database.prepare('UPDATE pending_actions SET payload = ?').run(JSON.stringify({ type: 'record', change: lunchChange(5000) }))
    expect(() => services.pending.confirm(pending.id, ORIGIN)).toThrow('pending.payloadTampered')
    expect(recordCount(database)).toBe(0)
  })
})

describe('重启恢复', () => {
  it('没过期的卡片重启后还能确认', () => {
    const file = path.join(mkdtempSync(path.join(tmpdir(), 'vita-pending-')), 'vita-api.db')
    const clock = new TestClock()
    const launch = () => createServices({ database: openDatabase(file), reference: referenceCatalog(), now: () => clock.now, timeZone: () => SHANGHAI })

    const first = launch()
    const pending = first.pending.proposeRecord(lunchChange(), DAY, 0, ORIGIN)
    first.context.database.close()

    clock.advance(10)
    const relaunched = launch()
    expect(relaunched.pending.active(DAY)?.id).toBe(pending.id)
    relaunched.pending.confirm(pending.id, ORIGIN)
    expect(relaunched.days.day(DAY).records).toHaveLength(1)
    relaunched.context.database.close()
  })
})

describe('个人食品库', () => {
  const milk: FoodProductDraft = { name: '纯牛奶', brandOrSupplier: '某乳业', package: { amount: 250, unit: 'ml' }, note: null }
  const manual = (kcal: number, protein = 3): FoodVersionDraft => ({
    basis: { quantity: { amount: 100, unit: 'ml' }, nutrients: { energyKcal: kcal, proteinG: protein, fatG: 3, carbohydrateG: 5 } },
    sourceKind: 'manualEntry',
    labelScanId: null,
    derivedFromReferenceId: null,
    sourceNote: null,
  })

  function confirm(services: ReturnType<typeof setup>['services'], change: FoodChange, date = DAY) {
    const pending = services.pending.proposeFood(change, date, ORIGIN)
    return services.pending.confirm(pending.id, ORIGIN).resultId!
  }

  it('只在确认后创建', () => {
    const { services } = setup()
    const pending = services.pending.proposeFood({ kind: 'createProduct', product: milk, version: manual(60) }, DAY, ORIGIN)
    expect(pending.preview).toMatchObject({ type: 'food', food: { productName: '纯牛奶' } })
    expect(services.foods.products()).toEqual([])
    const productId = services.pending.confirm(pending.id, ORIGIN).resultId
    const [product] = services.foods.products()
    expect(product.id).toBe(productId)
    expect(product.package).toEqual({ amount: 250, unit: 'ml' })
    expect(product.activeVersion?.basis.nutrients.energyKcal).toBe(60)
  })

  it('新版本让旧版本退役，历史记录不变；旧版本不能再引用', () => {
    const { services } = setup()
    const productId = confirm(services, { kind: 'createProduct', product: milk, version: manual(60) })
    const v1 = services.foods.products()[0].activeVersion!.id
    const drink: ItemDraft = {
      displayName: '纯牛奶',
      groupName: null,
      originalAmountText: '一盒',
      quantity: { amount: 250, unit: 'ml' },
      amountSource: 'packageConversion',
      nutrition: { source: 'personalFoodVersion', foodVersionId: v1 },
      includeInSummary: true,
    }
    services.records.apply({ kind: 'create', draft: lunch([drink]) }, DAY, 0, ORIGIN)

    const pending = services.pending.proposeFood({ kind: 'addVersion', productId, expectedActiveVersionId: v1, version: manual(70, 4) }, DAY, ORIGIN)
    expect(pending.preview).toMatchObject({ type: 'food', food: { previousBasis: { nutrients: { energyKcal: 60 } } } })
    services.pending.confirm(pending.id, ORIGIN)

    const [product] = services.foods.products()
    expect(product.versions).toHaveLength(2)
    expect(product.activeVersion?.basis.nutrients.energyKcal).toBe(70)
    expect(product.versions.find((version) => version.id === v1)?.retiredAt).not.toBeNull()
    expect(services.days.day(DAY).summary.totals.energyKcal).toBe(150)
    expect(() => services.records.apply({ kind: 'create', draft: lunch([drink]) }, DAY, 1, ORIGIN)).toThrow('record.invalidItem')
  })

  it('提案后生效版本变了，确认作废', () => {
    const { services } = setup()
    const productId = confirm(services, { kind: 'createProduct', product: milk, version: manual(60) })
    const v1 = services.foods.products()[0].activeVersion!.id
    const stale = services.pending.proposeFood({ kind: 'addVersion', productId, expectedActiveVersionId: v1, version: manual(65) }, DAY, ORIGIN)
    // 另一个日期上先确认了一个新版本。
    confirm(services, { kind: 'addVersion', productId, expectedActiveVersionId: v1, version: manual(70) }, '2026-10-29')
    expect(() => services.pending.confirm(stale.id, ORIGIN)).toThrow('pending.revisionConflict')
    expect(services.foods.products()[0].activeVersion?.basis.nutrients.energyKcal).toBe(70)
  })

  it('营养标签来源必须指向存档的标签照片', () => {
    const { services, database } = setup()
    const version = { ...manual(60), sourceKind: 'nutritionLabel' as const, labelScanId: randomUUID() }
    expect(() => services.pending.proposeFood({ kind: 'createProduct', product: milk, version }, DAY, ORIGIN)).toThrow('food.unknownLabel')
    database.prepare('INSERT INTO label_scans (id, created_at) VALUES (?, ?)').run(version.labelScanId, '2026-10-30T12:00:00.000Z')
    confirm(services, { kind: 'createProduct', product: milk, version })
    expect(services.foods.products()[0].activeVersion?.labelScanId).toBe(version.labelScanId)
  })

  it('参考库来源的数值必须与参考库一致', () => {
    const { services } = setup()
    const egg = referenceCatalog().food('vita.reference.egg.whole.raw')!
    const version: FoodVersionDraft = {
      basis: { quantity: { amount: 100, unit: 'g' }, nutrients: { ...egg.nutrients, proteinG: egg.nutrients.proteinG + 5 } },
      sourceKind: 'referenceDerived',
      labelScanId: null,
      derivedFromReferenceId: egg.id,
      sourceNote: null,
    }
    const product = { name: '土鸡蛋', brandOrSupplier: null, package: null, note: null }
    expect(() => services.pending.proposeFood({ kind: 'createProduct', product, version }, DAY, ORIGIN)).toThrow('food.basisDiffersFromReference')
    confirm(services, { kind: 'createProduct', product, version: { ...version, basis: { ...version.basis, nutrients: egg.nutrients } } })
    expect(services.foods.products()[0].activeVersion?.derivedFromReferenceId).toBe(egg.id)
  })

  it('按包装换算需要单位相符的包装规格', () => {
    const { services } = setup()
    confirm(services, { kind: 'createProduct', product: milk, version: manual(60) })
    const versionId = services.foods.products()[0].activeVersion!.id
    const halfBox = (quantity: ItemDraft['quantity'], nutrition: ItemDraft['nutrition']): RecordChange => ({
      kind: 'create',
      draft: lunch([{ displayName: 'x', groupName: null, originalAmountText: '半盒', quantity, amountSource: 'packageConversion', nutrition, includeInSummary: true }]),
    })
    const reason = (change: RecordChange) => {
      try {
        services.records.preview(change, DAY, 0)
        return null
      } catch (error) {
        return (error as { details?: { reason?: string } }).details?.reason
      }
    }
    expect(reason(halfBox({ amount: 125, unit: 'g' }, { source: 'personalFoodVersion', foodVersionId: versionId }))).toBe('packageUnavailable')
    expect(reason(halfBox({ amount: 50, unit: 'g' }, { source: 'referenceFood', referenceFoodId: 'vita.reference.egg.whole.raw' }))).toBe('packageUnavailable')
    services.records.apply(halfBox({ amount: 125, unit: 'ml' }, { source: 'personalFoodVersion', foodVersionId: versionId }), DAY, 0, ORIGIN)
    expect(services.days.day(DAY).summary.totals.energyKcal).toBe(75)
  })

  it('按名称或品牌搜索，忽略全半角与大小写', () => {
    const { services } = setup()
    confirm(services, { kind: 'createProduct', product: { name: 'Oatly 燕麦奶', brandOrSupplier: 'Oatly', package: null, note: null }, version: manual(50) })
    expect(services.foods.search('ｏａｔｌｙ')).toHaveLength(1)
    expect(services.foods.search('燕麦')).toHaveLength(1)
    expect(services.foods.search('牛奶')).toEqual([])
  })
})
