import Foundation
import os

/// 一次工具调用的结果：回给模型的 JSON，以及界面需要知道的副作用（生成了确认卡、需要切换日期）。
struct ToolOutcome: Equatable, Sendable {
    var output: String
    var pendingID: UUID?
    var requestedDate: String?
    var goalChanged = false
}

/// 执行模型发出的工具调用（agent-tools.md）。只读工具直接查询；Propose 工具交给 `ProposalToolHandler`，
/// 只会创建或替换 Pending；`updateGoal` 是唯一的直接指令。`sessionDate` 由客户端注入，不信任模型给的日期。
@MainActor
final class AgentToolRunner {
    private let services: AppServices
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(services: AppServices, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.services = services
        self.now = now
        self.timeZone = timeZone
    }

    /// 诊断日志只记工具名与结果码，不记参数或结果内容（llm-provider.md §6）。
    private static let log = Logger(subsystem: "com.leonardo.vita", category: "agent.tools")

    func run(_ call: LLMFunctionCall, sessionDate: LocalDate, requestID: UUID) async -> ToolOutcome {
        let outcome = await execute(call, sessionDate: sessionDate, requestID: requestID)
        let code = (try? JSONDecoder().decode(ToolResultCode.self, from: Data(outcome.output.utf8)))?.error?.code ?? "ok"
        Self.log.info("tool \(call.name, privacy: .public) -> \(code, privacy: .public)")
        return outcome
    }

    private struct ToolResultCode: Decodable {
        struct Failure: Decodable { var code: String }
        var error: Failure?
    }

    private func execute(_ call: LLMFunctionCall, sessionDate: LocalDate, requestID: UUID) async -> ToolOutcome {
        let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .null
        guard case .object = arguments else {
            return Self.failure("malformedArguments", "参数必须是 JSON 对象。")
        }
        do {
            switch call.name {
            case _ where ProposalToolHandler.toolNames.contains(call.name):
                return try propose(call.name, arguments: arguments, sessionDate: sessionDate, requestID: requestID)
            case "getDaySummary":
                let date = try arguments["date"]?.stringValue.map(Self.date) ?? sessionDate
                return try Self.encode(DayOut(try services.dayData.day(date), pending: try services.pending.active(on: date), isSessionDate: date == sessionDate))
            case "getRecordDetail":
                let id = try Self.uuid(arguments["recordId"], "recordId")
                guard let record = try services.dayData.day(sessionDate).records.first(where: { $0.id == id }) else {
                    return Self.failure("recordNotFound", "该记录不在当前日期中。")
                }
                return try Self.encode(RecordOut(record))
            case "searchPersonalFoods":
                let query = try Self.string(arguments["query"], "query")
                // 不做字符串匹配：个人库很小，整库交给模型做语义匹配（PRD §3.1 设计要点）。query 只是模型想找什么的提示。
                _ = query
                return try Self.encode(PersonalSearchOut(
                    products: try services.foods.products().map(ProductOut.init),
                    note: "这是个人食品库的全部产品。是不是用户说的那一个由你判断；有多个可能或不确定时先问用户。"
                ))
            case "searchReferenceFoods":
                let query = try Self.string(arguments["query"], "query")
                let aliases: [String] = if case .array(let values) = arguments["aliases"] { values.compactMap(\.stringValue) } else { [] }
                let matches = services.container.referenceFoods.search(query, aliases: aliases)
                return try Self.encode(ReferenceSearchOut(matches: matches))
            case "getGoals":
                return try Self.encode(GoalOut(try services.goals.activeGoal(on: sessionDate)))
            case "getHealthSnapshot":
                return try Self.encode(HealthOut(await services.health.snapshot(on: sessionDate)))
            case "getGoalRecommendation":
                let snapshot = await services.health.snapshot(on: sessionDate)
                return try Self.encode(RecommendationOut(GoalRecommendationPolicy.recommend(snapshot: snapshot, on: sessionDate, now: now())))
            case "updateGoal":
                return try updateGoal(arguments, sessionDate: sessionDate, requestID: requestID)
            default:
                return Self.failure("unknownTool", "没有名为 \(call.name) 的工具。")
            }
        } catch let failure as Failure {
            return Self.failure(failure.code, failure.message)
        } catch {
            return Self.failure("internal", "客户端暂时无法处理这个请求。")
        }
    }

    // MARK: - Propose

