/**
 * 体脂秤称重的保存、历史、校准与删除（身体成分模块 §5，移植自 1.0 的 BodyCompositionService）。
 * 蓝牙连秤与写 Apple 健康在手机上：手机上传锁定的称重，这里存原始数据，读取时按当前校准算出体脂率与各项指标。
 */
import { isDeepStrictEqual } from 'node:util'

import type { BodyFatCalibration, BodyFatModel, Weighing, WeighingUpload } from '@vita/contract'

import { audit, recordHealthChange, transaction } from '../db.ts'
import { bmiOf, bodyMetrics, bodyType, estimateBodyFat, fitBodyFat, isUsableModel, predictBodyFat, type CalibrationSample } from '../domain/body.ts'
import { ageOn } from '../domain/recommendation.ts'
import { localDateOf } from '../domain/time.ts'
import { ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'
import type { HealthService, ScaleReadings } from './health.ts'

/** 合理的体重范围，与手动补录相同；超出多半是没站稳或别的东西压到了秤。 */
const PLAUSIBLE_WEIGHT_KG = [20, 400] as const

interface WeighingRow {
  id: string
  measured_at: string
  weight_grams: number
  impedance_a: number | null
  impedance_b: number | null
  source: Weighing['source']
  time_reliable: number
  profile: string
  scale_body_fat_permille: number | null
}

export class BodyService {
  private readonly context: ServiceContext
  private readonly health: HealthService

  constructor(context: ServiceContext, health: HealthService) {
    this.context = context
    this.health = health
  }

  /**
   * 存下一次称重。离线记录的时间晚于现在（秤的时钟不对）时按现在记、标为时间不可靠。
   * 指标按称重当天的身高、年龄、性别算；手机不能写 Apple 健康时，体重与体脂率记为手动补录。
   * 同一个 id 重传时返回已存的那次，不重复记录。
   */
  record(upload: WeighingUpload, origin: WriteOrigin): Weighing {
    const { database, now } = this.context
    const existing = this.row(upload.id)
    if (existing) return this.toWeighing(existing, this.appliedModel())
    if (upload.weightKg < PLAUSIBLE_WEIGHT_KG[0] || upload.weightKg > PLAUSIBLE_WEIGHT_KG[1]) {
      throw new ServiceError('body', 'invalidMetrics')
    }

    const at = now()
    const recordedAt = upload.recordedAt ? new Date(upload.recordedAt) : null
    const reliable = recordedAt && recordedAt <= at ? recordedAt : null
    const measuredAt = reliable ?? at
    const snapshot = this.health.snapshot(localDateOf(measuredAt, this.context.timeZone()))
    const profile = {
      heightCm: snapshot.heightCm.status === 'value' ? snapshot.heightCm.value : null,
      ageYears: snapshot.dateOfBirth.status === 'value' ? ageOn(snapshot.dateOfBirth.value, localDateOf(measuredAt, this.context.timeZone())) : null,
      sex: snapshot.sex.status === 'value' ? snapshot.sex.value : null,
    }

    const recorded = transaction(database, () => {
      database
        .prepare(
          `INSERT INTO scale_weighings (id, measured_at, weight_grams, impedance_a, impedance_b, source, time_reliable, profile, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          upload.id,
          measuredAt.toISOString(),
          Math.round(upload.weightKg * 1000),
          upload.impedance?.a ?? null,
          upload.impedance?.b ?? null,
          upload.source,
          upload.source === 'live' || reliable ? 1 : 0,
          JSON.stringify(profile),
          at.toISOString(),
        )
      const weighing = this.toWeighing(this.row(upload.id)!, this.appliedModel())
      if (upload.appleHealthWritable) recordHealthChange(database, 'weighing', upload.id, at)
      else this.health.recordWeighingAsManual(weighing.weightKg, weighing.bodyFat?.value ?? null, measuredAt)
      audit(database, { actor: origin.actor, action: 'body.weighing', targetId: upload.id, result: 'success', at })
      return weighing
    })
    this.health.notifyBodyDataChange('weighing')
    return recorded
  }

  /** 全部称重，新的在前；体脂率按当前校准算。 */
  weighings(): Weighing[] {
    const model = this.appliedModel()
    return this.rows().map((row) => this.toWeighing(row, model))
  }

  /** 健康数据快照用：最新一次称重的体重，与最新一次算得出体脂率的称重的体脂率（按当前校准）。 */
  latestReadings(): ScaleReadings {
    const model = this.appliedModel()
    const rows = this.rows()
    const latest = rows[0]
    let bodyFatFraction: ScaleReadings['bodyFatFraction'] = null
    for (const row of rows) {
      const fat = this.toWeighing(row, model).bodyFat
      if (fat) {
        bodyFatFraction = { value: fat.value, measuredAt: row.measured_at }
        break
      }
    }
    return { bodyMassKg: latest ? { value: latest.weight_grams / 1000, measuredAt: latest.measured_at } : null, bodyFatFraction }
  }

  get(id: string): Weighing {
    const row = this.row(id)
    if (!row) throw new ServiceError('body', 'weighingNotFound')
    return this.toWeighing(row, this.appliedModel())
  }

  /** 由全部记下的秤读数拟合。读数很少，每次现算。 */
  calibration(): BodyFatCalibration {
    const samples = this.rows().flatMap((row): CalibrationSample[] => {
      const height = (JSON.parse(row.profile) as Weighing['profile']).heightCm
      if (row.scale_body_fat_permille === null || row.impedance_a === null || row.impedance_b === null || !height) return []
      return [{ weightKg: row.weight_grams / 1000, heightCm: height, impedance: { a: row.impedance_a, b: row.impedance_b }, observed: row.scale_body_fat_permille / 1000 }]
    })
    const model = fitBodyFat(samples)
    return { readingCount: samples.length, model, applied: model !== null && isUsableModel(model) }
  }

  /**
   * 记下（或清掉）这次称重时秤屏幕上的体脂率。返回 calibrationChanged：采用的公式因此变了，
   * 全部称重的体脂率都可能变化，手机要重写 Apple 健康里的历史；没变时只需重写这一次。
   */
  setScaleReading(id: string, bodyFatFraction: number | null, origin: WriteOrigin): { weighing: Weighing; calibrationChanged: boolean } {
    const { database, now } = this.context
    if (!this.row(id)) throw new ServiceError('body', 'weighingNotFound')
    const before = this.appliedModel()
    transaction(database, () => {
      database
        .prepare('UPDATE scale_weighings SET scale_body_fat_permille = ? WHERE id = ?')
        .run(bodyFatFraction === null ? null : Math.round(bodyFatFraction * 1000), id)
      audit(database, { actor: origin.actor, action: 'body.scaleReading', targetId: id, result: 'success', at: now() })
    })
    const after = this.appliedModel()
    const calibrationChanged = !isDeepStrictEqual(before, after)
    // 体脂率变了的称重都要重写健康里的那份：公式变了就是全部，否则只有这一次。
    transaction(database, () => {
      for (const target of calibrationChanged ? this.rows().map((row) => row.id) : [id]) recordHealthChange(database, 'weighing', target, now())
    })
    return { weighing: this.get(id), calibrationChanged }
  }

  /** 删除一次称重。Apple 健康里的那份由手机删除。 */
  delete(id: string, origin: WriteOrigin) {
    const { database, now } = this.context
    if (!this.row(id)) throw new ServiceError('body', 'weighingNotFound')
    transaction(database, () => {
      database.prepare('DELETE FROM scale_weighings WHERE id = ?').run(id)
      recordHealthChange(database, 'weighing', id, now())
      audit(database, { actor: origin.actor, action: 'body.weighing.delete', targetId: id, result: 'success', at: now() })
    })
    this.health.notifyBodyDataChange('weighing')
  }

  private appliedModel(): BodyFatModel | null {
    const { model, applied } = this.calibration()
    return applied ? model : null
  }

  private rows(): WeighingRow[] {
    return this.context.database.prepare('SELECT * FROM scale_weighings ORDER BY measured_at DESC, created_at DESC').all() as unknown as WeighingRow[]
  }

  private row(id: string): WeighingRow | null {
    return (this.context.database.prepare('SELECT * FROM scale_weighings WHERE id = ?').get(id) as WeighingRow | undefined) ?? null
  }

  private toWeighing(row: WeighingRow, model: BodyFatModel | null): Weighing {
    const profile = JSON.parse(row.profile) as Weighing['profile']
    const weightKg = row.weight_grams / 1000
    const impedance = row.impedance_a !== null && row.impedance_b !== null ? { a: row.impedance_a, b: row.impedance_b } : null
    const scaleBodyFatFraction = row.scale_body_fat_permille === null ? null : row.scale_body_fat_permille / 1000
    const bmi = bmiOf(weightKg, profile.heightCm)
    const bodyFat = this.bodyFat(weightKg, impedance, profile, scaleBodyFatFraction, model)
    return {
      id: row.id,
      measuredAt: row.measured_at,
      weightKg,
      impedance,
      source: row.source,
      timeReliable: row.time_reliable === 1,
      profile,
      scaleBodyFatFraction,
      bodyFat,
      bmi,
      metrics: bodyMetrics(weightKg, bmi, bodyFat?.value ?? null, profile.sex),
      bodyType: bodyType(bmi, bodyFat?.value ?? null, profile.sex),
    }
  }

  /** 秤屏幕读数优先；没测到阻抗（穿鞋、没站稳）不给体脂率；有校准用校准公式，否则按 BMI 估算。 */
  private bodyFat(
    weightKg: number,
    impedance: Weighing['impedance'],
    profile: Weighing['profile'],
    scaleReading: number | null,
    model: BodyFatModel | null,
  ): Weighing['bodyFat'] {
    if (scaleReading !== null) return { value: scaleReading, source: 'scaleReading' }
    if (!impedance) return null
    const calibrated = model ? predictBodyFat(model, weightKg, profile.heightCm, impedance) : null
    if (calibrated !== null) return { value: calibrated, source: 'calibrated' }
    const estimated = estimateBodyFat(weightKg, profile.heightCm, profile.ageYears, profile.sex)
    return estimated === null ? null : { value: estimated, source: 'estimated' }
  }
}
