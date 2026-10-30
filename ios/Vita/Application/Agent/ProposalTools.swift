import Foundation

/// 模型调用 Propose 级工具时的参数（agent-tools.md）。模型提交的是“意图”，不是可直接写入的实体：
/// 用量单位由客户端标准化，personal / reference 的营养值由客户端计算（即使模型带了也不解码），
/// 事件时间由客户端按 Session 日期与时区构造，没表达时间则注入 `defaultedEntryTime`。
enum ProposalArguments {
    /// 公共信封。`sessionDate` 是模型以为的日期，只用于发现它想写别的日期。
    struct Envelope<Payload: Decodable>: Decodable {
        var requestId: UUID
        var sessionDate: String
        var expectedRevision: Int
        var payload: Payload
    }

    struct RecordChangePayload: Decodable {
        enum Intent: String, Decodable { case create, appendItems, replaceItem, removeItem }

        var intent: Intent
        var recordId: UUID?
        var itemId: UUID?
        var record: RecordArgs?
        var items: [ItemArgs]?
        var item: ItemArgs?
        /// 修正当前 Pending 时填它的 ID；否则当天已有 Pending 会拒绝新的独立写入。
        var replacesPendingId: UUID?
    }

    struct RecordDeletionPayload: Decodable {
        var recordId: UUID
        var replacesPendingId: UUID?
    }

    struct FoodChangePayload: Decodable {
        enum Intent: String, Decodable { case createProduct, addVersion }

        var intent: Intent
        var productId: UUID?
        /// addVersion 时模型看到的生效版本，用来发现提案后产品已被更新。
        var expectedActiveVersionId: UUID?
        var product: ProductArgs?
        var version: VersionArgs
        var replacesPendingId: UUID?
    }

    struct ProductArgs: Decodable {
        var name: String
        var brandOrSupplier: String?
        var package: QuantityArgs?
        var note: String?
    }

    /// `source` 只接受 nutritionLabel / manualEntry / referenceDerived；AI 估算不能沉淀为食品版本。
    struct VersionArgs: Decodable {
        var source: String
        /// nutritionLabel：`attachNutritionLabel` 返回的识别 ID。
        var labelScanId: UUID?
        /// referenceDerived：起点条目；营养值由客户端从参考库复制，模型给的忽略。
        var referenceFoodId: String?
        var basis: QuantityArgs?
        var values: NutrientValues?
        var note: String?
    }

    struct RecordArgs: Decodable {
        var eventTime: EventTimeArgs?
        var mealLabel: String?
        var note: String?
        var items: [ItemArgs]
    }

    struct EventTimeArgs: Decodable {
        var precision: TimePrecision
        /// `HH:mm`，仅 exact / approximate。
        var time: String?
        var mealPeriod: MealPeriod?
    }

    struct ItemArgs: Decodable {
        var displayName: String
        var groupName: String?
        var originalAmountText: String
        var quantity: QuantityArgs?
        var amountSource: AmountSource
        var nutrition: NutritionArgs
        var includeInSummary: Bool?
    }

    struct QuantityArgs: Decodable {
        var amount: Decimal
        var unit: String
    }

    struct NutritionArgs: Decodable {
        enum Source: String, Decodable { case personalFoodVersion, referenceFood, aiEstimated }

        var source: Source
        var foodVersionId: UUID?
        var referenceFoodId: String?
        var values: NutrientValues?
        var estimateBasis: String?
    }
}

enum ProposalToolError: Error, Equatable {
    case unknownTool(String)
    case malformedArguments(String)
    case missingField(String)
    case invalidField(String)
    /// 模型以为的日期与当前界面日期不同。
    case dateMismatch(requested: String)
    /// 想把 AI 估算或其他未知来源存成食品版本。
    case estimateNotAllowed
}

/// 返回给模型的结构化结果。错误只给机器码与一句可解释的说明，不含内部细节。
struct ToolResult: Equatable, Encodable, Sendable {
    struct Failure: Equatable, Encodable, Sendable {
        var code: String
        var message: String
    }

    var ok: Bool
    var pendingId: UUID?
    /// 模型想写的日期与当前界面日期不同：请用户切换，客户端不自动导航、不跨日期写入（TDD §5.2）。
    var requestedDate: String?
    var error: Failure?

    static func failure(_ code: String, _ message: String, requestedDate: String? = nil) -> ToolResult {
        ToolResult(ok: false, requestedDate: requestedDate, error: Failure(code: code, message: message))
    }
}

