/**
 * Propose 级工具（agent-tools.md，移植自 1.0 的 ProposalToolHandler）。模型提交的是"意图"，不是可直接写入的实体：
 * 用量单位由服务端标准化，个人食品与参考库的营养值由服务端计算（模型给了也不采用），
 * 摄入时间按会话日期与时区构造，没表达时间则注入 defaultedEntryTime。只会创建或替换确认卡，不写正式数据。
 */
import { MealLabel } from '@vita/contract'
import { z } from 'zod'

import type { FoodChange, FoodVersionDraft, ItemDraft, RecordChange } from '../domain/changes.ts'
import { defaultedEntryTime, EventTimeError, makeEventTime } from '../domain/eventTime.ts'
import { normalizeQuantity, UnitNormalizationError } from '../domain/nutrition.ts'
import { zonedInstant } from '../domain/time.ts'
import { ServiceError } from '../services/context.ts'
import type { Services } from '../services/index.ts'

export const PROPOSAL_TOOLS = new Set(['proposeRecordChange', 'proposeRecordDeletion', 'proposeFoodChange'])

/** 回给模型的结构化结果。错误只给机器码与一句可解释的说明，不含内部细节。 */
export interface ToolResult {
  ok: boolean
  pendingId?: string
  /** 模型想写的日期与当前日期不同：请用户切换，服务端不跨日期写入（TDD §5.2）。 */
  requestedDate?: string
  error?: { code: string; message: string }
}

export function failure(code: string, message: string, requestedDate?: string): ToolResult {
  return { ok: false, ...(requestedDate ? { requestedDate } : {}), error: { code, message } }
}

class ProposalError extends Error {
  readonly result: ToolResult
  constructor(result: ToolResult) {
    super(result.error?.code)
    this.result = result
  }
}

const reject = (code: string, message: string, requestedDate?: string) => new ProposalError(failure(code, message, requestedDate))
const missing = (field: string) => reject('missingField', `缺少字段 ${field}。`)
const invalid = (field: string) => reject('invalidField', `字段 ${field} 的值不合法。`)

// MARK: - 参数格式

const QuantityArgs = z.object({ amount: z.number(), unit: z.string() })
const NutrientArgs = z.object({
  energyKcal: z.number(),
  proteinG: z.number(),
  fatG: z.number(),
  carbohydrateG: z.number(),
  sodiumMg: z.number().nullish(),
  saturatedFatG: z.number().nullish(),
  sugarG: z.number().nullish(),
})

const ItemArgs = z.object({
  displayName: z.string(),
  groupName: z.string().nullish(),
  originalAmountText: z.string(),
  quantity: QuantityArgs.nullish(),
  amountSource: z.enum(['userMeasured', 'userStated', 'packageConversion', 'aiEstimated']),
  nutrition: z.object({
    source: z.enum(['personalFoodVersion', 'referenceFood', 'aiEstimated']),
    foodVersionId: z.string().nullish(),
    referenceFoodId: z.string().nullish(),
    values: NutrientArgs.nullish(),
    estimateBasis: z.string().nullish(),
  }),
  includeInSummary: z.boolean().nullish(),
})
type ItemArgs = z.infer<typeof ItemArgs>

const EventTimeArgs = z.object({
  precision: z.enum(['exact', 'approximate', 'mealPeriod', 'dateOnly', 'defaultedEntryTime']),
  /** HH:mm，仅 exact / approximate。 */
  time: z.string().nullish(),
  mealPeriod: z.enum(['breakfast', 'lunch', 'dinner', 'snack', 'other']).nullish(),
})

const RecordChangePayload = z.object({
  intent: z.enum(['create', 'appendItems', 'replaceItem', 'removeItem']),
  recordId: z.string().nullish(),
  itemId: z.string().nullish(),
  record: z
    .object({ eventTime: EventTimeArgs.nullish(), mealLabel: MealLabel.nullish(), note: z.string().nullish(), items: z.array(ItemArgs) })
    .nullish(),
  items: z.array(ItemArgs).nullish(),
  item: ItemArgs.nullish(),
  /** appendItems 用：同一条记录里已有的 Item 顺带改分组。 */
  regroup: z.array(z.object({ itemId: z.string(), groupName: z.string().nullish() })).nullish(),
  replacesPendingId: z.string().nullish(),
})

