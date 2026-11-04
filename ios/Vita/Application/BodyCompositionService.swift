import Foundation
import OSLog

/// 一次称重存到了哪里。
enum ScaleSaveDestination: Equatable, Sendable {
    case appleHealth
    /// 不支持或没允许写入 Apple 健康：服务端记为手动补录，目标生成照样用得上。
    case manual
    /// 连不上服务端，先存在本机，有网时自动补传。
    case queued
}

/// 删除一次称重的结果。
enum WeighingDeletion: Equatable, Sendable {
    case deleted
    /// 服务端删了，但没有权限删健康里的那份（PRD §3.3：权限撤销时只更新 Vita 并提示）。
    case keptInAppleHealth
}

/// 体脂秤称重（身体成分模块 §5）。蓝牙连秤在手机上；称重存在服务端，指标与校准由服务端计算，
/// 体重、体脂率经变更流写进 Apple 健康（`HealthSyncService`）。弱网时称重先进本机队列，id 由手机生成，补传不会重复。
@MainActor
final class BodyCompositionService {
    private static let log = Logger(subsystem: "com.leonardo.vita", category: "health")
    static let queueName = "weighing-queue"

    private let api: VitaAPIClient
    private let store: any HealthDataStore
    private let local: any LocalStateStore
    private let healthSync: HealthSyncService
    private let now: () -> Date

    init(api: VitaAPIClient, store: any HealthDataStore, local: any LocalStateStore, healthSync: HealthSyncService, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.store = store
        self.local = local
        self.healthSync = healthSync
        self.now = now
    }

    /// 还没传上去的称重。
    var queued: [WeighingUploadDTO] { local.load(Self.queueName, as: [WeighingUploadDTO].self) ?? [] }

    /// 存下一次称重。第一次会申请体重写入权限；读数不合理时抛 `invalidMetrics`，什么都不存。
    /// `recordedAt` 是离线记录的称重时间；服务端按它判断时间是否可靠。
    func record(_ measurement: ScaleMeasurement, recordedAt: Date? = nil, source: WeighingSource) async throws -> (BodyWeighing?, ScaleSaveDestination) {
        guard ManualBodyMetrics(bodyMassKg: measurement.weightKg, enteredAt: now()).isValid else { throw HealthServiceError.invalidMetrics }
        let writable = await canWriteToHealth()
        let upload = WeighingUploadDTO(
            id: UUID(), weightKg: measurement.weightKg,
            impedance: measurement.impedance.map { .init(a: $0.a, b: $0.b) }, source: source,
            recordedAt: source == .live ? nil : recordedAt, appleHealthWritable: writable
        )
        do {
            let response: WeighingResponseDTO = try await uploader.send("POST", "/v1/weighings", body: upload)
            await healthSync.run()
            // 体脂率要按当前采用的校准算，和历史列表一致。
            let saved = (try? await load())?.weighings.first { $0.id == upload.id }
                ?? response.weighing.domain(calibration: nil, inAppleHealth: healthSync.isInAppleHealth(weighing: upload.id))
            return (saved, writable ? .appleHealth : .manual)
        } catch let error as APIError where Self.isTransient(error) {
            // 连不上、超时或服务端暂时出错（如部署重启时的 502）：先存在手机上。
            // 实时称重没有自带时间，排队时记下现在，补传时按离线记录交给服务端。
            var pending = upload
            if pending.source == .live { pending.source = .offline; pending.recordedAt = now() }
            try enqueue(pending)
            return (nil, .queued)
        }
    }

    /// 补传队列里的称重。打开称重页、回到前台时调用；传成功的出队，服务端按 id 去重。
    @discardableResult
    func flushQueue() async -> Int {
        var remaining = queued
        guard !remaining.isEmpty else { return 0 }
        var sent = 0
        while let next = remaining.first {
            do {
                let _: WeighingResponseDTO = try await uploader.send("POST", "/v1/weighings", body: next)
                sent += 1
                remaining.removeFirst()
                try? local.save(remaining, as: Self.queueName)
            } catch APIError.server(let status, _, _) where (400..<500).contains(status) && status != 429 {
                // 服务端拒绝（如读数不合理）：重传也不会成功，丢掉这一条。
                Self.log.error("queued weighing rejected with \(status)")
                remaining.removeFirst()
                try? local.save(remaining, as: Self.queueName)
            } catch {
                break
            }
        }
        if sent > 0 { await healthSync.run() }
        return sent
    }

    /// 上传称重用短一点的超时：秤在等保存结果，等太久不如先进队列。
    private var uploader: VitaAPIClient {
        var client = api
        client.timeout = 10
        return client
    }

    /// 这些错误过一会儿重传多半就好了，进队列；其余（如读数被拒）照常报错。
    static func isTransient(_ error: APIError) -> Bool {
        switch error {
        case .offline: true
        case .server(let status, _, _): status >= 500 || status == 429
        case .missingToken, .unauthorized, .invalidResponse: false
        }
    }

    private func enqueue(_ upload: WeighingUploadDTO) throws {
        var all = queued
        all.append(upload)
        try local.save(all, as: Self.queueName)
    }

    /// 全部称重（新的在前）与校准情况。体脂率按服务端拟合的校准公式算。
    func load() async throws -> (weighings: [BodyWeighing], calibration: BodyFatCalibrationStatus) {
        let response: WeighingsResponseDTO = try await api.get("/v1/weighings")
        let calibration = response.calibration.domain
        let model = calibration.applied
        return (response.weighings.map { $0.domain(calibration: model, inAppleHealth: healthSync.isInAppleHealth(weighing: $0.id)) }, calibration)
    }

    /// 记下（或清掉）这次称重时秤屏幕上的体脂率。校准公式因此变化时服务端登记全部称重的变更，
    /// 同步时重写健康里的体脂率与去脂体重，让健康里的历史和 Vita 显示一致。
    func setScaleBodyFat(_ fraction: Decimal?, for id: UUID) async throws {
        if let fraction, !(Decimal(string: "0.02")!...Decimal(string: "0.7")!).contains(fraction) {
            throw HealthServiceError.invalidMetrics
        }
        let _: ScaleReadingResponseDTO = try await api.send("PUT", "/v1/weighings/\(id.apiString)/scale-reading", body: ScaleReadingRequestDTO(bodyFatFraction: fraction))
        await healthSync.run()
    }

    /// 删除一次称重，同步时连同写进 Apple 健康的体重、体脂率一起删。没有权限删健康里的那份时只删 Vita 的。
    func delete(_ id: UUID) async throws -> WeighingDeletion {
        let wasInHealth = healthSync.isInAppleHealth(weighing: id)
        try await api.perform("DELETE", "/v1/weighings/\(id.apiString)")
        await healthSync.run()
        return wasInHealth && healthSync.isInAppleHealth(weighing: id) ? .keptInAppleHealth : .deleted
    }

    /// 打开称重页时先问：授权弹窗要是在同步离线记录时才弹出，保存会一直等着，秤收不到确认就不停重发、也不发实时体重。
    func prepareHealthWrite() async {
        _ = await canWriteToHealth()
    }

    /// 没允许就申请一次全部健康权限：已经答复过的类型系统不会再问，只列出没问过的。
    private func canWriteToHealth() async -> Bool {
        guard store.isAvailable else { return false }
        if store.hasUndeterminedBodyWrite() || store.bodyWriteAuthorization() != .authorized {
            do { try await store.requestAuthorization() } catch { Self.log.error("health authorization failed: \(error, privacy: .public)") }
        }
        return store.bodyWriteAuthorization() == .authorized
    }
}
