import Foundation

// Vita API 的响应与请求，按 `packages/contract/src/index.ts` 手写。字段和契约一致的直接复用领域类型
// （NutrientValues、Quantity、NutritionSnapshot、DayData.Item、GoalTargets 等），其余在这里转换成界面已有的模型。

extension UUID {
    /// 服务端的 ID 是小写（SQLite 按原样比较）；Swift 默认输出大写，发给 API 的 ID 一律用这个。
    var apiString: String { uuidString.lowercased() }
}

// MARK: - 设备

struct DeviceDTO: Decodable, Equatable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var revokedAt: Date?
}

struct MeResponseDTO: Decodable, Sendable {
    var device: DeviceDTO
}

// MARK: - 时间

struct EventTimeDTO: Codable, Sendable {
    var localDate: LocalDate
    var precision: TimePrecision
    var timestamp: Date?
    var mealPeriod: MealPeriod?
    var timeZone: String

    init(_ eventTime: EventTime) {
        localDate = eventTime.localDate
        precision = eventTime.precision
        timestamp = eventTime.timestamp
        mealPeriod = eventTime.mealPeriod
        timeZone = eventTime.timeZoneIdentifier
    }

    func domain() throws -> EventTime {
        try EventTime(localDate: localDate, precision: precision, timestamp: timestamp, mealPeriod: mealPeriod, timeZoneIdentifier: timeZone)
    }
}

// MARK: - 一天的数据

struct DayRecordDTO: Decodable, Sendable {
    var id: UUID
    var eventTime: EventTimeDTO
    var mealLabel: String?
    var note: String?
    var revision: Int
    var items: [DayData.Item]

    func domain(healthSync: SyncState?) throws -> DayData.Record {
        DayData.Record(
            id: id, eventTime: try eventTime.domain(), mealLabel: mealLabel, note: note,
            revision: revision, items: items, healthSync: healthSync
        )
    }
}

enum EnergyAdjustmentDTO: Codable, Equatable, Sendable {
    case fraction(Decimal)
    case kcal(Decimal)

    private enum CodingKeys: String, CodingKey { case type, value }

