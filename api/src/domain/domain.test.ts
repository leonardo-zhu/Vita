/**
 * 移植自 1.0 的 EventTimeTests、NutritionCalculatorTests、NutritionSnapshotTests、ReferenceFoodCatalogTests。
 */
import { describe, expect, it } from 'vitest'

import { NOW, referenceCatalog, SHANGHAI } from '../test/support.ts'
import { defaultedEntryTime, EventTimeError, makeEventTime, representativeTimestamp } from './eventTime.ts'
import { computedSnapshot, convertQuantity, estimatedSnapshot, normalizeQuantity, sumNutrients } from './nutrition.ts'
import { normalizeName, ReferenceCatalog } from './reference.ts'
import { isLocalDate, localDateOf, zonedInstant } from './time.ts'
import { pendingExpiresAt } from '../services/pending.ts'

describe('本地日期与时区', () => {
  it('只接受合法的日历日期', () => {
    expect(isLocalDate('2026-10-30')).toBe(true)
    expect(isLocalDate('2028-02-29')).toBe(true)
    for (const value of ['2026-02-29', '2026-13-01', '2026-1-01', '20261030']) expect(isLocalDate(value)).toBe(false)
  })

  it('按给定时区取本地日期', () => {
    const instant = new Date('2026-10-30T17:00:00Z')
    expect(localDateOf(instant, SHANGHAI)).toBe('2026-10-31')
    expect(localDateOf(instant, 'America/Los_Angeles')).toBe('2026-10-30')
  })

  it('本地时分换算成时刻，跨夏令时也对', () => {
    expect(zonedInstant('2026-10-30', 12, 30, 0, SHANGHAI).toISOString()).toBe('2026-10-30T04:30:00.000Z')
    // 纽约 2026-11-01 结束夏令时：前一天是 UTC-4，后一天是 UTC-5。
    expect(zonedInstant('2026-10-31', 12, 0, 0, 'America/New_York').toISOString()).toBe('2026-10-31T16:00:00.000Z')
    expect(zonedInstant('2026-11-02', 12, 0, 0, 'America/New_York').toISOString()).toBe('2026-11-02T17:00:00.000Z')
  })
})

describe('摄入时间', () => {
  it('餐段不带伪造的时刻，代表性时间只用于计算', () => {
    const lunch = makeEventTime({ localDate: '2026-10-30', precision: 'mealPeriod', mealPeriod: 'lunch', timeZone: SHANGHAI })
    expect(lunch.timestamp).toBeNull()
    expect(representativeTimestamp(lunch).toISOString()).toBe('2026-10-30T04:30:00.000Z')
    expect(() => makeEventTime({ localDate: '2026-10-30', precision: 'mealPeriod', timeZone: SHANGHAI })).toThrow(EventTimeError)
    expect(() =>
      makeEventTime({ localDate: '2026-10-30', precision: 'mealPeriod', mealPeriod: 'lunch', timestamp: NOW, timeZone: SHANGHAI }),
    ).toThrow(EventTimeError)
  })

  it('各精度的代表性时间', () => {
    const at = (precision: 'dateOnly' | 'mealPeriod', mealPeriod?: 'breakfast' | 'dinner' | 'snack') =>
      representativeTimestamp(makeEventTime({ localDate: '2026-10-30', precision, mealPeriod, timeZone: SHANGHAI })).toISOString()
    expect(at('mealPeriod', 'breakfast')).toBe('2026-10-30T00:00:00.000Z')
    expect(at('mealPeriod', 'dinner')).toBe('2026-10-30T10:30:00.000Z')
    expect(at('mealPeriod', 'snack')).toBe('2026-10-30T07:30:00.000Z')
    expect(at('dateOnly')).toBe('2026-10-30T04:00:00.000Z')
  })

  it('精确时间必须落在本地日期内', () => {
    expect(() =>
      makeEventTime({ localDate: '2026-10-29', precision: 'exact', timestamp: NOW, timeZone: SHANGHAI }),
    ).toThrow('timestampOutsideLocalDate')
    expect(() => makeEventTime({ localDate: '2026-10-30', precision: 'exact', timeZone: SHANGHAI })).toThrow('missingTimestamp')
    expect(() => makeEventTime({ localDate: '2026-10-30', precision: 'dateOnly', timeZone: 'Mars/Base' })).toThrow('unknownTimeZone')
  })

  it('默认录入时间落在历史日期内，时分取现在', () => {
    const eventTime = defaultedEntryTime('2026-10-23', NOW, SHANGHAI)
    expect(eventTime.precision).toBe('defaultedEntryTime')
    expect(eventTime.localDate).toBe('2026-10-23')
    expect(eventTime.timestamp).toBe('2026-10-23T12:00:00.000Z')
  })
})

