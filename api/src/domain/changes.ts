/**
 * 写入的"意图"：记录与食品库的变更。确认卡保存的就是它，确认时原样执行（TDD §5.1）。
 * 这些类型只在 API 内部使用，模型的工具参数（M2）先解析成它们再交给服务。
 */
import type { AmountSource, EventTime, FoodVersionBasis, FoodVersionSource, NutrientValues, Quantity } from '@vita/contract'

/** 一个 Item 的营养从哪里来：命中数据源时只给引用，数值由服务端计算；只有 AI 估算才带数值与依据。 */
export type NutritionInput =
  | { source: 'personalFoodVersion'; foodVersionId: string }
  | { source: 'referenceFood'; referenceFoodId: string }
  | { source: 'aiEstimated'; values: NutrientValues; estimateBasis: string }

export interface ItemDraft {
  displayName: string
  groupName: string | null
  /** 用户原话里的用量，原样保留。 */
  originalAmountText: string
  /** 标准化用量；为空时必须是 AI 估算。 */
  quantity: Quantity | null
  amountSource: AmountSource
  nutrition: NutritionInput
  includeInSummary: boolean
}

export interface RecordDraft {
  eventTime: EventTime
  mealLabel: string | null
  note: string | null
  items: ItemDraft[]
}

export type RecordChange =
  | { kind: 'create'; draft: RecordDraft }
  | { kind: 'appendItems'; recordId: string; items: ItemDraft[] }
  | { kind: 'replaceItem'; recordId: string; itemId: string; item: ItemDraft }
  | { kind: 'removeItem'; recordId: string; itemId: string }
  | { kind: 'deleteRecord'; recordId: string }

export function recordAuditAction(change: RecordChange): string {
  return change.kind === 'deleteRecord' ? 'record.delete' : `record.${change.kind}`
}

export interface FoodProductDraft {
  name: string
  brandOrSupplier: string | null
  /** 包装规格，如 250 ml，用于把"一盒、半瓶"换算为用量。 */
  package: Quantity | null
  note: string | null
  /** 用户的常用叫法。 */
  aliases?: string[]
}

/** 不可变食品版本的草稿。没有 AI 估算这一来源：估算值不能沉淀为个人食品（PRD §3.2.1）。 */
export interface FoodVersionDraft {
  basis: FoodVersionBasis
  sourceKind: FoodVersionSource
  /** nutritionLabel 必填：服务端存档的标签照片。 */
  labelScanId: string | null
  /** referenceDerived 必填：作为起点的参考库条目。 */
  derivedFromReferenceId: string | null
  sourceNote: string | null
}

export type FoodChange =
  | { kind: 'createProduct'; product: FoodProductDraft; version: FoodVersionDraft }
  /** 标签、配方或包装变化：同一产品下新建版本并切换生效版本。expectedActiveVersionId 用于发现提案后产品已被更新。 */
  | { kind: 'addVersion'; productId: string; expectedActiveVersionId: string | null; version: FoodVersionDraft }
  /** 对话里改名称、品牌、常用叫法（“这个以后叫 X”）。没给的项不变；aliases 是改后的完整列表。营养值不变。 */
  | {
      kind: 'updateProduct'
      productId: string
      name: string | null
      brandOrSupplier: string | null | undefined
      aliases: string[] | null
      /** 补上或改包装规格（如“一袋 288 g”）；不给不变。 */
      package?: Quantity | null
    }

export type PendingChange = { type: 'record'; change: RecordChange } | { type: 'food'; change: FoodChange }