    init(_ adjustment: EnergyPlan.Adjustment) {
        switch adjustment {
        case .fraction(let value): self = .fraction(value)
        case .kcal(let value): self = .kcal(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Decimal.self, forKey: .value)
        switch try container.decode(String.self, forKey: .type) {
        case "fraction": self = .fraction(value)
        case "kcal": self = .kcal(value)
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown adjustment \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fraction(let value):
            try container.encode("fraction", forKey: .type)
            try container.encode(value, forKey: .value)
        case .kcal(let value):
            try container.encode("kcal", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    var domain: EnergyPlan.Adjustment {
        switch self {
        case .fraction(let value): .fraction(value)
        case .kcal(let value): .kcal(value)
        }
    }
}

struct EnergyPlanDTO: Codable, Sendable {
    var kind: EnergyPlan.Kind
    var adjustment: EnergyAdjustmentDTO
    var bmrKcal: Decimal
    var baselineActivityKcal: Decimal
    var baselineEstimated: Bool

    init(_ plan: EnergyPlan) {
        kind = plan.kind
        adjustment = EnergyAdjustmentDTO(plan.adjustment)
        bmrKcal = plan.bmrKcal
        baselineActivityKcal = plan.baselineActivityKcal
        baselineEstimated = plan.baselineEstimated
    }

    var domain: EnergyPlan {
        EnergyPlan(kind: kind, adjustment: adjustment.domain, bmrKcal: bmrKcal, baselineActivityKcal: baselineActivityKcal, baselineEstimated: baselineEstimated)
    }
}

struct GoalDTO: Codable, Sendable {
    var id: UUID
    var effectiveFrom: LocalDate
    var targets: GoalTargets
    var energyPlan: EnergyPlanDTO?
    var origin: GoalOrigin
    var revision: Int

    var domain: GoalSnapshot {
        GoalSnapshot(id: id, effectiveFrom: effectiveFrom, targets: targets, origin: origin, revision: revision, energyPlan: energyPlan?.domain)
    }
}

struct EnergyTargetDTO: Decodable, Sendable {
    var targetKcal: Decimal
    var bmrKcal: Decimal
    var baselineActivityKcal: Decimal
    var projectedActivityKcal: Decimal
    var countedActivityKcal: Decimal
    var tdeeKcal: Decimal
    var adjustmentKcal: Decimal
    var raisedToBMR: Bool
    var activityEstimated: Bool

    var domain: EnergyTarget {
        EnergyTarget(
            targetKcal: targetKcal, bmrKcal: bmrKcal, baselineActivityKcal: baselineActivityKcal,
            projectedActivityKcal: projectedActivityKcal, countedActivityKcal: countedActivityKcal, tdeeKcal: tdeeKcal,
            adjustmentKcal: adjustmentKcal, raisedToBMR: raisedToBMR, activityEstimated: activityEstimated
        )
    }
}

struct EnergyBalanceDTO: Decodable, Sendable {
    var burnedKcal: Decimal
    var consumedKcal: Decimal
}

struct DaySummaryDTO: Decodable, Sendable {
    struct MissingExtras: Decodable, Sendable {
        var sodiumMg: Int
        var saturatedFatG: Int
        var sugarG: Int
    }

    var totals: NutrientValues
    var includedItemCount: Int
    var missingExtras: MissingExtras?
    var excludedItemCount: Int
    var estimatedItemCount: Int
    var goal: GoalDTO?
    var energy: EnergyTargetDTO?
    var balance: EnergyBalanceDTO?
    /// 2.5.0 起；旧服务端没有这个字段。
    var bmrChange: BmrChangeDTO?

    var domain: DaySummary {
        DaySummary(
            totals: totals, includedItemCount: includedItemCount, excludedItemCount: excludedItemCount,
            estimatedItemCount: estimatedItemCount, goal: goal?.domain, energy: energy?.domain,
            balance: balance.map { EnergyBalance(burnedKcal: $0.burnedKcal, consumedKcal: $0.consumedKcal) },
            missingExtras: missingExtras.map { [.sodiumMg: $0.sodiumMg, .saturatedFatG: $0.saturatedFatG, .sugarG: $0.sugarG] } ?? [:],
            bmrChange: bmrChange?.domain
        )
    }
}

struct BmrChangeDTO: Decodable, Sendable {
    var previousBmrKcal: Decimal
    var bmrKcal: Decimal
    var reason: String
    var weightKg: Decimal

    var domain: BmrChange {
        BmrChange(previousBmrKcal: previousBmrKcal, bmrKcal: bmrKcal, reason: BmrChange.Reason(rawValue: reason), weightKg: weightKg)
    }
}

struct DayResponseDTO: Decodable, Sendable {
    var date: LocalDate
    var revision: Int
    var records: [DayRecordDTO]
    var summary: DaySummaryDTO

    func domain(healthSync: (UUID) -> SyncState?) throws -> DayData {
        DayData(date: date, revision: revision, records: try records.map { try $0.domain(healthSync: healthSync($0.id)) }, summary: summary.domain)
    }
}

// MARK: - 个人食品库

struct FoodVersionDTO: Codable, Sendable {
    var id: UUID
    var basis: FoodVersionBasis
    var sourceKind: FoodVersionSource
    var labelScanId: UUID?
    var derivedFromReferenceId: String?
    var sourceNote: String?
    var createdAt: Date
    var retiredAt: Date?

    /// 标签照片的引用改为 labelScanId，经 `LabelScanService.imageData` 从 API 读取。
    var domain: FoodVersionSummary {
        FoodVersionSummary(
            id: id, basis: basis, sourceKind: sourceKind, labelImageReference: labelScanId?.uuidString,
            derivedFromReferenceID: derivedFromReferenceId, sourceNote: sourceNote, createdAt: createdAt, retiredAt: retiredAt
        )
    }
}

struct FoodProductDTO: Decodable, Sendable {
    var id: UUID
    var name: String
    var brandOrSupplier: String?
    var package: Quantity?
    var note: String?
    var aliases: [String]?
    var activeVersion: FoodVersionDTO?
    var versions: [FoodVersionDTO]

    var domain: FoodProductSummary {
        FoodProductSummary(
            id: id, name: name, brandOrSupplier: brandOrSupplier, package: package, note: note, aliases: aliases ?? [],
            activeVersion: activeVersion?.domain, versions: versions.map(\.domain)
        )
    }
}

struct FoodsResponseDTO: Decodable, Sendable {
    var products: [FoodProductDTO]
}

// MARK: - 确认卡

struct RecordChangePreviewDTO: Decodable, Sendable {
    var kind: ChangePreview.Kind
    var recordLabel: String?
    var eventTime: EventTimeDTO
    var items: [DayData.Item]
    var removedItemNames: [String]
    var regroupedItems: [DayData.Item]?

    func domain() throws -> ChangePreview {
        ChangePreview(
            kind: kind, recordLabel: recordLabel, eventTime: try eventTime.domain(), items: items,
            removedItemNames: removedItemNames, regroupedItems: regroupedItems
        )
    }
}

struct FoodChangePreviewDTO: Decodable, Sendable {
    var kind: FoodChangePreview.Kind
    var productName: String
    var brandOrSupplier: String?
    var package: Quantity?
    var aliases: [String]?
    var previous: FoodChangePreview.Previous?
    var basis: FoodVersionBasis
    var sourceKind: FoodVersionSource
    var previousBasis: FoodVersionBasis?

    var domain: FoodChangePreview {
        FoodChangePreview(
            kind: kind, productName: productName, brandOrSupplier: brandOrSupplier, package: package,
            aliases: aliases ?? [], previous: previous,
            version: FoodVersionDraft(basis: basis, sourceKind: sourceKind), previousBasis: previousBasis
        )
    }
}

struct PendingDTO: Decodable, Sendable {
    struct Preview: Decodable, Sendable {
        var type: String
        var record: RecordChangePreviewDTO?
        var food: FoodChangePreviewDTO?
    }

    var id: UUID
    var sessionDate: LocalDate
    var status: PendingStatus
    var createdAt: Date
    var expiresAt: Date
    var preview: Preview?
    var resolutionCode: String?
    var resultId: UUID?
    var afterConfirm: String?

    func domain() throws -> PendingSnapshot {
        let preview: PendingPreview? = if let record = self.preview?.record {
            .record(try record.domain())
        } else if let food = self.preview?.food {
            .food(food.domain)
        } else {
            nil
        }
        return PendingSnapshot(
            id: id, sessionDate: sessionDate, status: status, createdAt: createdAt, expiresAt: expiresAt,
            preview: preview, resolutionCode: resolutionCode, resultRecordID: resultId, afterConfirm: afterConfirm
        )
    }
}

struct ActivePendingResponseDTO: Decodable, Sendable {
    var pending: PendingDTO?
}

struct PendingResponseDTO: Decodable, Sendable {
    var pending: PendingDTO
}

// MARK: - 健康数据

/// 契约里的读数：`{status: value | noData | failed}`。
struct HealthReadingDTO<Value: Codable & Equatable & Sendable>: Codable, Sendable {
    var status: String
    var value: Value?
    var source: MetricSource?
    var measuredAt: Date?
    var message: String?

    init(_ reading: HealthReading<Value>) {
        switch reading {
        case .value(let value, let source, let measuredAt):
            status = "value"
            self.value = value
            self.source = source
            self.measuredAt = measuredAt
        case .noData:
            status = "noData"
        case .failed(let message):
            status = "failed"
            self.message = message
        }
    }

    var domain: HealthReading<Value> {
        switch status {
        case "value":
            if let value, let source { .value(value, source: source, measuredAt: measuredAt) } else { .noData }
        case "failed": .failed(message ?? "")
        default: .noData
        }
    }

    /// `value` 状态下 measuredAt 必须出现（可以是 null），这里显式写出 null。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        switch status {
        case "value":
            try container.encode(value, forKey: .value)
            try container.encode(source, forKey: .source)
            try container.encode(measuredAt, forKey: .measuredAt)
        case "failed":
            try container.encode(message ?? "", forKey: .message)
        default:
            break
        }
    }

    private enum CodingKeys: String, CodingKey { case status, value, source, measuredAt, message }
}

/// PUT /v1/health/snapshot：手机读到的身体数据（不含手动补录，补录在服务端合并）。
struct HealthUploadDTO: Encodable, Sendable {
    var bodyMassKg: HealthReadingDTO<Decimal>
    var heightCm: HealthReadingDTO<Decimal>
    var bodyFatFraction: HealthReadingDTO<Decimal>
    var dateOfBirth: HealthReadingDTO<LocalDate>
    var sex: HealthReadingDTO<BiologicalSex>
    var sleepHours: HealthReadingDTO<Decimal>
    var authorizationRequested: Bool
    var writeDenied: Bool

    init(_ snapshot: HealthSnapshot) {
        bodyMassKg = .init(snapshot.bodyMassKg)
        heightCm = .init(snapshot.heightCm)
        bodyFatFraction = .init(snapshot.bodyFatFraction)
        dateOfBirth = .init(snapshot.dateOfBirth)
        sex = .init(snapshot.sex)
        sleepHours = .init(snapshot.sleepHours)
        authorizationRequested = snapshot.authorizationRequested
        writeDenied = snapshot.writeDenied
    }
}

struct HealthSnapshotDTO: Decodable, Sendable {
    var bodyMassKg: HealthReadingDTO<Decimal>
    var heightCm: HealthReadingDTO<Decimal>
    var bodyFatFraction: HealthReadingDTO<Decimal>
    var dateOfBirth: HealthReadingDTO<LocalDate>
    var sex: HealthReadingDTO<BiologicalSex>
    var sleepHours: HealthReadingDTO<Decimal>
    var authorizationRequested: Bool
    var writeDenied: Bool
    var activeEnergyKcal: HealthReadingDTO<Decimal>
    var averageActiveEnergyKcal: HealthReadingDTO<Decimal>

    var domain: HealthSnapshot {
        HealthSnapshot(
            bodyMassKg: bodyMassKg.domain, heightCm: heightCm.domain, bodyFatFraction: bodyFatFraction.domain,
            dateOfBirth: dateOfBirth.domain, sex: sex.domain, activeEnergyKcal: activeEnergyKcal.domain,
            averageActiveEnergyKcal: averageActiveEnergyKcal.domain, sleepHours: sleepHours.domain,
            authorizationRequested: authorizationRequested, writeDenied: writeDenied
        )
    }
}

struct ActivityUploadDTO: Encodable, Sendable {
    struct Day: Encodable, Sendable {
        var date: LocalDate
        var activeKcal: Decimal?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date, forKey: .date)
            try container.encode(activeKcal, forKey: .activeKcal)
        }

        private enum CodingKeys: String, CodingKey { case date, activeKcal }
    }