/// 处理 `proposeRecordChange` / `proposeRecordDeletion`。只会创建或替换 Pending，不写正式数据。
@MainActor
final class ProposalToolHandler {
    static let toolNames: Set<String> = ["proposeRecordChange", "proposeRecordDeletion", "proposeFoodChange"]

    private let pending: PendingService
    private let referenceFoods: ReferenceFoodCatalog
    private let labels: LabelScanService?
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(
        pending: PendingService,
        referenceFoods: ReferenceFoodCatalog = .empty,
        labels: LabelScanService? = nil,
        now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.pending = pending
        self.referenceFoods = referenceFoods
        self.labels = labels
        self.now = now
        self.timeZone = timeZone
    }

    /// `sessionDate` 由客户端从当前界面状态注入，不信任模型给的日期。
    func handle(tool: String, arguments: Data, sessionDate: LocalDate) -> ToolResult {
        do {
            let (envelope, change, replacing) = try decode(tool: tool, arguments: arguments, sessionDate: sessionDate)
            let snapshot = switch change {
            case .record(let change):
                try pending.propose(change, on: sessionDate, expectedRevision: envelope.expectedRevision, replacing: replacing, requestID: envelope.requestID)
            case .food(let change):
                try pending.propose(food: change, on: sessionDate, replacing: replacing, requestID: envelope.requestID)
            }
            return ToolResult(ok: true, pendingId: snapshot.id)
        } catch let error as ProposalToolError {
            return Self.result(for: error)
        } catch let error as PendingServiceError {
            return Self.result(for: error)
        } catch let error as RecordServiceError {
            return Self.result(for: error)
        } catch let error as FoodServiceError {
            return Self.result(for: error)
        } catch {
            return .failure("internal", "客户端暂时无法处理这个提案。")
        }
    }

    // MARK: - 解码

    private struct EnvelopeInfo {
        var expectedRevision: Int
        var requestID: UUID
    }

    private func decode(tool: String, arguments: Data, sessionDate: LocalDate) throws -> (EnvelopeInfo, PendingChange, UUID?) {
        let decoder = JSONDecoder()
        do {
            switch tool {
            case "proposeRecordChange":
                let envelope = try decoder.decode(ProposalArguments.Envelope<ProposalArguments.RecordChangePayload>.self, from: arguments)
                let info = try Self.info(envelope, sessionDate: sessionDate)
                return (info, .record(try change(from: envelope.payload, sessionDate: sessionDate)), envelope.payload.replacesPendingId)
            case "proposeRecordDeletion":
                let envelope = try decoder.decode(ProposalArguments.Envelope<ProposalArguments.RecordDeletionPayload>.self, from: arguments)
                return (try Self.info(envelope, sessionDate: sessionDate), .record(.deleteRecord(recordID: envelope.payload.recordId)), envelope.payload.replacesPendingId)
            case "proposeFoodChange":
                let envelope = try decoder.decode(ProposalArguments.Envelope<ProposalArguments.FoodChangePayload>.self, from: arguments)
                let info = try Self.info(envelope, sessionDate: sessionDate)
                return (info, .food(try foodChange(from: envelope.payload)), envelope.payload.replacesPendingId)
            default:
                throw ProposalToolError.unknownTool(tool)
            }
        } catch let error as DecodingError {
            throw ProposalToolError.malformedArguments(Self.describe(error))
        }
    }

    /// 日期不符时不再解析内容，直接请求切换。
    private static func info<P>(_ envelope: ProposalArguments.Envelope<P>, sessionDate: LocalDate) throws -> EnvelopeInfo {
        guard LocalDate(isoString: envelope.sessionDate) == sessionDate else {
            throw ProposalToolError.dateMismatch(requested: envelope.sessionDate)
        }
        return EnvelopeInfo(expectedRevision: envelope.expectedRevision, requestID: envelope.requestId)
    }

    private func change(from payload: ProposalArguments.RecordChangePayload, sessionDate: LocalDate) throws -> RecordChange {
        func require<T>(_ value: T?, _ field: String) throws -> T {
            guard let value else { throw ProposalToolError.missingField(field) }
            return value
        }
        switch payload.intent {
        case .create:
            let record = try require(payload.record, "payload.record")
            return .create(RecordDraft(
                eventTime: try eventTime(record.eventTime, sessionDate: sessionDate),
                mealLabel: record.mealLabel,
                note: record.note,
                items: try record.items.map(item)
            ))
        case .appendItems:
            return .appendItems(recordID: try require(payload.recordId, "payload.recordId"), items: try require(payload.items, "payload.items").map(item))
        case .replaceItem:
            return .replaceItem(
                recordID: try require(payload.recordId, "payload.recordId"),
                itemID: try require(payload.itemId, "payload.itemId"),
                item: try item(require(payload.item, "payload.item"))
            )
        case .removeItem:
            return .removeItem(recordID: try require(payload.recordId, "payload.recordId"), itemID: try require(payload.itemId, "payload.itemId"))
        }
    }

