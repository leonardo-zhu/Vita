import Foundation
import Testing
@testable import Vita

@MainActor
struct APIClientTests {
    @Test func decodesADayWithGoalEnergyAndBalance() async throws {
        let stub = APIStub()
        let recordID = UUID()
        var json = APIFixtures.day("2026-10-30", kcal: 650, protein: 40, recordID: recordID)
        json = json.replacingOccurrences(of: #""goal":null,"energy":null,"balance":null"#, with: """
        "goal":{"id":"\(UUID().apiString)","effectiveFrom":"2026-10-01","targets":{"energyKcal":1980,"proteinG":130,"fatG":null,"carbohydrateG":null},
        "energyPlan":{"kind":"lose","adjustment":{"type":"fraction","value":0.85},"bmrKcal":1700,"baselineActivityKcal":500,"baselineEstimated":false},
        "origin":"initialRecommendation","revision":2},
        "energy":{"targetKcal":1980,"bmrKcal":1700,"baselineActivityKcal":500,"projectedActivityKcal":630,"countedActivityKcal":565,"tdeeKcal":2265,
        "adjustmentKcal":-285,"raisedToBMR":false,"activityEstimated":false},
        "balance":{"burnedKcal":1800,"consumedKcal":650,"balanceKcal":-1150}
        """)
        stub.on("GET", "/v1/days/2026-10-30", json: json)
        let service = DayDataService(api: stub.client()) { $0 == recordID ? .synced : nil }

        let day = try await service.day(Fixtures.day)
        #expect(day.revision == 1)
        let record = try #require(day.records.first)
        #expect(record.eventTime.mealPeriod == .lunch)
        #expect(record.eventTime.timeZoneIdentifier == "Asia/Shanghai")
        #expect(record.healthSync == .synced)
        #expect(record.totals.energyKcal == 650)
        #expect(day.summary.totals.proteinG == 40)
        #expect(day.summary.goal?.targets.energyKcal == 1980)
        #expect(day.summary.goal?.targets.fatG == nil)
        #expect(day.summary.goal?.energyPlan?.adjustment == .fraction(Decimal(string: "0.85")!))
        #expect(day.summary.energy?.adjustmentKcal == -285)
        #expect(day.summary.balance?.balanceKcal == -1150)
        #expect(stub.requests.first?.headers["Authorization"] == "Bearer test-token")
    }

    @Test func mapsErrors() async throws {
        let stub = APIStub()
        stub.on("GET", "/v1/foods", status: 401, json: #"{"error":{"code":"unauthorized","message":"令牌无效"}}"#)
        stub.on("POST", "/v1/pending/\(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!.apiString)/confirm", status: 409,
                json: #"{"error":{"code":"revisionConflict","message":"当天数据变了"}}"#)
        await #expect(throws: APIError.unauthorized) { try await FoodService(api: stub.client()).products() }

        let pending = PendingService(api: stub.client())
        do {
            try await pending.confirm(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
            Issue.record("should have thrown")
        } catch let error as APIError {
            #expect(error.code == "revisionConflict")
            #expect(error.userMessage == "当天数据变了")
        }
        // 路径里的 ID 是小写，和服务端存的一致。
        #expect(stub.requests.last?.path == "/v1/pending/6f9619ff-8b86-d011-b42d-00c04fc964ff/confirm")

        await #expect(throws: APIError.missingToken) { try await FoodService(api: stub.client(token: nil)).products() }
        #expect(stub.requests.count == 2)
    }

    @Test func healthUploadWritesExplicitNulls() throws {
        var snapshot = HealthSnapshot.empty
        snapshot.bodyMassKg = .value(dec("70.5"), source: .healthKit, measuredAt: nil)
        snapshot.sleepHours = .failed("boom")
        let json = try JSONSerialization.jsonObject(with: VitaAPIClient.encoder.encode(HealthUploadDTO(snapshot))) as! [String: Any]
        let weight = json["bodyMassKg"] as! [String: Any]
        #expect(weight["status"] as? String == "value")
        #expect(weight.keys.contains("measuredAt"))
        #expect(weight["measuredAt"] is NSNull)
        #expect((json["heightCm"] as! [String: Any]).keys.sorted() == ["status"])
        #expect((json["sleepHours"] as! [String: Any])["message"] as? String == "boom")
    }

    @Test func parsesServerSentEvents() {
        var parser = SSEParser()
        #expect(parser.feed("event: text") == nil)
        #expect(parser.feed("data: {\"a\":") == nil)
        #expect(parser.feed("data: 1}\r") == nil)
        #expect(parser.feed(": keep-alive") == nil)
        #expect(parser.feed("") == "{\"a\":\n1}")
        #expect(parser.feed("") == nil)
        #expect(parser.feed("data:{\"b\":2}") == nil)
        #expect(parser.finish() == "{\"b\":2}")
    }

    @Test func datesRoundTripInUTC() throws {
        let date = try #require(VitaAPIClient.parseDate("2026-10-30T12:00:00.000Z"))
        #expect(VitaAPIClient.formatDate(date) == "2026-10-30T12:00:00.000Z")
        #expect(VitaAPIClient.parseDate("2026-10-30T20:00:00+08:00") == date)
    }
}

@MainActor
struct ChatServiceTests {
    private func reply(_ text: String, card: String = "null") -> String {
        #"{"id":"\#(UUID().apiString)","role":"assistant","text":"\#(text)","cardRef":\#(card),"createdAt":"2026-10-30T12:00:00.000Z"}"#
    }

    @Test func streamsProgressAndReturnsTheSavedReply() async throws {
        let stub = APIStub()
        let pendingID = UUID()
        let scanID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        stub.onStream("/v1/days/2026-10-30/chat", events: [
            #"{"type":"started","requestId":"\#(UUID().apiString)"}"#,
            #"{"type":"reasoning","delta":"想一想"}"#,
            #"{"type":"step","index":0,"tool":"searchReferenceFoods","status":"running"}"#,
            #"{"type":"step","index":0,"tool":"searchReferenceFoods","status":"done"}"#,
            #"{"type":"text","delta":"已生成"}"#,
            #"{"type":"text","delta":"确认卡。"}"#,
            #"{"type":"done","reply":\#(reply("已生成确认卡。", card: #"{"type":"pending","id":"\#(pendingID.apiString)"}"#)),"pendingId":"\#(pendingID.apiString)","requestedDate":null,"goalChanged":false}"#,
        ])
        var seen: [ChatProgress] = []
        let result = try await ChatService(api: stub.client()).send("中午吃了鸡胸肉", on: Fixtures.day, labelScan: scanID) { seen.append($0) }

        #expect(result.pendingID == pendingID)
        #expect(result.reply?.cardRef == .pending(pendingID))
        #expect(seen.last?.text == "已生成确认卡。")
        #expect(seen.last?.activity == nil)
        #expect(seen.contains { $0.activity == .tool("searchReferenceFoods") })
        #expect(seen.last?.steps == [.init(tool: "searchReferenceFoods", done: true)])
        let body = try #require(stub.requests.first).json()
        #expect(body["text"] as? String == "中午吃了鸡胸肉")
        #expect(body["labelScanId"] as? String == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test func errorEventsThrowWithTheServerMessage() async throws {
        let stub = APIStub()
        stub.onStream("/v1/days/2026-10-30/chat", events: [
            #"{"type":"started","requestId":"\#(UUID().apiString)"}"#,
            #"{"type":"error","code":"upstream","message":"模型暂时不可用"}"#,
        ])
        await #expect(throws: ChatTurnError(code: "upstream", message: "模型暂时不可用")) {
            try await ChatService(api: stub.client()).send("hi", on: Fixtures.day)
        }

        let cancelled = APIStub()
        cancelled.onStream("/v1/days/2026-10-30/chat", events: [#"{"type":"error","code":"cancelled","message":"已停止"}"#])
        await #expect(throws: CancellationError.self) { try await ChatService(api: cancelled.client()).send("hi", on: Fixtures.day) }
    }

    @Test func refusedTurnsSurfaceTheErrorBody() async throws {
        let stub = APIStub()
        stub.on("POST", "/v1/days/2026-10-30/chat", status: 503, json: #"{"error":{"code":"agentUnavailable","message":"暂时不能对话"}}"#)
        await #expect(throws: APIError.server(status: 503, code: "agentUnavailable", message: "暂时不能对话")) {
            try await ChatService(api: stub.client()).send("hi", on: Fixtures.day)
        }
    }

    @Test func continuationUsesThePendingEndpoint() async throws {
        let stub = APIStub()
        let id = UUID()
        stub.onStream("/v1/pending/\(id.apiString)/continue", events: [
            #"{"type":"done","reply":\#(reply("好的")),"pendingId":null,"requestedDate":"2026-10-29","goalChanged":true}"#,
        ])
        let result = try await ChatService(api: stub.client()).continueAfterConfirm(id)
        #expect(result.requestedDate == LocalDate(isoString: "2026-10-29"))
        #expect(result.goalChanged)
    }
}

@MainActor
struct HealthSyncTests {
    let stub = APIStub()
    let store = FakeHealthDataStore(writeAuthorization: .authorized)
    let local = InMemoryLocalStateStore()

    init() async throws {
        try await store.requestAuthorization()
    }

    private func sync() -> HealthSyncService {
        HealthSyncService(api: stub.client(), store: store, local: local)
    }

    private func recordChange(seq: Int, id: UUID, kcal: Int, deleted: Bool = false) -> String {
        let samples = deleted ? "[]" : #"[{"nutrient":"energyKcal","value":\#(kcal),"date":"2026-10-30T04:30:00.000Z","metadata":{"vita.recordID":"\#(id.apiString)"}}]"#
        return #"{"seq":\#(seq),"entity":"record","id":"\#(id.apiString)","deleted":\#(deleted),"syncVersion":\#(seq),"samples":\#(samples)}"#
    }

    private func page(_ changes: [String], cursor: Int, hasMore: Bool = false) -> String {
        #"{"changes":[\#(changes.joined(separator: ","))],"cursor":\#(cursor),"hasMore":\#(hasMore)}"#
    }

    @Test func writesTheLatestStateAndAdvancesTheCursor() async throws {
        let record = UUID()
        let weighing = UUID()
        stub.on("GET", "/v1/health-sync/changes", json: page([
            recordChange(seq: 1, id: record, kcal: 500),
        ], cursor: 1, hasMore: true))
        stub.on("GET", "/v1/health-sync/changes", json: page([
            #"{"seq":2,"entity":"weighing","id":"\#(weighing.apiString)","deleted":false,"syncVersion":2,"body":{"bodyMassKg":70.2,"bodyFatFraction":0.18,"leanBodyMassKg":57.56,"date":"2026-10-30T00:00:00.000Z"}}"#,
        ], cursor: 2))
        let service = sync()

        let result = await service.run()
        #expect(result.synced == 2)
        #expect(store.dietary[record]?.samples.map(\.value) == [500])
        #expect(store.dietary[record]?.version == 1)
        #expect(store.bodySamples[weighing]?.sample.leanBodyMassKg == dec("57.56"))
        #expect(service.state(forRecord: record) == .synced)
        #expect(service.isInAppleHealth(weighing: weighing))
        #expect(stub.requests.map { $0.query["after"] } == ["0", "1"])
        // 进度存在本机：重开 App 后从游标接着拉。
        #expect(local.load(HealthSyncService.stateName, as: HealthSyncService.State.self)?.cursor == 2)
        #expect(HealthSyncService(api: stub.client(), store: store, local: local).state(forRecord: record) == .synced)
    }

    @Test func deletionsRemoveTheSamples() async throws {
        let record = UUID()
        stub.on("GET", "/v1/health-sync/changes", json: page([recordChange(seq: 1, id: record, kcal: 500)], cursor: 1))
        stub.on("GET", "/v1/health-sync/changes", json: page([recordChange(seq: 3, id: record, kcal: 0, deleted: true)], cursor: 3))
        let service = sync()
        await service.run()
        await service.run()
        #expect(store.dietary[record] == nil)
        #expect(service.state(forRecord: record) == nil)
        #expect(stub.requests.last?.query["after"] == "1")
    }

    @Test func failedWritesAreRetriedFromTheStart() async throws {
        let first = UUID()
        let second = UUID()
        stub.on("GET", "/v1/health-sync/changes", json: page([recordChange(seq: 1, id: first, kcal: 300), recordChange(seq: 2, id: second, kcal: 400)], cursor: 2))
        store.failNext(1)
        let service = sync()
        let result = await service.run()
        #expect(result.failed == 1)
        #expect(result.synced == 1)
        #expect(service.state(forRecord: first) == .failedRetryable)
        #expect(store.dietary[second] != nil)

        // 有失败的对象时从 0 重拉；已写好的不再重写。
        let retried = await service.run()
        #expect(stub.requests.last?.query["after"] == "0")
        #expect(retried.synced == 1)
        #expect(service.state(forRecord: first) == .synced)
    }

    @Test func waitsForPermissionWithoutFetching() async throws {
        let denied = FakeHealthDataStore(writeAuthorization: .notDetermined)
        let service = HealthSyncService(api: stub.client(), store: denied, local: local)
        let result = await service.run()
        #expect(result == .init())
        #expect(stub.requests.isEmpty)
    }

    @Test func deniedWritesNeedTheUser() async throws {
        let record = UUID()
        stub.on("GET", "/v1/health-sync/changes", json: page([recordChange(seq: 1, id: record, kcal: 300)], cursor: 1))
        // 膳食写入被拒，体重写入允许：同步照常进行，饮食记录标为需要用户处理。
        store.setWriteAuthorization(.denied)
        let service = sync()
        let result = await service.run()
        #expect(result.waitingForPermission == 1)
        #expect(service.state(forRecord: record) == .requiresUserResolution)
    }
}
