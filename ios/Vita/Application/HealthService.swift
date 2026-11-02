import Foundation
import SwiftData

enum HealthServiceError: Error, Equatable {
    case invalidMetrics
}

/// 读取 HealthKit 并用手动补录兜底（`getHealthSnapshot`、`submitManualBodyMetrics`）。
@MainActor
final class HealthService {
    private let context: ModelContext
    private let store: any HealthDataStore
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    /// 各天的活动读数，供每日能量目标同步读取（TDD §6.2）。Data 页、回到前台与每轮对话开始时刷新。
    private var activityCache: [LocalDate: DayActivity] = [:]
    /// 平时活动至少要有几天的数据。
    static let minimumAverageDays = 3

    init(context: ModelContext, store: any HealthDataStore, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.context = context
        self.store = store
        self.now = now
        self.timeZone = timeZone
    }

    var isAvailable: Bool { store.isAvailable }

    func requestAuthorization() async throws {
        try await store.requestAuthorization()
    }

    /// 某日的健康数据。每一项单独读取，一项失败不影响其他项；HealthKit 没有的项目用手动补录兜底。
    func snapshot(on date: LocalDate) async -> HealthSnapshot {
        let manual = try? manualMetrics()
        let zone = timeZone()
        var snapshot = HealthSnapshot.empty
        if store.isAvailable {
            snapshot.authorizationRequested = await store.hasRequestedAuthorization()
            snapshot.writeDenied = store.writeAuthorization() == .denied
            snapshot.bodyMassKg = await read { try await self.store.latestBodyMassKg() }
            snapshot.heightCm = await read { try await self.store.latestHeightCm() }
            snapshot.bodyFatFraction = await read { try await self.store.latestBodyFatFraction() }
            snapshot.activeEnergyKcal = await read { try await self.store.activeEnergyKcal(on: date, timeZone: zone).map { ($0, nil) } }
            snapshot.averageActiveEnergyKcal = await read { try await self.averageActiveEnergy(before: date).map { ($0, nil) } }
            activityCache[date] = DayActivity(
                activeKcal: snapshot.activeEnergyKcal.value, dailyAverageKcal: snapshot.averageActiveEnergyKcal.value
            )
            snapshot.sleepHours = await read { try await self.store.sleepHours(endingOn: date, timeZone: zone).map { ($0, nil) } }
            snapshot.dateOfBirth = readCharacteristic { try self.store.dateOfBirth() }
            snapshot.sex = readCharacteristic { try self.store.biologicalSex() }
        }
        let at = manual?.enteredAt
        snapshot.bodyMassKg = snapshot.bodyMassKg.fallback(to: manual?.bodyMassKg, at: at)
        snapshot.heightCm = snapshot.heightCm.fallback(to: manual?.heightCm, at: at)
        snapshot.bodyFatFraction = snapshot.bodyFatFraction.fallback(to: manual?.bodyFatFraction, at: at)
        snapshot.dateOfBirth = snapshot.dateOfBirth.fallback(to: manual?.dateOfBirth, at: at)
        snapshot.sex = snapshot.sex.fallback(to: manual?.sex, at: at)
        return snapshot
    }

    /// 缓存里某天的活动；还没读过时为 nil，调用方用目标设定时保存的平时活动。
    func cachedActivity(on date: LocalDate) -> DayActivity? {
        activityCache[date]
    }

    /// 重新读取这些天的活动，并更新缓存。读取失败的项留空。
    func refreshActivity(on dates: [LocalDate]) async {
        guard store.isAvailable else { return }
        let zone = timeZone()
        for date in dates {
            let active = try? await store.activeEnergyKcal(on: date, timeZone: zone)
            let average = try? await averageActiveEnergy(before: date)
            activityCache[date] = DayActivity(activeKcal: active ?? nil, dailyAverageKcal: average ?? nil)
        }
    }

    /// `date` 之前 7 个完整日里有数据的那些天的日均活动；不足 3 天返回 nil。
    private func averageActiveEnergy(before date: LocalDate) async throws -> Decimal? {
        let zone = timeZone()
        var values: [Decimal] = []
        for offset in 1...7 {
            if let value = try await store.activeEnergyKcal(on: date.adding(days: -offset), timeZone: zone), value > 0 {
                values.append(value)
            }
        }
        guard values.count >= Self.minimumAverageDays else { return nil }
        return values.reduce(0, +) / Decimal(values.count)
    }

    /// 只保存最新一份；新值覆盖同名项，没填的项沿用上一次。
    func submitManualBodyMetrics(_ metrics: ManualBodyMetrics) throws {
        guard metrics.isValid else { throw HealthServiceError.invalidMetrics }
        let existing = try context.fetch(FetchDescriptor<ManualBodyMetricsEntry>())
        var merged = (try existing.first?.metrics()) ?? ManualBodyMetrics(enteredAt: metrics.enteredAt)
        merged.bodyMassKg = metrics.bodyMassKg ?? merged.bodyMassKg
        merged.heightCm = metrics.heightCm ?? merged.heightCm
        merged.bodyFatFraction = metrics.bodyFatFraction ?? merged.bodyFatFraction
        merged.dateOfBirth = metrics.dateOfBirth ?? merged.dateOfBirth
        merged.sex = metrics.sex ?? merged.sex
        merged.enteredAt = metrics.enteredAt
        existing.forEach(context.delete)
        context.insert(ManualBodyMetricsEntry(metrics: merged))
        context.insert(AuditEvent(operation: "health.manualMetrics", result: .success, createdAt: now()))
        try context.save()
    }

    func manualMetrics() throws -> ManualBodyMetrics? {
        try context.fetch(FetchDescriptor<ManualBodyMetricsEntry>()).first?.metrics()
    }

    private func read<Value>(_ body: () async throws -> (Value, Date?)?) async -> HealthReading<Value> {
        do {
            guard let (value, date) = try await body() else { return .noData }
            return .value(value, source: .healthKit, measuredAt: date)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func readCharacteristic<Value>(_ body: () throws -> Value?) -> HealthReading<Value> {
        do {
            guard let value = try body() else { return .noData }
            return .value(value, source: .healthKit, measuredAt: nil)
        } catch {
            // 未授权时读取特征值会抛错，与“查询失败”同样展示为没有数据。
            return .noData
        }
    }
}
