import Foundation
import Testing
@testable import Vita

/// 帧样例是 AFUScale 用真机抓到的数据。
struct ScalePacketParserTests {
    @Test func parsesRealtimeWeight() throws {
        let result = try #require(ScalePacketParser.parse(Data(hex: "ac 29 80 69 0f e0 02 00 05 40 00 64 00 00 00 00 00 29 d5 06")))
        #expect(result.weightKg == Decimal(string: "69.6")!)
        #expect(result.isStable)
        #expect(!result.isFinal)
        #expect(result.impedance == nil)
    }

    @Test func parsesFinalResultWithImpedance() throws {
        let result = try #require(ScalePacketParser.parse(Data(hex: "ac 29 02 00 01 e2 01 b0 01 80 69 0f e0 00 00 00 00 29 d6 0e")))
        #expect(result.weightKg == Decimal(string: "69.6")!)
        #expect(result.isFinal)
        #expect(result.impedance == .init(a: 482, b: 432))
    }

    @Test func parsesFinalResultWithoutImpedance() throws {
        let result = try #require(ScalePacketParser.parse(Data(hex: "ac 29 02 00 00 00 00 00 01 80 68 13 ec 00 00 00 00 29 d6 09")))
        #expect(result.weightKg == Decimal(string: "5.1")!)
        #expect(result.isFinal)
        #expect(result.impedance == nil)
    }

    /// 2026-11-03 真机抓到的离线记录（D8），秤上显示 74.5 kg 与 75.5 kg。
    @Test func parsesOfflineRecords() throws {
        let first = try #require(ScalePacketParser.parseOfflineRecord(Data(hex: "ac 29 01 c2 cb e5 b2 80 69 23 04 02 28 01 e6 00 00 29 d8 07")))
        #expect(first.measurement.weightKg == Decimal(string: "74.5")!)
        #expect(first.measurement.isFinal)
        #expect(first.measurement.impedance == .init(a: 552, b: 486))
        let second = try #require(ScalePacketParser.parseOfflineRecord(Data(hex: "ac 29 01 c2 ce a2 3c 80 69 26 ec 02 1b 01 db 00 00 29 d8 04")))
        #expect(second.measurement.weightKg == Decimal(string: "75.5")!)
        #expect(second.measurement.impedance == .init(a: 539, b: 475))
    }

    @Test func readsRecordTimeOnlyFromACalibratedClock() throws {
        // 时钟从没按大端校准过：读出来是 2073 年，保存时晚于现在、改用同步时间。
        #expect(try #require(ScalePacketParser.parseOfflineRecord(Data(hex: "ac 29 01 c2 cb e5 b2 80 69 23 04 02 28 01 e6 00 00 29 d8 07"))).recordedAt
            == Date(timeIntervalSince1970: 3_268_142_514))
        let record = try #require(ScalePacketParser.parseOfflineRecord(Data(hex: "ac 29 01 6a e9 94 d3 80 69 23 68 02 09 01 cc 00 00 29 d8 04")))
        #expect(record.recordedAt == Date(timeIntervalSince1970: 1_793_692_883))
        #expect(ScalePacketParser.parseOfflineRecord(Data(hex: "ac 29 01 00 00 10 00 80 69 23 68 02 09 01 cc 00 00 29 d8 04"))?.recordedAt == nil)
    }

    @Test func keepsOfflineRecordsAndHandshakeOutOfLiveWeight() {
        #expect(ScalePacketParser.parse(Data(hex: "ac 29 01 c2 cb e5 b2 80 69 23 04 02 28 01 e6 00 00 29 d8 07")) == nil)
        #expect(ScalePacketParser.parse(Data(hex: "ac 29 06 00 af 9d 42 a7 f0 ef 55 bc 14 bb ae 53 2c 61 df 07")) == nil)
        #expect(ScalePacketParser.parseOfflineRecord(Data(hex: "ac 29 02 00 01 e2 01 b0 01 80 69 0f e0 00 00 00 00 29 d6 0e")) == nil)
    }

    @Test func ignoresOtherPackets() {
        #expect(ScalePacketParser.parse(Data([0x00, 0x01])) == nil)
        #expect(ScalePacketParser.parse(Data(hex: "ab 29 02 00 00 00 00 00 01 80 68 13 ec 00 00 00 00 29 d6 09")) == nil)
    }
}

struct BodyFatEstimateTests {
    @Test func matchesAFUScaleFormula() {
        // BMI 24.08（69.6 kg / 170 cm），30 岁男性：1.2×24.08 + 6.9 − 10.8 − 5.4 + 1.5 = 21.10%。
        let fat = BodyFatEstimate.fraction(weightKg: Decimal(string: "69.6")!, heightCm: 170, ageYears: 30, sex: .male)
        #expect(fat == Decimal(string: "0.211")!)
    }