    /// 补上公共信封里由客户端负责的字段：`requestId` 总由客户端生成；模型没给 `sessionDate` 或 `expectedRevision` 时用当前值。
    /// 模型给了别的日期则保留，让处理器返回 `requiresDateSwitch`。
    private func propose(_ tool: String, arguments: JSONValue, sessionDate: LocalDate, requestID: UUID) throws -> ToolOutcome {
        guard case .object(var envelope) = arguments else { throw Failure("malformedArguments", "参数必须是 JSON 对象。") }
        envelope["requestId"] = .string(requestID.uuidString)
        if envelope["sessionDate"]?.stringValue == nil { envelope["sessionDate"] = .string(sessionDate.isoString) }
        if envelope["expectedRevision"]?.intValue == nil {
            envelope["expectedRevision"] = .number(Double(try services.dayData.day(sessionDate).revision))
        }
        let handler = ProposalToolHandler(
            pending: services.pending, referenceFoods: services.container.referenceFoods,
            labels: services.labels, now: now, timeZone: timeZone
        )
        let result = handler.handle(tool: tool, arguments: try JSONEncoder().encode(JSONValue.object(envelope)), sessionDate: sessionDate)
        var outcome = try Self.encode(result)
        outcome.pendingID = result.pendingId
        outcome.requestedDate = result.requestedDate
        return outcome
    }

    // MARK: - updateGoal

    private func updateGoal(_ arguments: JSONValue, sessionDate: LocalDate, requestID: UUID) throws -> ToolOutcome {
        _ = try Self.string(arguments["userCommand"], "userCommand")
        func value(_ key: String) throws -> Decimal? {
            guard let raw = arguments[key], raw != .null else { return nil }
            guard case .number(let number) = raw, number > 0, number.isFinite else { throw Failure("invalidField", "\(key) 必须是正数。") }
            return Decimal(string: String(number))
        }
        let changes = GoalTargets(
            energyKcal: try value("energyKcal"), proteinG: try value("proteinG"),
            fatG: try value("fatG"), carbohydrateG: try value("carbohydrateG")
        )
        guard Nutrient.allCases.contains(where: { changes.target(for: $0) != nil }) else {
            throw Failure("missingField", "没有给出要修改的目标数值。")
        }
        let (previous, current) = try services.goals.updateGoal(changes, effectiveFrom: sessionDate, requestID: requestID)
        var outcome = try Self.encode(GoalUpdateOut(previous: previous.map(GoalOut.Targets.init), current: GoalOut.Targets(current), effectiveFrom: sessionDate.isoString))
        outcome.goalChanged = true
        return outcome
    }

    // MARK: - 参数与编码

    private struct Failure: Error {
        var code: String
        var message: String

        init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    private static func string(_ value: JSONValue?, _ field: String) throws -> String {
        guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure("missingField", "缺少字段 \(field)。")
        }
        return text
    }

    private static func uuid(_ value: JSONValue?, _ field: String) throws -> UUID {
        guard let id = UUID(uuidString: try string(value, field)) else { throw Failure("invalidField", "字段 \(field) 不是有效 ID。") }
        return id
    }

    private static func date(_ text: String) throws -> LocalDate {
        guard let date = LocalDate(isoString: text) else { throw Failure("invalidField", "日期格式应为 YYYY-MM-DD。") }
        return date
    }