const RecordDeletionPayload = z.object({ recordId: z.string(), replacesPendingId: z.string().nullish() })

const FoodChangePayload = z.object({
  intent: z.enum(['createProduct', 'addVersion', 'updateProduct']),
  productId: z.string().nullish(),
  expectedActiveVersionId: z.string().nullish(),
  product: z
    .object({
      name: z.string().nullish(),
      brandOrSupplier: z.string().nullish(),
      package: QuantityArgs.nullish(),
      note: z.string().nullish(),
      aliases: z.array(z.string()).nullish(),
    })
    .nullish(),
  version: z
    .object({
    source: z.string(),
    labelScanId: z.string().nullish(),
    referenceFoodId: z.string().nullish(),
    basis: QuantityArgs.nullish(),
    values: NutrientArgs.nullish(),
    note: z.string().nullish(),
  })
    .nullish(),
  replacesPendingId: z.string().nullish(),
})

/** 公共信封。sessionDate 是模型以为的日期，只用来发现它想写别的日期。 */
const Envelope = <T extends z.ZodType>(payload: T) =>
  z.object({ sessionDate: z.string().nullish(), expectedRevision: z.number().int().nullish(), afterConfirm: z.string().nullish(), payload })

export interface ProposalContext {
  services: Services
  sessionDate: string
  requestId: string
  actor: string
}

export interface ProposalOutcome {
  result: ToolResult
  pendingId: string | null
  afterConfirm: string | null
}

/** 解析参数、提出确认卡。任何问题都变成给模型的错误结果，不抛出。 */
export function handleProposal(tool: string, args: unknown, context: ProposalContext): ProposalOutcome {
  try {
    const pending = propose(tool, args, context)
    return { result: { ok: true, pendingId: pending.id }, pendingId: pending.id, afterConfirm: pending.afterConfirm }
  } catch (error) {
    if (error instanceof ProposalError) return { result: error.result, pendingId: null, afterConfirm: null }
    if (error instanceof ServiceError) return { result: serviceFailure(error), pendingId: null, afterConfirm: null }
    throw error
  }
}

function parse<T extends z.ZodType>(schema: T, args: unknown): z.infer<T> {
  const parsed = schema.safeParse(args)
  if (!parsed.success) {
    const path = parsed.error.issues[0]?.path.join('.') || 'arguments'
    throw reject('malformedArguments', `参数格式不对：${path}。`)
  }
  return parsed.data
}

function propose(tool: string, args: unknown, { services, sessionDate, requestId, actor }: ProposalContext) {
  const schema =
    tool === 'proposeRecordChange'
      ? Envelope(RecordChangePayload)
      : tool === 'proposeRecordDeletion'
        ? Envelope(RecordDeletionPayload)
        : tool === 'proposeFoodChange'
          ? Envelope(FoodChangePayload)
          : null
  if (!schema) throw reject('unknownTool', `没有名为 ${tool} 的工具。`)
  const envelope = parse(schema, args)
  // 日期不符时不再解析内容，直接请求切换。sessionDate 由服务端按当前会话注入，不信任模型给的日期。
  if (envelope.sessionDate && envelope.sessionDate !== sessionDate) {
    throw reject('requiresDateSwitch', `请让用户切换到 ${envelope.sessionDate} 再记录。`, envelope.sessionDate)
  }
  const options = { actor, requestId, replacing: envelope.payload.replacesPendingId ?? null, afterConfirm: envelope.afterConfirm ?? null }
  const expectedRevision = envelope.expectedRevision ?? services.days.day(sessionDate).revision

  if (tool === 'proposeFoodChange') {
    return services.pending.proposeFood(foodChange(envelope.payload as z.infer<typeof FoodChangePayload>, services), sessionDate, options)
  }
  const change: RecordChange =
    tool === 'proposeRecordDeletion'
      ? { kind: 'deleteRecord', recordId: (envelope.payload as z.infer<typeof RecordDeletionPayload>).recordId }
      : recordChange(envelope.payload as z.infer<typeof RecordChangePayload>, sessionDate, services)
  return services.pending.proposeRecord(change, sessionDate, expectedRevision, options)
}

