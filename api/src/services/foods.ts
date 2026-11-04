/**
 * 个人食品库（PRD §3.2.1，移植自 1.0 的 FoodService）。变更只经确认卡执行；食品版本一经创建不再修改。
 */
import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'

import type { FoodChangePreview, FoodProduct, FoodVersion, FoodVersionBasis } from '@vita/contract'

import { audit, transaction } from '../db.ts'
import type { FoodChange, FoodVersionDraft } from '../domain/changes.ts'
import { isValidNutrients } from '../domain/nutrition.ts'
import { normalizeName } from '../domain/reference.ts'
import { ServiceError, type ServiceContext, type WriteOrigin } from './context.ts'

interface ProductRow {
  id: string
  name: string
  brand_or_supplier: string | null
  package: string | null
  note: string | null
  active_version_id: string | null
}

interface VersionRow {
  id: string
  product_id: string
  basis: string
  source_kind: FoodVersion['sourceKind']
  label_scan_id: string | null
  derived_from_reference_id: string | null
  source_note: string | null
  created_at: string
  retired_at: string | null
}

interface Prepared {
  preview: FoodChangePreview
  /** 返回产品 ID。 */
  commit: () => string
}

export interface FoodApplyOptions extends WriteOrigin {
  /** 与变更同一事务，确认卡用它一并更新自己的状态。 */
  alongside?: (productId: string) => void
}

export class FoodService {
  private readonly context: ServiceContext

  constructor(context: ServiceContext) {
    this.context = context
  }

  /** 按名称排序。 */
  products(): FoodProduct[] {
    const { database } = this.context
    const products = database.prepare('SELECT * FROM food_products ORDER BY name').all() as unknown as ProductRow[]
    const versions = database.prepare('SELECT * FROM food_versions ORDER BY created_at DESC, rowid DESC').all() as unknown as VersionRow[]
    return products.map((product) => toProduct(product, versions.filter((version) => version.product_id === product.id)))
  }

  /** 名称或品牌包含查询词（忽略全半角、大小写与空白）。个人库很小，不做索引。 */
  search(query: string): FoodProduct[] {
    const key = normalizeName(query)
    if (!key) return []
    return this.products().filter((product) => [product.name, product.brandOrSupplier ?? ''].some((name) => normalizeName(name).includes(key)))
  }

  preview(change: FoodChange): FoodChangePreview {
    return this.prepare(change).preview
  }

  apply(change: FoodChange, options: FoodApplyOptions): string {
    const { database, now } = this.context
    const action = change.kind === 'createProduct' ? 'food.createProduct' : 'food.addVersion'
    try {
      return transaction(database, () => {
        const productId = this.prepare(change).commit()
        options.alongside?.(productId)
        audit(database, { actor: options.actor, action, targetId: productId, result: 'success', requestId: options.requestId, at: now() })
        return productId
      })
    } catch (error) {
      const code = error instanceof ServiceError ? error.auditCode : 'food.persistence'
      audit(database, { actor: options.actor, action, result: 'failure', errorCode: code, requestId: options.requestId, at: now() })
      throw error
    }
  }