    private func foodChange(from payload: ProposalArguments.FoodChangePayload) throws -> FoodChange {
        let version = try versionDraft(payload.version)
        switch payload.intent {
        case .createProduct:
            guard let product = payload.product else { throw ProposalToolError.missingField("payload.product") }
            let package: Quantity?
            do {
                package = try product.package.map { try UnitNormalizer.normalize(amount: $0.amount, unit: $0.unit) }
            } catch {
                throw ProposalToolError.invalidField("payload.product.package")
            }
            return .createProduct(
                FoodProductDraft(name: product.name, brandOrSupplier: product.brandOrSupplier, package: package, note: product.note),
                version: version
            )
        case .addVersion:
            guard let productID = payload.productId else { throw ProposalToolError.missingField("payload.productId") }
            return .addVersion(productID: productID, expectedActiveVersionID: payload.expectedActiveVersionId, version: version)
        }
    }

    private func versionDraft(_ args: ProposalArguments.VersionArgs) throws -> FoodVersionDraft {
        switch args.source {
        case FoodVersionSource.referenceDerived.rawValue:
            guard let id = args.referenceFoodId else { throw ProposalToolError.missingField("payload.version.referenceFoodId") }
            guard let food = referenceFoods.food(id: id) else { throw ProposalToolError.invalidField("payload.version.referenceFoodId") }
            return FoodVersionDraft(
                basis: FoodVersionBasis(quantity: food.base.asQuantity, nutrients: food.nutrients),
                sourceKind: .referenceDerived, derivedFromReferenceID: id, sourceNote: args.note
            )
        case FoodVersionSource.nutritionLabel.rawValue, FoodVersionSource.manualEntry.rawValue:
            let kind = FoodVersionSource(rawValue: args.source)!
            guard let basisArgs = args.basis else { throw ProposalToolError.missingField("payload.version.basis") }
            guard let values = args.values else { throw ProposalToolError.missingField("payload.version.values") }
            let basis: Quantity
            do {
                basis = try UnitNormalizer.normalize(amount: basisArgs.amount, unit: basisArgs.unit)
            } catch {
                throw ProposalToolError.invalidField("payload.version.basis")
            }
            var labelReference: String?
            if kind == .nutritionLabel {
                guard let scanID = args.labelScanId else { throw ProposalToolError.missingField("payload.version.labelScanId") }
                guard let reference = try labels?.imageReference(forScan: scanID) else { throw ProposalToolError.invalidField("payload.version.labelScanId") }
                labelReference = reference
            }
            return FoodVersionDraft(
                basis: FoodVersionBasis(quantity: basis, nutrients: values),
                sourceKind: kind, labelImageReference: labelReference, sourceNote: args.note
            )
        default:
            throw ProposalToolError.estimateNotAllowed
        }
    }

    private func eventTime(_ args: ProposalArguments.EventTimeArgs?, sessionDate: LocalDate) throws -> EventTime {
        let zone = timeZone()
        guard let args else {
            // 用户完全没表达时间：客户端（而非模型）注入录入时刻（ADR-011）。
            return try EventTime.defaultedEntryTime(sessionDate: sessionDate, now: now(), timeZone: zone)
        }
        do {
            switch args.precision {
            case .exact, .approximate:
                let timestamp = try clockTime(args.time, on: sessionDate, timeZone: zone)
                return try EventTime(localDate: sessionDate, precision: args.precision, timestamp: timestamp, timeZoneIdentifier: zone.identifier)
            case .mealPeriod:
                return try EventTime(localDate: sessionDate, precision: .mealPeriod, mealPeriod: args.mealPeriod, timeZoneIdentifier: zone.identifier)
            case .dateOnly:
                return try EventTime(localDate: sessionDate, precision: .dateOnly, timeZoneIdentifier: zone.identifier)
            case .defaultedEntryTime:
                // 只能由客户端注入；模型应省略 eventTime。
                throw ProposalToolError.invalidField("payload.record.eventTime.precision")
            }
        } catch is EventTimeError {
            throw ProposalToolError.invalidField("payload.record.eventTime")
        }
    }

