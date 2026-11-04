import Foundation
import OSLog
import SwiftData

/// 从 1.0 迁到 2.0（架构设计 §13）：把手机上的 SwiftData 业务库整理成 `POST /v1/import` 的格式导入服务端，
/// 对比条数与每日能量合计，一致后删掉 Vita 1.0 写进 Apple 健康的旧 Sample（没带同步标识），再从头拉变更流，
/// 按 2.0 的方式带标识重写；最后删除本机业务库与标签照片。导出文件留在“文件”App 里，至少保留一个月。
@MainActor
final class LegacyMigration {
    private static let log = Logger(subsystem: "com.leonardo.vita", category: "migration")

    enum Step: Equatable, Sendable {
        case exporting
        case uploading
        case verifying
        case rewritingHealth
        case cleaningUp
    }

    struct Report: Equatable, Sendable {
        var records: Int
        var items: Int
        var products: Int
        var messages: Int
        var weighings: Int
        var days: Int
        /// 导出文件，保存在 App 的“文稿”目录（“文件”App 里能看到）。
        var exportFile: URL?
    }

    enum MigrationError: Error, Equatable {
        /// 服务端与本机对不上：哪一项、本机多少、服务端多少。
        case mismatch(String)

        var userMessage: String {
            switch self {
            case .mismatch(let detail): "导入后核对不一致（\(detail)），本机数据没有删除。请把这个结果告诉开发者。"
            }
        }
    }

    private let container: ModelContainer
    private let storeURL: URL
    private let labelImages: any LabelImageStore
    private let api: VitaAPIClient
    private let healthStore: any HealthDataStore
    private let healthSync: HealthSyncService
    private let secrets: any SecretStore
    private let defaults: UserDefaults
    private let now: () -> Date

    /// 导入并核对通过后记下：之后的步骤中途被打断（App 被杀、没电），下次打开从更新健康接着做，不再重新导入。
    static let importedKey = "vita.migration.imported"

    init(
        container: ModelContainer, storeURL: URL, labelImages: any LabelImageStore, api: VitaAPIClient,
        healthStore: any HealthDataStore, healthSync: HealthSyncService, secrets: any SecretStore,
        defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init
    ) {
        self.container = container
        self.storeURL = storeURL
        self.labelImages = labelImages
        self.api = api
        self.healthStore = healthStore
        self.healthSync = healthSync
        self.secrets = secrets
        self.defaults = defaults
        self.now = now
    }

    /// 1.0 的库默认放在 Application Support 下。
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// 这台手机上还有没迁走的 1.0 数据。
    static func hasLegacyData(at url: URL = defaultStoreURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    static func open(at url: URL = defaultStoreURL) throws -> ModelContainer {
        try PersistenceStore.makeContainer(url: url)
    }

    private var context: ModelContext { container.mainContext }

    /// 1.0 里有没有业务数据（只装过、没用过的不用迁）。
    func isEmpty() throws -> Bool {
        try context.fetchCount(FetchDescriptor<ConsumptionRecord>()) == 0
            && context.fetchCount(FetchDescriptor<ChatMessage>()) == 0
            && context.fetchCount(FetchDescriptor<FoodProduct>()) == 0
            && context.fetchCount(FetchDescriptor<DailyGoal>()) == 0
            && context.fetchCount(FetchDescriptor<ScaleWeighing>()) == 0
    }

    // MARK: - 迁移

    func run(progress: (Step) -> Void) async throws -> Report {
        progress(.exporting)
        let expected = try localTotals()
        let messages = try context.fetchCount(FetchDescriptor<ChatMessage>())
        var file = Self.latestExport()
        if !defaults.bool(forKey: Self.importedKey) {
            let data = try VitaAPIClient.encoder.encode(try exportBundle().json)
            file = try saveExport(data)

            progress(.uploading)
            var request = try api.request("POST", "/v1/import")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = data
            request.timeoutInterval = 300
            do {
                let response = try await perform(request)
                progress(.verifying)
                try verify(response, expected: expected)
            } catch let error as APIError where error.code == "notEmpty" {
                // 上次已经传上去、但没来得及核对就被打断：按天读回来核对，一致就接着做，不一致照常报错。
                progress(.verifying)
                guard (try? await remoteMatches(expected)) == true else { throw error }
            }
            defaults.set(true, forKey: Self.importedKey)
        }

        progress(.rewritingHealth)
        await removeLegacyHealthSamples()
        healthSync.resetCursor()
        await healthSync.run()

        progress(.cleaningUp)
        try removeLocalStore()
        try? secrets.delete(.conduitToken)
        defaults.removeObject(forKey: Self.importedKey)
        return Report(
            records: expected.records, items: expected.items, products: expected.products,
            messages: messages, weighings: expected.weighings,
            days: expected.dailyEnergy.count, exportFile: file
        )
    }

    /// 按天读服务端的记录：条数与每天计入汇总的能量都要和本机一致。
    private func remoteMatches(_ expected: Expected) async throws -> Bool {
        var records = 0
        for (date, energy) in expected.dailyEnergy {
            let day: DayResponseDTO = try await api.get("/v1/days/\(date)")
            records += day.records.count
            if abs(NSDecimalNumber(decimal: day.summary.totals.energyKcal - energy).doubleValue) > 0.01 { return false }
        }
        return records == expected.records
    }

    /// 最近一次导出的文件（中途打断后接着做时用）。
    private static func latestExport() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: URL.documentsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("vita-1.0-export-") }.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 只有空库、没东西可迁时：直接删掉 1.0 的库。
    func discardEmptyStore() throws {
        try removeLocalStore()
        try? secrets.delete(.conduitToken)
    }

