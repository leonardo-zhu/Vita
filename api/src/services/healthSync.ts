/**
 * Apple 健康同步的变更流（架构设计 §9，替代 1.0 HealthSyncService 的本机 outbox）。健康只能在手机上写：
 * 服务端记下哪条记录、哪次称重变过，手机按游标拉取，拿到每个对象的最新状态后删旧写新。
 * 同一对象变了多次只给最新一次，所以积压的修改只执行一遍，结果只剩最新版。
 */
import type { DietarySample, HealthChange, HealthChangesResponse } from '@vita/contract'

import { representativeTimestamp } from '../domain/eventTime.ts'
import type { BodyService } from './body.ts'
import type { ServiceContext } from './context.ts'
import type { DayService } from './day.ts'

/** 写进 Sample 的 metadata 版本，与 1.0 相同。 */
const METADATA_SCHEMA_VERSION = '1'

export class HealthSyncService {
  private readonly context: ServiceContext
  private readonly days: DayService
  private readonly body: BodyService

  constructor(context: ServiceContext, days: DayService, body: BodyService) {
    this.context = context
    this.days = days
    this.body = body
  }

  /** `after` 之后的变更，每个对象只取最新一条，按 seq 排序。 */
  changes(after: number, limit = 100): HealthChangesResponse {
    const rows = this.context.database
      .prepare(
        `SELECT max(seq) AS seq, entity, entity_id FROM health_changes WHERE seq > ?
         GROUP BY entity, entity_id ORDER BY seq LIMIT ?`,
      )
      .all(after, limit + 1) as { seq: number; entity: 'record' | 'weighing'; entity_id: string }[]
    const page = rows.slice(0, limit)
    return {
      changes: page.map((row) => this.state(row.seq, row.entity, row.entity_id)),
      cursor: page.length ? page[page.length - 1].seq : after,
      hasMore: rows.length > limit,
    }
  }

  private state(seq: number, entity: 'record' | 'weighing', id: string): HealthChange {
    if (entity === 'weighing') {
      const weighing = this.body.weighings().find((candidate) => candidate.id === id)
      if (!weighing) return { seq, entity, id, deleted: true, syncVersion: seq, body: null }
      const lean = weighing.metrics.find((metric) => metric.kind === 'leanMass')?.value ?? null
      return {
        seq,
        entity,
        id,
        deleted: false,
        syncVersion: seq,
        body: { bodyMassKg: weighing.weightKg, bodyFatFraction: weighing.bodyFat?.value ?? null, leanBodyMassKg: lean, date: weighing.measuredAt },
      }
    }
    const row = this.context.database.prepare('SELECT session_date FROM consumption_records WHERE id = ?').get(id) as { session_date: string } | undefined
    const record = row ? this.days.day(row.session_date).records.find((candidate) => candidate.id === id) : undefined
    if (!record) return { seq, entity, id, deleted: true, syncVersion: seq, samples: [] }
    const { eventTime } = record
    const metadata: Record<string, string> = {
      'vita.recordID': record.id,
      'vita.recordRevision': String(record.revision),
      'vita.timePrecision': eventTime.precision,
      'vita.schemaVersion': METADATA_SCHEMA_VERSION,
    }
    if (eventTime.precision === 'mealPeriod') {
      metadata['vita.timeWasRepresentative'] = 'true'
      if (eventTime.mealPeriod) metadata['vita.mealPeriod'] = eventTime.mealPeriod
    } else if (eventTime.precision === 'dateOnly') {
      metadata['vita.timeWasRepresentative'] = 'true'
    } else if (eventTime.precision === 'defaultedEntryTime') {
      metadata['vita.timeDefaultedAtEntry'] = 'true'
    }
    const date = representativeTimestamp(eventTime).toISOString()
    const samples: DietarySample[] = (['energyKcal', 'proteinG', 'fatG', 'carbohydrateG'] as const)
      .filter((nutrient) => record.totals[nutrient] > 0)
      .map((nutrient) => ({ nutrient, value: record.totals[nutrient], date, metadata }))
    return { seq, entity, id, deleted: false, syncVersion: seq, samples }
  }
}