    var days: [Day]
}

struct ManualBodyMetricsDTO: Codable, Sendable {
    var bodyMassKg: Decimal?
    var heightCm: Decimal?
    var bodyFatFraction: Decimal?
    var dateOfBirth: LocalDate?
    var sex: BiologicalSex?

    init(_ metrics: ManualBodyMetrics) {
        bodyMassKg = metrics.bodyMassKg
        heightCm = metrics.heightCm
        bodyFatFraction = metrics.bodyFatFraction
        dateOfBirth = metrics.dateOfBirth
        sex = metrics.sex
    }
}

// MARK: - 目标

struct GoalRequestDTO: Encodable, Sendable {
    var date: LocalDate
    var kind: EnergyPlan.Kind?
    var adjustment: EnergyAdjustmentDTO?
}

struct GoalResponseDTO: Decodable, Sendable {
    var goal: GoalDTO?
}

// MARK: - 身体成分

struct ImpedanceDTO: Codable, Sendable {
    var a: Int
    var b: Int
}

struct WeighingUploadDTO: Codable, Equatable, Sendable {
    var id: UUID
    var weightKg: Decimal
    var impedance: Impedance?
    var source: WeighingSource
    var recordedAt: Date?
    var appleHealthWritable: Bool

    struct Impedance: Codable, Equatable, Sendable {
        var a: Int
        var b: Int
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.apiString, forKey: .id)
        try container.encode(weightKg, forKey: .weightKg)
        try container.encode(impedance, forKey: .impedance)
        try container.encode(source, forKey: .source)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(appleHealthWritable, forKey: .appleHealthWritable)
    }

    private enum CodingKeys: String, CodingKey { case id, weightKg, impedance, source, recordedAt, appleHealthWritable }
}