    private func clockTime(_ text: String?, on date: LocalDate, timeZone: TimeZone) throws -> Date {
        let parts = (text ?? "").split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw ProposalToolError.invalidField("payload.record.eventTime.time")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let result = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute)) else {
            throw ProposalToolError.invalidField("payload.record.eventTime.time")
        }
        return result
    }

    private func item(_ args: ProposalArguments.ItemArgs) throws -> ItemDraft {
        let quantity: Quantity?
        do {
            quantity = try args.quantity.map { try UnitNormalizer.normalize(amount: $0.amount, unit: $0.unit) }
        } catch {
            throw ProposalToolError.invalidField("item.quantity")
        }
        let nutrition: NutritionInput
        switch args.nutrition.source {
        case .referenceFood:
            guard let id = args.nutrition.referenceFoodId else { throw ProposalToolError.missingField("item.nutrition.referenceFoodId") }
            nutrition = .referenceFood(id)
        case .personalFoodVersion:
            guard let id = args.nutrition.foodVersionId else { throw ProposalToolError.missingField("item.nutrition.foodVersionId") }
            nutrition = .personalFoodVersion(id)
        case .aiEstimated:
            guard let values = args.nutrition.values else { throw ProposalToolError.missingField("item.nutrition.values") }
            guard let basis = args.nutrition.estimateBasis else { throw ProposalToolError.missingField("item.nutrition.estimateBasis") }
            nutrition = .aiEstimated(values, estimateBasis: basis)
        }
        return ItemDraft(
            displayName: args.displayName,
            groupName: args.groupName,
            originalAmountText: args.originalAmountText,
            quantity: quantity,
            amountSource: args.amountSource,
            nutrition: nutrition,
            includeInSummary: args.includeInSummary ?? true
        )
    }

    // MARK: - 错误映射

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context): (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.map(\.stringValue).joined(separator: ".")
        @unknown default: "arguments"
        }
    }

    private static func result(for error: ProposalToolError) -> ToolResult {
        switch error {
        case .unknownTool(let name): .failure("unknownTool", "没有名为 \(name) 的工具。")
        case .malformedArguments(let path): .failure("malformedArguments", "参数格式不对：\(path)。")
        case .missingField(let field): .failure("missingField", "缺少字段 \(field)。")
        case .invalidField(let field): .failure("invalidField", "字段 \(field) 的值不合法。")
        case .dateMismatch(let requested): .failure("requiresDateSwitch", "请让用户切换到 \(requested) 再记录。", requestedDate: requested)
        case .estimateNotAllowed:
            .failure("estimateNotAllowed", "AI 估算不能保存为个人食品。只有营养标签、用户提供的数值或公共参考库可以作为来源。")
        }
    }

    private static func result(for error: PendingServiceError) -> ToolResult {
        switch error {
        case .anotherPendingActive(let id):
            .failure("pendingActive", "当天已有一张待确认卡片（\(id.uuidString)）。修正它请带上 replacesPendingId；否则请等用户确认或取消。")
        case .notFound: .failure("pendingNotFound", "要替换的待确认卡片不存在或已结束。")
        default: .failure("pendingUnavailable", "待确认卡片不可用，请重新提出。")
        }
    }

    private static func result(for error: FoodServiceError) -> ToolResult {
        switch error {
        case .activeVersionChanged: .failure("revisionConflict", "这个食品在提案后已更新，请重新读取后再提出。")
        case .productNotFound: .failure("productNotFound", "个人食品库中没有这个产品。")
        case .unknownLabel: .failure("unknownLabel", "找不到对应的营养标签识别结果。")
        default: .failure("invalidFood", "食品数据不合格：\(error.auditCode)。")
        }
    }

    private static func result(for error: RecordServiceError) -> ToolResult {
        switch error {
        case .revisionConflict: .failure("revisionConflict", "当天数据已变化，请重新读取后再提出。")
        case .recordNotFound, .recordNotInSession: .failure("recordNotFound", "该记录不在当前日期中。")
        case .itemNotFound: .failure("itemNotFound", "该条目不在这条记录中。")
        case .emptyRecord: .failure("emptyRecord", "记录至少要有一项；要删除整条记录请用 proposeRecordDeletion。")
        case .eventTimeOutsideSession: .failure("eventTimeOutsideSession", "事件时间不在当前日期内。")
        case .invalidItem(let index, let reason): .failure("invalidItem", "第 \(index + 1) 项不合格：\(reason.code)。")
        }
    }
}
