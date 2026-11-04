/**
 * 执行模型发出的工具调用（agent-tools.md，移植自 1.0 的 AgentToolRunner）。只读工具直接查询；Propose 工具只会
 * 创建或替换确认卡；updateGoal 是唯一的直接指令。会话日期由服务端按请求注入，不信任模型给的日期。
 * 回给模型的数值保留一位小数，避免把计算误差的长尾交给模型。
 */
import Big from 'big.js'

import type { DayItem, DayRecord, DaySummary, EnergyTarget, Goal, GoalRecommendationResponse, HealthSnapshot, NutrientValues, Quantity, ReferenceFood } from '@vita/contract'

import { METRIC_INFO, movingAverage, RATING_LABELS } from '../domain/body.ts'
import { recommendGoals } from '../domain/recommendation.ts'
import { isLocalDate, localParts } from '../domain/time.ts'
import { ServiceError } from '../services/context.ts'
import type { EnergyPlanChange } from '../services/goals.ts'
import type { Services } from '../services/index.ts'
import type { LLMFunctionCall } from './llm.ts'
import { failure, handleProposal, PROPOSAL_TOOLS } from './proposals.ts'

/** 一次工具调用的结果：回给模型的 JSON，以及界面需要知道的副作用。 */
export interface ToolOutcome {
  output: string
  /** 返回错误码时为它，成功为 ok；记进对话追踪。 */
  resultCode: string
  pendingId: string | null
  /** 模型在提案里写下的、卡片确认后要做的下一步。 */
  afterConfirm: string | null
  requestedDate: string | null
  goalChanged: boolean
}

class ToolFailure extends Error {
  readonly code: string
  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

const round = (value: number, places = 1) => Number(new Big(value).round(places, Big.roundHalfUp).toString())

function outcome(value: unknown, extra: Partial<ToolOutcome> = {}): ToolOutcome {
  const output = JSON.stringify(value)
  const code = (value as { error?: { code?: string } } | null)?.error?.code
  return { output, resultCode: code ?? 'ok', pendingId: null, afterConfirm: null, requestedDate: null, goalChanged: false, ...extra }
}

export class ToolRunner {
  private readonly services: Services

  constructor(services: Services) {
    this.services = services
  }

  run(call: LLMFunctionCall, sessionDate: string, requestId: string, actor: string): ToolOutcome {
    let args: unknown
    try {
      args = JSON.parse(call.arguments)
    } catch {
      args = null
    }
    if (typeof args !== 'object' || args === null || Array.isArray(args)) return outcome(failure('malformedArguments', '参数必须是 JSON 对象。'))
    const input = args as Record<string, unknown>
    try {
      if (PROPOSAL_TOOLS.has(call.name)) {
        const proposal = handleProposal(call.name, input, { services: this.services, sessionDate, requestId, actor })
        return outcome(proposal.result, {
          pendingId: proposal.pendingId,
          afterConfirm: proposal.result.ok ? proposal.afterConfirm : null,
          requestedDate: proposal.result.requestedDate ?? null,
        })
      }
      return this.read(call.name, input, sessionDate, requestId, actor)
    } catch (error) {
      if (error instanceof ToolFailure) return outcome(failure(error.code, error.message))
      console.error(error)
      return outcome(failure('internal', '服务暂时无法处理这个请求。'))
    }
  }

