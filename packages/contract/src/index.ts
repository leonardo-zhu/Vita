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

// MARK: - 目标与能量（TDD §6.2、ADR-018）

/** 每日目标值；未设的项为 null。 */
export const GoalTargets = z.object({
  energyKcal: z.number().positive().nullable(),
  proteinG: z.number().positive().nullable(),
  fatG: z.number().positive().nullable(),
  carbohydrateG: z.number().positive().nullable(),
})
export type GoalTargets = z.infer<typeof GoalTargets>

export const GoalKind = z.enum(['maintain', 'lose', 'gain'])
export type GoalKind = z.infer<typeof GoalKind>

/** 相对每日消耗的调整：比例（0.85 = 少吃 15%，0.5–1.5）或千卡（−400 = 每天少吃 400，−1500…+1500）。 */
export const EnergyAdjustment = z.discriminatedUnion('type', [
  z.object({ type: z.literal('fraction'), value: z.number().min(0.5).max(1.5) }),
  z.object({ type: z.literal('kcal'), value: z.number().min(-1500).max(1500) }),
])
export type EnergyAdjustment = z.infer<typeof EnergyAdjustment>

/** 能量目标的规则：存规则而不是一个数，每天按当天活动算出目标。没有它的目标是固定能量目标。 */
export const EnergyPlan = z.object({
  kind: GoalKind,
  adjustment: EnergyAdjustment,
  bmrKcal: z.number(),
  /** 设定时的平时活动（7 日日均）；读不到当天活动时用它。 */
  baselineActivityKcal: z.number(),
  /** 平时活动是否按 BMR × 0.375 估算。 */
  baselineEstimated: z.boolean(),
})
export type EnergyPlan = z.infer<typeof EnergyPlan>

export const GoalOrigin = z.enum(['initialRecommendation', 'explicitUserCommand', 'manualOnboarding'])
export type GoalOrigin = z.infer<typeof GoalOrigin>

export const Goal = z.object({
  id: z.uuid(),
  effectiveFrom: LocalDate,
  targets: GoalTargets,
  energyPlan: EnergyPlan.nullable(),
  origin: GoalOrigin,
  revision: z.number().int(),
})
export type Goal = z.infer<typeof Goal>

/** 某天的能量目标与它的来历，供 Data 页解释数字为什么变了。 */
export const EnergyTarget = z.object({
  targetKcal: z.number(),
  bmrKcal: z.number(),
  baselineActivityKcal: z.number(),
  /** 当天活动预估：今天是"已消耗 + 平时 × 剩余比例"，过去是全天实际。 */
  projectedActivityKcal: z.number(),
  /** 计入消耗的活动：超出平时的部分打了折。 */
  countedActivityKcal: z.number(),
  tdeeKcal: z.number(),
  /** 目标相对消耗的调整（负数为缺口）。 */
  adjustmentKcal: z.number(),
  raisedToBMR: z.boolean(),
  /** 没有当天的活动数据，按平时活动估算。 */
  activityEstimated: z.boolean(),
})
export type EnergyTarget = z.infer<typeof EnergyTarget>

/** 截至现在的热量收支：balance 为负表示缺口。 */
export const EnergyBalance = z.object({
  burnedKcal: z.number(),
  consumedKcal: z.number(),
  balanceKcal: z.number(),
})
export type EnergyBalance = z.infer<typeof EnergyBalance>

