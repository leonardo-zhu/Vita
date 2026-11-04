/**
 * 测试夹具，对应 1.0 的 VitaTests/TestSupport 与 RecordDraftFixtures：同一个日期、时刻、时区与小型参考库。
 */
import path from 'node:path'

import { openDatabase } from '../db.ts'
import type { ItemDraft, RecordDraft } from '../domain/changes.ts'
import { makeEventTime } from '../domain/eventTime.ts'
import { ReferenceCatalog } from '../domain/reference.ts'
import { createServices } from '../services/index.ts'

export const DAY = '2026-10-30'
export const SHANGHAI = 'Asia/Shanghai'
/** 2026-10-30 20:00 上海时间。 */
export const NOW = new Date('2026-10-30T12:00:00Z')
export const ORIGIN = { actor: 'test' }

export const referenceCatalog = () => ReferenceCatalog.load(path.join(import.meta.dirname, 'reference-foods.fixture.json'))

/** 可调的时钟，用来跨过有效期与午夜。 */
export class TestClock {
  now = NOW
  advance(minutes: number) {
    this.now = new Date(this.now.getTime() + minutes * 60_000)
  }
}

export function setup() {
  const clock = new TestClock()
  const database = openDatabase(':memory:')
  const services = createServices({ database, reference: referenceCatalog(), now: () => clock.now, timeZone: () => SHANGHAI })
  return { clock, database, services }
}

export function reference(id: string, grams: number, name = 'item', text = 'some'): ItemDraft {
  return {
    displayName: name,
    groupName: null,
    originalAmountText: text,
    quantity: { amount: grams, unit: 'g' },
    amountSource: 'userStated',
    nutrition: { source: 'referenceFood', referenceFoodId: id },
    includeInSummary: true,
  }
}

export function estimate(kcal: number, protein = 0, include = true): ItemDraft {
  return {
    displayName: '外卖',
    groupName: null,
    originalAmountText: '一份',
    quantity: null,
    amountSource: 'aiEstimated',
    nutrition: { source: 'aiEstimated', values: { energyKcal: kcal, proteinG: protein, fatG: 0, carbohydrateG: 0 }, estimateBasis: '按一份估算' },
    includeInSummary: include,
  }
}

export function lunch(items: ItemDraft[], date = DAY): RecordDraft {
  return {
    eventTime: makeEventTime({ localDate: date, precision: 'mealPeriod', mealPeriod: 'lunch', timeZone: SHANGHAI }),
    mealLabel: '午餐',
    note: null,
    items,
  }
}
