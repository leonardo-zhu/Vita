/**
 * 健康数据（TDD §6.1，替代 1.0 的 HealthService）。Apple 健康只能在手机上读：手机把读到的身体数据和每日活动上传，
 * 这里保存最新一份，补上手动补录的兜底，并按活动记录算出 7 日日均。只用于目标与 Agent，不复制成长期业务主数据。
 * 连了 Google 健康时，活动能量与睡眠用服务端拉到的（google_day_metrics，见 GoogleHealthService），没有的日子再用手机上传的。
 * 体重与体脂率：体脂秤的称重服务端本来就有（scale_weighings，见 BodyService），不比 Apple 健康里的旧就直接用，
 * 不必等手机写进 Apple 健康再读回来；Apple 健康更新时（别的秤、别的 App 记的）用 Apple 健康的。
 */
import Big from 'big.js'

import type { ActivityUpload, HealthSnapshot, HealthUpload, ManualBodyMetrics, MetricSource } from '@vita/contract'

import { audit, transaction } from '../db.ts'
import type { DayActivity } from '../domain/energy.ts'
import { ageOn, mifflinStJeor } from '../domain/recommendation.ts'
import { addDays, localDateOf, zonedInstant } from '../domain/time.ts'
import type { ServiceContext, WriteOrigin } from './context.ts'

/** 平时活动至少要有几天的数据。 */
const MINIMUM_AVERAGE_DAYS = 3

const NO_DATA = { status: 'noData' } as const

type Reading<T> =
  | { status: 'value'; value: T; source: MetricSource; measuredAt: string | null }
  | { status: 'noData' }
  | { status: 'failed'; message: string }

/** Apple 健康没有时用手动值补上。 */
function withFallback<T>(reading: Reading<T>, value: T | null | undefined, enteredAt: string | undefined): Reading<T> {
  if (reading.status === 'value' || value === null || value === undefined || enteredAt === undefined) return reading
  return { status: 'value', value, source: 'manual', measuredAt: enteredAt }
}

function measured(value: number | null, source: 'healthKit' | 'googleHealth' = 'healthKit'): Reading<number> {
  return value === null ? NO_DATA : { status: 'value', value, source, measuredAt: null }
}

/** 体脂秤最新的体重与体脂率，各带称重时间（ISO）。由 BodyService 提供，见 HealthService.useScale。 */
export interface ScaleReadings {
  bodyMassKg: { value: number; measuredAt: string } | null
  bodyFatFraction: { value: number; measuredAt: string } | null
}

/**
 * 称重不比 Apple 健康的读数旧时用称重。同一时刻多半就是手机写进 Apple 健康的那份，以服务端为准（体脂率按当前校准算）；
 * Apple 健康的读数没有时间或读取失败时也用称重。按时刻比较，手机给的 ISO 字符串可能不带毫秒。
 */
function newerOf(reading: Reading<number>, scale: ScaleReadings['bodyMassKg']): Reading<number> {
  if (!scale) return reading
  if (reading.status === 'value' && reading.measuredAt !== null && Date.parse(reading.measuredAt) > Date.parse(scale.measuredAt)) return reading
  return { status: 'value', value: scale.value, source: 'vitaScale', measuredAt: scale.measuredAt }
}

/** 某天的活动能量与来源：Google 健康拉到的优先，没有时用手机上传的。 */
interface ActivityDay {
  date: string
  kcal: number | null
  source: 'healthKit' | 'googleHealth'
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
  private scale: () => ScaleReadings = () => ({ bodyMassKg: null, bodyFatFraction: null })

  constructor(context: ServiceContext) {
    this.context = context
  }

  /** 接上体脂秤的称重。BodyService 要用快照里的身高、年龄、性别，所以不能在构造时互相传入。 */
  useScale(readings: () => ScaleReadings) {
    this.scale = readings
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
    return transaction(database, () => {
      const merged = this.writeManual(metrics, at)
      audit(database, { actor: origin.actor, action: 'health.manualMetrics', result: 'success', at })
      return merged
    })
  }

  /**
   * 称重没能写进 Apple 健康时，把体重与体脂率记为手动补录。离线记录可能比已有的补录还旧，不能拿旧体重覆盖新的。
   * 由称重服务在自己的事务里调用。
   */
  recordWeighingAsManual(weightKg: number, bodyFatFraction: number | null, measuredAt: Date) {
    const enteredAt = this.manualRow()?.enteredAt
    if (enteredAt && enteredAt > measuredAt.toISOString()) return
    this.writeManual({ bodyMassKg: weightKg, bodyFatFraction }, measuredAt)
  }

  private writeManual(metrics: ManualBodyMetrics, enteredAt: Date): ManualBodyMetrics {
    const merged: ManualBodyMetrics = { ...(this.manualRow()?.metrics ?? {}) }
    for (const [key, value] of Object.entries(metrics) as [keyof ManualBodyMetrics, unknown][]) {
      if (value !== null && value !== undefined) Object.assign(merged, { [key]: value })
    }
    this.context.database
      .prepare('INSERT INTO manual_body_metrics (id, data, entered_at) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data, entered_at = excluded.entered_at')
      .run(JSON.stringify(merged), enteredAt.toISOString())
    return merged
  }

  /** 某天的活动：当天的累计，加上之前 7 个完整日里有数据（大于 0）的那些天的日均（不足 3 天为 null）。 */
  activity(date: string): DayActivity {
    const { today, average } = this.activityWithSource(date)
    return { activeKcal: today.kcal, dailyAverageKcal: average.kcal }
  }

