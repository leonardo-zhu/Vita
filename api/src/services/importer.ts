/**
 * 从 1.0 迁移（架构设计 §13）：手机导出本机全部数据，这里一次性写入。只在业务库为空时接受，整体一个事务，
 * ID 保持不变（手机上健康同步的映射靠它对上）。每条记录与能写健康的称重都登记一次变化，
 * 手机随后按变更流把健康里的旧数据换成带同步标识的新数据。
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'

import type { ImportBundle, ImportResponse } from '@vita/contract'

import { audit, recordHealthChange, transaction } from '../db.ts'
import { representativeTimestamp } from '../domain/eventTime.ts'
import { ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'
import type { DayService } from './day.ts'

const BUSINESS_TABLES = ['day_sessions', 'consumption_records', 'food_products', 'daily_goals', 'chat_messages', 'scale_weighings', 'label_scans']

export class ImportService {
  private readonly context: ServiceContext
  private readonly filesDir: string
  private readonly days: DayService

  constructor(context: ServiceContext, filesDir: string, days: DayService) {
    this.context = context
    this.filesDir = filesDir
    this.days = days
  }

  run(bundle: ImportBundle, origin: WriteOrigin): ImportResponse {
    const { database, now } = this.context
    for (const table of BUSINESS_TABLES) {
      if (database.prepare(`SELECT 1 FROM ${table} LIMIT 1`).get()) throw new ServiceError('import', 'notEmpty', { table })
    }
    this.checkReferences(bundle)
    const at = now()
    const written: string[] = []
    try {
      transaction(database, () => {
        mkdirSync(this.filesDir, { recursive: true })
        for (const scan of bundle.labelScans) {
          const file = `label-${scan.id}.${scan.contentType.split('/')[1] ?? 'jpeg'}`
          writeFileSync(path.join(this.filesDir, file), Buffer.from(scan.dataBase64, 'base64'))
          written.push(file)
          database.prepare('INSERT INTO label_scans (id, created_at, file, content_type) VALUES (?, ?, ?, ?)').run(scan.id, scan.createdAt, file, scan.contentType)
        }
        for (const s of bundle.sessions) {
          database
            .prepare('INSERT INTO day_sessions (local_date, time_zone, revision, created_at, updated_at) VALUES (?, ?, ?, ?, ?)')
            .run(s.localDate, s.timeZone, s.revision, s.createdAt, s.updatedAt)
        }
        for (const p of bundle.products) {
          database
            .prepare('INSERT INTO food_products (id, name, brand_or_supplier, package, note, active_version_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
            .run(p.id, p.name, p.brandOrSupplier, p.package ? JSON.stringify(p.package) : null, p.note, p.activeVersionId, p.createdAt, p.updatedAt)
          for (const v of p.versions) {
            database
              .prepare(
                'INSERT INTO food_versions (id, product_id, basis, source_kind, label_scan_id, derived_from_reference_id, source_note, created_at, retired_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
              )
              .run(v.id, p.id, JSON.stringify(v.basis), v.sourceKind, v.labelScanId, v.derivedFromReferenceId, v.sourceNote, v.createdAt, v.retiredAt)
          }
        }
        for (const r of bundle.records) {
          database
            .prepare(
              'INSERT INTO consumption_records (id, session_date, event_time, sort_time, meal_label, note, revision, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            )
            .run(r.id, r.sessionDate, JSON.stringify(r.eventTime), representativeTimestamp(r.eventTime).toISOString(), r.mealLabel, r.note, r.revision, r.createdAt, r.updatedAt)
          for (const i of r.items) {
            database
              .prepare(
                `INSERT INTO consumption_items (id, record_id, position, group_name, display_name, original_amount_text, quantity, amount_source, snapshot,
                   include_in_summary, food_product_id, food_version_id, reference_food_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
              )
              .run(
                i.id, r.id, i.position, i.groupName, i.displayName, i.originalAmountText, i.quantity ? JSON.stringify(i.quantity) : null, i.amountSource,
                JSON.stringify(i.snapshot), i.includeInSummary ? 1 : 0, i.foodProductId, i.foodVersionId, i.referenceFoodId, i.createdAt, i.updatedAt,
              )
          }
          recordHealthChange(database, 'record', r.id, at)
        }
        for (const g of bundle.goals) {
          database
            .prepare('INSERT INTO daily_goals (id, effective_from, targets, energy_plan, origin, evidence, revision, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
            .run(g.id, g.effectiveFrom, JSON.stringify(g.targets), g.energyPlan ? JSON.stringify(g.energyPlan) : null, g.origin, g.evidence == null ? null : JSON.stringify(g.evidence), g.revision, g.createdAt)
        }
        for (const m of bundle.messages) {
          database
            .prepare('INSERT INTO chat_messages (id, session_date, role, text, card_ref, created_at) VALUES (?, ?, ?, ?, ?, ?)')
            .run(m.id, m.sessionDate, m.role, m.text, m.cardRef ? `${m.cardRef.type}:${m.cardRef.id}` : null, m.createdAt)
        }
        for (const w of bundle.weighings) {
          database
            .prepare(
              `INSERT INTO scale_weighings (id, measured_at, weight_grams, impedance_a, impedance_b, source, time_reliable, profile, scale_body_fat_permille, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            )
            .run(
              w.id, w.measuredAt, Math.round(w.weightKg * 1000), w.impedance?.a ?? null, w.impedance?.b ?? null, w.source, w.timeReliable ? 1 : 0,
              JSON.stringify(w.profile), w.scaleBodyFatFraction === null ? null : Math.round(w.scaleBodyFatFraction * 1000), w.createdAt,
            )
          recordHealthChange(database, 'weighing', w.id, at)
        }
        if (bundle.manualMetrics) {
          database
            .prepare('INSERT INTO manual_body_metrics (id, data, entered_at) VALUES (1, ?, ?)')
            .run(JSON.stringify(bundle.manualMetrics.metrics), bundle.manualMetrics.enteredAt)
        }
        audit(database, { actor: origin.actor, action: 'import.v1', result: 'success', at })
      })
    } catch (error) {
      // 事务回滚了，已经写下的照片文件不再被引用；留着无害，下次导入同名会覆盖。
      audit(database, { actor: origin.actor, action: 'import.v1', result: 'failure', errorCode: error instanceof ServiceError ? error.auditCode : 'import.persistence', at })
      throw error
    }

    // 从写进去的数据读回来算，证明服务端看到的和手机一致。
    const dailyEnergyKcal: Record<string, number> = {}
    for (const date of new Set(bundle.records.map((r) => r.sessionDate))) dailyEnergyKcal[date] = this.days.day(date).summary.totals.energyKcal
    return {
      counts: {
        sessions: bundle.sessions.length,
        records: bundle.records.length,
        items: bundle.records.reduce((sum, r) => sum + r.items.length, 0),
        products: bundle.products.length,
        versions: bundle.products.reduce((sum, p) => sum + p.versions.length, 0),
        goals: bundle.goals.length,
        messages: bundle.messages.length,
        labelScans: bundle.labelScans.length,
        weighings: bundle.weighings.length,
      },
      dailyEnergyKcal,
    }
  }

  /** 引用都要能对上：记录属于导入的日期、食品版本与标签照片都在包里。对不上就整包拒绝，不写一半。 */
  private checkReferences(bundle: ImportBundle) {
    const fail = (what: string) => new ServiceError('import', 'brokenReference', { what })
    const sessions = new Set(bundle.sessions.map((s) => s.localDate))
    const versions = new Set(bundle.products.flatMap((p) => p.versions.map((v) => v.id)))
    const labels = new Set(bundle.labelScans.map((l) => l.id))
    for (const r of bundle.records) {
      if (!sessions.has(r.sessionDate)) throw fail(`record ${r.id} 的日期 ${r.sessionDate} 没有会话`)
      for (const i of r.items) if (i.foodVersionId && !versions.has(i.foodVersionId)) throw fail(`item ${i.id} 的食品版本`)
    }
    for (const p of bundle.products) {
      if (p.activeVersionId && !p.versions.some((v) => v.id === p.activeVersionId)) throw fail(`product ${p.id} 的生效版本`)
      for (const v of p.versions) if (v.labelScanId && !labels.has(v.labelScanId)) throw fail(`version ${v.id} 的标签照片`)
    }
    for (const m of bundle.messages) if (m.cardRef?.type === 'label' && !labels.has(m.cardRef.id)) throw fail(`message ${m.id} 的标签照片`)
  }
}