  private prepare(change: FoodChange): Prepared {
    const { database } = this.context
    switch (change.kind) {
      case 'createProduct': {
        const { product, version } = change
        if (!product.name.trim()) throw new ServiceError('food', 'emptyName')
        if (product.package && !(product.package.amount > 0)) throw new ServiceError('food', 'invalidPackage')
        this.validate(version)
        return {
          preview: {
            kind: 'createProduct',
            productName: product.name,
            brandOrSupplier: product.brandOrSupplier,
            package: product.package,
            basis: version.basis,
            sourceKind: version.sourceKind,
            previousBasis: null,
          },
          commit: () => {
            const at = this.context.now().toISOString()
            const id = randomUUID()
            database
              .prepare('INSERT INTO food_products (id, name, brand_or_supplier, package, note, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
              .run(id, product.name, product.brandOrSupplier, product.package ? JSON.stringify(product.package) : null, product.note, at, at)
            this.insertVersion(version, id, at)
            return id
          },
        }
      }

      case 'addVersion': {
        const product = database.prepare('SELECT * FROM food_products WHERE id = ?').get(change.productId) as ProductRow | undefined
        if (!product) throw new ServiceError('food', 'productNotFound')
        if (product.active_version_id !== change.expectedActiveVersionId) throw new ServiceError('food', 'activeVersionChanged')
        this.validate(change.version)
        const previous = product.active_version_id
          ? (database.prepare('SELECT * FROM food_versions WHERE id = ?').get(product.active_version_id) as VersionRow | undefined)
          : undefined
        return {
          preview: {
            kind: 'addVersion',
            productName: product.name,
            brandOrSupplier: product.brand_or_supplier,
            package: product.package ? JSON.parse(product.package) : null,
            basis: change.version.basis,
            sourceKind: change.version.sourceKind,
            previousBasis: previous ? (JSON.parse(previous.basis) as FoodVersionBasis) : null,
          },
          commit: () => {
            const at = this.context.now().toISOString()
            if (previous) database.prepare('UPDATE food_versions SET retired_at = ? WHERE id = ?').run(at, previous.id)
            this.insertVersion(change.version, product.id, at)
            return product.id
          },
        }
      }
    }
  }

  private validate(version: FoodVersionDraft) {
    const { basis } = version
    if (!(basis.quantity.amount > 0) || !isValidNutrients(basis.nutrients)) throw new ServiceError('food', 'invalidBasis')
    switch (version.sourceKind) {
      case 'nutritionLabel': {
        const scan = version.labelScanId ? this.context.database.prepare('SELECT id FROM label_scans WHERE id = ?').get(version.labelScanId) : undefined
        if (!scan) throw new ServiceError('food', 'unknownLabel')
        break
      }
      case 'referenceDerived': {
        const food = version.derivedFromReferenceId ? this.context.reference.food(version.derivedFromReferenceId) : null
        if (!food) throw new ServiceError('food', 'unknownReferenceFood')
        const expected: FoodVersionBasis = { quantity: { amount: food.base.quantity, unit: food.base.unit }, nutrients: food.nutrients }
        if (!isDeepStrictEqual(basis, expected)) throw new ServiceError('food', 'basisDiffersFromReference')
        break
      }
      case 'manualEntry':
        break
    }
  }

  private insertVersion(draft: FoodVersionDraft, productId: string, at: string) {
    const { database } = this.context
    const id = randomUUID()
    database
      .prepare(
        `INSERT INTO food_versions (id, product_id, basis, source_kind, label_scan_id, derived_from_reference_id, source_note, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(id, productId, JSON.stringify(draft.basis), draft.sourceKind, draft.labelScanId, draft.derivedFromReferenceId, draft.sourceNote, at)
    database.prepare('UPDATE food_products SET active_version_id = ?, updated_at = ? WHERE id = ?').run(id, at, productId)
  }
}

function toVersion(row: VersionRow): FoodVersion {
  return {
    id: row.id,
    basis: JSON.parse(row.basis),
    sourceKind: row.source_kind,
    labelScanId: row.label_scan_id,
    derivedFromReferenceId: row.derived_from_reference_id,
    sourceNote: row.source_note,
    createdAt: row.created_at,
    retiredAt: row.retired_at,
  }
}

function toProduct(row: ProductRow, versionRows: VersionRow[]): FoodProduct {
  const versions = versionRows.map(toVersion)
  return {
    id: row.id,
    name: row.name,
    brandOrSupplier: row.brand_or_supplier,
    package: row.package ? JSON.parse(row.package) : null,
    note: row.note,
    activeVersion: versions.find((version) => version.id === row.active_version_id) ?? null,
    versions,
  }
}