struct WeighingDTO: Decodable, Sendable {
    var id: UUID
    var measuredAt: Date
    var weightKg: Decimal
    var impedance: ImpedanceDTO?
    var source: WeighingSource
    var timeReliable: Bool
    var profile: WeighingProfile
    var scaleBodyFatFraction: Decimal?

    /// 体脂率与各项指标仍由界面按同一套公式算（与服务端的移植一致），校准用服务端拟合的公式。
    func domain(calibration: BodyFatModel?, inAppleHealth: Bool) -> BodyWeighing {
        BodyWeighing(
            id: id, measuredAt: measuredAt, weightKg: weightKg,
            impedance: impedance.map { .init(a: $0.a, b: $0.b) }, source: source, timeReliable: timeReliable,
            profile: profile, inAppleHealth: inAppleHealth, scaleBodyFatFraction: scaleBodyFatFraction, calibration: calibration
        )
    }
}

struct BodyFatCalibrationDTO: Decodable, Sendable {
    var readingCount: Int
    var model: BodyFatModel?
    var applied: Bool

    var domain: BodyFatCalibrationStatus {
        BodyFatCalibrationStatus(readingCount: readingCount, model: model)
    }
}

struct WeighingsResponseDTO: Decodable, Sendable {
    var weighings: [WeighingDTO]
    var calibration: BodyFatCalibrationDTO
}