  private read(name: string, args: Record<string, unknown>, sessionDate: string, requestId: string, actor: string): ToolOutcome {
    const { services } = this
    switch (name) {
      case 'getDaySummary': {
        const date = args.date === undefined || args.date === null ? sessionDate : dateArg(args.date)
        const day = services.days.day(date)
        const pending = services.pending.active(date)
        return outcome({
          date,
          // 提案时作为 expectedRevision。
          revision: day.revision,
          writable: date === sessionDate,
          records: day.records.map(recordOut),
          totals: nutrientsOut(day.summary.totals),
          goal: day.summary.goal ? goalOut(day.summary.goal, day.summary.energy) : undefined,
          activePending: pending ? { id: pending.id, expiresAt: pending.expiresAt } : undefined,
        })
      }
      case 'getRecordDetail': {
        const id = stringArg(args.recordId, 'recordId')
        const record = services.days.day(sessionDate).records.find((candidate) => candidate.id === id)
        if (!record) return outcome(failure('recordNotFound', '该记录不在当前日期中。'))
        return outcome(recordOut(record))
      }
      case 'searchPersonalFoods':
        // 不做字符串匹配：个人库很小，整库交给模型做语义匹配（ADR-015）。query 只是模型想找什么的提示。
        stringArg(args.query, 'query')
        return outcome({
          products: services.foods.products().map((product) => ({
            productId: product.id,
            name: product.name,
            brandOrSupplier: product.brandOrSupplier ?? undefined,
            aliases: product.aliases.length ? product.aliases : undefined,
            package: product.package ? quantityOut(product.package) : undefined,
            activeVersionId: product.activeVersion?.id,
            basis: product.activeVersion ? quantityOut(product.activeVersion.basis.quantity) : undefined,
            nutrientsPerBasis: product.activeVersion ? nutrientsOut(product.activeVersion.basis.nutrients) : undefined,
          })),
          note: '这是个人食品库的全部产品。是不是用户说的那一个由你判断；有多个可能或不确定时先问用户。',
        })
      case 'searchReferenceFoods': {
        const query = stringArg(args.query, 'query')
        const aliases = Array.isArray(args.aliases) ? args.aliases.filter((alias): alias is string => typeof alias === 'string') : []
        return outcome(referenceOut(services.context.reference.search(query, aliases)))
      }
      case 'getGoals':
        // 能量目标随活动计算时，返回当天算出的值和来历。
        return outcome(goalsOut(services.days.day(sessionDate).summary))
      case 'getHealthSnapshot':
        return outcome(healthOut(services.health.snapshot(sessionDate)))
      case 'getBodyComposition': {
        const days = args.days === undefined || args.days === null ? 30 : args.days
        if (typeof days !== 'number' || !Number.isInteger(days) || days < 1 || days > 365) {
          throw new ToolFailure('invalidField', 'days 应在 1 到 365 之间。')
        }
        return outcome(this.bodyComposition(days))
      }
      case 'getGoalRecommendation':
        return outcome(recommendationOut(recommendGoals(services.health.snapshot(sessionDate), sessionDate, services.context.now())))
      case 'updateGoal':
        return this.updateGoal(args, sessionDate, requestId, actor)
      default:
        return outcome(failure('unknownTool', `没有名为 ${name} 的工具。`))
    }
  }

  // MARK: - updateGoal

  private updateGoal(args: Record<string, unknown>, sessionDate: string, requestId: string, actor: string): ToolOutcome {
    stringArg(args.userCommand, 'userCommand')
    const value = (key: string): number | undefined => {
      const raw = args[key]
      if (raw === undefined || raw === null) return undefined
      if (typeof raw !== 'number' || !(raw > 0) || !Number.isFinite(raw)) throw new ToolFailure('invalidField', `${key} 必须是正数。`)
      return raw
    }
    const changes = { energyKcal: value('energyKcal'), proteinG: value('proteinG'), fatG: value('fatG'), carbohydrateG: value('carbohydrateG') }
    const plan = energyPlanChange(args)
    if (changes.energyKcal !== undefined && plan) {
      throw new ToolFailure('invalidField', 'energyKcal 是固定目标，不能和 goalType / energyPercent / energyAdjustmentKcal / energyAuto 同时给。')
    }
    if (Object.values(changes).every((change) => change === undefined) && !plan) {
      throw new ToolFailure('missingField', '没有给出要修改的目标数值。')
    }
    const previous = this.services.days.day(sessionDate).summary
    try {
      this.services.goals.update(changes, plan, sessionDate, { actor, requestId })
    } catch (error) {
      if (error instanceof ServiceError && error.code === 'noEnergyPlan') {
        throw new ToolFailure('noEnergyPlan', '还没有自动设定过目标，没法按活动计算。请用户在 Data 页的目标设定里生成一次。')
      }
      if (error instanceof ServiceError && error.code === 'invalidTargets') {
        throw new ToolFailure('invalidField', '目标数值不合理（比例 50%–150%，千卡 −1500 到 +1500，其他须为正数）。')
      }
      throw error
    }
    const current = this.services.days.day(sessionDate).summary
    if (!current.goal) throw new ToolFailure('internal', '目标保存后读取失败。')
    return outcome(
      {
        ok: true,
        previous: previous.goal ? goalOut(previous.goal, previous.energy) : undefined,
        current: goalOut(current.goal, current.energy),
        effectiveFrom: sessionDate,
      },
      { goalChanged: true },
    )
  }

