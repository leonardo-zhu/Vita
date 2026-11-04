/**
 * Vita API 的接口定义（《Vita 2.0 架构设计》§5）。
 *
 * API 用这里的 schema 校验请求、组装响应；Admin 引用同一份类型调 API，接口一改两边编译时就会报错。
 * iOS 按这里手写 Swift 模型。只放跨服务的定义，API 内部用的类型留在 api/。
 */
import { z } from 'zod'

/** 所有错误响应的格式：机器码 + 一句说明，不含内部细节。 */
export const ErrorResponse = z.object({
  error: z.object({
    code: z.string(),
    message: z.string(),
  }),
})
export type ErrorResponse = z.infer<typeof ErrorResponse>

/** GET /v1/health：不需要鉴权，给 Caddy、Docker 健康检查和部署脚本用。 */
export const HealthResponse = z.object({
  ok: z.literal(true),
  version: z.string(),
})
export type HealthResponse = z.infer<typeof HealthResponse>

// MARK: - 设备令牌（架构设计 §8）

/** 手机的设备令牌。只有 Admin（服务令牌）能签发、列出和吊销。 */
export const Device = z.object({
  id: z.uuid(),
  name: z.string(),
  createdAt: z.iso.datetime(),
  lastUsedAt: z.iso.datetime().nullable(),
  revokedAt: z.iso.datetime().nullable(),
})
export type Device = z.infer<typeof Device>

/** POST /v1/admin/devices */
export const CreateDeviceRequest = z.object({
  name: z.string().trim().min(1).max(64),
})
export type CreateDeviceRequest = z.infer<typeof CreateDeviceRequest>

/** 令牌明文只在签发时返回这一次，API 只存哈希。 */
export const CreateDeviceResponse = z.object({
  device: Device,
  token: z.string(),
})
export type CreateDeviceResponse = z.infer<typeof CreateDeviceResponse>

/** GET /v1/admin/devices */
export const ListDevicesResponse = z.object({
  devices: z.array(Device),
})
export type ListDevicesResponse = z.infer<typeof ListDevicesResponse>

/** GET /v1/me：设备令牌验证用，手机填完令牌后调一次确认能连上。 */
export const MeResponse = z.object({
  device: Device,
})
export type MeResponse = z.infer<typeof MeResponse>

// MARK: - 营养与用量（TDD §3.2、§3.3）。营养值在服务端用十进制计算，传输时是普通数字

export const QuantityUnit = z.enum(['g', 'ml'])
export type QuantityUnit = z.infer<typeof QuantityUnit>

export const Quantity = z.object({ amount: z.number(), unit: QuantityUnit })
export type Quantity = z.infer<typeof Quantity>

export const NutrientValues = z.object({
  energyKcal: z.number(),
  proteinG: z.number(),
  fatG: z.number(),
  carbohydrateG: z.number(),
})
export type NutrientValues = z.infer<typeof NutrientValues>

export const AmountSource = z.enum(['userMeasured', 'userStated', 'packageConversion', 'aiEstimated'])
export type AmountSource = z.infer<typeof AmountSource>

export const NutritionSource = z.enum(['personalFoodVersion', 'referenceFood', 'aiEstimated'])
export type NutritionSource = z.infer<typeof NutritionSource>

export const FoodVersionSource = z.enum(['nutritionLabel', 'manualEntry', 'referenceDerived'])
export type FoodVersionSource = z.infer<typeof FoodVersionSource>

/** Item 创建或修改当时的营养快照，同时记录这组数怎么来的。之后不随食品版本或参考库变化。 */
export const NutritionSnapshot = z.object({
  nutritionSource: NutritionSource,
  /** 食品版本 ID 或参考条目 ID；AI 估算为 null。 */
  sourceRef: z.string().nullable(),
  /** 计算基准：每 basisQuantity 含多少营养。AI 估算没有基准。 */
  basisQuantity: Quantity.nullable(),
  basisNutrients: NutrientValues.nullable(),
  /** 参与计算的标准化用量（已换算到基准单位）。 */
  quantityUsed: Quantity.nullable(),
  /** 命中数据源时由服务端计算（client），只有 AI 估算采用模型给的数（model）。 */
  computedBy: z.enum(['client', 'model']),
  estimateBasis: z.string().nullable(),
  values: NutrientValues,
})
export type NutritionSnapshot = z.infer<typeof NutritionSnapshot>

