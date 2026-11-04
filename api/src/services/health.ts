/**
 * 健康数据（TDD §6.1，替代 1.0 的 HealthService）。Apple 健康只能在手机上读：手机把读到的身体数据和每日活动上传，
 * 这里保存最新一份，补上手动补录的兜底，并按活动记录算出 7 日日均。只用于目标与 Agent，不复制成长期业务主数据。
 */
import Big from 'big.js'

import type { ActivityUpload, HealthSnapshot, HealthUpload, ManualBodyMetrics } from '@vita/contract'

import { audit, transaction } from '../db.ts'
import type { DayActivity } from '../domain/energy.ts'
import { addDays } from '../domain/time.ts'
import type { ServiceContext, WriteOrigin } from './context.ts'

/** 平时活动至少要有几天的数据。 */
const MINIMUM_AVERAGE_DAYS = 3

const NO_DATA = { status: 'noData' } as const

type Reading<T> =
  | { status: 'value'; value: T; source: 'healthKit' | 'manual'; measuredAt: string | null }
  | { status: 'noData' }
  | { status: 'failed'; message: string }

/** Apple 健康没有时用手动值补上。 */
function withFallback<T>(reading: Reading<T>, value: T | null | undefined, enteredAt: string | undefined): Reading<T> {
  if (reading.status === 'value' || value === null || value === undefined || enteredAt === undefined) return reading
  return { status: 'value', value, source: 'manual', measuredAt: enteredAt }
}

function measured(value: number | null): Reading<number> {
  return value === null ? NO_DATA : { status: 'value', value, source: 'healthKit', measuredAt: null }
}

const EMPTY_UPLOAD: HealthUpload = {
  bodyMassKg: NO_DATA,
  heightCm: NO_DATA,
  bodyFatFraction: NO_DATA,
  dateOfBirth: NO_DATA,
  sex: NO_DATA,
  sleepHours: NO_DATA,
  authorizationRequested: false,
  writeDenied: false,
}

export class HealthService {
  private readonly context: ServiceContext

  constructor(context: ServiceContext) {
    this.context = context
  }

  /** 保存手机读到的身体数据，覆盖上一份。 */
  upload(data: HealthUpload, origin: WriteOrigin) {
    const { database, now } = this.context
    const at = now()
    transaction(database, () => {
      database
        .prepare('INSERT INTO health_upload (id, data, uploaded_at) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data, uploaded_at = excluded.uploaded_at')
        .run(JSON.stringify(data), at.toISOString())
      audit(database, { actor: origin.actor, action: 'health.upload', result: 'success', at })
    })
  }

  /** 保存若干天的活动能量；同一天以最后一次上传为准。 */
  uploadActivity(upload: ActivityUpload, origin: WriteOrigin) {
    const { database, now } = this.context
    const at = now()
    transaction(database, () => {
      const statement = database.prepare(
        'INSERT INTO day_activity (local_date, active_kcal, updated_at) VALUES (?, ?, ?) ON CONFLICT(local_date) DO UPDATE SET active_kcal = excluded.active_kcal, updated_at = excluded.updated_at',
      )
      for (const day of upload.days) statement.run(day.date, day.activeKcal, at.toISOString())
      audit(database, { actor: origin.actor, action: 'health.activity', result: 'success', at })
    })
  }

  /** 补录只覆盖给出的项，没给的沿用上一次。返回合并后的结果。 */
  submitManualMetrics(metrics: ManualBodyMetrics, origin: WriteOrigin): ManualBodyMetrics {
    const { database, now } = this.context
    const at = now()
    const previous = this.manualRow()?.metrics ?? {}
    const merged: ManualBodyMetrics = { ...previous }
    for (const [key, value] of Object.entries(metrics) as [keyof ManualBodyMetrics, unknown][]) {
      if (value !== null && value !== undefined) Object.assign(merged, { [key]: value })
    }
    transaction(database, () => {
      database
        .prepare('INSERT INTO manual_body_metrics (id, data, entered_at) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data, entered_at = excluded.entered_at')
        .run(JSON.stringify(merged), at.toISOString())
      audit(database, { actor: origin.actor, action: 'health.manualMetrics', result: 'success', at })
    })
    return merged
  }

  /** 某天的活动：当天上传的累计，加上之前 7 个完整日里有数据（大于 0）的那些天的日均（不足 3 天为 null）。 */
  activity(date: string): DayActivity {
    const rows = this.context.database
      .prepare('SELECT local_date, active_kcal FROM day_activity WHERE local_date BETWEEN ? AND ?')
      .all(addDays(date, -7), date) as { local_date: string; active_kcal: number | null }[]
    const byDate = new Map(rows.map((row) => [row.local_date, row.active_kcal]))
    const previous = rows.filter((row) => row.local_date !== date && row.active_kcal !== null && row.active_kcal > 0).map((row) => row.active_kcal!)
    const average =
      previous.length >= MINIMUM_AVERAGE_DAYS
        ? Number(previous.reduce((sum, value) => sum.plus(value), new Big(0)).div(previous.length).toString())
        : null
    return { activeKcal: byDate.get(date) ?? null, dailyAverageKcal: average }
  }

  /** 某天的健康数据：上传的各项，缺的用手动补录兜底；活动按服务端的活动记录。 */
  snapshot(date: string): HealthSnapshot {
    const row = this.context.database.prepare('SELECT data, uploaded_at FROM health_upload WHERE id = 1').get() as
      | { data: string; uploaded_at: string }
      | undefined
    const upload: HealthUpload = row ? JSON.parse(row.data) : EMPTY_UPLOAD
    const manual = this.manualRow()
    const metrics = manual?.metrics
    const activity = this.activity(date)
    return {
      ...upload,
      bodyMassKg: withFallback(upload.bodyMassKg, metrics?.bodyMassKg, manual?.enteredAt),
      heightCm: withFallback(upload.heightCm, metrics?.heightCm, manual?.enteredAt),
      bodyFatFraction: withFallback(upload.bodyFatFraction, metrics?.bodyFatFraction, manual?.enteredAt),
      dateOfBirth: withFallback(upload.dateOfBirth, metrics?.dateOfBirth, manual?.enteredAt),
      sex: withFallback(upload.sex, metrics?.sex, manual?.enteredAt),
      activeEnergyKcal: measured(activity.activeKcal),
      averageActiveEnergyKcal: measured(activity.dailyAverageKcal),
      uploadedAt: row?.uploaded_at ?? null,
    }
  }

  private manualRow(): { metrics: ManualBodyMetrics; enteredAt: string } | null {
    const row = this.context.database.prepare('SELECT data, entered_at FROM manual_body_metrics WHERE id = 1').get() as
      | { data: string; entered_at: string }
      | undefined
    return row ? { metrics: JSON.parse(row.data), enteredAt: row.entered_at } : null
  }
}