    private func perform(_ request: URLRequest) async throws -> ImportResponseDTO {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await api.session.data(for: request)
        } catch {
            throw APIError.offline(String(describing: error))
        }
        try VitaAPIClient.check(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        do {
            return try VitaAPIClient.decoder.decode(ImportResponseDTO.self, from: data)
        } catch {
            throw APIError.invalidResponse(String(describing: error))
        }
    }

    // MARK: - 导出

    struct Expected: Equatable {
        var records = 0
        var items = 0
        var products = 0
        var versions = 0
        var goals = 0
        var weighings = 0
        /// 每天计入汇总的能量合计。
        var dailyEnergy: [String: Decimal] = [:]
    }

    func localTotals() throws -> Expected {
        var expected = Expected()
        for record in try context.fetch(FetchDescriptor<ConsumptionRecord>()) {
            guard let date = record.session?.localDateKey else { continue }
            expected.records += 1
            expected.items += record.items.count
            // 只有不计入汇总的条目的那天也要列出来，按天核对条数时才数得到。
            expected.dailyEnergy[date, default: 0] += 0
            for item in record.items where item.includeInSummary {
                expected.dailyEnergy[date, default: 0] += try item.snapshot().values.energyKcal
            }
        }
        expected.products = try context.fetchCount(FetchDescriptor<FoodProduct>())
        expected.versions = try context.fetchCount(FetchDescriptor<FoodVersion>())
        expected.goals = try context.fetchCount(FetchDescriptor<DailyGoal>())
        expected.weighings = try context.fetchCount(FetchDescriptor<ScaleWeighing>())
        return expected
    }

    private func verify(_ response: ImportResponseDTO, expected: Expected) throws {
        let counts = response.counts
        let pairs: [(String, Int, Int)] = [
            ("记录", expected.records, counts.records), ("食物条目", expected.items, counts.items),
            ("个人食品", expected.products, counts.products), ("食品版本", expected.versions, counts.versions),
            ("目标", expected.goals, counts.goals), ("称重", expected.weighings, counts.weighings),
        ]
        for (name, local, remote) in pairs where local != remote {
            throw MigrationError.mismatch("\(name)：本机 \(local)，服务端 \(remote)")
        }
        // 能量合计允许 0.01 千卡的十进制尾差。
        let days = Set(expected.dailyEnergy.keys).union(response.dailyEnergyKcal.keys)
        for day in days.sorted() {
            let local = expected.dailyEnergy[day] ?? 0
            let remote = response.dailyEnergyKcal[day] ?? 0
            if abs(NSDecimalNumber(decimal: local - remote).doubleValue) > 0.01 {
                throw MigrationError.mismatch("\(day) 的能量：本机 \(local)，服务端 \(remote)")
            }
        }
    }