    @Test func needsHeightAgeAndSex() {
        #expect(BodyFatEstimate.fraction(weightKg: 60, heightCm: nil, ageYears: 30, sex: .female) == nil)
        #expect(BodyFatEstimate.fraction(weightKg: 60, heightCm: 165, ageYears: nil, sex: .female) == nil)
        #expect(BodyFatEstimate.fraction(weightKg: 60, heightCm: 165, ageYears: 30, sex: .other) == nil)
    }
}

/// 指令帧与真机握手时发出、秤有应答的帧逐字节一致。
struct ScaleCommandTests {
    @Test func buildsControlFrames() {
        #expect(ScaleCommand.readSign == Data(hex: "ac 29 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df e5"))
        #expect(ScaleCommand.replySign == Data(hex: "ac 29 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df e6"))
        #expect(ScaleCommand.historyAck == Data(hex: "ac 29 04 d8 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df bb"))
    }

    @Test func buildsTimeAndUserFrames() {
        let date = Date(timeIntervalSince1970: 1_793_692_883)
        let user = ScaleCommand.User(heightCm: 175, weightKg: Decimal(string: "76")!, ageYears: 26, isMale: true)
        #expect(ScaleCommand.setTime(date, timeZone: Fixtures.shanghai) == Data(hex: "ac 29 08 6a e9 94 d3 20 00 00 00 00 00 00 00 00 00 00 df c1"))
        #expect(ScaleCommand.userList(user) == Data(hex: "ac 29 01 00 00 af b0 1d 9a b0 1d 00 00 00 00 00 00 00 d4 b8"))
        #expect(ScaleCommand.timeAndUser(user, date: date, timeZone: Fixtures.shanghai)
            == Data(hex: "ac 29 6a e9 94 d3 20 00 01 af b0 1d 9a b0 1d 01 00 00 d7 96"))
    }
}

@MainActor
struct BodyCompositionServiceTests {
    let stub = APIStub()
    let store = FakeHealthDataStore()
    let local = InMemoryLocalStateStore()

    private let final = ScaleMeasurement(weightKg: Decimal(string: "69.6")!, isStable: true, isFinal: true, impedance: .init(a: 482, b: 432))

    private func service(api: VitaAPIClient? = nil) -> BodyCompositionService {
        let api = api ?? stub.client()
        return BodyCompositionService(api: api, store: store, local: local, healthSync: HealthSyncService(api: api, store: store, local: local), now: { Fixtures.now })
    }

    private func weighingJSON(_ id: String) -> String {
        """
        {"id":"\(id)","measuredAt":"2026-10-30T12:00:00.000Z","weightKg":69.6,"impedance":{"a":482,"b":432},"source":"live","timeReliable":true,
         "profile":{"heightCm":170,"ageYears":36,"sex":"male"},"scaleBodyFatFraction":null,"bodyFat":{"value":0.2,"source":"estimated"},"bmi":24.1,"metrics":[],"bodyType":null}
        """
    }