describe('单位与营养计算', () => {
  it('换算质量与体积单位', () => {
    expect(normalizeQuantity(1.5, 'kg')).toEqual({ amount: 1500, unit: 'g' })
    expect(normalizeQuantity(2, '两')).toEqual({ amount: 100, unit: 'g' })
    expect(normalizeQuantity(1, '斤')).toEqual({ amount: 500, unit: 'g' })
    expect(normalizeQuantity(250, ' ML ')).toEqual({ amount: 250, unit: 'ml' })
    expect(normalizeQuantity(0.5, '升')).toEqual({ amount: 500, unit: 'ml' })
    expect(normalizeQuantity(300, 'mg')).toEqual({ amount: 0.3, unit: 'g' })
  })

  it('拒绝计数单位与非正数', () => {
    expect(() => normalizeQuantity(1, '个')).toThrow('unsupportedUnit')
    expect(() => normalizeQuantity(1, '碗')).toThrow('unsupportedUnit')
    expect(() => normalizeQuantity(0, 'g')).toThrow('nonPositiveAmount')
  })

  it('按十进制计算，没有二进制误差', () => {
    const snapshot = computedSnapshot({
      source: 'referenceFood',
      sourceRef: 'x',
      basisQuantity: { amount: 100, unit: 'g' },
      basisNutrients: { energyKcal: 465.8, proteinG: 8.9, fatG: 37.6, carbohydrateG: 23.9 },
      quantity: { amount: 80, unit: 'g' },
    })
    expect(snapshot.values).toEqual({ energyKcal: 372.64, proteinG: 7.12, fatG: 30.08, carbohydrateG: 19.12 })
    expect(snapshot.computedBy).toBe('client')
    expect(sumNutrients([{ energyKcal: 0.1, proteinG: 0.2, fatG: 0, carbohydrateG: 0 }, { energyKcal: 0.2, proteinG: 0.1, fatG: 0, carbohydrateG: 0 }]))
      .toEqual({ energyKcal: 0.3, proteinG: 0.3, fatG: 0, carbohydrateG: 0 })
  })

  it('只有给出密度时才在 g 与 ml 之间换算', () => {
    expect(convertQuantity({ amount: 200, unit: 'ml' }, 'g', 1.03)).toEqual({ amount: 206, unit: 'g' })
    expect(() => convertQuantity({ amount: 50, unit: 'ml' }, 'g', null)).toThrow('unitMismatch')
  })

  it('AI 估算保留模型的数值与依据', () => {
    const snapshot = estimatedSnapshot({ energyKcal: 600, proteinG: 20, fatG: 25, carbohydrateG: 70 }, '按一份估算', null)
    expect(snapshot).toMatchObject({ nutritionSource: 'aiEstimated', computedBy: 'model', estimateBasis: '按一份估算', basisNutrients: null })
  })
})

describe('确认卡的有效期', () => {
  it('创建后 30 分钟，或本地午夜，取较早者', () => {
    expect(pendingExpiresAt(NOW, SHANGHAI).toISOString()).toBe('2026-10-30T12:30:00.000Z')
    const lateNight = new Date('2026-10-30T15:50:00Z') // 23:50 上海
    expect(pendingExpiresAt(lateNight, SHANGHAI).toISOString()).toBe('2026-10-30T16:00:00.000Z')
  })
})

describe('公共营养参考库', () => {
  const catalog = referenceCatalog()

  it('夹具通过校验', () => {
    expect(catalog.count).toBe(15)
  })

  it('有歧义的写法返回全部候选，不替用户选', () => {
    expect(catalog.search('鸡胸肉').map((food) => food.id)).toEqual([
      'vita.reference.chicken-breast.cooked',
      'vita.reference.chicken-breast.raw',
    ])
  })

  it('统一全半角、大小写与空白，但仍是精确匹配', () => {
    expect(normalizeName(' Ｏａｔ ｍｉｌｋ ')).toBe('oatmilk')
    expect(catalog.search('熟鸡胸').map((food) => food.id)).toEqual(['vita.reference.chicken-breast.cooked'])
    expect(catalog.search('鸡胸肉(生)').map((food) => food.id)).toEqual(['vita.reference.chicken-breast.raw'])
    expect(catalog.search(' 鸡胸肉 （ 生 ） ').map((food) => food.id)).toEqual(['vita.reference.chicken-breast.raw'])
    expect(catalog.search('鸡胸肉丁')).toEqual([])
    expect(catalog.search('不存在', ['西红柿']).map((food) => food.id)).toEqual(['vita.reference.tomato.raw'])
  })

  it('拒绝不合格的条目', () => {
    const egg = catalog.food('vita.reference.egg.whole.raw')!
    const variants = [
      { ...egg, id: 'egg' },
      { ...egg, canonicalName: '  ' },
      { ...egg, base: { quantity: 50, unit: 'g' as const } },
      { ...egg, nutrients: { ...egg.nutrients, fatG: -1 } },
      { ...egg, densityGPerMl: 0 },
    ]
    for (const variant of variants) expect(() => new ReferenceCatalog([variant])).toThrow()
    expect(() => new ReferenceCatalog([egg, egg])).toThrow('重复 ID')
    expect(() => new ReferenceCatalog([egg, { ...egg, id: 'vita.reference.egg2' }])).toThrow('重复')
  })

  it('浏览把精确候选和部分匹配分开', () => {
    const chicken = catalog.browse('鸡胸肉')
    expect(chicken.exact.map((food) => food.id)).toEqual(['vita.reference.chicken-breast.cooked', 'vita.reference.chicken-breast.raw'])
    expect(chicken.partial).toEqual([])
    // "鸡"不是任何条目的名称或别名：精确查询为空，浏览仍能列出包含它的条目。
    const partial = catalog.browse('鸡')
    expect(partial.exact).toEqual([])
    expect(partial.partial.map((food) => food.id)).toEqual(expect.arrayContaining(['vita.reference.chicken-breast.raw', 'vita.reference.egg.whole.raw']))
    expect(catalog.browse('  ')).toEqual({ exact: [], partial: [] })
  })

  it('扩展层只在精选层没有命中时参与查询', () => {
    const egg = catalog.food('vita.reference.egg.whole.raw')!
    const extended = { ...egg, id: 'vita.reference.cfct6.egg', canonicalName: '鸡蛋（白皮）', aliases: ['鸡蛋', '白皮鸡蛋'], tier: 'extended' as const }
    const mixed = new ReferenceCatalog([egg, extended])
    expect(mixed.search('鸡蛋').map((food) => food.id)).toEqual(['vita.reference.egg.whole.raw'])
    expect(mixed.search('白皮鸡蛋').map((food) => food.id)).toEqual(['vita.reference.cfct6.egg'])
  })
})