// MARK: - 转成变更

function recordChange(payload: z.infer<typeof RecordChangePayload>, sessionDate: string, services: Services): RecordChange {
  const require = <T>(value: T | null | undefined, field: string): T => {
    if (value === null || value === undefined) throw missing(field)
    return value
  }
  switch (payload.intent) {
    case 'create': {
      const record = require(payload.record, 'payload.record')
      return {
        kind: 'create',
        draft: {
          eventTime: eventTime(record.eventTime ?? null, sessionDate, services),
          mealLabel: record.mealLabel ?? null,
          note: record.note ?? null,
          items: record.items.map(item),
        },
      }
    }
    case 'appendItems': {
      const regroup = (payload.regroup ?? []).map((entry) => ({ itemId: entry.itemId, groupName: entry.groupName?.trim() || null }))
      return {
        kind: 'appendItems',
        recordId: require(payload.recordId, 'payload.recordId'),
        items: require(payload.items, 'payload.items').map(item),
        ...(regroup.length ? { regroup } : {}),
      }
    }
    case 'replaceItem':
      return {
        kind: 'replaceItem',
        recordId: require(payload.recordId, 'payload.recordId'),
        itemId: require(payload.itemId, 'payload.itemId'),
        item: item(require(payload.item, 'payload.item')),
      }
    case 'removeItem':
      return { kind: 'removeItem', recordId: require(payload.recordId, 'payload.recordId'), itemId: require(payload.itemId, 'payload.itemId') }
  }
}

function eventTime(args: z.infer<typeof EventTimeArgs> | null, sessionDate: string, services: Services) {
  const { now, timeZone } = services.context
  const zone = timeZone()
  // 用户完全没表达时间：由服务端（而非模型）注入录入时刻（ADR-011）。
  if (!args) return defaultedEntryTime(sessionDate, now(), zone)
  try {
    switch (args.precision) {
      case 'exact':
      case 'approximate': {
        const match = /^(\d{1,2}):(\d{2})$/.exec(args.time ?? '')
        const [hour, minute] = match ? [Number(match[1]), Number(match[2])] : [NaN, NaN]
        if (!(hour >= 0 && hour < 24 && minute >= 0 && minute < 60)) throw invalid('payload.record.eventTime.time')
        return makeEventTime({ localDate: sessionDate, precision: args.precision, timestamp: zonedInstant(sessionDate, hour, minute, 0, zone), timeZone: zone })
      }
      case 'mealPeriod':
        return makeEventTime({ localDate: sessionDate, precision: 'mealPeriod', mealPeriod: args.mealPeriod ?? null, timeZone: zone })
      case 'dateOnly':
        return makeEventTime({ localDate: sessionDate, precision: 'dateOnly', timeZone: zone })
      case 'defaultedEntryTime':
        // 只能由服务端注入；模型应省略 eventTime。
        throw invalid('payload.record.eventTime.precision')
    }
  } catch (error) {
    if (error instanceof EventTimeError) throw invalid('payload.record.eventTime')
    throw error
  }
}

function quantity(args: z.infer<typeof QuantityArgs>, field: string) {
  try {
    return normalizeQuantity(args.amount, args.unit)
  } catch (error) {
    if (error instanceof UnitNormalizationError) throw invalid(field)
    throw error
  }
}