    /// 整理成 `ImportBundle`。所有 ID 原样保留（小写），可空字段显式写 null（契约用的是 nullable）。
    func exportBundle() throws -> ExportBundle {
        let sessions = try context.fetch(FetchDescriptor<DaySession>())
        let records = try context.fetch(FetchDescriptor<ConsumptionRecord>())
        let products = try context.fetch(FetchDescriptor<FoodProduct>())
        let goals = try context.fetch(FetchDescriptor<DailyGoal>())
        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        let scans = try context.fetch(FetchDescriptor<NutritionLabelScan>())
        let weighings = try context.fetch(FetchDescriptor<ScaleWeighing>())
        let manual = try context.fetch(FetchDescriptor<ManualBodyMetricsEntry>()).first

        // 食品版本里存的是照片文件引用，导入后改用标签照片的 ID。
        var scanIDByImage: [String: UUID] = [:]
        var labelScans: [JSONValue] = []
        for scan in scans {
            guard let image = try labelImages.load(scan.imageReference) else { continue }
            scanIDByImage[scan.imageReference] = scan.id
            labelScans.append(.object([
                "id": .id(scan.id), "createdAt": .date(scan.createdAt), "contentType": "image/jpeg",
                "dataBase64": .string(image.base64EncodedString()),
            ]))
        }
        let knownScans = Set(scanIDByImage.values)

        let sessionJSON: [JSONValue] = sessions.map { session in
            .object([
                "localDate": .string(session.localDateKey), "timeZone": .string(session.timeZoneIdentifier),
                "revision": .int(session.revision), "createdAt": .date(session.createdAt), "updatedAt": .date(session.updatedAt),
            ])
        }

        let recordJSON: [JSONValue] = try records.compactMap { record in
            guard let session = record.session else { return nil }
            return .object([
                "id": .id(record.id), "sessionDate": .string(session.localDateKey),
                "eventTime": .eventTime(try record.eventTime()),
                "mealLabel": .optional(record.mealLabel), "note": .optional(record.note),
                "revision": .int(record.revision), "createdAt": .date(record.createdAt), "updatedAt": .date(record.updatedAt),
                "items": .array(try record.items.map { item in
                    .object([
                        "id": .id(item.id), "position": .int(item.position), "displayName": .string(item.displayName),
                        "groupName": .optional(item.groupName), "originalAmountText": .string(item.originalAmountText),
                        "quantity": .quantity(try item.quantity()), "amountSource": .string(item.amountSource.rawValue),
                        "snapshot": .snapshot(try item.snapshot()), "includeInSummary": .bool(item.includeInSummary),
                        "foodProductId": .optionalID(item.foodProductID), "foodVersionId": .optionalID(item.foodVersionID),
                        "referenceFoodId": .optional(item.referenceFoodID),
                        "createdAt": .date(item.createdAt), "updatedAt": .date(item.updatedAt),
                    ])
                }),
            ])
        }

        let productJSON: [JSONValue] = try products.map { product in
            .object([
                "id": .id(product.id), "name": .string(product.name), "brandOrSupplier": .optional(product.brandOrSupplier),
                "package": .quantity(try product.package()), "note": .optional(product.note),
                "activeVersionId": .optionalID(product.activeVersionID),
                "createdAt": .date(product.createdAt), "updatedAt": .date(product.updatedAt),
                "versions": .array(try product.versions.sorted { $0.createdAt > $1.createdAt }.map { version in
                    let scan = version.labelImageReference.flatMap { scanIDByImage[$0] }
                    return .object([
                        "id": .id(version.id), "basis": .basis(try version.basis()), "sourceKind": .string(version.sourceKind.rawValue),
                        "labelScanId": .optionalID(scan), "derivedFromReferenceId": .optional(version.derivedFromReferenceID),
                        "sourceNote": .optional(version.sourceNote), "createdAt": .date(version.createdAt),
                        "retiredAt": version.retiredAt.map(JSONValue.date) ?? .null,
                    ])
                }),
            ])
        }

        let goalJSON: [JSONValue] = try goals.map { goal in
            let snapshot = try goal.snapshot()
            let evidence = goal.evidenceData.flatMap { try? VitaAPIClient.decoder.decode(JSONValue.self, from: $0) } ?? .null
            return .object([
                "id": .id(goal.id), "effectiveFrom": .string(goal.effectiveFromKey), "targets": .targets(snapshot.targets),
                "energyPlan": snapshot.energyPlan.map(JSONValue.energyPlan) ?? .null,
                "origin": .string(snapshot.origin.rawValue), "revision": .int(goal.revision),
                "evidence": evidence, "createdAt": .date(goal.createdAt),
            ])
        }

        // 1.0 的确认卡不迁移，指向它们（和已确认记录）的卡片引用清掉；标签照片的引用保留。
        let messageJSON: [JSONValue] = messages.compactMap { message in
            guard let session = message.session else { return nil }
            var card = JSONValue.null
            if case .label(let id) = message.cardRef, knownScans.contains(id) {
                card = .object(["type": "label", "id": .id(id)])
            }
            return .object([
                "id": .id(message.id), "sessionDate": .string(session.localDateKey),
                "role": .string(message.role == .user ? "user" : "assistant"), "text": .string(message.text),
                "cardRef": card, "createdAt": .date(message.createdAt),
            ])
        }

        let weighingJSON: [JSONValue] = try weighings.map { weighing in
            let snapshot = try weighing.snapshot()
            return .object([
                "id": .id(weighing.id), "measuredAt": .date(weighing.measuredAt), "weightKg": .decimal(snapshot.weightKg),
                "impedance": snapshot.impedance.map { .object(["a": .int($0.a), "b": .int($0.b)]) } ?? .null,
                "source": .string(snapshot.source.rawValue), "timeReliable": .bool(weighing.timeReliable),
                "profile": .object([
                    "heightCm": snapshot.profile.heightCm.map(JSONValue.decimal) ?? .null,
                    "ageYears": snapshot.profile.ageYears.map(JSONValue.int) ?? .null,
                    "sex": snapshot.profile.sex.map { .string($0.rawValue) } ?? .null,
                ]),
                "scaleBodyFatFraction": weighing.scaleBodyFatFraction.map(JSONValue.decimal) ?? .null,
                "createdAt": .date(weighing.createdAt),
            ])
        }

        var manualJSON = JSONValue.null
        if let metrics = try manual?.metrics() {
            manualJSON = .object([
                "metrics": .object([
                    "bodyMassKg": metrics.bodyMassKg.map(JSONValue.decimal) ?? .null,
                    "heightCm": metrics.heightCm.map(JSONValue.decimal) ?? .null,
                    "bodyFatFraction": metrics.bodyFatFraction.map(JSONValue.decimal) ?? .null,
                    "dateOfBirth": metrics.dateOfBirth.map { .string($0.isoString) } ?? .null,
                    "sex": metrics.sex.map { .string($0.rawValue) } ?? .null,
                ]),
                "enteredAt": .date(metrics.enteredAt),
            ])
        }

        return ExportBundle(json: .object([
            "formatVersion": .int(1), "exportedAt": .date(now()),
            "sessions": .array(sessionJSON), "records": .array(recordJSON), "products": .array(productJSON),
            "goals": .array(goalJSON), "messages": .array(messageJSON), "labelScans": .array(labelScans),
            "weighings": .array(weighingJSON), "manualMetrics": manualJSON,
        ]))
    }

