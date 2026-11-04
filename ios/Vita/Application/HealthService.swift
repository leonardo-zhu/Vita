import Foundation
import OSLog

enum HealthServiceError: Error, Equatable {
    case invalidMetrics
}

/// Apple 健康只能在手机上读：读到的身体数据和活动能量传给服务端，目标、能量与 Agent 都用服务端那份
/// （架构设计 §16 M1“目标与健康数据”）。手动补录也存在服务端，7 日日均由服务端按活动记录计算。
@MainActor
final class HealthService {
    private static let log = Logger(subsystem: "com.leonardo.vita", category: "health")
    private let api: VitaAPIClient
    private let store: any HealthDataStore
    private let timeZone: () -> TimeZone
    private let now: () -> Date

    init(api: VitaAPIClient, store: any HealthDataStore, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.api = api
        self.store = store
        self.now = now
        self.timeZone = timeZone
    }

    var isAvailable: Bool { store.isAvailable }

    func requestAuthorization() async throws {
        try await store.requestAuthorization()
    }

    /// 读一遍 Apple 健康传给服务端，再取回合并了手动补录、算好日均的那份。传不上去时用本机读到的兜底显示。
    func snapshot(on date: LocalDate) async -> HealthSnapshot {
        let local = await readLocal(on: date)
        do {
            if store.isAvailable {
                try await api.perform("PUT", "/v1/health/snapshot", body: HealthUploadDTO(local))
                try await uploadActivity(endingOn: date)
            }
            let remote: HealthSnapshotDTO = try await api.get("/v1/health/snapshot", query: [URLQueryItem(name: "date", value: date.isoString)])
            return remote.domain
        } catch {
            Self.log.error("health snapshot sync failed: \(String(describing: error), privacy: .public)")
            return local
        }
    }

    /// 这些天的活动能量传给服务端（能量目标随当天活动计算）。周视图用。
    func refreshActivity(on dates: [LocalDate]) async {
        guard store.isAvailable, !dates.isEmpty else { return }
        let zone = timeZone()
        var days: [ActivityUploadDTO.Day] = []
        for date in dates {
            days.append(.init(date: date, activeKcal: (try? await store.activeEnergyKcal(on: date, timeZone: zone)) ?? nil))
        }
        do {
            try await api.perform("PUT", "/v1/health/activity", body: ActivityUploadDTO(days: days))
        } catch {
            Self.log.error("activity upload failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 当天与前 7 天：服务端用前 7 天算日均。
    private func uploadActivity(endingOn date: LocalDate) async throws {
        let zone = timeZone()
        let today = LocalDate(date: now(), timeZone: zone)
        var days: [ActivityUploadDTO.Day] = []
        for offset in 0...7 {
            let day = date.adding(days: -offset)
            guard day <= today else { continue }
            days.append(.init(date: day, activeKcal: (try? await store.activeEnergyKcal(on: day, timeZone: zone)) ?? nil))
        }
        guard !days.isEmpty else { return }
        try await api.perform("PUT", "/v1/health/activity", body: ActivityUploadDTO(days: days))
    }

    /// 只读本机的 Apple 健康，不上传、不等网络（连体脂秤时写进秤里的身高、年龄、性别用它）。
    func localSnapshot(on date: LocalDate) async -> HealthSnapshot {
        await readLocal(on: date)
    }

    /// 只读 Apple 健康，不含手动补录与日均。每一项单独读取，一项失败不影响其他项。
    private func readLocal(on date: LocalDate) async -> HealthSnapshot {
        let zone = timeZone()
        var snapshot = HealthSnapshot.empty
        guard store.isAvailable else { return snapshot }
        snapshot.authorizationRequested = await store.hasRequestedAuthorization()
        snapshot.writeDenied = store.writeAuthorization() == .denied
        snapshot.bodyMassKg = await read { try await self.store.latestBodyMassKg() }
        snapshot.heightCm = await read { try await self.store.latestHeightCm() }
        snapshot.bodyFatFraction = await read { try await self.store.latestBodyFatFraction() }
        snapshot.activeEnergyKcal = await read { try await self.store.activeEnergyKcal(on: date, timeZone: zone).map { ($0, nil) } }
        snapshot.sleepHours = await read { try await self.store.sleepHours(endingOn: date, timeZone: zone).map { ($0, nil) } }
        snapshot.dateOfBirth = readCharacteristic { try self.store.dateOfBirth() }
        snapshot.sex = readCharacteristic { try self.store.biologicalSex() }
        return snapshot
    }

    /// 只保存最新一份；新值覆盖同名项，没填的项沿用上一次。只用于目标生成，不写回 Apple 健康。
    func submitManualBodyMetrics(_ metrics: ManualBodyMetrics) async throws {
        guard metrics.isValid else { throw HealthServiceError.invalidMetrics }
        let _: ManualBodyMetricsDTO = try await api.send("PUT", "/v1/health/manual-metrics", body: ManualBodyMetricsDTO(metrics))
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
