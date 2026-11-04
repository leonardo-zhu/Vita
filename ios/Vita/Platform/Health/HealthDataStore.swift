import Foundation

/// 写进 Apple 健康的膳食项：四项主营养素，加上 2.3.0 起的钠、饱和脂肪、糖（PRD v2.0 §4.3）。
enum DietaryKind: String, Codable, Sendable, CaseIterable {
    case energyKcal, proteinG, fatG, carbohydrateG, sodiumMg, saturatedFatG, sugarG

    /// 扩展项：单独申请权限，没授权时只是不写这几项，不影响四项主营养素。
    var isExtended: Bool { self == .sodiumMg || self == .saturatedFatG || self == .sugarG }
}

/// 写入 Apple 健康的一条膳食 Sample（TDD §6.3）。
struct DietarySample: Equatable, Codable, Sendable {
    var nutrient: DietaryKind
    var value: Decimal
    var date: Date
    var metadata: [String: String]
}

/// 一次称重写进 Apple 健康的体重、体脂率与去脂体重（服务端算好的，见变更流）。
struct BodyMeasurementSample: Equatable, Codable, Sendable {
    var bodyMassKg: Decimal
    /// 0–1；没测到阻抗或缺资料时不写。
    var bodyFatFraction: Decimal?
    var leanBodyMassKg: Decimal? = nil
    var date: Date
}

/// Vita 写进健康的 Sample 的同步标识（`HKMetadataKeySyncIdentifier`，架构设计 §9）：同一对象的同一项只有一条，
/// 换手机后经 iCloud 回来的旧数据也认得出。
enum HealthSyncIdentifier {
    enum BodyKind: String, Sendable { case bodyMass, bodyFat, leanMass }

    static func record(_ id: UUID, _ nutrient: DietaryKind) -> String {
        "vita:record:\(id.uuidString.lowercased()):\(nutrient.rawValue)"
    }

    static func weighing(_ id: UUID, _ kind: BodyKind) -> String {
        "vita:weighing:\(id.uuidString.lowercased()):\(kind.rawValue)"
    }
}

enum HealthWriteAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized
}

enum HealthStoreError: Error, Equatable {
    case unavailable
    case notAuthorized
    case failed(String)
}

/// HealthKit 适配层，业务层只依赖此协议；测试与预览使用 `FakeHealthDataStore`（TDD §1.1）。
protocol HealthDataStore: Sendable {
    var isAvailable: Bool { get }
    /// 只请求 PRD 所列类型（TDD §6.1）。
    func requestAuthorization() async throws
    /// 是否已经弹过授权框。HealthKit 不告诉 App 读权限是否被拒绝，只能知道是否问过。
    func hasRequestedAuthorization() async -> Bool
    /// 四项膳食写入权限的合并状态：任一被拒即为 denied。
    func writeAuthorization() -> HealthWriteAuthorization
    /// 钠、饱和脂肪、糖还没问过（从旧版本升上来时），需要再申请一次。
    func hasUndeterminedExtendedWrite() -> Bool

    func latestBodyMassKg() async throws -> (Decimal, Date)?
    func latestHeightCm() async throws -> (Decimal, Date)?
    func latestBodyFatFraction() async throws -> (Decimal, Date)?
    func dateOfBirth() throws -> LocalDate?
    func biologicalSex() throws -> BiologicalSex?
    func activeEnergyKcal(on date: LocalDate, timeZone: TimeZone) async throws -> Decimal?
    /// 截至该日中午的前一晚睡眠时长（小时）。
    func sleepHours(endingOn date: LocalDate, timeZone: TimeZone) async throws -> Decimal?

    /// 把一条饮食记录在健康里的 Sample 换成这些（空数组即删除）。按同步标识先删后写。
    func replaceDietary(recordID: UUID, with samples: [DietarySample], syncVersion: Int) async throws
    /// 删除 1.0 写入的、没带同步标识的膳食 Sample（迁移时用）；已经不存在的忽略。
    func delete(_ uuids: [UUID]) async throws

    /// 体重、体脂率、去脂体重里还有没问过的（新版本加了类型时会这样），需要再申请一次。
    func hasUndeterminedBodyWrite() -> Bool
    /// 体重的写入状态（体脂率随体重一起申请）。
    func bodyWriteAuthorization() -> HealthWriteAuthorization
    /// 把一次称重在健康里的体重、体脂率、去脂体重换成这一份（nil 即删除）。按同步标识先删后写。
    func replaceBody(weighingID: UUID, with sample: BodyMeasurementSample?, syncVersion: Int) async throws
    /// 删除 1.0 写入的、没带同步标识的体重、体脂率 Sample（迁移时用）；已经不存在的忽略。
    func deleteBodyMeasurements(_ uuids: [UUID]) async throws
}

