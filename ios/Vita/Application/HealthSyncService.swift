import Foundation
import OSLog

/// 把服务端的饮食记录与称重同步到 Apple 健康（架构设计 §9）。服务端是准的：手机按游标拉取变更流，
/// 每个变了的对象按最新状态在健康里删旧写新（带同步标识），没变的不用管。
///
/// 某个对象写失败时游标照样往前走，失败的那个记在本机，下次同步先补它（按最新状态重拉一遍）。
/// 没有写入权限时本地照常，状态显示为待处理；授权后重新同步就能补上。
@MainActor
final class HealthSyncService {
    private static let log = Logger(subsystem: "com.leonardo.vita", category: "health")
    static let stateName = "health-sync"

    /// 存在本机的同步进度。
    struct State: Codable, Equatable, Sendable {
        /// 已经处理到变更流的哪个位置。
        var cursor = 0
        /// 写入成功、现在在健康里的对象（`record:<id>` / `weighing:<id>`）。
        var written: Set<String> = []
        /// 还没写成功的对象和原因。
        var failed: [String: SyncState] = [:]
    }

    struct RunResult: Equatable {
        var synced = 0
        var failed = 0
        var waitingForPermission = 0
    }

    private let api: VitaAPIClient
    private let store: any HealthDataStore
    private let local: any LocalStateStore
    private var isRunning = false
    private(set) var state: State

    init(api: VitaAPIClient, store: any HealthDataStore, local: any LocalStateStore) {
        self.api = api
        self.store = store
        self.local = local
        state = local.load(Self.stateName, as: State.self) ?? State()
    }

    static func key(_ entity: HealthChangeDTO.Entity, _ id: UUID) -> String { "\(entity.rawValue):\(id.apiString)" }

    /// 启动、回到前台、确认卡片之后、称重之后与用户点“重试”时调用。同一时间只跑一次。
    @discardableResult
    func run() async -> RunResult {
        guard !isRunning else { return RunResult() }
        isRunning = true
        defer { isRunning = false }
        var result = RunResult()
        guard store.isAvailable else { return result }
        // 两种写入都没允许时什么也写不进去，先不拉，等授权后再同步。
        guard store.writeAuthorization() == .authorized || store.bodyWriteAuthorization() == .authorized else {
            result.waitingForPermission = state.failed.count
            return result
        }

        // 有失败的对象时从头拉一遍：变更流只按游标给，每个对象只给最新状态，失败的那些就在里面；
        // 游标之前、已经写好的跳过。没有失败时只拉游标之后的。
        do {
            var after = state.failed.isEmpty ? state.cursor : 0
            var hasMore = true
            while hasMore {
                let page: HealthChangesResponseDTO = try await api.get("/v1/health-sync/changes", query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "extended", value: "1")])
                for change in page.changes {
                    // 重拉时只处理之前失败的和游标之后的新变更，已经写好的不重写。
                    let key = Self.key(change.entity, change.id)
                    guard change.seq > state.cursor || state.failed[key] != nil else { continue }
                    switch await apply(change) {
                    case .synced: result.synced += 1
                    case .waitingForPermission: result.waitingForPermission += 1
                    case .failed: result.failed += 1
                    }
                }
                state.cursor = max(state.cursor, page.cursor)
                after = page.cursor
                hasMore = page.hasMore
                save()
            }
        } catch {
            Self.log.error("health sync fetch failed: \(String(describing: error), privacy: .public)")
        }
        return result
    }

    private enum Outcome { case synced, waitingForPermission, failed }

    private func apply(_ change: HealthChangeDTO) async -> Outcome {
        let key = Self.key(change.entity, change.id)
        do {
            switch change.entity {
            case .record:
                let samples = change.deleted ? [] : (change.samples ?? []).map {
                    DietarySample(nutrient: $0.nutrient, value: $0.value, date: $0.date, metadata: $0.metadata)
                }
                try await store.replaceDietary(recordID: change.id, with: samples, syncVersion: change.syncVersion)
                if samples.isEmpty { state.written.remove(key) } else { state.written.insert(key) }
            case .weighing:
                let sample = change.deleted ? nil : change.body.map {
                    BodyMeasurementSample(bodyMassKg: $0.bodyMassKg, bodyFatFraction: $0.bodyFatFraction, leanBodyMassKg: $0.leanBodyMassKg, date: $0.date)
                }
                try await store.replaceBody(weighingID: change.id, with: sample, syncVersion: change.syncVersion)
                if sample == nil { state.written.remove(key) } else { state.written.insert(key) }
            }
            state.failed[key] = nil
            return .synced
        } catch HealthStoreError.notAuthorized {
            // 从未授权时保持待同步，不打扰；被拒绝时标为需要用户处理（TDD §6.3）。
            let denied = (change.entity == .record ? store.writeAuthorization() : store.bodyWriteAuthorization()) == .denied
            state.failed[key] = denied ? .requiresUserResolution : .pending
            return .waitingForPermission
        } catch {
            Self.log.error("health write failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            state.failed[key] = .failedRetryable
            return .failed
        }
    }

    private func save() {
        try? local.save(state, as: Self.stateName)
    }

    /// 迁移完成后从头同步：服务端导入时给每条记录、每次称重都登记了变更。
    func resetCursor() {
        state = State()
        save()
    }

    // MARK: - 状态

    /// 记录在“健康”里的同步状态；不需要同步或还不知道时为空。
    func state(forRecord id: UUID) -> SyncState? {
        let key = Self.key(.record, id)
        if let failed = state.failed[key] { return failed }
        return state.written.contains(key) ? .synced : nil
    }

    func isInAppleHealth(weighing id: UUID) -> Bool {
        state.written.contains(Self.key(.weighing, id))
    }

    var writeAuthorization: HealthWriteAuthorization {
        store.isAvailable ? store.writeAuthorization() : .denied
    }
}
