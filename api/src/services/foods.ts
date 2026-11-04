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
  aliases: string | null
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
    const products = database.prepare('SELECT * FROM food_products WHERE deleted_at IS NULL ORDER BY name').all() as unknown as ProductRow[]
    const versions = database.prepare('SELECT * FROM food_versions ORDER BY created_at DESC, rowid DESC').all() as unknown as VersionRow[]
    return products.map((product) => toProduct(product, versions.filter((version) => version.product_id === product.id)))
  }

  /** 名称、品牌或常用叫法包含查询词（忽略全半角、大小写与空白）。个人库很小，不做索引。 */
  search(query: string): FoodProduct[] {
    const key = normalizeName(query)
    if (!key) return []
    return this.products().filter((product) =>
      [product.name, product.brandOrSupplier ?? '', ...product.aliases].some((name) => normalizeName(name).includes(key)),
    )
  }

  preview(change: FoodChange): FoodChangePreview {
    return this.prepare(change).preview
  }

  apply(change: FoodChange, options: FoodApplyOptions): string {
    const { database, now } = this.context
    const action = `food.${change.kind}`
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

  // MARK: - 用户直接编辑（PRD v2.0 §4.1）。营养值不能就地改：改营养存为新版本，旧版本保留，已有记录的快照不变

  product(id: string): FoodProduct {
    const row = this.context.database.prepare('SELECT * FROM food_products WHERE id = ? AND deleted_at IS NULL').get(id) as ProductRow | undefined
    if (!row) throw new ServiceError('food', 'productNotFound')
    const versions = this.context.database
      .prepare('SELECT * FROM food_versions WHERE product_id = ? ORDER BY created_at DESC, rowid DESC')
      .all(id) as unknown as VersionRow[]
    return toProduct(row, versions)
  }

  /** 改名称、品牌、常用叫法、包装规格、备注；没给的项不变。 */
  updateProduct(
    id: string,
    changes: { name?: string; brandOrSupplier?: string | null; aliases?: string[]; package?: FoodProduct['package']; note?: string | null },
    origin: WriteOrigin,
  ): FoodProduct {
    const { database, now } = this.context
    return this.write('food.edit', id, origin, () => {
      const current = this.product(id)
      const name = changes.name === undefined ? current.name : changes.name.trim()
      if (!name) throw new ServiceError('food', 'emptyName')
      const pack = changes.package === undefined ? current.package : changes.package
      if (pack && !(pack.amount > 0)) throw new ServiceError('food', 'invalidPackage')
      const brand = changes.brandOrSupplier === undefined ? current.brandOrSupplier : changes.brandOrSupplier?.trim() || null
      const note = changes.note === undefined ? current.note : changes.note?.trim() || null
      const aliases = changes.aliases === undefined ? current.aliases : cleanAliases(changes.aliases, name)
      database
        .prepare('UPDATE food_products SET name = ?, brand_or_supplier = ?, package = ?, note = ?, aliases = ?, updated_at = ? WHERE id = ?')
        .run(name, brand, pack ? JSON.stringify(pack) : null, note, aliasesColumn(aliases), now().toISOString(), id)
      return this.product(id)
    })
  }

  /** 手动改营养值：存为新版本（manualEntry）并切换生效版本。expectedActiveVersionId 防止和别处的修改互相覆盖。 */
  addManualVersion(
    id: string,
    expectedActiveVersionId: string | null,
    basis: FoodVersionBasis,
    sourceNote: string | null,
    origin: WriteOrigin,
  ): FoodProduct {
    this.apply(
      {
        kind: 'addVersion',
        productId: id,
        expectedActiveVersionId,
        version: { basis, sourceKind: 'manualEntry', labelScanId: null, derivedFromReferenceId: null, sourceNote: sourceNote?.trim() || '手动修改' },
      },
      origin,
    )
    return this.product(id)
  }

  /** 删除只做标记：不再出现在食品库和模型的上下文里，也不能再用来记新的；已有记录照旧。 */
  deleteProduct(id: string, origin: WriteOrigin) {
    const { database, now } = this.context
    this.write('food.delete', id, origin, () => {
      this.product(id)
      database.prepare('UPDATE food_products SET deleted_at = ?, updated_at = ? WHERE id = ?').run(now().toISOString(), now().toISOString(), id)
    })
  }

  private write<T>(action: string, id: string, origin: WriteOrigin, body: () => T): T {
    const { database, now } = this.context
    try {
      return transaction(database, () => {
        const result = body()
        audit(database, { actor: origin.actor, action, targetId: id, result: 'success', requestId: origin.requestId, at: now() })
        return result
      })
    } catch (error) {
      const code = error instanceof ServiceError ? error.auditCode : 'food.persistence'
      audit(database, { actor: origin.actor, action, targetId: id, result: 'failure', errorCode: code, requestId: origin.requestId, at: now() })
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
            aliases: cleanAliases(product.aliases ?? [], product.name),
            previous: null,
            basis: version.basis,
            sourceKind: version.sourceKind,
            previousBasis: null,
          },
          commit: () => {
            const at = this.context.now().toISOString()
            const id = randomUUID()
            database
              .prepare('INSERT INTO food_products (id, name, brand_or_supplier, package, note, aliases, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
              .run(
                id,
                product.name,
                product.brandOrSupplier,
                product.package ? JSON.stringify(product.package) : null,
                product.note,
                aliasesColumn(cleanAliases(product.aliases ?? [], product.name)),
                at,
                at,
              )
            this.insertVersion(version, id, at)
            return id
          },
        }
      }

      case 'addVersion': {
        const product = database.prepare('SELECT * FROM food_products WHERE id = ? AND deleted_at IS NULL').get(change.productId) as ProductRow | undefined
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
            aliases: parseAliases(product.aliases),
            previous: null,
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

      case 'updateProduct': {
        const current = this.product(change.productId)
        if (!current.activeVersion) throw new ServiceError('food', 'productNotFound')
        const name = change.name?.trim() || current.name
        const brand = change.brandOrSupplier === undefined ? current.brandOrSupplier : change.brandOrSupplier?.trim() || null
        const aliases = change.aliases === null ? current.aliases : cleanAliases(change.aliases, name)
        if (name === current.name && brand === current.brandOrSupplier && isDeepStrictEqual(aliases, current.aliases)) {
          throw new ServiceError('food', 'nothingToChange')
        }
        return {
          preview: {
            kind: 'updateProduct',
            productName: name,
            brandOrSupplier: brand,
            package: current.package,
            aliases,
            previous: { name: current.name, brandOrSupplier: current.brandOrSupplier, aliases: current.aliases },
            basis: current.activeVersion.basis,
            sourceKind: current.activeVersion.sourceKind,
            previousBasis: null,
          },
          commit: () => {
            database
              .prepare('UPDATE food_products SET name = ?, brand_or_supplier = ?, aliases = ?, updated_at = ? WHERE id = ?')
              .run(name, brand, aliasesColumn(aliases), this.context.now().toISOString(), current.id)
            return current.id
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
    aliases: parseAliases(row.aliases),
    activeVersion: versions.find((version) => version.id === row.active_version_id) ?? null,
    versions,
  }
}

function parseAliases(raw: string | null): string[] {
  return raw ? (JSON.parse(raw) as string[]) : []
}

function aliasesColumn(aliases: string[]): string | null {
  return aliases.length ? JSON.stringify(aliases) : null
}

/** 去空白、去重，去掉和名称一样的。 */
function cleanAliases(aliases: string[], name: string): string[] {
  const seen = new Set([normalizeName(name)])
  const result: string[] = []
  for (const alias of aliases) {
    const trimmed = alias.trim()
    const key = normalizeName(trimmed)
    if (!trimmed || seen.has(key)) continue
    seen.add(key)
    result.push(trimmed)
  }
  return result.slice(0, 20)
}
