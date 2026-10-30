import Foundation
import SwiftData
import Testing
@testable import Vita

/// 可调的时钟，用来跨过 TTL 与午夜。
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

@MainActor
struct PendingServiceTests {
    let clock = TestClock(Fixtures.now)
    let services: AppServices
    let context: ModelContext

    init() throws {
        let container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        let clock = clock
        services = AppServices(container: container, now: { clock.now }, timeZone: { Fixtures.shanghai })
        context = container.modelContainer.mainContext
    }

    private func records() throws -> Int {
        try context.fetch(FetchDescriptor<ConsumptionRecord>()).count
    }

    private func lunch(_ kcal: Decimal = 500, on date: LocalDate = Fixtures.day) throws -> RecordChange {
        .create(try .lunch(on: date, [.estimate(kcal: kcal)]))
    }

    // MARK: - 确认门

    @Test func proposalWritesNothingUntilConfirmed() throws {
        let pending = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        #expect(pending.status == .readyForConfirmation)
        #expect(pending.recordPreview?.totals.energyKcal == 500)
        #expect(try records() == 0)
        #expect(try services.dayData.day(Fixtures.day).summary.totals == .zero)

        let recordID = try services.pending.confirm(pending.id)
        #expect(try records() == 1)
        let resolved = try services.pending.pending(pending.id)
        #expect(resolved.status == .confirmed)
        #expect(resolved.resultRecordID == recordID)
        #expect(resolved.preview == nil)
        #expect(try services.pending.active(on: Fixtures.day) == nil)
    }

    @Test func invalidProposalCreatesNoPending() throws {
        #expect(throws: RecordServiceError.self) {
            try services.pending.propose(.create(try .lunch([.reference("vita.reference.nope", grams: 10)])), on: Fixtures.day, expectedRevision: 0)
        }
        #expect(try services.pending.active(on: Fixtures.day) == nil)
    }

    @Test func cancelWritesNothingAndCannotConfirmLater() throws {
        let pending = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        try services.pending.cancel(pending.id)
        #expect(throws: PendingServiceError.notActive(.cancelled)) { try services.pending.confirm(pending.id) }
        #expect(try records() == 0)
    }

    // MARK: - 每个日期最多一个活跃 Pending

    @Test func onlyOneActivePendingPerDate() throws {
        let first = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        #expect(throws: PendingServiceError.anotherPendingActive(first.id)) {
            try services.pending.propose(try lunch(300), on: Fixtures.day, expectedRevision: 0)
        }
        // 另一个日期不受影响。
        let yesterday = LocalDate(isoString: "2026-10-29")!
        _ = try services.pending.propose(try lunch(on: yesterday), on: yesterday, expectedRevision: 0)

        // 修正：明确替换当前 Pending，旧的作废且不能再确认。
        let corrected = try services.pending.propose(try lunch(300), on: Fixtures.day, expectedRevision: 0, replacing: first.id)
        #expect(try services.pending.active(on: Fixtures.day)?.id == corrected.id)
        #expect(try services.pending.pending(first.id).resolutionCode == "replaced")
        #expect(throws: PendingServiceError.notActive(.cancelled)) { try services.pending.confirm(first.id) }

        try services.pending.confirm(corrected.id)
        #expect(try services.dayData.day(Fixtures.day).summary.totals.energyKcal == 300)
    }

    // MARK: - 过期（场景 5、7）

    @Test func expiresThirtyMinutesAfterCreation() throws {
        let pending = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        #expect(pending.expiresAt == Fixtures.now.addingTimeInterval(30 * 60))
        clock.advance(minutes: 29)
        #expect(try services.pending.active(on: Fixtures.day)?.id == pending.id)
        clock.advance(minutes: 1)
        #expect(throws: PendingServiceError.expired) { try services.pending.confirm(pending.id) }
        #expect(try records() == 0)
        #expect(try services.pending.pending(pending.id).status == .expired)
    }

    @Test func expiresAtLocalMidnightWhenSooner() throws {
        clock.now = Fixtures.now.addingTimeInterval(3 * 3600 + 50 * 60) // 23:50 上海
        let pending = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        #expect(pending.expiresAt == Fixtures.now.addingTimeInterval(4 * 3600)) // 次日 00:00
        clock.advance(minutes: 10)
        #expect(try services.pending.active(on: Fixtures.day) == nil)
        #expect(try records() == 0)
    }

    /// 场景 7：在历史日期 Session 中创建的 Pending，按创建时刻计算截止，不会创建即过期。
    @Test func historicalSessionPendingIsNotBornExpired() throws {
        let lastWeek = LocalDate(isoString: "2026-10-23")!
        let pending = try services.pending.propose(try lunch(on: lastWeek), on: lastWeek, expectedRevision: 0)
        #expect(pending.expiresAt == Fixtures.now.addingTimeInterval(30 * 60))
        #expect(try services.pending.active(on: lastWeek)?.id == pending.id)
        try services.pending.confirm(pending.id)
        #expect(try services.dayData.day(lastWeek).records.count == 1)
    }

    // MARK: - Revision 冲突与篡改（场景 5）

    @Test func revisionConflictVoidsPendingWithoutGhostWrite() throws {
        let pending = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        // 提案之后，当天数据被别的途径改动。
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 100)]))
        #expect(throws: PendingServiceError.revisionConflict) { try services.pending.confirm(pending.id) }
        #expect(try records() == 1)
        #expect(try services.pending.pending(pending.id).resolutionCode == "revisionConflict")
        #expect(try services.pending.active(on: Fixtures.day) == nil)
    }

    @Test func tamperedPayloadIsNeverExecuted() throws {
        let pending = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        let action = try #require(try context.fetch(FetchDescriptor<PendingAction>()).first)
        action.payloadData = JSONColumn.encode(try lunch(5000))
        try context.save()
        #expect(throws: PendingServiceError.payloadTampered) { try services.pending.confirm(pending.id) }
        #expect(try records() == 0)
    }

    // MARK: - 重启恢复

    @Test func unexpiredPendingSurvivesRestart() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "vita-pending-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = clock
        func launch() throws -> AppServices {
            let container = AppContainer(
                modelContainer: try PersistenceStore.makeContainer(url: url),
                secrets: InMemorySecretStore(),
                config: LayeredConfigProvider(builtin: try VitaConfig.loadBuiltin()),
                environment: BuildEnvironment(conduitBaseURL: URL(string: "https://conduit.invalid")!),
                referenceFoods: try Fixtures.referenceFoods()
            )
            return AppServices(container: container, now: { clock.now }, timeZone: { Fixtures.shanghai })
        }

        var app: AppServices? = try launch()
        let pending = try app!.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        app = nil

        clock.advance(minutes: 10)
        let relaunched = try launch()
        #expect(try relaunched.pending.active(on: Fixtures.day)?.id == pending.id)
        try relaunched.pending.confirm(pending.id)
        #expect(try relaunched.dayData.day(Fixtures.day).records.count == 1)
    }

    @Test func expiryIsAudited() throws {
        let pending = try services.pending.propose(try lunch(), on: Fixtures.day, expectedRevision: 0)
        clock.advance(minutes: 31)
        try services.pending.expireDue()
        let audits = try context.fetch(FetchDescriptor<AuditEvent>()).filter { $0.operation == "pending.expire" }
        #expect(audits.map(\.targetID) == [pending.id.uuidString])
    }
}