    private func emptyFeed() {
        stub.on("GET", "/v1/health-sync/changes", json: #"{"changes":[],"cursor":0,"hasMore":false}"#)
    }

    @Test func uploadsTheWeighingWithAPhoneGeneratedID() async throws {
        store.bodyWriteAnswer = .authorized
        stub.on("POST", "/v1/weighings", status: 201, json: #"{"weighing":\#(weighingJSON(UUID().apiString))}"#)
        stub.on("GET", "/v1/weighings", json: #"{"weighings":[],"calibration":{"readingCount":0,"model":null,"applied":false}}"#)
        emptyFeed()

        let (_, destination) = try await service().record(final, source: .live)
        #expect(destination == .appleHealth)
        let body = try #require(stub.requests.first { $0.method == "POST" }).json()
        let id = try #require(body["id"] as? String)
        #expect(id == id.lowercased())
        #expect(body["appleHealthWritable"] as? Bool == true)
        #expect(body["recordedAt"] is NSNull)
        #expect((body["impedance"] as? [String: Any])?["b"] as? Int == 432)
    }

    @Test func tellsTheServerWhenHealthCannotTakeIt() async throws {
        store.bodyWriteAnswer = .denied
        stub.on("POST", "/v1/weighings", status: 201, json: #"{"weighing":\#(weighingJSON(UUID().apiString))}"#)
        stub.on("GET", "/v1/weighings", json: #"{"weighings":[],"calibration":{"readingCount":0,"model":null,"applied":false}}"#)
        emptyFeed()
        let (_, destination) = try await service().record(final, source: .live)
        #expect(destination == .manual)
        #expect(try stub.requests.first { $0.method == "POST" }?.json()["appleHealthWritable"] as? Bool == false)
    }

    @Test func rejectsImplausibleWeightWithoutUploading() async throws {
        let silly = ScaleMeasurement(weightKg: 900, isStable: true, isFinal: true, impedance: nil)
        await #expect(throws: HealthServiceError.invalidMetrics) { try await service().record(silly, source: .live) }
        #expect(stub.requests.isEmpty)
    }

    @Test func queuesWhileOfflineAndFlushesLater() async throws {
        // 没注册的替身：请求连不上。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let offline = VitaAPIClient(baseURL: URL(string: "https://vita-api.test")!, token: { "t" }, session: URLSession(configuration: configuration))

        let (weighing, destination) = try await service(api: offline).record(final, source: .live)
        #expect(weighing == nil)
        #expect(destination == .queued)
        let queued = try #require(service().queued.first)
        // 排队的实时称重记下当时的时间，补传时按离线记录交给服务端。
        #expect(queued.source == .offline)
        #expect(queued.recordedAt == Fixtures.now)

        stub.on("POST", "/v1/weighings", status: 201, json: #"{"weighing":\#(weighingJSON(queued.id.apiString))}"#)
        emptyFeed()
        #expect(await service().flushQueue() == 1)
        #expect(service().queued.isEmpty)
        #expect(try stub.requests.first?.json()["id"] as? String == queued.id.apiString)
    }

    @Test func dropsQueuedWeighingsTheServerRejects() async throws {
        try local.save([WeighingUploadDTO(id: UUID(), weightKg: 70, impedance: nil, source: .offline, recordedAt: Fixtures.now, appleHealthWritable: false)], as: BodyCompositionService.queueName)
        stub.on("POST", "/v1/weighings", status: 400, json: #"{"error":{"code":"invalidBody","message":"读数不合理"}}"#)
        #expect(await service().flushQueue() == 0)
        #expect(service().queued.isEmpty)
    }

    @Test func loadsHistoryWithTheServerCalibration() async throws {
        let id = UUID()
        stub.on("GET", "/v1/weighings", json: """
        {"weighings":[\(weighingJSON(id.apiString))],"calibration":{"readingCount":6,"model":{"channel":"a","heightSquaredOverImpedance":0.5,"weight":0.1,"constant":-0.2,
         "sampleCount":6,"meanAbsoluteError":0.002},"applied":true}}
        """)
        let (weighings, calibration) = try await service().load()
        #expect(weighings.map(\.id) == [id])
        #expect(calibration.readingCount == 6)
        #expect(calibration.applied?.channel == .a)
        #expect(weighings.first?.calibration == calibration.applied)
        #expect(weighings.first?.profile.heightCm == 170)
    }
}


/// 用蚂蚁阿福「身材管理」的样本 A（76.80 kg、体脂 21.4%、男）核对换算（身体成分模块 §3.2）。
struct BodyCompositionTests {
    private func metrics(weight: String = "76.8", fat: String? = "0.214", sex: BiologicalSex? = .male) -> [BodyMetricKind: BodyMetric] {
        let list = BodyComposition.metrics(
            weightKg: Decimal(string: weight)!, bmi: Decimal(string: "24.8"), bodyFatFraction: fat.flatMap { Decimal(string: $0) }, sex: sex
        )
        return Dictionary(uniqueKeysWithValues: list.map { ($0.kind, $0) })
    }

    private func close(_ value: Decimal?, _ expected: String, within tolerance: String = "0.35") -> Bool {
        guard let value else { return false }
        return abs(NSDecimalNumber(decimal: value - Decimal(string: expected)!).doubleValue) <= Double(tolerance)!
    }

    @Test func matchesVendorSampleWithinTolerance() {
        let m = metrics()
        #expect(close(m[.fatMass]?.value, "16.4", within: "0.05"))
        #expect(close(m[.leanMass]?.value, "60.4", within: "0.05"))
        #expect(close(m[.boneMass]?.value, "3.3", within: "0.05"))
        #expect(close(m[.muscleMass]?.value, "57.1", within: "0.05"))
        #expect(close(m[.basalMetabolism]?.value, "1674", within: "1"))
        #expect(close(m[.waterMass]?.value, "44.8"))
        #expect(close(m[.skeletalMuscleMass]?.value, "33.0"))
        #expect(close(m[.proteinMass]?.value, "11.6"))
        #expect(close(m[.subcutaneousFatMass]?.value, "11.8", within: "0.05"))
    }

    @Test func ratesMaleRangesLikeTheVendor() {
        let m = metrics()
        #expect(m[.bodyFat]?.rating == .high)
        #expect(m[.fatMass]?.rating == .high)
        #expect(m[.muscleRate]?.rating == .standard)
        #expect(m[.muscleMass]?.rating == .standard)
        #expect(m[.waterRate]?.rating == .standard)
        #expect(m[.bmi]?.rating == .high)
        #expect(m[.basalMetabolism]?.rating == nil)
    }

    @Test func rangeBoundaryBelongsToTheHigherBand() {
        let range = BodyRange(bounds: [Decimal(string: "0.10")!, Decimal(string: "0.20")!], ratings: [.low, .standard, .high])
        #expect(range.rating(of: Decimal(string: "0.0999")!) == .low)
        #expect(range.rating(of: Decimal(string: "0.10")!) == .standard)
        #expect(range.rating(of: Decimal(string: "0.20")!) == .high)
    }

    @Test func onlyWeightAndBMIWithoutBodyFat() {
        #expect(Set(metrics(fat: nil).keys) == [.weight, .bmi])
    }

    @Test func classifiesBodyTypeFromBMIAndBodyFat() {
        #expect(BodyComposition.bodyType(bmi: Decimal(string: "24.8"), bodyFatFraction: Decimal(string: "0.214"), sex: .male)?.name == "偏胖")
        #expect(BodyComposition.bodyType(bmi: 26, bodyFatFraction: Decimal(string: "0.15"), sex: .male)?.name == "结实")
        #expect(BodyComposition.bodyType(bmi: 22, bodyFatFraction: Decimal(string: "0.26"), sex: .male)?.name == "隐形肥胖")
        #expect(BodyComposition.bodyType(bmi: 22, bodyFatFraction: Decimal(string: "0.15"), sex: .male)?.name == "标准")
        #expect(BodyComposition.bodyType(bmi: 22, bodyFatFraction: Decimal(string: "0.15"), sex: .female) == nil)
    }

    @Test func noRatingsWithoutAKnownRange() {
        #expect(metrics(sex: .female).values.allSatisfy { $0.rating == nil })
    }
}

struct BodyFatCalibrationTests {
    /// 假设秤按这个公式算，显示取到 0.1%。
    static func scaleFormula(weightKg: Double, heightCm: Double, impedance: Int) -> Decimal {
        let feature = (heightCm / 100) * (heightCm / 100) / Double(impedance)
        let value = -32 * feature + 0.0035 * weightKg + 0.17
        return Decimal((value * 1000).rounded()) / 1000
    }

    static let readings: [(weight: Double, impedance: Int)] = [(73.2, 560), (73.9, 540), (74.5, 522), (75.1, 505), (75.8, 498), (76.4, 481)]

    private func samples(_ readings: [(weight: Double, impedance: Int)] = readings) -> [BodyFatCalibration.Sample] {
        readings.map {
            BodyFatCalibration.Sample(
                weightKg: Decimal($0.weight), heightCm: 175, impedance: .init(a: $0.impedance + 60, b: $0.impedance),
                observed: Self.scaleFormula(weightKg: $0.weight, heightCm: 175, impedance: $0.impedance)
            )
        }
    }

    @Test func recoversTheScaleFormulaFromSixReadings() throws {
        let model = try #require(BodyFatCalibration.fit(samples()))
        #expect(model.channel == .b)
        #expect(BodyFatCalibration.isUsable(model))
        let predicted = try #require(model.predict(weightKg: 74.8, heightCm: 175, impedance: .init(a: 575, b: 515)))
        #expect(abs(NSDecimalNumber(decimal: predicted - Self.scaleFormula(weightKg: 74.8, heightCm: 175, impedance: 515)).doubleValue) < 0.002)
    }

    @Test func needsSixReadings() {
        #expect(BodyFatCalibration.fit(Array(samples().prefix(5))) == nil)
    }

    @Test func rejectsReadingsThatDoNotFitTheFormula() throws {
        var noisy = samples()
        noisy = noisy.enumerated().map { index, sample in
            .init(weightKg: sample.weightKg, heightCm: sample.heightCm, impedance: sample.impedance,
                  observed: sample.observed + (index.isMultiple(of: 2) ? Decimal(string: "0.03")! : Decimal(string: "-0.03")!))
        }
        let model = try #require(BodyFatCalibration.fit(noisy))
        #expect(!BodyFatCalibration.isUsable(model))
    }

    @Test func movingAverageCoversTheLastSevenDays() {
        let day: TimeInterval = 86400
        let start = Fixtures.now
        let averaged = BodyComposition.movingAverage([(start, 70), (start + day, 72), (start + 7 * day, 80)])
        #expect(averaged.map(\.value) == [70, 71, 76])
    }
}

private extension Data {
    init(hex: String) {
        self.init(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }
}
