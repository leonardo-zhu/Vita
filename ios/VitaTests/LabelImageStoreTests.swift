import Foundation
import Testing
@testable import Vita

struct LabelImageStoreTests {
    /// App Support 的路径带空格；`URL.path()` 默认百分号编码，曾导致存得进、读不出。
    @Test func roundTripsInADirectoryWithSpaces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Vita Tests \(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = FileLabelImageStore(directory: directory)

        let data = Data("label-image".utf8)
        let reference = try store.save(data)
        #expect(try store.load(reference) == data)

        try store.delete(reference)
        #expect(try store.load(reference) == nil)
    }
}
