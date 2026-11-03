import Foundation
import OSLog
import SwiftData

/// 一次称重存到了哪里。
enum ScaleSaveDestination: Equatable, Sendable {
    case appleHealth
    /// 不支持或没允许写入 Apple 健康：存为手动补录，目标生成照样用得上。
    case manual
}

/// 删除一次称重的结果。
enum WeighingDeletion: Equatable, Sendable {
    case deleted
    /// 本地删了，但没有权限删健康里的那份（PRD §3.3：权限撤销时只更新本地并提示）。
    case keptInAppleHealth
}

/// 体脂秤称重的保存、历史与删除（身体成分模块 §5）。原始称重存在 Vita，体重、体脂率同时写入 Apple 健康。
@MainActor
final class BodyCompositionService {
    private static let log = Logger(subsystem: "com.leonardo.vita", category: "health")
    private let context: ModelContext
    private let store: any HealthDataStore
    private let health: HealthService
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(
        context: ModelContext, store: any HealthDataStore, health: HealthService,
        now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.context = context
        self.store = store
        self.health = health
        self.now = now
        self.timeZone = timeZone
    }

    /// 存下一次称重并写入 Apple 健康；第一次会申请体重写入权限，不支持或被拒时改存手动补录。
    /// `recordedAt` 是离线记录的称重时间；没有或晚于现在（秤的时钟不对）时用现在。
    /// 读数不合理时抛 `invalidMetrics`，什么都不存；已允许但写入失败时抛错，由用户重试。
    func record(
        _ measurement: ScaleMeasurement, recordedAt: Date? = nil, source: WeighingSource, profile: HealthSnapshot
    ) async throws -> (BodyWeighing, ScaleSaveDestination) {
        let reliableTime = recordedAt.flatMap { $0 <= now() ? $0 : nil }
        let date = reliableTime ?? now()
        let weighingProfile = WeighingProfile(
            heightCm: profile.heightCm.value,
            ageYears: profile.dateOfBirth.value.map { GoalRecommendationPolicy.age(of: $0, on: LocalDate(date: date, timeZone: timeZone())) },
            sex: profile.sex.value
        )
        let entry = ScaleWeighing(
            measuredAt: date, weightGrams: NSDecimalNumber(decimal: measurement.weightKg * 1000).intValue,
            impedance: measurement.impedance, source: source, timeReliable: source == .live || reliableTime != nil,
            profile: weighingProfile, healthSampleIDs: [], now: now()
        )
        let weighing = try entry.snapshot()
        let metrics = ManualBodyMetrics(bodyMassKg: weighing.weightKg, bodyFatFraction: weighing.bodyFatFraction, enteredAt: date)
        guard metrics.isValid else { throw HealthServiceError.invalidMetrics }

        let destination: ScaleSaveDestination
        if await canWriteToHealth() {
            let sample = BodyMeasurementSample(bodyMassKg: weighing.weightKg, bodyFatFraction: weighing.bodyFatFraction, date: date)
            entry.healthSampleIDs = try await store.saveBodyMeasurement(sample)
            destination = .appleHealth
        } else {
            // 离线记录可能比已有的补录还旧，不能拿旧体重覆盖新的。
            if try (health.manualMetrics()?.enteredAt ?? .distantPast) <= date {
                try health.submitManualBodyMetrics(metrics)
            }
            destination = .manual
        }
        context.insert(entry)
        context.insert(AuditEvent(operation: "health.scaleMeasurement", result: .success, createdAt: now()))
        try context.save()
        return (try entry.snapshot(), destination)
    }

    /// 全部称重，新的在前。
    func weighings() throws -> [BodyWeighing] {
        try context.fetch(FetchDescriptor<ScaleWeighing>(sortBy: [SortDescriptor(\.measuredAt, order: .reverse)]))
            .map { try $0.snapshot() }
    }

    /// 删除一次称重，连同写进 Apple 健康的体重、体脂率。没有权限删健康里的那份时只删本地。
    func delete(_ id: UUID) async throws -> WeighingDeletion {
        guard let entry = try context.fetch(FetchDescriptor<ScaleWeighing>(predicate: #Predicate { $0.id == id })).first else {
            return .deleted
        }
        var result = WeighingDeletion.deleted
        let sampleIDs = entry.healthSampleIDs
        if !sampleIDs.isEmpty {
            do {
                try await store.deleteBodyMeasurements(sampleIDs)
            } catch HealthStoreError.notAuthorized {
                result = .keptInAppleHealth
            }
        }
        context.delete(entry)
        context.insert(AuditEvent(operation: "health.scaleMeasurement.delete", result: .success, createdAt: now()))
        try context.save()
        return result
    }

    /// 打开称重页时先问：授权弹窗要是在同步离线记录时才弹出，保存会一直等着，秤收不到确认就不停重发、也不发实时体重。
    func prepareHealthWrite() async {
        _ = await canWriteToHealth()
    }

    /// 没允许就申请一次全部健康权限：已经答复过的类型系统不会再问，只列出没问过的。
    private func canWriteToHealth() async -> Bool {
        guard store.isAvailable else { return false }
        if store.bodyWriteAuthorization() != .authorized {
            do { try await store.requestAuthorization() } catch { Self.log.error("health authorization failed: \(error, privacy: .public)") }
        }
        let authorization = store.bodyWriteAuthorization()
        Self.log.info("body write authorization: \(String(describing: authorization), privacy: .public)")
        return authorization == .authorized
    }
}