struct WeighingResponseDTO: Decodable, Sendable {
    var weighing: WeighingDTO
}

struct ScaleReadingRequestDTO: Encodable, Sendable {
    var bodyFatFraction: Decimal?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bodyFatFraction, forKey: .bodyFatFraction)
    }

    private enum CodingKeys: String, CodingKey { case bodyFatFraction }
}

struct ScaleReadingResponseDTO: Decodable, Sendable {
    var weighing: WeighingDTO
    var calibrationChanged: Bool
}

// MARK: - 对话

struct CardRefDTO: Codable, Sendable {
    var type: String
    var id: UUID

    var domain: ChatCardRef? {
        switch type {
        case "pending": .pending(id)
        case "label": .label(id)
        default: nil
        }
    }
}

struct ChatMessageDTO: Decodable, Sendable {
    var id: UUID
    var role: ChatRole
    var text: String
    var cardRef: CardRefDTO?
    /// 2.1 起有；更早的服务端没有这个字段时从 cardRef 推出。
    var labelScanIds: [UUID]?
    /// 2.0 M4 起有：Admin 排除出模型上下文的消息。
    var excludedFromContext: Bool?
    var createdAt: Date

    var domain: ChatEntry {
        let ref = cardRef?.domain
        let labels: [UUID] = labelScanIds ?? (ref.flatMap { if case .label(let id) = $0 { [id] } else { nil } } ?? [])
        return ChatEntry(id: id, role: role, text: text, cardRef: ref, createdAt: createdAt, labelIDs: labels, isExcluded: excludedFromContext ?? false)
    }
}

