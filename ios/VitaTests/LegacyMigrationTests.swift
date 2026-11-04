import Foundation
import SwiftData
import Testing
@testable import Vita

/// 1.0 → 2.0 的迁移（架构设计 §13）：导出格式、核对与收尾。
@MainActor
struct LegacyMigrationTests {
    let directory: URL
    let storeURL: URL
    let container: ModelContainer
    let images = InMemoryLabelImageStore()
    let health = FakeHealthDataStore(writeAuthorization: .authorized)
    let stub = APIStub()
    let secrets = InMemorySecretStore()
    let defaults = UserDefaults(suiteName: "vita-migration-\(UUID().uuidString)")!

    // 固定的 ID：导出结果同时作为 API 导入测试的样例（shared/fixtures/ios-1.0-export.json）。
    let recordID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let productID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let versionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let scanID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let pendingID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let weighingID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    let legacySample = UUID()
    let labelReference: String

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "vita-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appending(path: "default.store")
        container = try PersistenceStore.makeContainer(url: storeURL)
        try secrets.write("legacy-conduit", for: .conduitToken)
        labelReference = try images.save(Data("jpeg".utf8))
        try seed()
    }

    private func seed() throws {
        let context = container.mainContext
        let now = Fixtures.now
        let session = DaySession(localDate: Fixtures.day, timeZoneIdentifier: "Asia/Shanghai", now: now)
        session.revision = 2
        context.insert(session)

        let reference = labelReference
        let scan = NutritionLabelScan(id: scanID, imageReference: reference, createdAt: now)
        context.insert(scan)

        let product = FoodProduct(id: productID, name: "纯牛奶", brandOrSupplier: nil, package: Quantity(amount: 250, unit: .milliliter), now: now)
        let version = FoodVersion(
            id: versionID,
            basis: FoodVersionBasis(quantity: Quantity(amount: 100, unit: .milliliter), nutrients: NutrientValues(energyKcal: 65, proteinG: dec("3.2"), fatG: dec("3.6"), carbohydrateG: dec("4.8"))),
            sourceKind: .nutritionLabel, labelImageReference: reference, now: now
        )
        context.insert(product)
        context.insert(version)
        version.product = product
        product.activeVersionID = versionID

        let record = ConsumptionRecord(
            id: recordID, eventTime: try EventTime(localDate: Fixtures.day, precision: .mealPeriod, mealPeriod: .lunch, timeZoneIdentifier: "Asia/Shanghai"),
            mealLabel: "午餐", note: nil, now: now
        )
        context.insert(record)
        record.session = session
        for (position, (kcal, included)) in [(Decimal(500), true), (Decimal(162.5), true), (Decimal(80), false)].enumerated() {
            let item = ConsumptionItem(id: UUID(uuidString: "7777777\(position)-7777-4777-8777-777777777777")!, position: position, now: now)
            item.displayName = "item \(position)"
            item.originalAmountText = "一份"
            item.includeInSummary = included
            item.snapshotData = JSONColumn.encode(NutritionSnapshot(
                nutritionSource: .aiEstimated, sourceRef: nil, basisQuantity: nil, basisNutrients: nil, quantityUsed: nil,
                computedBy: .model, estimateBasis: "估算", values: NutrientValues(energyKcal: kcal, proteinG: 0, fatG: 0, carbohydrateG: 0)
            ))
            if position == 1 {
                item.foodProductID = productID
                item.foodVersionID = versionID
            }
            context.insert(item)
            item.record = record
        }

        let goal = DailyGoal(
            id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!, effectiveFrom: Fixtures.day, targets: GoalTargets(energyKcal: 1800, proteinG: 120),
            energyPlan: EnergyPlan(kind: .lose, adjustment: .fraction(dec("0.85")), bmrKcal: 1700, baselineActivityKcal: 500, baselineEstimated: false),
            origin: .initialRecommendation, evidenceData: Data(#"{"policyVersion":2,"generatedAt":815000000}"#.utf8), revision: 1, now: now
        )
        context.insert(goal)

        let messages: [(ChatRole, String, ChatCardRef?)] = [(.user, "拍了标签", .label(scanID)), (.assistant, "生成了卡片", .pending(pendingID)), (.toolSummary, "已确认", nil)]
        for (index, (role, text, card)) in messages.enumerated() {
            let message = ChatMessage(
                id: UUID(uuidString: "9999999\(index)-9999-4999-8999-999999999999")!, role: role, text: text, cardRef: card,
                createdAt: now.addingTimeInterval(Double(index))
            )
            context.insert(message)
            message.session = session
        }

        context.insert(ScaleWeighing(
            id: weighingID, measuredAt: now, weightGrams: 70250, impedance: .init(a: 480, b: 430), source: .live, timeReliable: true,
            profile: WeighingProfile(heightCm: 175, ageYears: 35, sex: .male), healthSampleIDs: [UUID()], now: now
        ))
        context.insert(HealthSyncMapping(recordID: recordID, nutrient: .energyKcal, sampleUUID: legacySample, now: now))
        context.insert(ManualBodyMetricsEntry(metrics: ManualBodyMetrics(heightCm: 175, enteredAt: now)))
        try context.save()
        health.legacySamples = [legacySample]
    }

    private func migration() -> LegacyMigration {
        let sync = HealthSyncService(api: stub.client(), store: health, local: InMemoryLocalStateStore())
        return LegacyMigration(
            container: container, storeURL: storeURL, labelImages: images, api: stub.client(),
            healthStore: health, healthSync: sync, secrets: secrets, defaults: defaults, now: { Fixtures.now }
        )
    }

    private func importResponse(records: Int = 1, energy: String = "662.5") -> String {
        """
        {"counts":{"sessions":1,"records":\(records),"items":3,"products":1,"versions":1,"goals":1,"messages":3,"labelScans":1,"weighings":1},
         "dailyEnergyKcal":{"2026-10-30":\(energy)}}
        """
    }

    @Test func exportsTheContractFormatWithExplicitNulls() throws {
        let bundle = try migration().exportBundle()
        let data = try VitaAPIClient.encoder.encode(bundle.json)
        // 设了 TEST_RUNNER_VITA_EXPORT_FIXTURE 时把导出写到那里，API 的导入测试用它核对两端格式一致。
        if let path = ProcessInfo.processInfo.environment["VITA_EXPORT_FIXTURE"] {
            let pretty = JSONEncoder()
            pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try pretty.encode(bundle.json).write(to: URL(filePath: path))
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["formatVersion"] as? Int == 1)

        let record = (json["records"] as! [[String: Any]])[0]
        #expect(record["id"] as? String == recordID.apiString)
        #expect(record["note"] is NSNull)
        let eventTime = record["eventTime"] as! [String: Any]
        #expect(eventTime["timestamp"] is NSNull)
        #expect(eventTime["timeZone"] as? String == "Asia/Shanghai")
        let items = record["items"] as! [[String: Any]]
        #expect(items.count == 3)
        let snapshot = items[0]["snapshot"] as! [String: Any]
        #expect(snapshot["sourceRef"] is NSNull)
        #expect(snapshot.keys.contains("basisQuantity"))
        #expect(items.contains { $0["foodVersionId"] as? String == versionID.apiString })

        // 食品版本的照片引用换成了标签照片的 ID，照片本身随包上传。
        let version = ((json["products"] as! [[String: Any]])[0]["versions"] as! [[String: Any]])[0]
        #expect(version["labelScanId"] as? String == scanID.apiString)
        #expect(version["retiredAt"] is NSNull)
        let scan = (json["labelScans"] as! [[String: Any]])[0]
        #expect(scan["dataBase64"] as? String == Data("jpeg".utf8).base64EncodedString())

        // 1.0 的确认卡不迁移：指向它的引用清掉；工具摘要按助手消息迁。
        let messages = json["messages"] as! [[String: Any]]
        #expect(messages.contains { ($0["cardRef"] as? [String: Any])?["id"] as? String == scanID.apiString })
        #expect(messages.filter { $0["cardRef"] is NSNull }.count == 2)
        #expect(Set(messages.compactMap { $0["role"] as? String }) == ["user", "assistant"])

        let goal = (json["goals"] as! [[String: Any]])[0]
        #expect((goal["targets"] as! [String: Any])["fatG"] is NSNull)
        #expect(((goal["energyPlan"] as! [String: Any])["adjustment"] as! [String: Any])["type"] as? String == "fraction")
        #expect((goal["evidence"] as? [String: Any])?["policyVersion"] as? Int == 2)

        let weighing = (json["weighings"] as! [[String: Any]])[0]
        #expect(weighing["weightKg"] as? Double == 70.25)
        #expect(weighing["scaleBodyFatFraction"] is NSNull)
        #expect(((json["manualMetrics"] as! [String: Any])["metrics"] as! [String: Any])["bodyMassKg"] is NSNull)
    }

    @Test func migratesVerifiesAndCleansUp() async throws {
        stub.on("POST", "/v1/import", status: 201, json: importResponse())
        stub.on("GET", "/v1/health-sync/changes", json: """
        {"changes":[{"seq":1,"entity":"record","id":"\(recordID.apiString)","deleted":false,"syncVersion":1,
         "samples":[{"nutrient":"energyKcal","value":662.5,"date":"2026-10-30T04:30:00.000Z","metadata":{}}]}],"cursor":1,"hasMore":false}
        """)
        var steps: [LegacyMigration.Step] = []

        let report = try await migration().run { steps.append($0) }

        #expect(steps == [.exporting, .uploading, .verifying, .rewritingHealth, .cleaningUp])
        #expect(report.records == 1)
        #expect(report.days == 1)
        // 1.0 写的旧 Sample 删掉，按变更流带标识重写。
        #expect(health.legacySamples.isEmpty)
        #expect(health.dietary[recordID]?.samples.first?.value == dec("662.5"))
        // 本机的库与照片删掉，导出文件留底，1.0 的令牌清掉。
        #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
        #expect(try images.load(labelReference) == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(report.exportFile).path(percentEncoded: false)))
        #expect(try secrets.read(.conduitToken) == nil)
        if let file = report.exportFile { try? FileManager.default.removeItem(at: file) }
    }

    @Test func mismatchesKeepTheLocalStore() async throws {
        stub.on("POST", "/v1/import", status: 201, json: importResponse(energy: "500"))
        await #expect(throws: LegacyMigration.MigrationError.self) { try await migration().run { _ in } }
        #expect(FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
        #expect(health.legacySamples == [legacySample])
        #expect(try secrets.read(.conduitToken) == "legacy-conduit")
    }

    /// 上次传上去了但没来得及核对（App 被杀）：服务端说已有数据时，按天读回来核对一致就接着做。
    @Test func resumesWhenTheServerAlreadyHasTheImport() async throws {
        stub.on("POST", "/v1/import", status: 409, json: #"{"error":{"code":"notEmpty","message":"服务端已经有数据"}}"#)
        stub.on("GET", "/v1/days/2026-10-30", json: APIFixtures.day("2026-10-30", kcal: 0).replacingOccurrences(of: #""summary":{"totals":{"energyKcal":0"#, with: #""summary":{"totals":{"energyKcal":662.5"#))
        stub.on("GET", "/v1/health-sync/changes", json: #"{"changes":[],"cursor":0,"hasMore":false}"#)
        let report = try await migration().run { _ in }
        #expect(report.records == 1)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
        #expect(!defaults.bool(forKey: LegacyMigration.importedKey))
        if let file = report.exportFile { try? FileManager.default.removeItem(at: file) }
    }

    /// 服务端已有的数据和本机对不上（不是这台手机传的）：照常报错，什么都不删。
    @Test func refusedImportsShowTheServerMessage() async throws {
        stub.on("POST", "/v1/import", status: 409, json: #"{"error":{"code":"notEmpty","message":"服务端已经有数据"}}"#)
        stub.on("GET", "/v1/days/2026-10-30", json: APIFixtures.day("2026-10-30", kcal: 300))
        await #expect(throws: APIError.server(status: 409, code: "notEmpty", message: "服务端已经有数据")) { try await migration().run { _ in } }
        #expect(FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
    }

    @Test func emptyStoresAreDiscarded() throws {
        let emptyURL = directory.appending(path: "empty.store")
        let empty = LegacyMigration(
            container: try PersistenceStore.makeContainer(url: emptyURL), storeURL: emptyURL, labelImages: InMemoryLabelImageStore(),
            api: stub.client(), healthStore: health, healthSync: HealthSyncService(api: stub.client(), store: health, local: InMemoryLocalStateStore()),
            secrets: secrets
        )
        #expect(try empty.isEmpty())
        #expect(try !migration().isEmpty())
        try empty.discardEmptyStore()
        #expect(!LegacyMigration.hasLegacyData(at: emptyURL))
    }
}
