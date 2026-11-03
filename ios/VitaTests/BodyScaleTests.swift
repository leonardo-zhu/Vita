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
    let store = FakeHealthDataStore()
    let services: AppServices

    init() throws {
        var container = try AppContainer.inMemory()
        container.healthStore = store
        services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        store.body.heightCm = 170
        store.body.sex = .male
        store.body.dateOfBirth = LocalDate(year: 1990, month: 1, day: 1)
    }

    private let final = ScaleMeasurement(weightKg: Decimal(string: "69.6")!, isStable: true, isFinal: true, impedance: .init(a: 482, b: 432))

    private func record(_ measurement: ScaleMeasurement? = nil, recordedAt: Date? = nil, source: WeighingSource = .live) async throws
        -> (BodyWeighing, ScaleSaveDestination)
    {
        let profile = await services.health.snapshot(on: Fixtures.day)
        return try await services.bodyComposition.record(measurement ?? final, recordedAt: recordedAt, source: source, profile: profile)
    }

    @Test func writesWeightAndBodyFatToHealthAndKeepsTheWeighing() async throws {
        let (weighing, destination) = try await record()
        #expect(destination == .appleHealth)
        #expect(weighing.bodyFatFraction != nil)
        #expect(weighing.inAppleHealth)
        #expect(store.bodySamples.map(\.bodyMassKg) == [Decimal(string: "69.6")!])
        #expect(try services.bodyComposition.weighings() == [weighing])
        #expect(try services.health.manualMetrics() == nil)
        // 下次读取就是新称的体重。
        #expect(await services.health.snapshot(on: Fixtures.day).bodyMassKg.value == Decimal(string: "69.6")!)
    }

    @Test func skipsBodyFatWithoutImpedance() async throws {
        let (weighing, _) = try await record(ScaleMeasurement(weightKg: 70, isStable: true, isFinal: true, impedance: nil))
        #expect(weighing.bodyFatFraction == nil)
        #expect(store.bodySamples.first?.bodyFatFraction == nil)
    }

    @Test func usesOfflineRecordTimeUnlessInTheFuture() async throws {
        let earlier = Fixtures.now.addingTimeInterval(-3600)
        let (timed, _) = try await record(recordedAt: earlier, source: .offline)
        #expect(timed.measuredAt == earlier)
        #expect(timed.timeReliable)
        let (future, _) = try await record(recordedAt: Fixtures.now.addingTimeInterval(3600), source: .offline)
        #expect(future.measuredAt == Fixtures.now)
        #expect(!future.timeReliable)
        #expect(try services.bodyComposition.weighings().map(\.id) == [future.id, timed.id])
    }

    @Test func fallsBackToManualWhenWriteDenied() async throws {
        store.bodyWriteAnswer = .denied
        let (weighing, destination) = try await record()
        #expect(destination == .manual)
        #expect(!weighing.inAppleHealth)
        #expect(store.bodySamples.isEmpty)
        #expect(try services.health.manualMetrics()?.bodyMassKg == Decimal(string: "69.6")!)
    }

    @Test func olderOfflineRecordDoesNotOverwriteNewerManualWeight() async throws {
        store.bodyWriteAnswer = .denied
        _ = try await record()
        _ = try await record(ScaleMeasurement(weightKg: 72, isStable: true, isFinal: true, impedance: nil),
                             recordedAt: Fixtures.now.addingTimeInterval(-86400), source: .offline)
        #expect(try services.health.manualMetrics()?.bodyMassKg == Decimal(string: "69.6")!)
        #expect(try services.bodyComposition.weighings().count == 2)
    }

    @Test func rejectsImplausibleWeightWithoutSavingAnything() async throws {
        await #expect(throws: HealthServiceError.invalidMetrics) {
            try await record(ScaleMeasurement(weightKg: Decimal(string: "7.45")!, isStable: true, isFinal: true, impedance: nil))
        }
        #expect(store.bodySamples.isEmpty)
        #expect(try services.bodyComposition.weighings().isEmpty)
    }

    @Test func deletingAWeighingAlsoDeletesItFromHealth() async throws {
        let (weighing, _) = try await record()
        #expect(try await services.bodyComposition.delete(weighing.id) == .deleted)
        #expect(store.bodySamples.isEmpty)
        #expect(try services.bodyComposition.weighings().isEmpty)
    }

    @Test func deletingWithoutHealthAccessKeepsTheHealthCopy() async throws {
        let (weighing, _) = try await record()
        store.revokeBodyWrite()
        #expect(try await services.bodyComposition.delete(weighing.id) == .keptInAppleHealth)
        #expect(store.bodySamples.count == 1)
        #expect(try services.bodyComposition.weighings().isEmpty)
    }
}

private extension Data {
    init(hex: String) {
        self.init(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }
}