struct MessagesResponseDTO: Decodable, Sendable {
    var messages: [ChatMessageDTO]
}

struct ChatRequestDTO: Encodable, Sendable {
    var text: String
    var labelScanIds: [UUID] = []

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if !labelScanIds.isEmpty { try container.encode(labelScanIds.map(\.apiString), forKey: .labelScanIds) }
    }

    private enum CodingKeys: String, CodingKey { case text, labelScanIds }
}

struct LabelScanResponseDTO: Decodable, Sendable {
    var labelScanId: UUID
}

/// 一轮对话的 SSE 事件（契约 `ChatEvent`）。
enum ChatEventDTO: Decodable, Sendable {
    case started(requestID: UUID)
    case reasoning(String)
    case text(String)
    case step(index: Int, tool: String, status: String)
    /// 确认卡占位：`drafting` 时先显示骨架卡，`cleared` 时收起（这次提案失败了）。
    case cardDraft(tool: String, drafting: Bool)
    /// 以后新增、这个版本还不认识的事件：忽略，不让整轮失败。
    case unknown(String)
    case done(reply: ChatMessageDTO, pendingID: UUID?, requestedDate: LocalDate?, goalChanged: Bool)
    case error(code: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case type, requestId, delta, index, tool, status, reply, pendingId, requestedDate, goalChanged, code, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "started": self = .started(requestID: try c.decode(UUID.self, forKey: .requestId))
        case "reasoning": self = .reasoning(try c.decode(String.self, forKey: .delta))
        case "text": self = .text(try c.decode(String.self, forKey: .delta))
        case "step":
            self = .step(index: try c.decode(Int.self, forKey: .index), tool: try c.decode(String.self, forKey: .tool), status: try c.decode(String.self, forKey: .status))
        case "cardDraft":
            self = .cardDraft(tool: try c.decode(String.self, forKey: .tool), drafting: try c.decode(String.self, forKey: .status) == "drafting")
        case "done":
            self = .done(
                reply: try c.decode(ChatMessageDTO.self, forKey: .reply),
                pendingID: try c.decodeIfPresent(UUID.self, forKey: .pendingId),
                requestedDate: try c.decodeIfPresent(LocalDate.self, forKey: .requestedDate),
                goalChanged: try c.decodeIfPresent(Bool.self, forKey: .goalChanged) ?? false
            )
        case "error": self = .error(code: try c.decode(String.self, forKey: .code), message: try c.decode(String.self, forKey: .message))
        case let other: self = .unknown(other)
        }
    }
}

// MARK: - Apple 健康同步

struct DietarySampleDTO: Decodable, Sendable {
    var nutrient: DietaryKind
    var value: Decimal
    var date: Date
    var metadata: [String: String]
}

struct BodySampleDTO: Decodable, Sendable {
    var bodyMassKg: Decimal
    var bodyFatFraction: Decimal?
    var leanBodyMassKg: Decimal?
    var date: Date
}

struct HealthChangeDTO: Decodable, Sendable {
    enum Entity: String, Decodable, Sendable { case record, weighing }

    var seq: Int
    var entity: Entity
    var id: UUID
    var deleted: Bool
    var syncVersion: Int
    var samples: [DietarySampleDTO]?
    var body: BodySampleDTO?
}

struct HealthChangesResponseDTO: Decodable, Sendable {
    var changes: [HealthChangeDTO]
    var cursor: Int
    var hasMore: Bool
}


// MARK: - Google 健康（服务端拉活动能量与睡眠）

/// GET /v1/google-health：连接状态（连接与断开在 Vita Admin 里做）。
struct GoogleHealthStatusDTO: Codable, Equatable, Sendable {
    /// 服务端配了 OAuth 客户端才能连接。
    var configured: Bool
    var connected: Bool
    var connectedAt: Date?
    var lastSyncAt: Date?
    /// reauthorizationRequired / network / googleError / internal；成功后为空。
    var lastError: String?
    var lastErrorAt: Date?
}