// MARK: - 时间（TDD §3.1）

export const LocalDate = z.iso.date()
export type LocalDate = z.infer<typeof LocalDate>

export const TimePrecision = z.enum(['exact', 'approximate', 'mealPeriod', 'dateOnly', 'defaultedEntryTime'])
export type TimePrecision = z.infer<typeof TimePrecision>

export const MealPeriod = z.enum(['breakfast', 'lunch', 'dinner', 'snack', 'other'])
export type MealPeriod = z.infer<typeof MealPeriod>

/** 摄入发生的本地语义：精度决定哪些字段存在，"中午"不会被写成 12:00。 */
export const EventTime = z.object({
  localDate: LocalDate,
  precision: TimePrecision,
  /** exact / approximate / defaultedEntryTime 才有，ISO 8601。 */
  timestamp: z.iso.datetime({ offset: true }).nullable(),
  mealPeriod: MealPeriod.nullable(),
  timeZone: z.string(),
})
export type EventTime = z.infer<typeof EventTime>

// MARK: - 一天的数据

export const DayItem = z.object({
  id: z.uuid(),
  displayName: z.string(),
  groupName: z.string().nullable(),
  /** 用户原话里的用量，如"2 个鸡蛋、共 108g"。 */
  originalAmountText: z.string(),
  quantity: Quantity.nullable(),
  amountSource: AmountSource,
  includeInSummary: z.boolean(),
  snapshot: NutritionSnapshot,
  /** 来源的可读说明：参考库条目名与数据源、个人食品名；AI 估算为 null。 */
  sourceLabel: z.string().nullable(),
})
export type DayItem = z.infer<typeof DayItem>

export const DayRecord = z.object({
  id: z.uuid(),
  eventTime: EventTime,
  mealLabel: z.string().nullable(),
  note: z.string().nullable(),
  revision: z.number().int(),
  items: z.array(DayItem),
  totals: NutrientValues,
})
export type DayRecord = z.infer<typeof DayRecord>

export const DaySummary = z.object({
  totals: NutrientValues,
  includedItemCount: z.number().int(),
  excludedItemCount: z.number().int(),
  estimatedItemCount: z.number().int(),
})
export type DaySummary = z.infer<typeof DaySummary>

/** GET /v1/days/:date。没有记录的日子 revision 为 0。 */
export const DayResponse = z.object({
  date: LocalDate,
  revision: z.number().int(),
  records: z.array(DayRecord),
  summary: DaySummary,
})
export type DayResponse = z.infer<typeof DayResponse>

// MARK: - 个人食品库（PRD §3.2.1）

export const FoodVersionBasis = z.object({ quantity: Quantity, nutrients: NutrientValues })
export type FoodVersionBasis = z.infer<typeof FoodVersionBasis>

export const FoodVersion = z.object({
  id: z.uuid(),
  basis: FoodVersionBasis,
  sourceKind: FoodVersionSource,
  labelScanId: z.uuid().nullable(),
  derivedFromReferenceId: z.string().nullable(),
  sourceNote: z.string().nullable(),
  createdAt: z.iso.datetime(),
  retiredAt: z.iso.datetime().nullable(),
})
export type FoodVersion = z.infer<typeof FoodVersion>

export const FoodProduct = z.object({
  id: z.uuid(),
  name: z.string(),
  brandOrSupplier: z.string().nullable(),
  package: Quantity.nullable(),
  note: z.string().nullable(),
  activeVersion: FoodVersion.nullable(),
  /** 新的在前。 */
  versions: z.array(FoodVersion),
})
export type FoodProduct = z.infer<typeof FoodProduct>

