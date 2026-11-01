import Foundation
import os

/// 诊断事件的本地队列：`Application Support/Diagnostics/queue.json`。上报成功才删；最多留 500 条，满了丢最旧的。
protocol DiagnosticsQueue: Sendable {
    func load() -> [DiagnosticEvent]
    func save(_ events: [DiagnosticEvent])
}

struct FileDiagnosticsQueue: DiagnosticsQueue {
    let file: URL

    static func live() throws -> FileDiagnosticsQueue {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileDiagnosticsQueue(file: directory.appending(path: "queue.json"))
    }

    func load() -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DiagnosticEvent].self, from: data)) ?? []
    }

    func save(_ events: [DiagnosticEvent]) {
        if events.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? DiagnosticsBatch.encoder.encode(events).write(to: file, options: .atomic)
    }
}

final class InMemoryDiagnosticsQueue: DiagnosticsQueue, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    func load() -> [DiagnosticEvent] { lock.withLock { events } }
    func save(_ events: [DiagnosticEvent]) { lock.withLock { self.events = events } }
}

/// 上报的 HTTP 层，测试里替换为替身。
protocol DiagnosticsTransport: Sendable {
    func post(_ request: URLRequest) async throws -> HTTPURLResponse
}

/// 只发往构建配置里的那一个地址，拒绝跨主机重定向。
final class URLSessionDiagnosticsTransport: NSObject, DiagnosticsTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    func post(_ request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// 客户端诊断日志（ADR-014，vita-admin.md §11.4）：记录到本机队列，回到前台或攒够 20 条时批量上报。
///
/// - 设置页可关，默认开；关掉时不记录，并清空还没发出去的。
/// - 匿名安装 ID 每 30 天换一个（和服务端的保留期一致），不含设备标识或用户信息。
/// - 上报失败保留在队列里下次再发；服务端 400（格式不被接受）丢掉这批，403（被封禁）清空并停止本次运行的上报。
final class DiagnosticsService: DiagnosticsRecording, @unchecked Sendable {
    static let enabledKey = "vita.diagnostics.enabled"
    static let installKey = "vita.diagnostics.install"
    static let maxQueued = 500
    static let batchSize = 100
    static let flushThreshold = 20
    static let installLifetime: TimeInterval = 30 * 86400

    private let lock = NSLock()
    private let url: URL
    private let appVersion: String
    private let osVersion: String?
    private let queue: any DiagnosticsQueue
    private let transport: any DiagnosticsTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private var flushing: Task<Void, Never>?
    private var refused = false

    private static let log = Logger(subsystem: "com.leonardo.vita", category: "diagnostics")

    init(
        url: URL, appVersion: String, osVersion: String?, queue: any DiagnosticsQueue,
        transport: any DiagnosticsTransport = URLSessionDiagnosticsTransport(),
        defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init
    ) {
        self.url = url
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.queue = queue
        self.transport = transport
        self.defaults = defaults
        self.now = now
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { lock.withLock { queue.save([]) } }
    }

    var pendingCount: Int { lock.withLock { queue.load().count } }

    func record(_ event: DiagnosticEvent) {
        guard isEnabled else { return }
        let count = lock.withLock {
            var events = queue.load()
            events.append(event)
            if events.count > Self.maxQueued { events.removeFirst(events.count - Self.maxQueued) }
            queue.save(events)
            return events.count
        }
        if count >= Self.flushThreshold { Task { await flush() } }
    }

    /// 同一时刻只跑一次；进行中的再次调用等那一次结束。
    func flush() async {
        let task: Task<Void, Never> = lock.withLock {
            if let flushing { return flushing }
            let task = Task { await self.send() }
            flushing = task
            return task
        }
        await task.value
        lock.withLock { flushing = nil }
    }

    private func send() async {
        while isEnabled, !lock.withLock({ refused }) {
            let batch = Array(lock.withLock { queue.load() }.prefix(Self.batchSize))
            guard !batch.isEmpty else { return }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try DiagnosticsBatch.encoder.encode(
                    DiagnosticsBatch(installId: installID(), appVersion: appVersion, osVersion: osVersion, events: batch)
                )
                let response = try await transport.post(request)
                switch response.statusCode {
                case 200..<300:
                    remove(batch)
                case 400, 413:
                    // 格式不被接受，重发也没用
                    Self.log.error("diagnostics batch rejected: \(response.statusCode)")
                    remove(batch)
                case 403:
                    lock.withLock {
                        refused = true
                        queue.save([])
                    }
                    return
                default:
                    Self.log.error("diagnostics upload failed: \(response.statusCode)")
                    return
                }
            } catch {
                Self.log.error("diagnostics upload failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private func remove(_ sent: [DiagnosticEvent]) {
        let ids = Set(sent.map(\.eventId))
        lock.withLock { queue.save(queue.load().filter { !ids.contains($0.eventId) }) }
    }

    /// 匿名安装 ID，超过 30 天换新的。
    func installID() -> UUID {
        struct Stored: Codable { var id: UUID; var createdAt: Date }
        if let data = defaults.data(forKey: Self.installKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           now().timeIntervalSince(stored.createdAt) < Self.installLifetime {
            return stored.id
        }
        let fresh = Stored(id: UUID(), createdAt: now())
        defaults.set(try? JSONEncoder().encode(fresh), forKey: Self.installKey)
        return fresh.id
    }
}