function item(args: ItemArgs): ItemDraft {
  const { nutrition } = args
  let input: ItemDraft['nutrition']
  switch (nutrition.source) {
    case 'referenceFood':
      if (!nutrition.referenceFoodId) throw missing('item.nutrition.referenceFoodId')
      input = { source: 'referenceFood', referenceFoodId: nutrition.referenceFoodId }
      break
    case 'personalFoodVersion':
      if (!nutrition.foodVersionId) throw missing('item.nutrition.foodVersionId')
      input = { source: 'personalFoodVersion', foodVersionId: nutrition.foodVersionId }
      break
    case 'aiEstimated':
      if (!nutrition.values) throw missing('item.nutrition.values')
      if (!nutrition.estimateBasis) throw missing('item.nutrition.estimateBasis')
      input = { source: 'aiEstimated', values: nutrients(nutrition.values), estimateBasis: nutrition.estimateBasis }
      break
  }
  return {
    displayName: args.displayName,
    groupName: args.groupName ?? null,
    originalAmountText: args.originalAmountText,
    quantity: args.quantity ? quantity(args.quantity, 'item.quantity') : null,
    amountSource: args.amountSource,
    nutrition: input,
    includeInSummary: args.includeInSummary ?? true,
  }
}

function foodChange(payload: z.infer<typeof FoodChangePayload>, services: Services): FoodChange {
  if (payload.intent === 'updateProduct') {
    if (!payload.productId) throw missing('payload.productId')
    const product = payload.product ?? {}
    return {
      kind: 'updateProduct',
      productId: payload.productId,
      name: product.name?.trim() || null,
      // 没给品牌就不改；给了空字符串表示清空。
      brandOrSupplier: product.brandOrSupplier === undefined || product.brandOrSupplier === null ? undefined : product.brandOrSupplier,
      aliases: product.aliases ?? null,
      ...(product.package ? { package: quantity(product.package, 'payload.product.package') } : {}),
    }
  }
  if (!payload.version) throw missing('payload.version')
  const version = versionDraft(payload.version, services)
  if (payload.intent === 'createProduct') {
    if (!payload.product) throw missing('payload.product')
    const { product } = payload
    if (!product.name?.trim()) throw missing('payload.product.name')
    // 预包装食品的标签按国标必须印净含量；没有它，“一袋 / 一盒”就换算不了。所以在提案时就拦下，
    // 让模型这一轮去读清楚或先问用户，而不是先存一个缺包装的食品、确认后再补一张卡。
    if (version.sourceKind === 'nutritionLabel' && !product.package) {
      throw reject(
        'packageRequired',
        '按营养标签存库必须带 product.package（净含量，如 288 g、950 ml）。从照片里找净含量；读不到就先问用户一袋 / 一盒多重，拿到后再提案，不要先存。',
      )
    }
    return {
      kind: 'createProduct',
      product: {
        name: product.name.trim(),
        brandOrSupplier: product.brandOrSupplier ?? null,
        package: product.package ? quantity(product.package, 'payload.product.package') : null,
        note: product.note ?? null,
        aliases: product.aliases ?? [],
      },
      version,
    }
  }
  if (!payload.productId) throw missing('payload.productId')
  return { kind: 'addVersion', productId: payload.productId, expectedActiveVersionId: payload.expectedActiveVersionId ?? null, version }
}

