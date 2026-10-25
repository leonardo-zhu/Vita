import Foundation
import SwiftData
import Testing
@testable import Vita

@MainActor
struct PersistenceTests {
    @Test func coldStartCreatesEmptyInMemoryStore() throws {
        let container = try AppContainer.inMemory()
        let events = try container.modelContainer.mainContext.fetch(FetchDescriptor<AuditEvent>())
        #expect(events.isEmpty)
    }

    @Test func insertAndFetchAuditEvent() throws {
        let container = try AppContainer.inMemory()
        let context = container.modelContainer.mainContext
        context.insert(AuditEvent(operation: "test.op", targetID: "abc", result: .success))
        try context.save()
        let events = try context.fetch(FetchDescriptor<AuditEvent>())
        #expect(events.count == 1)
        #expect(events.first?.operation == "test.op")
        #expect(events.first?.result == .success)
    }

    @Test func containersAreIsolated() throws {
        let first = try AppContainer.inMemory()
        first.modelContainer.mainContext.insert(AuditEvent(operation: "x", result: .failure, errorCode: "E1"))
        try first.modelContainer.mainContext.save()
        let second = try AppContainer.inMemory()
        let events = try second.modelContainer.mainContext.fetch(FetchDescriptor<AuditEvent>())
        #expect(events.isEmpty)
    }
}
