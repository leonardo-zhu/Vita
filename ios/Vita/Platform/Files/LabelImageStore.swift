import Foundation

/// 营养标签原图的本地存储（TDD §1 “App Support：营养标签原图”）。引用形如 `label:<uuid>`。
protocol LabelImageStore: Sendable {
    func save(_ data: Data) throws -> String
    func load(_ reference: String) throws -> Data?
    func delete(_ reference: String) throws
}

enum LabelImageReference {
    static func make() -> String { "label:\(UUID().uuidString)" }

    static func id(_ reference: String) -> UUID? {
        guard reference.hasPrefix("label:") else { return nil }
        return UUID(uuidString: String(reference.dropFirst("label:".count)))
    }
}

struct FileLabelImageStore: LabelImageStore {
    let directory: URL

    static func live() throws -> FileLabelImageStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return FileLabelImageStore(directory: base.appending(path: "NutritionLabels", directoryHint: .isDirectory))
    }

    private func url(_ reference: String) throws -> URL {
        guard let id = LabelImageReference.id(reference) else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appending(path: id.uuidString)
    }

    func save(_ data: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reference = LabelImageReference.make()
        try data.write(to: try url(reference), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return reference
    }

    func load(_ reference: String) throws -> Data? {
        let file = try url(reference)
        guard FileManager.default.fileExists(atPath: file.path()) else { return nil }
        return try Data(contentsOf: file)
    }

    func delete(_ reference: String) throws {
        let file = try url(reference)
        if FileManager.default.fileExists(atPath: file.path()) { try FileManager.default.removeItem(at: file) }
    }
}

/// 测试替身。
final class InMemoryLabelImageStore: LabelImageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: Data] = [:]

    func save(_ data: Data) throws -> String {
        let reference = LabelImageReference.make()
        lock.withLock { images[reference] = data }
        return reference
    }

    func load(_ reference: String) throws -> Data? {
        lock.withLock { images[reference] }
    }

    func delete(_ reference: String) throws {
        lock.withLock { _ = images.removeValue(forKey: reference) }
    }
}