    struct ExportBundle {
        var json: JSONValue
    }

    /// 导出文件留底：“文件”App → 我的 iPhone → Vita。
    private func saveExport(_ data: Data) throws -> URL {
        let stamp = VitaAPIClient.formatDate(now()).prefix(19).replacingOccurrences(of: ":", with: "-")
        let url = URL.documentsDirectory.appending(path: "vita-1.0-export-\(stamp).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    // MARK: - 收尾

    /// 1.0 写入的 Sample 没带同步标识，按本机映射删掉；随后变更流会带标识重写。没有权限删的留着（会和新写的重复）。
    private func removeLegacyHealthSamples() async {
        guard healthStore.isAvailable else { return }
        let dietary = ((try? context.fetch(FetchDescriptor<HealthSyncMapping>())) ?? []).map(\.sampleUUID)
        let body = ((try? context.fetch(FetchDescriptor<ScaleWeighing>())) ?? []).flatMap(\.healthSampleIDs)
        do { try await healthStore.delete(dietary) } catch { Self.log.error("legacy dietary delete failed: \(String(describing: error), privacy: .public)") }
        do { try await healthStore.deleteBodyMeasurements(body) } catch { Self.log.error("legacy body delete failed: \(String(describing: error), privacy: .public)") }
    }

    private func removeLocalStore() throws {
        try labelImages.deleteAll()
        let manager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(filePath: storeURL.path(percentEncoded: false) + suffix)
            if manager.fileExists(atPath: url.path(percentEncoded: false)) { try manager.removeItem(at: url) }
        }
    }
}

struct ImportResponseDTO: Decodable, Sendable {
    struct Counts: Decodable, Sendable {
        var sessions: Int
        var records: Int
        var items: Int
        var products: Int
        var versions: Int
        var goals: Int
        var messages: Int
        var labelScans: Int
        var weighings: Int
    }

