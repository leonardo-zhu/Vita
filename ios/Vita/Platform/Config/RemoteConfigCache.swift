import Foundation

/// 最近一份通过校验的远程配置，原样存在 App Support（非敏感，vita-admin.md §5）。
/// 读取失败等同没有缓存。
protocol RemoteConfigCache: Sendable {
    func load() -> RemoteConfigCacheEntry?
    func save(_ entry: RemoteConfigCacheEntry) throws
    func clear()
}

struct RemoteConfigCacheEntry: Equatable, Codable, Sendable {
    /// 服务器返回的原始字节，读出时重新解码与校验。
    var body: Data
    var etag: String?
    var configVersion: String
    var lastCheckedAt: Date
}

/// `Application Support/RemoteConfig/cache.json`，原子写入。
struct FileRemoteConfigCache: RemoteConfigCache {
    let file: URL

    static func live() throws -> FileRemoteConfigCache {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: "RemoteConfig", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileRemoteConfigCache(file: directory.appending(path: "cache.json"))
    }

    func load() -> RemoteConfigCacheEntry? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(RemoteConfigCacheEntry.self, from: data)
    }

    func save(_ entry: RemoteConfigCacheEntry) throws {
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}

final class InMemoryRemoteConfigCache: RemoteConfigCache, @unchecked Sendable {
    private let lock = NSLock()
    private var entry: RemoteConfigCacheEntry?

    init(_ entry: RemoteConfigCacheEntry? = nil) {
        self.entry = entry
    }

    func load() -> RemoteConfigCacheEntry? { lock.withLock { entry } }
    func save(_ entry: RemoteConfigCacheEntry) throws { lock.withLock { self.entry = entry } }
    func clear() { lock.withLock { entry = nil } }
}

extension RemoteConfigCacheEntry {
    /// 启动时用：缓存还得过一遍校验（App 降级后 minClientVersion 可能不再满足）。
    func validConfig(clientVersion: String) -> RemoteConfig? {
        guard let config = try? RemoteConfigValidator.decode(body),
              (try? RemoteConfigValidator.validate(config, clientVersion: clientVersion, current: nil)) != nil
        else { return nil }
        return config
    }
}