export const DaySummary = z.object({
  totals: NutrientValues,
  includedItemCount: z.number().int(),
  excludedItemCount: z.number().int(),
  estimatedItemCount: z.number().int(),
  /** 生效目标。能量目标随活动计算时，targets.energyKcal 已换成这一天算出的值。 */
  goal: Goal.nullable(),
  /** 能量目标随活动计算时的来历；固定目标为 null。 */
  energy: EnergyTarget.nullable(),
  /** 没有活动数据或没有随活动计算的目标时为 null。 */
  balance: EnergyBalance.nullable(),
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

/** GET /v1/pending/:id、POST /v1/pending/:id/confirm 与 /cancel */
export const PendingResponse = z.object({ pending: Pending })
export type PendingResponse = z.infer<typeof PendingResponse>

// MARK: - 健康数据（TDD §6.1）。手机读 Apple 健康后上传，服务端只存最新一份，用于目标与 Agent

export const MetricSource = z.enum(['healthKit', 'manual'])
export type MetricSource = z.infer<typeof MetricSource>

export const BiologicalSex = z.enum(['female', 'male', 'other'])
export type BiologicalSex = z.infer<typeof BiologicalSex>

/** 读取结果区分有数据 / 无数据 / 查询失败，不能把授权当成数据存在。 */
function reading<T extends z.ZodType>(value: T) {
  return z.discriminatedUnion('status', [
    z.object({ status: z.literal('value'), value, source: MetricSource, measuredAt: z.iso.datetime().nullable() }),
    z.object({ status: z.literal('noData') }),
    z.object({ status: z.literal('failed'), message: z.string() }),
  ])
}

/** PUT /v1/health/snapshot：手机读到的身体数据。活动能量单独上传（见 ActivityUpload）。 */
export const HealthUpload = z.object({
  bodyMassKg: reading(z.number()),
  heightCm: reading(z.number()),
  /** 0–1。 */
  bodyFatFraction: reading(z.number()),
  dateOfBirth: reading(LocalDate),
  sex: reading(BiologicalSex),
  /** 前一晚睡眠时长（小时）。 */
  sleepHours: reading(z.number()),
  authorizationRequested: z.boolean(),
  writeDenied: z.boolean(),
})
export type HealthUpload = z.infer<typeof HealthUpload>

/** GET /v1/health/snapshot?date=：上传的身体数据、手动补录的兜底，加上服务端按活动记录算出的当日与 7 日日均。 */
export const HealthSnapshot = HealthUpload.extend({
  activeEnergyKcal: reading(z.number()),
  /** 这一天之前 7 个完整日里有数据的那些天的日均；不足 3 天时没有。 */
  averageActiveEnergyKcal: reading(z.number()),
  /** 手机最后一次上传身体数据的时间；从没上传过为 null。 */
  uploadedAt: z.iso.datetime().nullable(),
})
export type HealthSnapshot = z.infer<typeof HealthSnapshot>

/** PUT /v1/health/activity：若干天的活动能量。今天的是截至现在的累计，过去的是全天；null 表示没有数据。 */
export const ActivityUpload = z.object({
  days: z.array(z.object({ date: LocalDate, activeKcal: z.number().min(0).nullable() })).min(1).max(31),
})
export type ActivityUpload = z.infer<typeof ActivityUpload>

/** PUT /v1/health/manual-metrics：用户补录的身体数据。只覆盖给出的项，没给的沿用上一次；只用于目标生成，不写回 Apple 健康。 */
export const ManualBodyMetrics = z.object({
  bodyMassKg: z.number().min(20).max(400).nullish(),
  heightCm: z.number().min(80).max(250).nullish(),
  bodyFatFraction: z.number().min(0.02).max(0.7).nullish(),
  dateOfBirth: LocalDate.nullish(),
  sex: BiologicalSex.nullish(),
})
export type ManualBodyMetrics = z.infer<typeof ManualBodyMetrics>

// MARK: - 目标建议与设定

/** POST /v1/goals/recommendation 与 /v1/goals/initial：按服务端存的健康数据计算，客户端只选类型和调整。 */
export const GoalRecommendationRequest = z.object({
  date: LocalDate,
  kind: GoalKind.optional(),
  adjustment: EnergyAdjustment.optional(),
})
export type GoalRecommendationRequest = z.infer<typeof GoalRecommendationRequest>

export const MissingMetric = z.enum(['bodyMass', 'height', 'dateOfBirth', 'sex'])
export type MissingMetric = z.infer<typeof MissingMetric>

export const GoalRecommendation = z.object({
  input: z.object({
    bodyMassKg: z.number(),
    weightSource: MetricSource,
    heightCm: z.number(),
    heightSource: MetricSource,
    ageYears: z.number().int(),
    ageSource: MetricSource,
    sex: BiologicalSex,
    sexSource: MetricSource,
    /** 平时活动（7 日日均）；没有时按轻度活动系数估算。 */
    activeEnergyKcal: z.number().nullable(),
  }),
  bmrKcal: z.number(),
  tdeeKcal: z.number(),
  tdeeEstimated: z.boolean(),
  targets: GoalTargets,
  energyPlan: EnergyPlan,
  generatedAt: z.iso.datetime(),
  policyVersion: z.number().int(),
})
export type GoalRecommendation = z.infer<typeof GoalRecommendation>

/** 体重、身高、出生日期、性别缺一项就不能建议，返回缺哪些。 */
export const GoalRecommendationResponse = z.discriminatedUnion('status', [
  z.object({ status: z.literal('ready'), recommendation: GoalRecommendation }),
  z.object({ status: z.literal('missing'), missing: z.array(MissingMetric) }),
])
export type GoalRecommendationResponse = z.infer<typeof GoalRecommendationResponse>

/** GET /v1/goals/active?date= 与 POST /v1/goals/initial */
export const GoalResponse = z.object({ goal: Goal.nullable() })
export type GoalResponse = z.infer<typeof GoalResponse>

// MARK: - 身体成分（身体成分模块）。蓝牙连秤与写 Apple 健康在手机上；称重存在服务端，指标读取时现算

export const Impedance = z.object({ a: z.number().int().positive(), b: z.number().int().positive() })
export type Impedance = z.infer<typeof Impedance>

/** live：打开称重页时站上去的；offline：秤里存着、同步过来的离线记录。 */
export const WeighingSource = z.enum(['live', 'offline'])
export type WeighingSource = z.infer<typeof WeighingSource>

/** POST /v1/weighings：秤锁定的一次称重。id 由手机生成，重传同一个 id 不会重复记录。 */
export const WeighingUpload = z.object({
  id: z.uuid(),
  weightKg: z.number().positive(),
  /** 光脚站上去才测得到；没有时不估算体脂率。 */
  impedance: Impedance.nullable(),
  source: WeighingSource,
  /** 离线记录的称重时间；没有或晚于现在（秤的时钟不对）时按现在记，并标为时间不可靠。 */
  recordedAt: z.iso.datetime().nullable(),
  /** 手机能否把这次称重写进 Apple 健康。不能时服务端把体重与体脂率记为手动补录，目标生成照样用得上。 */
  appleHealthWritable: z.boolean(),
})
export type WeighingUpload = z.infer<typeof WeighingUpload>

export const BodyRating = z.enum(['low', 'standard', 'high', 'veryHigh', 'excellent'])
export type BodyRating = z.infer<typeof BodyRating>

export const BodyMetricKind = z.enum([
  'weight', 'bmi', 'bodyFat', 'leanMass', 'basalMetabolism',
  'fatMass', 'subcutaneousFatRate', 'subcutaneousFatMass',
  'muscleMass', 'muscleRate', 'skeletalMuscleMass', 'skeletalMuscleRate', 'waterRate', 'waterMass', 'proteinMass', 'proteinRate', 'boneMass',
])
export type BodyMetricKind = z.infer<typeof BodyMetricKind>

/** 判定区间：bounds 从小到大，ratings 比它多一项；值等于边界时归入较高的一段。 */
export const BodyRange = z.object({ bounds: z.array(z.number()), ratings: z.array(BodyRating) })
export type BodyRange = z.infer<typeof BodyRange>

/** 一项指标。比例类（体脂率等）的值是 0–1。没有对应人群区间（目前只内置成年男性）时 range 与 rating 为 null。 */
export const BodyMetric = z.object({
  kind: BodyMetricKind,
  value: z.number(),
  range: BodyRange.nullable(),
  rating: BodyRating.nullable(),
})
export type BodyMetric = z.infer<typeof BodyMetric>

export const Weighing = z.object({
  id: z.uuid(),
  measuredAt: z.iso.datetime(),
  weightKg: z.number(),
  impedance: Impedance.nullable(),
  source: WeighingSource,
  /** false：离线记录没有可靠时间，measuredAt 是同步时间。 */
  timeReliable: z.boolean(),
  /** 称重当时的身高、年龄、性别，指标按它算。 */
  profile: z.object({ heightCm: z.number().nullable(), ageYears: z.number().int().nullable(), sex: BiologicalSex.nullable() }),
  /** 用户照着秤屏幕记下的体脂率（0–1），用来校准。 */
  scaleBodyFatFraction: z.number().nullable(),
  /** scaleReading：秤屏幕读数；calibrated：校准公式算出，应与秤显示一致；estimated：按 BMI、年龄、性别估算。 */
  bodyFat: z.object({ value: z.number(), source: z.enum(['scaleReading', 'calibrated', 'estimated']) }).nullable(),
  bmi: z.number().nullable(),
  /** 没有体脂率时只有体重和 BMI。 */
  metrics: z.array(BodyMetric),
  /** BMI 与体脂率的九宫格，只有已知区间的人群（成年男性）给出。 */
  bodyType: z.object({ name: z.string(), explanation: z.string() }).nullable(),
})
export type Weighing = z.infer<typeof Weighing>

/** 由用户记下的秤读数拟合出的体脂率公式：体脂率 = a · 身高² / 阻抗 + b · 体重 + c。 */
export const BodyFatModel = z.object({
  channel: z.enum(['a', 'b']),
  heightSquaredOverImpedance: z.number(),
  weight: z.number(),
  constant: z.number(),
  sampleCount: z.number().int(),
  /** 留一法交叉验证的平均绝对误差（0–1）。 */
  meanAbsoluteError: z.number(),
})
export type BodyFatModel = z.infer<typeof BodyFatModel>

export const BodyFatCalibration = z.object({
  readingCount: z.number().int(),
  model: BodyFatModel.nullable(),
  /** 误差足够小、已用来替代 BMI 估算。 */
  applied: z.boolean(),
})
export type BodyFatCalibration = z.infer<typeof BodyFatCalibration>

/** GET /v1/weighings：新的在前。 */
export const WeighingsResponse = z.object({ weighings: z.array(Weighing), calibration: BodyFatCalibration })
export type WeighingsResponse = z.infer<typeof WeighingsResponse>

export const WeighingResponse = z.object({ weighing: Weighing })
export type WeighingResponse = z.infer<typeof WeighingResponse>

/** PUT /v1/weighings/:id/scale-reading：记下或清掉（null）秤屏幕上的体脂率。 */
export const ScaleReadingRequest = z.object({ bodyFatFraction: z.number().min(0.02).max(0.7).nullable() })
export type ScaleReadingRequest = z.infer<typeof ScaleReadingRequest>

/** calibrationChanged 为 true 时，采用的公式变了，全部称重的体脂率都可能变化，手机要重写 Apple 健康里的历史。 */
export const ScaleReadingResponse = z.object({ weighing: Weighing, calibrationChanged: z.boolean() })
export type ScaleReadingResponse = z.infer<typeof ScaleReadingResponse>

// MARK: - 对话（TDD §3.4、架构设计 §10）。Agent 在服务端跑，进度以 SSE 推给手机

/** 消息附带的卡片：指向确认卡，或用户发的营养标签照片。 */
export const CardRef = z.object({ type: z.enum(['pending', 'label']), id: z.uuid() })
export type CardRef = z.infer<typeof CardRef>

export const ChatMessage = z.object({
  id: z.uuid(),
  role: z.enum(['user', 'assistant']),
  text: z.string(),
  cardRef: CardRef.nullable(),
  createdAt: z.iso.datetime(),
})
export type ChatMessage = z.infer<typeof ChatMessage>

/** GET /v1/days/:date/messages：按时间顺序。 */
export const MessagesResponse = z.object({ messages: z.array(ChatMessage) })
export type MessagesResponse = z.infer<typeof MessagesResponse>

/** POST /v1/days/:date/chat：照片先经 POST /v1/label-scans 上传，再带上 labelScanId。 */
export const ChatRequest = z.object({
  text: z.string().max(4000),
  labelScanId: z.uuid().nullish(),
})
export type ChatRequest = z.infer<typeof ChatRequest>

/** POST /v1/label-scans（请求体是 JPEG 本身）。 */
export const LabelScanResponse = z.object({ labelScanId: z.uuid() })
export type LabelScanResponse = z.infer<typeof LabelScanResponse>

/**
 * 一轮对话的 SSE 事件（event 名同 type，data 是这个 JSON）。顺序：started → 若干 reasoning / text / step → done 或 error。
 * 文字与推理是增量，客户端自己拼；推理只在生成时展示，不保存。断线后这一轮在服务端照样跑完并保存，重连后读历史即可。
 */
export const ChatEvent = z.discriminatedUnion('type', [
  /** 停止时用它调 POST /v1/chat-turns/:requestId/cancel。 */
  z.object({ type: z.literal('started'), requestId: z.uuid() }),
  z.object({ type: z.literal('reasoning'), delta: z.string() }),
  z.object({ type: z.literal('text'), delta: z.string() }),
  /** 一次工具调用：先 running，结束时 done 或 failed（工具返回错误，模型通常会据此改正）。 */
  z.object({ type: z.literal('step'), index: z.number().int(), tool: z.string(), status: z.enum(['running', 'done', 'failed']) }),
  z.object({
    type: z.literal('done'),
    /** 保存后的助手回复；附带确认卡时 cardRef 指向它。 */
    reply: ChatMessage,
    pendingId: z.uuid().nullable(),
    /** 模型提到了别的日期：只提示切换，不自动跳转。 */
    requestedDate: LocalDate.nullable(),
    goalChanged: z.boolean(),
  }),
  /** 这一轮没有保存（用户消息也没有），客户端把原文放回输入框。 */
  z.object({ type: z.literal('error'), code: z.string(), message: z.string() }),
])
export type ChatEvent = z.infer<typeof ChatEvent>

// MARK: - Apple 健康同步（架构设计 §9）。手机按游标拉取变更，按最新状态覆盖健康里的那份

/** 一项营养的 Sample：每项一条，值为计入汇总的 Item 之和，为 0 的不写。 */
export const DietarySample = z.object({
  nutrient: z.enum(['energyKcal', 'proteinG', 'fatG', 'carbohydrateG']),
  value: z.number(),
  /** 代表性时刻：餐段取代表性时间、仅日期取 12:00，metadata 里注明。 */
  date: z.iso.datetime(),
  metadata: z.record(z.string(), z.string()),
})
export type DietarySample = z.infer<typeof DietarySample>

/** 一次称重写进健康的体重、体脂率与去脂体重；没有体脂率时只写体重。 */
export const BodySample = z.object({
  bodyMassKg: z.number(),
  bodyFatFraction: z.number().nullable(),
  leanBodyMassKg: z.number().nullable(),
  date: z.iso.datetime(),
})
export type BodySample = z.infer<typeof BodySample>

/**
 * 一个对象的最新状态。deleted 为 true 时把健康里的那份删掉；否则先删旧的再写这些 Sample。
 * syncVersion 单调递增，可作为 HKMetadataKeySyncVersion；同一对象的标识是 `vita:<entity>:<id>`。
 */
export const HealthChange = z.discriminatedUnion('entity', [
  z.object({ seq: z.number().int(), entity: z.literal('record'), id: z.uuid(), deleted: z.boolean(), syncVersion: z.number().int(), samples: z.array(DietarySample) }),
  z.object({ seq: z.number().int(), entity: z.literal('weighing'), id: z.uuid(), deleted: z.boolean(), syncVersion: z.number().int(), body: BodySample.nullable() }),
])
export type HealthChange = z.infer<typeof HealthChange>

/** GET /v1/health-sync/changes?after=<cursor>：同一对象只给最新一条。处理完后把 cursor 存下，下次从它之后拉；hasMore 为 true 时接着拉。 */
export const HealthChangesResponse = z.object({
  changes: z.array(HealthChange),
  cursor: z.number().int(),
  hasMore: z.boolean(),
})
export type HealthChangesResponse = z.infer<typeof HealthChangesResponse>

// MARK: - 从 1.0 迁移（架构设计 §13）。手机把本机数据整理成这个格式，服务端只在业务库为空时接受

export const ImportBundle = z.object({
  formatVersion: z.literal(1),
  exportedAt: z.iso.datetime(),
  sessions: z.array(z.object({ localDate: LocalDate, timeZone: z.string(), revision: z.number().int(), createdAt: z.iso.datetime(), updatedAt: z.iso.datetime() })),
  records: z.array(
    z.object({
      id: z.uuid(),
      sessionDate: LocalDate,
      eventTime: EventTime,
      mealLabel: z.string().nullable(),
      note: z.string().nullable(),
      revision: z.number().int(),
      createdAt: z.iso.datetime(),
      updatedAt: z.iso.datetime(),
      items: z.array(
        z.object({
          id: z.uuid(),
          position: z.number().int(),
          displayName: z.string(),
          groupName: z.string().nullable(),
          originalAmountText: z.string(),
          quantity: Quantity.nullable(),
          amountSource: AmountSource,
          snapshot: NutritionSnapshot,
          includeInSummary: z.boolean(),
          foodProductId: z.uuid().nullable(),
          foodVersionId: z.uuid().nullable(),
          referenceFoodId: z.string().nullable(),
          createdAt: z.iso.datetime(),
          updatedAt: z.iso.datetime(),
        }),
      ),
    }),
  ),
  products: z.array(
    z.object({
      id: z.uuid(),
      name: z.string(),
      brandOrSupplier: z.string().nullable(),
      package: Quantity.nullable(),
      note: z.string().nullable(),
      activeVersionId: z.uuid().nullable(),
      createdAt: z.iso.datetime(),
      updatedAt: z.iso.datetime(),
      versions: z.array(FoodVersion),
    }),
  ),
  goals: z.array(Goal.extend({ evidence: z.unknown().nullable(), createdAt: z.iso.datetime() })),
  /** 1.0 的确认卡不迁移，指向它们的 cardRef 由手机清掉。 */
  messages: z.array(ChatMessage.extend({ sessionDate: LocalDate })),
  labelScans: z.array(z.object({ id: z.uuid(), createdAt: z.iso.datetime(), contentType: z.string(), dataBase64: z.string() })),
  weighings: z.array(
    z.object({
      id: z.uuid(),
      measuredAt: z.iso.datetime(),
      weightKg: z.number(),
      impedance: Impedance.nullable(),
      source: WeighingSource,
      timeReliable: z.boolean(),
      profile: z.object({ heightCm: z.number().nullable(), ageYears: z.number().int().nullable(), sex: BiologicalSex.nullable() }),
      scaleBodyFatFraction: z.number().nullable(),
      createdAt: z.iso.datetime(),
    }),
  ),
  manualMetrics: z.object({ metrics: ManualBodyMetrics, enteredAt: z.iso.datetime() }).nullable(),
})
export type ImportBundle = z.infer<typeof ImportBundle>

/** POST /v1/import：导入后各表条数与每天的能量合计，手机拿来和本机对比，一致才切换。 */
export const ImportResponse = z.object({
  counts: z.object({
    sessions: z.number().int(),
    records: z.number().int(),
    items: z.number().int(),
    products: z.number().int(),
    versions: z.number().int(),
    goals: z.number().int(),
    messages: z.number().int(),
    labelScans: z.number().int(),
    weighings: z.number().int(),
  }),
  /** 每天计入汇总的能量合计（千卡）。 */
  dailyEnergyKcal: z.record(LocalDate, z.number()),
})
export type ImportResponse = z.infer<typeof ImportResponse>
