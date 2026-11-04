/**
 * 营养来源的可读说明，Data 页与确认卡共用（reference-food-library.md §6）。
 */
import type { ServiceContext } from './context.ts'

export function sourceLabel(context: ServiceContext, referenceFoodId: string | null, foodVersionId: string | null): string | null {
  if (referenceFoodId) {
    // 参考库后来移除了该条目时，仍可凭快照解释数值，只是没有名称。
    const food = context.reference.food(referenceFoodId)
    return food ? `${food.canonicalName} · ${food.source.provider}` : referenceFoodId
  }
  if (foodVersionId) {
    const row = context.database
      .prepare(
        `SELECT p.name, p.brand_or_supplier FROM food_versions v JOIN food_products p ON p.id = v.product_id WHERE v.id = ?`,
      )
      .get(foodVersionId) as { name: string; brand_or_supplier: string | null } | undefined
    return row ? [row.name, row.brand_or_supplier].filter(Boolean).join(' · ') : null
  }
  return null
}