/// 内存实现：测试、预览与不支持 HealthKit 的环境使用。可注入失败与权限状态。
final class FakeHealthDataStore: HealthDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _write: HealthWriteAuthorization
    private var _requested = false
    private var _dietary: [UUID: (samples: [DietarySample], version: Int)] = [:]
    private var _legacy: Set<UUID> = []
    private var _failuresRemaining = 0
    private var _bodyWrite: HealthWriteAuthorization = .notDetermined
    /// 申请授权时用户对体重写入的答复。
    var bodyWriteAnswer: HealthWriteAuthorization = .authorized
    private var _body: [UUID: (sample: BodyMeasurementSample, version: Int)] = [:]
    var body = ManualBodyMetrics(enteredAt: .distantPast)
    var activeEnergy: Decimal?
    /// 按日期给不同的活动能量；没列出的日子用 `activeEnergy`。
    var activeEnergyByDate: [LocalDate: Decimal] = [:]
    var sleep: Decimal?

    init(writeAuthorization: HealthWriteAuthorization = .authorized) {
        _write = writeAuthorization
    }

    var isAvailable: Bool { true }

    /// 当前健康里各条记录的膳食 Sample 与版本。
    var dietary: [UUID: (samples: [DietarySample], version: Int)] { lock.withLock { _dietary } }
    /// 当前健康里各次称重的 Sample 与版本。
    var bodySamples: [UUID: (sample: BodyMeasurementSample, version: Int)] { lock.withLock { _body } }
    /// 1.0 写入的、没带标识的 Sample。
    var legacySamples: Set<UUID> {
        get { lock.withLock { _legacy } }
        set { lock.withLock { _legacy = newValue } }
    }

    func setWriteAuthorization(_ value: HealthWriteAuthorization) { lock.withLock { _write = value } }

    /// 接下来 `count` 次写入或删除失败（模拟网络、存储错误）。
    func failNext(_ count: Int) { lock.withLock { _failuresRemaining = count } }

    private func checkFailure() throws {
        try lock.withLock {
            if _failuresRemaining > 0 {
                _failuresRemaining -= 1
                throw HealthStoreError.failed("injected")
            }
        }
    }

    func requestAuthorization() async throws {
        lock.withLock {
            _requested = true
            if _bodyWrite == .notDetermined { _bodyWrite = bodyWriteAnswer }
        }
    }
    func hasRequestedAuthorization() async -> Bool { lock.withLock { _requested } }
    func writeAuthorization() -> HealthWriteAuthorization { lock.withLock { _write } }
    func hasUndeterminedExtendedWrite() -> Bool { false }

    func latestBodyMassKg() async throws -> (Decimal, Date)? { body.bodyMassKg.map { ($0, body.enteredAt) } }
    func latestHeightCm() async throws -> (Decimal, Date)? { body.heightCm.map { ($0, body.enteredAt) } }
    func latestBodyFatFraction() async throws -> (Decimal, Date)? { body.bodyFatFraction.map { ($0, body.enteredAt) } }
    func dateOfBirth() throws -> LocalDate? { body.dateOfBirth }
    func biologicalSex() throws -> BiologicalSex? { body.sex }
    func activeEnergyKcal(on date: LocalDate, timeZone: TimeZone) async throws -> Decimal? { activeEnergyByDate[date] ?? activeEnergy }
    func sleepHours(endingOn date: LocalDate, timeZone: TimeZone) async throws -> Decimal? { sleep }

    func replaceDietary(recordID: UUID, with samples: [DietarySample], syncVersion: Int) async throws {
        guard writeAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        try checkFailure()
        lock.withLock { _dietary[recordID] = samples.isEmpty ? nil : (samples, syncVersion) }
    }

    func delete(_ uuids: [UUID]) async throws {
        guard writeAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        try checkFailure()
        lock.withLock { _legacy.subtract(uuids) }
    }

    func bodyWriteAuthorization() -> HealthWriteAuthorization { lock.withLock { _bodyWrite } }
    func hasUndeterminedBodyWrite() -> Bool { lock.withLock { _bodyWrite == .notDetermined } }

    /// 用户在健康 App 里关掉了体重写入。
    func revokeBodyWrite() { lock.withLock { _bodyWrite = .denied } }

    func replaceBody(weighingID: UUID, with sample: BodyMeasurementSample?, syncVersion: Int) async throws {
        guard bodyWriteAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        try checkFailure()
        lock.withLock {
            _body[weighingID] = sample.map { ($0, syncVersion) }
            if let sample {
                body.bodyMassKg = sample.bodyMassKg
                body.bodyFatFraction = sample.bodyFatFraction ?? body.bodyFatFraction
                body.enteredAt = sample.date
            }
        }
    }

    func deleteBodyMeasurements(_ uuids: [UUID]) async throws {
        guard bodyWriteAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        try checkFailure()
        lock.withLock { _legacy.subtract(uuids) }
    }
}
