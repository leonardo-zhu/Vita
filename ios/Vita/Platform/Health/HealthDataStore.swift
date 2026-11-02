import Foundation

/// 写入 Apple 健康的一条膳食 Sample（TDD §6.3）。
struct DietarySample: Equatable, Codable, Sendable {
    var nutrient: Nutrient
    var value: Decimal
    var date: Date
    var metadata: [String: String]
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

    func latestBodyMassKg() async throws -> (Decimal, Date)?
    func latestHeightCm() async throws -> (Decimal, Date)?
    func latestBodyFatFraction() async throws -> (Decimal, Date)?
    func dateOfBirth() throws -> LocalDate?
    func biologicalSex() throws -> BiologicalSex?
    func activeEnergyKcal(on date: LocalDate, timeZone: TimeZone) async throws -> Decimal?
    /// 截至该日中午的前一晚睡眠时长（小时）。
    func sleepHours(endingOn date: LocalDate, timeZone: TimeZone) async throws -> Decimal?

    /// 保存并返回各 Sample 的 UUID，顺序与输入一致。
    func save(_ samples: [DietarySample]) async throws -> [UUID]
    /// 删除 Vita 写入过的 Sample；已经不存在的忽略。
    func delete(_ uuids: [UUID]) async throws
}

/// 内存实现：测试、预览与不支持 HealthKit 的环境使用。可注入失败与权限状态。
final class FakeHealthDataStore: HealthDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _write: HealthWriteAuthorization
    private var _requested = false
    private var _samples: [UUID: DietarySample] = [:]
    private var _failuresRemaining = 0
    var body = ManualBodyMetrics(enteredAt: .distantPast)
    var activeEnergy: Decimal?
    /// 按日期给不同的活动能量；没列出的日子用 `activeEnergy`。
    var activeEnergyByDate: [LocalDate: Decimal] = [:]
    var sleep: Decimal?

    init(writeAuthorization: HealthWriteAuthorization = .authorized) {
        _write = writeAuthorization
    }

    var isAvailable: Bool { true }

    /// 当前保存在“健康”里的 Vita Sample。
    var samples: [UUID: DietarySample] { lock.withLock { _samples } }

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

    func requestAuthorization() async throws { lock.withLock { _requested = true } }
    func hasRequestedAuthorization() async -> Bool { lock.withLock { _requested } }
    func writeAuthorization() -> HealthWriteAuthorization { lock.withLock { _write } }

    func latestBodyMassKg() async throws -> (Decimal, Date)? { body.bodyMassKg.map { ($0, body.enteredAt) } }
    func latestHeightCm() async throws -> (Decimal, Date)? { body.heightCm.map { ($0, body.enteredAt) } }
    func latestBodyFatFraction() async throws -> (Decimal, Date)? { body.bodyFatFraction.map { ($0, body.enteredAt) } }
    func dateOfBirth() throws -> LocalDate? { body.dateOfBirth }
    func biologicalSex() throws -> BiologicalSex? { body.sex }
    func activeEnergyKcal(on date: LocalDate, timeZone: TimeZone) async throws -> Decimal? { activeEnergyByDate[date] ?? activeEnergy }
    func sleepHours(endingOn date: LocalDate, timeZone: TimeZone) async throws -> Decimal? { sleep }

    func save(_ samples: [DietarySample]) async throws -> [UUID] {
        guard writeAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        try checkFailure()
        return lock.withLock {
            samples.map { sample in
                let id = UUID()
                _samples[id] = sample
                return id
            }
        }
    }

    func delete(_ uuids: [UUID]) async throws {
        guard writeAuthorization() == .authorized else { throw HealthStoreError.notAuthorized }
        try checkFailure()
        lock.withLock { uuids.forEach { _samples.removeValue(forKey: $0) } }
    }
}