/** GET /v1/foods */
export const FoodsResponse = z.object({ products: z.array(FoodProduct) })
export type FoodsResponse = z.infer<typeof FoodsResponse>

// MARK: - 公共营养参考库

export const ReferenceFood = z.object({
  id: z.string(),
  canonicalName: z.string(),
  aliases: z.array(z.string()),
  category: z.string(),
  preparationState: z.string(),
  base: z.object({ quantity: z.number(), unit: QuantityUnit }),
  nutrients: NutrientValues,
  densityGPerMl: z.number().nullable(),
  source: z.object({
    provider: z.string(),
    dataType: z.string(),
    externalId: z.string(),
    retrievedFromRelease: z.string(),
    attribution: z.string(),
    region: z.string().nullish(),
    description: z.string().nullish(),
    edibleFraction: z.number().nullish(),
    notes: z.array(z.string()).nullish(),
  }),
  /** 缺省为精选层；扩展层只在精选层没有命中时参与查询。 */
  tier: z.enum(['core', 'extended']).nullish(),
})
export type ReferenceFood = z.infer<typeof ReferenceFood>

/** GET /v1/reference-foods?q=：exact 与 Agent 的精确查询相同，partial 是名称包含查询词的其余条目。 */
export const ReferenceSearchResponse = z.object({
  exact: z.array(ReferenceFood),
  partial: z.array(ReferenceFood),
})
export type ReferenceSearchResponse = z.infer<typeof ReferenceSearchResponse>

// MARK: - 确认卡（ADR-004、TDD §5）

export const RecordChangePreview = z.object({
  kind: z.enum(['create', 'appendItems', 'replaceItem', 'removeItem', 'deleteRecord']),
  recordLabel: z.string().nullable(),
  eventTime: EventTime,
  /** 新增或替换后的 Item（id 只用于展示）。 */
  items: z.array(DayItem),
  /** 被替换、移除或随删除消失的 Item 名称。 */
  removedItemNames: z.array(z.string()),
  totals: NutrientValues,
})
export type RecordChangePreview = z.infer<typeof RecordChangePreview>

export const FoodChangePreview = z.object({
  kind: z.enum(['createProduct', 'addVersion']),
  productName: z.string(),
  brandOrSupplier: z.string().nullable(),
  package: Quantity.nullable(),
  basis: FoodVersionBasis,
  sourceKind: FoodVersionSource,
  /** 新版本取代的旧版本基准，便于对比。 */
  previousBasis: FoodVersionBasis.nullable(),
})
export type FoodChangePreview = z.infer<typeof FoodChangePreview>

export const PendingStatus = z.enum(['readyForConfirmation', 'confirmed', 'cancelled', 'expired'])
export type PendingStatus = z.infer<typeof PendingStatus>

export const Pending = z.object({
  id: z.uuid(),
  sessionDate: LocalDate,
  status: PendingStatus,
  createdAt: z.iso.datetime(),
  expiresAt: z.iso.datetime(),
  /** 结束后清空，只在待确认时展示。 */
  preview: z.discriminatedUnion('type', [
    z.object({ type: z.literal('record'), record: RecordChangePreview }),
    z.object({ type: z.literal('food'), food: FoodChangePreview }),
  ]).nullable(),
  /** 结束原因的机器码，如 replaced、revisionConflict、userCancelled。 */
  resolutionCode: z.string().nullable(),
  /** 已确认时：记录变更是 Record ID，食品变更是 Food Product ID。 */
  resultId: z.uuid().nullable(),
  /** 确认后要接着做的下一步（模型在提案里写的）。 */
  afterConfirm: z.string().nullable(),
})
export type Pending = z.infer<typeof Pending>

/** GET /v1/days/:date/pending：该日期当前可确认的卡片（最多一张）。 */
export const ActivePendingResponse = z.object({ pending: Pending.nullable() })
export type ActivePendingResponse = z.infer<typeof ActivePendingResponse>

/** POST /v1/pending/:id/confirm 与 /cancel */
export const PendingResponse = z.object({ pending: Pending })
export type PendingResponse = z.infer<typeof PendingResponse>
