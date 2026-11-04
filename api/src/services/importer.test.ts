/**
 * 从 1.0 迁移：整包导入、ID 不变、读回的数据与原来一致；非空库与对不上的引用整包拒绝。
 */
import { randomUUID } from 'node:crypto'

import type { ImportBundle } from '@vita/contract'
import { describe, expect, it } from 'vitest'

import { DAY, estimate, lunch, ORIGIN, reference, setup } from '../test/support.ts'
import { NO_TARGETS } from './goals.ts'

const at = '2026-10-30T12:00:00.000Z'

/** 用一套服务造出数据，再按导入格式整理（相当于手机的导出）。 */
function exportFrom(services: ReturnType<typeof setup>['services']): ImportBundle {
  const day = services.days.day(DAY)
  const products = services.foods.products()
  const goal = services.goals.active(DAY)!
  return {
    formatVersion: 1,
    exportedAt: at,
    sessions: [{ localDate: DAY, timeZone: 'Asia/Shanghai', revision: day.revision, createdAt: at, updatedAt: at }],
    records: day.records.map((r) => ({
      id: r.id,
      sessionDate: DAY,
      eventTime: r.eventTime,
      mealLabel: r.mealLabel,
      note: r.note,
      revision: r.revision,
      createdAt: at,
      updatedAt: at,
      items: r.items.map((i, position) => ({
        id: i.id,
        position,
        displayName: i.displayName,
        groupName: i.groupName,
        originalAmountText: i.originalAmountText,
        quantity: i.quantity,
        amountSource: i.amountSource,
        snapshot: i.snapshot,
        includeInSummary: i.includeInSummary,
        foodProductId: i.snapshot.nutritionSource === 'personalFoodVersion' ? products[0].id : null,
        foodVersionId: i.snapshot.nutritionSource === 'personalFoodVersion' ? i.snapshot.sourceRef : null,
        referenceFoodId: i.snapshot.nutritionSource === 'referenceFood' ? i.snapshot.sourceRef : null,
        createdAt: at,
        updatedAt: at,
      })),
    })),
    products: products.map((p) => ({
      id: p.id,
      name: p.name,
      brandOrSupplier: p.brandOrSupplier,
      package: p.package,
      note: p.note,
      activeVersionId: p.activeVersion?.id ?? null,
      createdAt: at,
      updatedAt: at,
      versions: p.versions,
    })),
    goals: [{ ...goal, evidence: null, createdAt: at }],
    messages: [{ id: randomUUID(), sessionDate: DAY, role: 'user', text: '中午吃了鸡蛋', cardRef: null, createdAt: at }],
    labelScans: [],
    weighings: [
      { id: randomUUID(), measuredAt: at, weightKg: 70.2, impedance: { a: 480, b: 430 }, source: 'live', timeReliable: true, profile: { heightCm: 175, ageYears: 30, sex: 'male' }, scaleBodyFatFraction: 0.2, createdAt: at },
    ],
    manualMetrics: { metrics: { heightCm: 175 }, enteredAt: at },
  }
}

function source() {
  const { services } = setup()
  const productId = services.foods.apply(
    {
      kind: 'createProduct',
      product: { name: '纯牛奶', brandOrSupplier: null, package: { amount: 250, unit: 'ml' }, note: null },
      version: { basis: { quantity: { amount: 100, unit: 'ml' }, nutrients: { energyKcal: 60, proteinG: 3, fatG: 3, carbohydrateG: 5 } }, sourceKind: 'manualEntry', labelScanId: null, derivedFromReferenceId: null, sourceNote: null },
    },
    ORIGIN,
  )
  const versionId = services.foods.products()[0].activeVersion!.id
  services.records.apply(
    {
      kind: 'create',
      draft: lunch([
        reference('vita.reference.egg.whole.raw', 108, '鸡蛋'),
        estimate(300),
        { displayName: '牛奶', groupName: null, originalAmountText: '一盒', quantity: { amount: 250, unit: 'ml' }, amountSource: 'packageConversion', nutrition: { source: 'personalFoodVersion', foodVersionId: versionId }, includeInSummary: true },
      ]),
    },
    DAY,
    0,
    ORIGIN,
  )
  services.goals.append({ ...NO_TARGETS, proteinG: 120 }, null, 'manualOnboarding', DAY, ORIGIN)
  return { services, productId }
}

describe('从 1.0 导入', () => {
  it('整包写入，ID 不变，读回的每日数据与原来一致，并登记健康同步', () => {
    const { services: from } = source()
    const bundle = exportFrom(from)
    const { services: to } = setup()
    const result = to.importer.run(bundle, ORIGIN)
    expect(result.counts).toMatchObject({ sessions: 1, records: 1, items: 3, products: 1, versions: 1, goals: 1, messages: 1, weighings: 1 })
    expect(result.dailyEnergyKcal[DAY]).toBe(from.days.day(DAY).summary.totals.energyKcal)

    const original = from.days.day(DAY)
    const imported = to.days.day(DAY)
    expect(imported.records).toEqual(original.records)
    expect(imported.revision).toBe(original.revision)
    expect(to.goals.active(DAY)?.targets.proteinG).toBe(120)
    expect(to.body.weighings()[0]).toMatchObject({ weightKg: 70.2, bodyFat: { value: 0.2, source: 'scaleReading' } })
    expect(to.health.snapshot(DAY).heightCm).toMatchObject({ value: 175, source: 'manual' })
    expect(to.chat.messages(DAY)).toHaveLength(1)
    // 导入后接着能正常写：revision 接上了。
    to.records.apply({ kind: 'create', draft: lunch([estimate(100)]) }, DAY, imported.revision, ORIGIN)
    expect(to.healthSync.changes(0).changes.map((c) => c.entity).sort()).toEqual(['record', 'record', 'weighing'])
  })

  it('已有数据时拒绝，什么都不改', () => {
    const { services } = source()
    expect(() => services.importer.run(exportFrom(services), ORIGIN)).toThrow('import.notEmpty')
  })

  it('引用对不上时整包拒绝', () => {
    const { services: from } = source()
    const bundle = exportFrom(from)
    bundle.products = []
    const { services: to } = setup()
    expect(() => to.importer.run(bundle, ORIGIN)).toThrow('import.brokenReference')
    expect(to.days.day(DAY).records).toEqual([])
  })
})