  /** 同 activity，带上来源：日均里只要有一天来自 Google 健康就标 googleHealth。 */
  private activityWithSource(date: string): { today: ActivityDay; average: { kcal: number | null; source: ActivityDay['source'] } } {
    const { database } = this.context
    const from = addDays(date, -7)
    const phone = database.prepare('SELECT local_date, active_kcal FROM day_activity WHERE local_date BETWEEN ? AND ?').all(from, date) as {
      local_date: string
      active_kcal: number | null
    }[]
    const google = database.prepare('SELECT local_date, active_kcal FROM google_day_metrics WHERE local_date BETWEEN ? AND ?').all(from, date) as {
      local_date: string
      active_kcal: number | null
    }[]
    const days = new Map<string, ActivityDay>()
    for (const row of phone) days.set(row.local_date, { date: row.local_date, kcal: row.active_kcal, source: 'healthKit' })
    for (const row of google) {
      if (row.active_kcal !== null) days.set(row.local_date, { date: row.local_date, kcal: row.active_kcal, source: 'googleHealth' })
    }
    const today = days.get(date) ?? { date, kcal: null, source: 'healthKit' }
    const previous = [...days.values()].filter((day) => day.date !== date && day.kcal !== null && day.kcal > 0)
    const kcal =
      previous.length >= MINIMUM_AVERAGE_DAYS
        ? Number(previous.reduce((sum, day) => sum.plus(day.kcal!), new Big(0)).div(previous.length).toString())
        : null
    const source = previous.some((day) => day.source === 'googleHealth') ? 'googleHealth' : 'healthKit'
    return { today, average: { kcal, source } }
  }

  /**
   * 某天的健康数据：上传的各项，缺的用手动补录兜底；体重与体脂率取体脂秤与 Apple 健康里较新的；
   * 活动按服务端的活动记录，睡眠有 Google 健康的用 Google 的。
   */
  snapshot(date: string): HealthSnapshot {
    const { database } = this.context
    const row = database.prepare('SELECT data, uploaded_at FROM health_upload WHERE id = 1').get() as { data: string; uploaded_at: string } | undefined
    const upload: HealthUpload = row ? JSON.parse(row.data) : EMPTY_UPLOAD
    const manual = this.manualRow()
    const metrics = manual?.metrics
    const { today, average } = this.activityWithSource(date)
    const scale = this.scale()
    const googleSleep = database.prepare('SELECT sleep_hours FROM google_day_metrics WHERE local_date = ?').get(date) as { sleep_hours: number | null } | undefined
    return {
      ...upload,
      bodyMassKg: withFallback(newerOf(upload.bodyMassKg, scale.bodyMassKg), metrics?.bodyMassKg, manual?.enteredAt),
      heightCm: withFallback(upload.heightCm, metrics?.heightCm, manual?.enteredAt),
      bodyFatFraction: withFallback(newerOf(upload.bodyFatFraction, scale.bodyFatFraction), metrics?.bodyFatFraction, manual?.enteredAt),
      dateOfBirth: withFallback(upload.dateOfBirth, metrics?.dateOfBirth, manual?.enteredAt),
      sex: withFallback(upload.sex, metrics?.sex, manual?.enteredAt),
      sleepHours: googleSleep && googleSleep.sleep_hours !== null ? measured(googleSleep.sleep_hours, 'googleHealth') : upload.sleepHours,
      activeEnergyKcal: measured(today.kcal, today.source),
      averageActiveEnergyKcal: measured(average.kcal, average.source),
      uploadedAt: row?.uploaded_at ?? null,
    }
  }

  /**
   * 某天的 BMR（Mifflin–St Jeor），每天按当时的身体数据重算，不用设定目标时定格的那个：体重变了，能量目标跟着变。
   * 体重取这一天结束前最新的一次：当前读数（称重、Apple 健康或补录）在这天之后的，改用这天之前最后一次称重，
   * 这样过去日子的目标不会被后来的称重改掉。身高、出生日期、性别取当前的。缺一项返回 null，由调用方用目标里存的。
   */
  bmrOn(date: string): number | null {
    const snapshot = this.snapshot(date)
    const { heightCm: height, dateOfBirth: birth, sex } = snapshot
    if (height.status !== 'value' || birth.status !== 'value' || sex.status !== 'value') return null
    const endOfDay = zonedInstant(addDays(date, 1), 0, 0, 0, this.context.timeZone())
    const current = snapshot.bodyMassKg
    let weight: number | null = null
    if (current.status === 'value') {
      // 没有时间的读数只能当作当前的：今天及以后用，过去的日子不用
      const usable = current.measuredAt === null ? date >= localDateOf(this.context.now(), this.context.timeZone()) : Date.parse(current.measuredAt) < endOfDay.getTime()
      if (usable) weight = current.value
    }
    if (weight === null) {
      const row = this.context.database
        .prepare('SELECT weight_grams FROM scale_weighings WHERE measured_at < ? ORDER BY measured_at DESC LIMIT 1')
        .get(endOfDay.toISOString()) as { weight_grams: number } | undefined
      weight = row ? row.weight_grams / 1000 : null
    }
    if (weight === null) return null
    const bmr = mifflinStJeor(weight, height.value, ageOn(birth.value, date), sex.value)
    return Math.round(Number(bmr.toString()) * 10) / 10
  }

  private manualRow(): { metrics: ManualBodyMetrics; enteredAt: string } | null {
    const row = this.context.database.prepare('SELECT data, entered_at FROM manual_body_metrics WHERE id = 1').get() as
      | { data: string; entered_at: string }
      | undefined
    return row ? { metrics: JSON.parse(row.data), enteredAt: row.entered_at } : null
  }
}
