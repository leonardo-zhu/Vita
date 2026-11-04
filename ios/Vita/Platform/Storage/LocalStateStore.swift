import Foundation

/// 2.0 里手机上只剩的几样本机状态（架构设计 §12）：Apple 健康同步的游标与结果、还没传上去的称重。
/// 都很小，一个 JSON 文件一份；业务数据不在这里。
protocol LocalStateStore: Sendable {
    func load<Value: Decodable>(_ name: String, as type: Value.Type) -> Value?
    func save<Value: Encodable>(_ value: Value, as name: String) throws
    func delete(_ name: String) throws
}

struct FileLocalStateStore: LocalStateStore {
    let directory: URL

    static func live() throws -> FileLocalStateStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return FileLocalStateStore(directory: base.appending(path: "VitaState", directoryHint: .isDirectory))
    }

    private func url(_ name: String) -> URL { directory.appending(path: "\(name).json") }

    func load<Value: Decodable>(_ name: String, as type: Value.Type) -> Value? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? VitaAPIClient.decoder.decode(Value.self, from: data)
    }

    func save<Value: Encodable>(_ value: Value, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try VitaAPIClient.encoder.encode(value).write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete(_ name: String) throws {
        let file = url(name)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { try FileManager.default.removeItem(at: file) }
    }
}

/// 测试替身。
final class InMemoryLocalStateStore: LocalStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    func load<Value: Decodable>(_ name: String, as type: Value.Type) -> Value? {
        guard let data = lock.withLock({ files[name] }) else { return nil }
        return try? VitaAPIClient.decoder.decode(Value.self, from: data)
    }

    func save<Value: Encodable>(_ value: Value, as name: String) throws {
        let data = try VitaAPIClient.encoder.encode(value)
        lock.withLock { files[name] = data }
    }

    func delete(_ name: String) throws {
        lock.withLock { _ = files.removeValue(forKey: name) }
    }
}