  // MARK: - 身体成分

  private bodyComposition(days: number) {
    const { body, context } = this.services
    const all = body.weighings()
    const calibration = body.calibration()
    const zone = context.timeZone()
    const since = context.now().getTime() - days * 86_400_000
    const latest = all[0]
    const ascending = [...all].reverse()
    const weightAverage = movingAverage(ascending.map((w) => ({ time: Date.parse(w.measuredAt), value: w.weightKg })))
    const withFat = ascending.filter((w) => w.bodyFat)
    const fatAverage = new Map(
      movingAverage(withFat.map((w) => ({ time: Date.parse(w.measuredAt), value: w.bodyFat!.value * 100 }))).map((value, index) => [withFat[index].id, value]),
    )
    const metric = (w: (typeof all)[number], kind: string) => w.metrics.find((m) => m.kind === kind)?.value
    return {
      latest: latest
        ? {
            measuredAt: localISO(latest.measuredAt, zone),
            timeReliable: latest.timeReliable,
            bodyFatSource: latest.bodyFat?.source,
            metrics: latest.metrics.map((m) => {
              const info = METRIC_INFO[m.kind]
              return {
                name: info.title,
                value: round(info.unit === '%' ? m.value * 100 : m.value, info.digits),
                unit: info.unit,
                estimated: info.estimated,
                rating: m.rating ? RATING_LABELS[m.rating] : undefined,
              }
            }),
          }
        : undefined,
      weighings: ascending.flatMap((w, index) =>
        Date.parse(w.measuredAt) < since
          ? []
          : [
              {
                measuredAt: localISO(w.measuredAt, zone),
                weightKg: round(w.weightKg, 2),
                bodyFatPercent: w.bodyFat ? round(w.bodyFat.value * 100) : undefined,
                leanMassKg: metric(w, 'leanMass') === undefined ? undefined : round(metric(w, 'leanMass')!),
                muscleMassKg: metric(w, 'muscleMass') === undefined ? undefined : round(metric(w, 'muscleMass')!),
                weightKg7DayAverage: round(weightAverage[index], 2),
                bodyFatPercent7DayAverage: fatAverage.has(w.id) ? round(fatAverage.get(w.id)!) : undefined,
              },
            ],
      ),
      calibration:
        calibration.applied && calibration.model
          ? `已按 ${calibration.model.sampleCount} 组秤读数校准，体脂率与秤显示一致`
          : `未校准（已记 ${calibration.readingCount} 组秤读数），体脂率按 BMI 估算，可能与秤显示不同`,
      note: all.length === 0 ? '还没有体脂秤称重记录。' : '除体重、BMI 外都是估算；比较趋势用 7 天平均。',
    }
  }
}

// MARK: - 参数

function stringArg(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new ToolFailure('missingField', `缺少字段 ${field}。`)
  return value
}

function dateArg(value: unknown): string {
  if (typeof value !== 'string' || !isLocalDate(value)) throw new ToolFailure('invalidField', '日期格式应为 YYYY-MM-DD。')
  return value
}

/** goalType / energyPercent / energyAdjustmentKcal / energyAuto：任何一个都表示能量目标随活动计算。 */
function energyPlanChange(args: Record<string, unknown>): EnergyPlanChange | null {
  const change: EnergyPlanChange = {}
  let given = false
  if (args.goalType !== undefined && args.goalType !== null) {
    if (args.goalType !== 'maintain' && args.goalType !== 'lose' && args.goalType !== 'gain') {
      throw new ToolFailure('invalidField', 'goalType 只能是 maintain / lose / gain。')
    }
    change.kind = args.goalType
    given = true
  }
  if (typeof args.energyPercent === 'number') {
    change.adjustment = { type: 'fraction', value: Number(new Big(args.energyPercent).div(100).toString()) }
    given = true
  }
  if (typeof args.energyAdjustmentKcal === 'number') {
    if (change.adjustment) throw new ToolFailure('invalidField', 'energyPercent 与 energyAdjustmentKcal 只能给一个。')
    change.adjustment = { type: 'kcal', value: args.energyAdjustmentKcal }
    given = true
  }
  if (args.energyAuto === true) given = true
  return given ? change : null
}

// MARK: - 回给模型的结构

function nutrientsOut(values: NutrientValues) {
  const extra = (value: number | undefined) => (value === undefined ? undefined : round(value))
  return {
    energyKcal: round(values.energyKcal),
    proteinG: round(values.proteinG),
    fatG: round(values.fatG),
    carbohydrateG: round(values.carbohydrateG),
    sodiumMg: extra(values.sodiumMg),
    saturatedFatG: extra(values.saturatedFatG),
    sugarG: extra(values.sugarG),
  }
}

function quantityOut(quantity: Quantity) {
  return { amount: round(quantity.amount), unit: quantity.unit }
}

function itemOut(item: DayItem) {
  return {
    id: item.id,
    displayName: item.displayName,
    groupName: item.groupName ?? undefined,
    originalAmountText: item.originalAmountText,
    quantity: item.quantity ? quantityOut(item.quantity) : undefined,
    amountSource: item.amountSource,
    nutritionSource: item.snapshot.nutritionSource,
    sourceRef: item.snapshot.sourceRef ?? undefined,
    estimateBasis: item.snapshot.estimateBasis ?? undefined,
    includeInSummary: item.includeInSummary,
    nutrients: nutrientsOut(item.snapshot.values),
  }
}

function recordOut(record: DayRecord) {
  const { eventTime } = record
  let time: string | undefined
  if (eventTime.timestamp) {
    const parts = localParts(new Date(eventTime.timestamp), eventTime.timeZone)
    time = `${String(parts.hour).padStart(2, '0')}:${String(parts.minute).padStart(2, '0')}`
  }
  return {
    id: record.id,
    eventTime: { precision: eventTime.precision, time, mealPeriod: eventTime.mealPeriod ?? undefined },
    mealLabel: record.mealLabel ?? undefined,
    note: record.note ?? undefined,
    items: record.items.map(itemOut),
    totals: nutrientsOut(record.totals),
  }
}

function goalOut(goal: Goal, energy: EnergyTarget | null) {
  const plan = goal.energyPlan
  const whole = (value: number | null) => (value === null ? undefined : round(value, 0))
  return {
    energyKcal: whole(goal.targets.energyKcal),
    proteinG: whole(goal.targets.proteinG),
    fatG: whole(goal.targets.fatG),
    carbohydrateG: whole(goal.targets.carbohydrateG),
    effectiveFrom: goal.effectiveFrom,
    origin: goal.origin,
    // auto：能量目标随当天活动计算；fixed：固定值。
    energyMode: plan ? 'auto' : 'fixed',
    energyPlan: plan
      ? {
          goalType: plan.kind,
          energyPercent: plan.adjustment.type === 'fraction' ? round(plan.adjustment.value * 100, 0) : undefined,
          energyAdjustmentKcal: plan.adjustment.type === 'kcal' ? round(plan.adjustment.value, 0) : undefined,
          bmrKcal: round(plan.bmrKcal, 0),
        }
      : undefined,
    energyToday: energy
      ? {
          baselineActivityKcal: round(energy.baselineActivityKcal, 0),
          projectedActivityKcal: round(energy.projectedActivityKcal, 0),
          countedActivityKcal: round(energy.countedActivityKcal, 0),
          tdeeKcal: round(energy.tdeeKcal, 0),
          adjustmentKcal: round(energy.adjustmentKcal, 0),
          activityEstimated: energy.activityEstimated,
        }
      : undefined,
  }
}

function goalsOut(summary: DaySummary) {
  return {
    goal: summary.goal ? goalOut(summary.goal, summary.energy) : undefined,
    note: !summary.goal
      ? '还没有每日目标。可调用 getGoalRecommendation 预览建议，再请用户在 Data 页的目标设定里确认。'
      : summary.energy
        ? '能量目标随当天活动计算：消耗 = BMR + 计入的活动（超出平时的部分计入一半），再按 energyPlan 调整；数值会随一天的活动变化。'
        : undefined,
  }
}

function referenceOut(foods: ReferenceFood[]) {
  return {
    // 精确查询本身就很窄，多于 10 条时只给前 10 条。
    matches: foods.slice(0, 10).map((food) => ({
      referenceFoodId: food.id,
      name: food.canonicalName,
      aliases: food.aliases,
      preparationState: food.preparationState,
      per100g: nutrientsOut(food.nutrients),
      densityGPerMl: food.densityGPerMl ?? undefined,
    })),
    note: foods.length === 0 ? '没有命中。可换常见写法再查；仍没有时用 aiEstimated。' : foods.length === 1 ? undefined : '命中多个候选，请先问用户是哪一种。',
  }
}

type Reading<T> = { status: 'value'; value: T; source: string } | { status: 'noData' } | { status: 'failed'; message: string }

function readingOut<T, O>(reading: Reading<T>, transform: (value: T) => O) {
  return reading.status === 'value' ? { value: transform(reading.value), source: reading.source, status: 'value' } : { status: reading.status }
}

function healthOut(snapshot: HealthSnapshot) {
  return {
    authorizationRequested: snapshot.authorizationRequested,
    bodyMassKg: readingOut(snapshot.bodyMassKg, (v) => round(v)),
    heightCm: readingOut(snapshot.heightCm, (v) => round(v, 0)),
    bodyFatPercent: readingOut(snapshot.bodyFatFraction, (v) => round(v * 100)),
    dateOfBirth: readingOut(snapshot.dateOfBirth, (v) => v),
    sex: readingOut(snapshot.sex, (v) => v),
    activeEnergyKcal: readingOut(snapshot.activeEnergyKcal, (v) => round(v, 0)),
    sleepHours: readingOut(snapshot.sleepHours, (v) => round(v)),
  }
}

function recommendationOut(result: GoalRecommendationResponse) {
  if (result.status === 'missing') {
    return {
      missing: result.missing,
      note: '缺少数据，无法生成。可请用户在 Data 页的目标设定里补录。',
    }
  }
  const { recommendation: r } = result
  const { input } = r
  return {
    ready: {
      energyKcal: r.targets.energyKcal === null ? undefined : round(r.targets.energyKcal, 0),
      proteinG: r.targets.proteinG === null ? undefined : round(r.targets.proteinG, 0),
      bmrKcal: round(r.bmrKcal, 0),
      tdeeKcal: round(r.tdeeKcal, 0),
      tdeeEstimated: r.tdeeEstimated,
      inputs: {
        bodyMassKg: `${round(input.bodyMassKg)} (${input.weightSource})`,
        heightCm: `${round(input.heightCm, 0)} (${input.heightSource})`,
        ageYears: `${input.ageYears} (${input.ageSource})`,
        sex: `${input.sex} (${input.sexSource})`,
      },
      formula:
        'Mifflin–St Jeor BMR；平时消耗 = BMR + 近 7 天日均活动（数据不足时 BMR × 1.375）；默认减脂吃到 85%，每天按当天活动重算；蛋白质 = 1.8 g/kg',
    },
    note: '这只是预览，没有保存。请用户在 Data 页"生成每日目标"里确认。',
  }
}

/** 本地时间的 ISO 8601（带时区偏移，不带毫秒），如 2026-10-30T08:12:00+08:00。 */
function localISO(iso: string, timeZone: string): string {
  const instant = new Date(iso)
  const p = localParts(instant, timeZone)
  const wall = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second)
  const offset = Math.round((wall - Math.floor(instant.getTime() / 1000) * 1000) / 60_000)
  const pad = (n: number) => String(Math.abs(n)).padStart(2, '0')
  const sign = offset >= 0 ? '+' : '-'
  return `${p.year}-${pad(p.month)}-${pad(p.day)}T${pad(p.hour)}:${pad(p.minute)}:${pad(p.second)}${sign}${pad(Math.trunc(Math.abs(offset) / 60))}:${pad(Math.abs(offset) % 60)}`
}
