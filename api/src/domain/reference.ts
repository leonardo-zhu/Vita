/**
 * 只读的公共营养参考库（TDD §7、reference-food-library.md）。查询只做规范化后的精确匹配，
 * 结果不唯一时原样返回全部候选，由调用方澄清，绝不替用户选。
 *
 * 数据文件含私有来源，不进仓库、不进镜像（ADR-006），由 VITA_API_REFERENCE_FILE 指向服务器上的文件。
 */
import { readFileSync } from 'node:fs'

import { ReferenceFood } from '@vita/contract'
import { z } from 'zod'

import { isValidNutrients } from './nutrition.ts'

export class ReferenceCatalogError extends Error {}

/**
 * 统一全半角、大小写与空白，不做模糊匹配。与构建脚本 tools/reference-food 的 normalize 一致：
 * NFKC 把全角字母数字转成半角，再转小写、去掉所有空白。
 */
export function normalizeName(name: string): string {
  return name.normalize('NFKC').toLowerCase().replace(/\s+/gu, '')
}

export class ReferenceCatalog {
  static readonly empty = new ReferenceCatalog([])

  private readonly byId = new Map<string, ReferenceFood>()
  private readonly coreByName = new Map<string, string[]>()
  private readonly extendedByName = new Map<string, string[]>()
  /** 全部条目，按 ID 排序。 */
  readonly all: ReferenceFood[]

  constructor(foods: ReferenceFood[]) {
    const seenNames = new Set<string>()
    for (const food of foods) {
      validate(food)
      if (this.byId.has(food.id)) throw new ReferenceCatalogError(`重复 ID ${food.id}`)
      const nameKey = normalizeName(food.canonicalName) + '|' + food.preparationState
      if (seenNames.has(nameKey)) throw new ReferenceCatalogError(`${food.id}: canonicalName + preparationState 重复`)
      seenNames.add(nameKey)
      this.byId.set(food.id, food)
      const index = food.tier === 'extended' ? this.extendedByName : this.coreByName
      for (const name of [food.canonicalName, ...food.aliases]) {
        const key = normalizeName(name)
        const ids = index.get(key) ?? []
        if (!ids.includes(food.id)) index.set(key, [...ids, food.id].sort())
      }
    }
    this.all = [...foods].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  }

  static load(file: string): ReferenceCatalog {
    const parsed = z.array(ReferenceFood).safeParse(JSON.parse(readFileSync(file, 'utf8')))
    if (!parsed.success) throw new ReferenceCatalogError(`参考库格式不对：${parsed.error.message}`)
    return new ReferenceCatalog(parsed.data)
  }

  get count(): number {
    return this.byId.size
  }

  food(id: string): ReferenceFood | null {
    return this.byId.get(id) ?? null
  }

  /**
   * `query` 与额外写法 `aliases` 中任一精确命中即返回，按 ID 排序、去重。
   * 先查精选层；精选层没有命中时才查扩展层，避免日常说法冒出大量候选。
   */
  search(query: string, aliases: string[] = []): ReferenceFood[] {
    const names = [query, ...aliases].map(normalizeName)
    for (const index of [this.coreByName, this.extendedByName]) {
      const ids = new Set(names.flatMap((name) => index.get(name) ?? []))
      if (ids.size > 0) return [...ids].sort().map((id) => this.byId.get(id)!)
    }
    return []
  }

  /** 浏览：exact 与 search 相同；partial 是名称或别名包含查询词、但精确查询不会返回的条目。 */
  browse(query: string): { exact: ReferenceFood[]; partial: ReferenceFood[] } {
    const key = normalizeName(query)
    if (!key) return { exact: [], partial: [] }
    const exact = this.search(query)
    const exactIds = new Set(exact.map((food) => food.id))
    const partial = this.all.filter(
      (food) => !exactIds.has(food.id) && [food.canonicalName, ...food.aliases].some((name) => normalizeName(name).includes(key)),
    )
    return { exact, partial }
  }
}

function validate(food: ReferenceFood) {
  const fail = (reason: string) => new ReferenceCatalogError(`${food.id}: ${reason}`)
  if (!food.id.startsWith('vita.reference.')) throw fail('id 必须以 vita.reference. 开头')
  if (!normalizeName(food.canonicalName)) throw fail('canonicalName 为空')
  if (!food.preparationState) throw fail('preparationState 为空')
  if (food.base.quantity !== 100 || food.base.unit !== 'g') throw fail('基准必须是 100 g')
  if (!isValidNutrients(food.nutrients)) throw fail('营养值为负')
  if (food.densityGPerMl !== null && food.densityGPerMl <= 0) throw fail('密度必须为正')
  if (!food.source.provider || !food.source.externalId || !food.source.attribution) throw fail('来源信息不完整')
}