/** source 只接受 nutritionLabel / manualEntry / referenceDerived；AI 估算不能沉淀为食品版本。 */
function versionDraft(args: NonNullable<z.infer<typeof FoodChangePayload>['version']>, services: Services): FoodVersionDraft {
  switch (args.source) {
    case 'referenceDerived': {
      if (!args.referenceFoodId) throw missing('payload.version.referenceFoodId')
      const food = services.context.reference.food(args.referenceFoodId)
      if (!food) throw invalid('payload.version.referenceFoodId')
      // 基准与营养值从参考库复制，模型给的忽略。
      return {
        basis: { quantity: { amount: food.base.quantity, unit: food.base.unit }, nutrients: food.nutrients },
        sourceKind: 'referenceDerived',
        labelScanId: null,
        derivedFromReferenceId: food.id,
        sourceNote: args.note ?? null,
      }
    }
    case 'nutritionLabel':
    case 'manualEntry': {
      if (!args.basis) throw missing('payload.version.basis')
      if (!args.values) throw missing('payload.version.values')
      if (args.source === 'nutritionLabel' && !args.labelScanId) throw missing('payload.version.labelScanId')
      return {
        basis: { quantity: quantity(args.basis, 'payload.version.basis'), nutrients: nutrients(args.values) },
        sourceKind: args.source,
        labelScanId: args.source === 'nutritionLabel' ? (args.labelScanId ?? null) : null,
        derivedFromReferenceId: null,
        sourceNote: args.note ?? null,
      }
    }
    default:
      throw reject('estimateNotAllowed', 'AI 估算不能保存为个人食品。只有营养标签、用户提供的数值或公共参考库可以作为来源。')
  }
}

/** 模型给的营养值：扩展项是 null 时去掉（存储里“没有”就是不给这个键）。 */
function nutrients(values: z.infer<typeof NutrientArgs>): FoodVersionDraft['basis']['nutrients'] {
  const { sodiumMg, saturatedFatG, sugarG, ...core } = values
  return {
    ...core,
    ...(sodiumMg == null ? {} : { sodiumMg }),
    ...(saturatedFatG == null ? {} : { saturatedFatG }),
    ...(sugarG == null ? {} : { sugarG }),
  }
}

// MARK: - 业务错误映射

function serviceFailure(error: ServiceError): ToolResult {
  const reason = error.details as { reason?: string; index?: number; pendingId?: string }
  if (error.code === 'anotherPendingActive') {
    return failure('pendingActive', `当天已有一张待确认卡片（${reason.pendingId}）。修正它请带上 replacesPendingId；否则请等用户确认或取消。`)
  }
  switch (error.auditCode.split('.').slice(0, 2).join('.')) {
    case 'pending.notFound':
      return failure('pendingNotFound', '要替换的待确认卡片不存在或已结束。')
    case 'record.revisionConflict':
      return failure('revisionConflict', '当天数据已变化，请重新读取后再提出。')
    case 'record.recordNotFound':
    case 'record.recordNotInSession':
      return failure('recordNotFound', '该记录不在当前日期中。')
    case 'record.itemNotFound':
      return failure('itemNotFound', '该条目不在这条记录中。')
    case 'record.emptyRecord':
      return failure('emptyRecord', '记录至少要有一项；要删除整条记录请用 proposeRecordDeletion。')
    case 'record.eventTimeOutsideSession':
      return failure('eventTimeOutsideSession', '事件时间不在当前日期内。')
    case 'record.invalidItem':
      if (reason.reason === 'packageUnavailable') {
        return failure(
          'invalidItem',
          `第 ${(reason.index ?? 0) + 1} 项不合格：这个食品没有记包装规格，不能按“一袋 / 一盒”换算。用户说了包装多大时，这次用 amountSource userStated 按克数或毫升数记；` +
            '并在 afterConfirm 里写“给这个食品补上包装规格”，确认后用 proposeFoodChange 的 updateProduct 补上 product.package，下次就能按袋记。用户没说就先问。',
        )
      }
      return failure('invalidItem', `第 ${(reason.index ?? 0) + 1} 项不合格：${reason.reason}。`)
    case 'food.activeVersionChanged':
      return failure('revisionConflict', '这个食品在提案后已更新，请重新读取后再提出。')
    case 'food.productNotFound':
      return failure('productNotFound', '个人食品库中没有这个产品。')
    case 'food.unknownLabel':
      return failure('unknownLabel', '找不到对应的营养标签照片。')
    default:
      return error.auditCode.startsWith('food.')
        ? failure('invalidFood', `食品数据不合格：${error.auditCode}。`)
        : failure('pendingUnavailable', '待确认卡片不可用，请重新提出。')
  }
}
