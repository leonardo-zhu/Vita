import Foundation
import Testing
@testable import Vita

struct SecretStoreTests {
    @Test func inMemoryStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        #expect(try store.read(.arkAPIKey) == nil)
        try store.write("k1", for: .arkAPIKey)
        #expect(try store.read(.arkAPIKey) == "k1")
        try store.delete(.arkAPIKey)
        #expect(try store.read(.arkAPIKey) == nil)
    }

    @Test func keychainStoreRoundTripAndOverwrite() throws {
        // 使用独立 service，避免污染真实数据。
        let store = KeychainSecretStore(service: "com.leonardo.vita.tests.\(UUID().uuidString)")
        defer { try? store.delete(.arkAPIKey) }
        #expect(try store.read(.arkAPIKey) == nil)
        try store.write("first", for: .arkAPIKey)
        try store.write("second", for: .arkAPIKey)
        #expect(try store.read(.arkAPIKey) == "second")
        try store.delete(.arkAPIKey)
        #expect(try store.read(.arkAPIKey) == nil)
    }
}