    private static func encode<T: Encodable>(_ value: T) throws -> ToolOutcome {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ToolOutcome(output: String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func failure(_ code: String, _ message: String) -> ToolOutcome {
        (try? encode(ToolResult.failure(code, message))) ?? ToolOutcome(output: #"{"ok":false}"#)
    }
}

// MARK: - 回给模型的结构

/// 数值保留一位小数，避免把计算误差的长尾交给模型。
private func rounded(_ value: Decimal, _ places: Int = 1) -> Decimal {
    var input = value
    var result = Decimal()
    NSDecimalRound(&result, &input, places, .plain)
    return result
}

private struct NutrientsOut: Encodable {
    var energyKcal: Decimal
    var proteinG: Decimal
    var fatG: Decimal
    var carbohydrateG: Decimal

    init(_ values: NutrientValues) {
        energyKcal = rounded(values.energyKcal)
        proteinG = rounded(values.proteinG)
        fatG = rounded(values.fatG)
        carbohydrateG = rounded(values.carbohydrateG)
    }
}

private struct QuantityOut: Encodable {
    var amount: Decimal
    var unit: String

    init(_ quantity: Quantity) {
        amount = rounded(quantity.amount)
        unit = quantity.unit.rawValue
    }
}

private struct EventTimeOut: Encodable {
    var precision: String
    var time: String?
    var mealPeriod: String?

    init(_ eventTime: EventTime) {
        precision = eventTime.precision.rawValue
        mealPeriod = eventTime.mealPeriod?.rawValue
        if let timestamp = eventTime.timestamp {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: eventTime.timeZoneIdentifier) ?? .current
            let parts = calendar.dateComponents([.hour, .minute], from: timestamp)
            time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
    }
}

private struct ItemOut: Encodable {
    var id: UUID
    var displayName: String
    var groupName: String?
    var originalAmountText: String
    var quantity: QuantityOut?
    var amountSource: String
    var nutritionSource: String
    var sourceRef: String?
    var estimateBasis: String?
    var includeInSummary: Bool
    var nutrients: NutrientsOut

    init(_ item: DayData.Item) {
        id = item.id
        displayName = item.displayName
        groupName = item.groupName
        originalAmountText = item.originalAmountText
        quantity = item.quantity.map(QuantityOut.init)
        amountSource = item.amountSource.rawValue
        nutritionSource = item.snapshot.nutritionSource.rawValue
        sourceRef = item.snapshot.sourceRef
        estimateBasis = item.snapshot.estimateBasis
        includeInSummary = item.includeInSummary
        nutrients = NutrientsOut(item.snapshot.values)
    }
}

private struct RecordOut: Encodable {
    var id: UUID
    var eventTime: EventTimeOut
    var mealLabel: String?
    var note: String?
    var items: [ItemOut]
    var totals: NutrientsOut

    init(_ record: DayData.Record) {
        id = record.id
        eventTime = EventTimeOut(record.eventTime)
        mealLabel = record.mealLabel
        note = record.note
        items = record.items.map(ItemOut.init)
        totals = NutrientsOut(record.totals)
    }
}

private struct DayOut: Encodable {
    struct PendingOut: Encodable {
        var id: UUID
        var expiresAt: Date
    }

    var date: String
    /// 提案时作为 `expectedRevision`。
    var revision: Int
    var writable: Bool
    var records: [RecordOut]
    var totals: NutrientsOut
    var goal: GoalOut.Targets?
    var activePending: PendingOut?

    init(_ day: DayData, pending: PendingSnapshot?, isSessionDate: Bool) {
        date = day.date.isoString
        revision = day.revision
        writable = isSessionDate
        records = day.records.map(RecordOut.init)
        totals = NutrientsOut(day.summary.totals)
        goal = day.summary.goal.map { GoalOut.Targets($0) }
        activePending = pending.map { PendingOut(id: $0.id, expiresAt: $0.expiresAt) }
    }
}

private struct ProductOut: Encodable {
    var productId: UUID
    var name: String
    var brandOrSupplier: String?
    var package: QuantityOut?
    var activeVersionId: UUID?
    var basis: QuantityOut?
    var nutrientsPerBasis: NutrientsOut?

    init(_ product: FoodProductSummary) {
        productId = product.id
        name = product.name
        brandOrSupplier = product.brandOrSupplier
        package = product.package.map(QuantityOut.init)
        activeVersionId = product.activeVersion?.id
        basis = product.activeVersion.map { QuantityOut($0.basis.quantity) }
        nutrientsPerBasis = product.activeVersion.map { NutrientsOut($0.basis.nutrients) }
    }
}

private struct PersonalSearchOut: Encodable {
    var products: [ProductOut]
    var note: String?
}

private struct ReferenceSearchOut: Encodable {
    struct Match: Encodable {
        var referenceFoodId: String
        var name: String
        var aliases: [String]
        var preparationState: String
        var per100g: NutrientsOut
        var densityGPerMl: Decimal?
    }

    var matches: [Match]
    var note: String?

    init(matches foods: [ReferenceFood]) {
        // 精确查询本身就很窄，多于 10 条时只给前 10 条。
        matches = foods.prefix(10).map {
            Match(referenceFoodId: $0.id, name: $0.canonicalName, aliases: $0.aliases, preparationState: $0.preparationState,
                  per100g: NutrientsOut($0.nutrients), densityGPerMl: $0.densityGPerMl)
        }
        note = switch foods.count {
        case 0: "没有命中。可换常见写法再查；仍没有时用 aiEstimated。"
        case 1: nil
        default: "命中多个候选，请先问用户是哪一种。"
        }
    }
}

private struct GoalOut: Encodable {
    struct Targets: Encodable {
        var energyKcal: Decimal?
        var proteinG: Decimal?
        var fatG: Decimal?
        var carbohydrateG: Decimal?
        var effectiveFrom: String
        var origin: String

        init(_ goal: GoalSnapshot) {
            energyKcal = goal.targets.energyKcal.map { rounded($0, 0) }
            proteinG = goal.targets.proteinG.map { rounded($0, 0) }
            fatG = goal.targets.fatG.map { rounded($0, 0) }
            carbohydrateG = goal.targets.carbohydrateG.map { rounded($0, 0) }
            effectiveFrom = goal.effectiveFrom.isoString
            origin = goal.origin.rawValue
        }
    }

    var goal: Targets?
    var note: String?

    init(_ goal: GoalSnapshot?) {
        self.goal = goal.map(Targets.init)
        note = goal == nil ? "还没有每日目标。可调用 getGoalRecommendation 预览建议，再请用户在 Data 页的目标设定里确认。" : nil
    }
}

private struct GoalUpdateOut: Encodable {
    var ok = true
    var previous: GoalOut.Targets?
    var current: GoalOut.Targets
    var effectiveFrom: String
}

private struct HealthOut: Encodable {
    struct Reading<Value: Encodable>: Encodable {
        var value: Value?
        var source: String?
        var status: String
    }

    var authorizationRequested: Bool
    var bodyMassKg: Reading<Decimal>
    var heightCm: Reading<Decimal>
    var bodyFatPercent: Reading<Decimal>
    var dateOfBirth: Reading<String>
    var sex: Reading<String>
    var activeEnergyKcal: Reading<Decimal>
    var sleepHours: Reading<Decimal>

    init(_ snapshot: HealthSnapshot) {
        func reading<V, Out>(_ reading: HealthReading<V>, _ transform: (V) -> Out) -> Reading<Out> {
            switch reading {
            case .value(let value, let source, _): Reading(value: transform(value), source: source.rawValue, status: "value")
            case .noData: Reading(value: nil, source: nil, status: "noData")
            case .failed: Reading(value: nil, source: nil, status: "failed")
            }
        }
        authorizationRequested = snapshot.authorizationRequested
        bodyMassKg = reading(snapshot.bodyMassKg) { rounded($0) }
        heightCm = reading(snapshot.heightCm) { rounded($0, 0) }
        bodyFatPercent = reading(snapshot.bodyFatFraction) { rounded($0 * 100) }
        dateOfBirth = reading(snapshot.dateOfBirth) { $0.isoString }
        sex = reading(snapshot.sex) { $0.rawValue }
        activeEnergyKcal = reading(snapshot.activeEnergyKcal) { rounded($0, 0) }
        sleepHours = reading(snapshot.sleepHours) { rounded($0) }
    }
}

private struct RecommendationOut: Encodable {
    struct Ready: Encodable {
        var energyKcal: Decimal?
        var proteinG: Decimal?
        var bmrKcal: Decimal
        var tdeeKcal: Decimal
        var tdeeEstimated: Bool
        var inputs: [String: String]
        var formula: String
    }

    var ready: Ready?
    var missing: [String]?
    var note: String

    init(_ result: GoalRecommendationResult) {
        switch result {
        case .ready(let recommendation):
            let input = recommendation.input
            ready = Ready(
                energyKcal: recommendation.targets.energyKcal.map { rounded($0, 0) },
                proteinG: recommendation.targets.proteinG.map { rounded($0, 0) },
                bmrKcal: rounded(recommendation.bmrKcal, 0),
                tdeeKcal: rounded(recommendation.tdeeKcal, 0),
                tdeeEstimated: recommendation.tdeeEstimated,
                inputs: [
                    "bodyMassKg": "\(rounded(input.bodyMassKg)) (\(input.weightSource.rawValue))",
                    "heightCm": "\(rounded(input.heightCm, 0)) (\(input.heightSource.rawValue))",
                    "ageYears": "\(input.ageYears) (\(input.ageSource.rawValue))",
                    "sex": "\(input.sex.rawValue) (\(input.sexSource.rawValue))",
                ],
                formula: "Mifflin–St Jeor BMR；TDEE = BMR + 当日活动能量（缺失时 BMR × 1.375）；能量 = 90% TDEE；蛋白质 = 1.8 g/kg"
            )
            note = "这只是预览，没有保存。请用户在 Data 页“生成每日目标”里确认。"
        case .missing(let metrics):
            missing = metrics.map(\.rawValue)
            note = "缺少数据，无法生成。可请用户在 Data 页的目标设定里补录。"
        }
    }
}