    var counts: Counts
    var dailyEnergyKcal: [String: Decimal]
}

/// 任意 JSON。导出时可空字段要显式写 null，Swift 自动生成的编码会省掉 nil 的键，所以手工拼。
indirect enum JSONValue: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }

    static func int(_ value: Int) -> JSONValue { .number(Decimal(value)) }
    static func decimal(_ value: Decimal) -> JSONValue { .number(value) }
    static func date(_ value: Date) -> JSONValue { .string(VitaAPIClient.formatDate(value)) }
    static func id(_ value: UUID) -> JSONValue { .string(value.apiString) }
    static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    static func optionalID(_ value: UUID?) -> JSONValue { value.map(JSONValue.id) ?? .null }

    static func nutrients(_ values: NutrientValues) -> JSONValue {
        .object([
            "energyKcal": .decimal(values.energyKcal), "proteinG": .decimal(values.proteinG),
            "fatG": .decimal(values.fatG), "carbohydrateG": .decimal(values.carbohydrateG),
        ])
    }

    static func quantity(_ value: Quantity?) -> JSONValue {
        value.map { .object(["amount": .decimal($0.amount), "unit": .string($0.unit.rawValue)]) } ?? .null
    }

    static func basis(_ basis: FoodVersionBasis) -> JSONValue {
        .object(["quantity": .quantity(basis.quantity), "nutrients": .nutrients(basis.nutrients)])
    }

    static func snapshot(_ s: NutritionSnapshot) -> JSONValue {
        .object([
            "nutritionSource": .string(s.nutritionSource.rawValue), "sourceRef": .optional(s.sourceRef),
            "basisQuantity": .quantity(s.basisQuantity), "basisNutrients": s.basisNutrients.map(nutrients) ?? .null,
            "quantityUsed": .quantity(s.quantityUsed), "computedBy": .string(s.computedBy.rawValue),
            "estimateBasis": .optional(s.estimateBasis), "values": .nutrients(s.values),
        ])
    }

    static func eventTime(_ t: EventTime) -> JSONValue {
        .object([
            "localDate": .string(t.localDate.isoString), "precision": .string(t.precision.rawValue),
            "timestamp": t.timestamp.map(date) ?? .null, "mealPeriod": t.mealPeriod.map { .string($0.rawValue) } ?? .null,
            "timeZone": .string(t.timeZoneIdentifier),
        ])
    }

    static func targets(_ t: GoalTargets) -> JSONValue {
        .object([
            "energyKcal": t.energyKcal.map(decimal) ?? .null, "proteinG": t.proteinG.map(decimal) ?? .null,
            "fatG": t.fatG.map(decimal) ?? .null, "carbohydrateG": t.carbohydrateG.map(decimal) ?? .null,
        ])
    }

    static func energyPlan(_ plan: EnergyPlan) -> JSONValue {
        let adjustment: JSONValue = switch plan.adjustment {
        case .fraction(let value): .object(["type": "fraction", "value": .decimal(value)])
        case .kcal(let value): .object(["type": "kcal", "value": .decimal(value)])
        }
        return .object([
            "kind": .string(plan.kind.rawValue), "adjustment": adjustment, "bmrKcal": .decimal(plan.bmrKcal),
            "baselineActivityKcal": .decimal(plan.baselineActivityKcal), "baselineEstimated": .bool(plan.baselineEstimated),
        ])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
