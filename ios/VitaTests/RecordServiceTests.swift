import Foundation
import SwiftData
import Testing
@testable import Vita

@MainActor
struct RecordServiceTests {
    let services: AppServices
    let context: ModelContext

    init() throws {
        let container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        context = container.modelContainer.mainContext
    }

    private func audits(_ operation: String) throws -> [AuditEvent] {
        try context.fetch(FetchDescriptor<AuditEvent>()).filter { $0.operation == operation }
    }

    // MARK: - Phase 1 验收：创建、修改、删除，汇总与目标完成度随之更新

    @Test func createModifyDeleteUpdatesSummaryAndGoalProgress() throws {
        try services.goals.appendGoal(GoalTargets(energyKcal: 2000, proteinG: 150), origin: .manualOnboarding, effectiveFrom: Fixtures.day)

        let recordID = try services.records.createRecord(
            on: Fixtures.day, expectedRevision: 0,
            draft: .lunch([.reference("vita.reference.chicken-breast.cooked", grams: 150, name: "鸡胸肉")])
        )
        var day = try services.dayData.day(Fixtures.day)
        #expect(day.revision == 1)
        #expect(day.records.count == 1)
        #expect(day.summary.totals.proteinG == dec("46.5"))
        #expect(day.summary.progress.first { $0.nutrient == .proteinG }?.fraction == dec("0.31"))

        try services.records.appendItems(
            [.reference("vita.reference.rice.white.cooked", grams: 200, name: "米饭")],
            to: recordID, on: Fixtures.day, expectedRevision: 1
        )
        day = try services.dayData.day(Fixtures.day)
        #expect(day.revision == 2)
        #expect(day.records[0].revision == 1)
        #expect(day.records[0].items.map(\.displayName) == ["鸡胸肉", "米饭"])
        #expect(day.summary.totals.energyKcal == dec("507.5"))

        let riceID = day.records[0].items[1].id
        try services.records.replaceItem(
            riceID, with: .reference("vita.reference.rice.white.cooked", grams: 100, name: "米饭"),
            in: recordID, on: Fixtures.day, expectedRevision: 2
        )
        #expect(try services.dayData.day(Fixtures.day).summary.totals.energyKcal == dec("377.5"))

        try services.records.removeItem(riceID, from: recordID, on: Fixtures.day, expectedRevision: 3)
        day = try services.dayData.day(Fixtures.day)
        #expect(day.records[0].items.count == 1)
        #expect(day.summary.totals.energyKcal == dec("247.5"))

        try services.records.deleteRecord(recordID, on: Fixtures.day, expectedRevision: 4)
        day = try services.dayData.day(Fixtures.day)
        #expect(day.records.isEmpty)
        #expect(day.revision == 5)
        #expect(day.summary.totals == .zero)
        #expect(try context.fetch(FetchDescriptor<ConsumptionItem>()).isEmpty)
        #expect(try audits("record.delete").first?.result == .success)
    }

    // MARK: - Revision 与 Session 隔离

    @Test func staleRevisionIsRejectedWithoutWriting() throws {
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([.estimate(kcal: 500)]))
        #expect(throws: RecordServiceError.revisionConflict(expected: 0, actual: 1)) {
            try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([.estimate(kcal: 300)]))
        }
        #expect(try services.dayData.day(Fixtures.day).records.count == 1)
        #expect(try audits("record.create").map(\.errorCode).contains("record.revisionConflict"))
    }

    @Test func cannotTouchARecordFromAnotherDay() throws {
        let yesterday = LocalDate(isoString: "2026-10-29")!
        let recordID = try services.records.createRecord(on: yesterday, expectedRevision: 0, draft: .lunch(on: yesterday, [.estimate(kcal: 500)]))
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([.estimate(kcal: 100)]))
        #expect(throws: RecordServiceError.recordNotInSession) {
            try services.records.deleteRecord(recordID, on: Fixtures.day, expectedRevision: 1)
        }
        #expect(try services.dayData.day(yesterday).records.count == 1)
    }

    @Test func eventTimeMustBelongToSessionDate() throws {
        let other = LocalDate(isoString: "2026-10-29")!
        #expect(throws: RecordServiceError.eventTimeOutsideSession) {
            try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch(on: other, [.estimate(kcal: 1)]))
        }
        // 读取不存在的日期不会顺带创建 Session。
        #expect(try context.fetch(FetchDescriptor<DaySession>()).isEmpty)
    }

    @Test func sessionKeepsTimeZoneFromCreation() throws {
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([.estimate(kcal: 1)]))
        #expect(try context.session(on: Fixtures.day)?.timeZoneIdentifier == "Asia/Shanghai")
    }

    // MARK: - Item 校验：任一项不合格则整条不写

    @Test func oneInvalidItemRejectsWholeRecord() throws {
        let draft = try RecordDraft.lunch([
            .reference("vita.reference.egg.whole.raw", grams: 50),
            .reference("vita.reference.does-not-exist", grams: 50),
        ])
        #expect(throws: RecordServiceError.invalidItem(index: 1, reason: .unknownReferenceFood("vita.reference.does-not-exist"))) {
            try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: draft)
        }
        #expect(try context.fetch(FetchDescriptor<ConsumptionItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DaySession>()).isEmpty)
    }

    @Test func itemRulesFollowTDD() throws {
        func reject(_ item: ItemDraft) -> ItemRejection? {
            do {
                try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([item]))
                return nil
            } catch RecordServiceError.invalidItem(_, let reason) {
                return reason
            } catch {
                return nil
            }
        }
        var noQuantity = ItemDraft.reference("vita.reference.egg.whole.raw", grams: 1)
        noQuantity.quantity = nil
        #expect(reject(noQuantity) == .amountSourceInconsistent)
        noQuantity.amountSource = .aiEstimated
        #expect(reject(noQuantity) == .quantityRequired)

        // 牛奶有密度，可按 ml 计算；鸡蛋没有，不能按 1ml = 1g 猜。
        var eggInMl = ItemDraft.reference("vita.reference.egg.whole.raw", grams: 1)
        eggInMl.quantity = Quantity(amount: 50, unit: .milliliter)
        #expect(reject(eggInMl) == .calculation(.unitMismatch(basis: .gram, input: .milliliter)))

        var noBasis = ItemDraft.estimate(kcal: 100)
        noBasis.nutrition = .aiEstimated(.zero, estimateBasis: "  ")
        #expect(reject(noBasis) == .invalidEstimate)

        var blank = ItemDraft.estimate(kcal: 100)
        blank.displayName = " "
        #expect(reject(blank) == .emptyName)
    }

    @Test func removingLastItemRequiresDeletingTheRecord() throws {
        let recordID = try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([.estimate(kcal: 1)]))
        let itemID = try services.dayData.day(Fixtures.day).records[0].items[0].id
        #expect(throws: RecordServiceError.emptyRecord) {
            try services.records.removeItem(itemID, from: recordID, on: Fixtures.day, expectedRevision: 1)
        }
    }

    // MARK: - 必测场景

    /// 场景 2：“2 个鸡蛋、共 108g”以 108g 计算并保留原始表达。
    @Test func measuredWeightWinsAndOriginalTextIsKept() throws {
        let item = ItemDraft(
            displayName: "鸡蛋", originalAmountText: "2 个鸡蛋、共 108g", quantity: Quantity(amount: 108, unit: .gram),
            amountSource: .userMeasured, nutrition: .referenceFood("vita.reference.egg.whole.raw"), includeInSummary: true
        )
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([item]))
        let stored = try services.dayData.day(Fixtures.day).records[0].items[0]
        #expect(stored.originalAmountText == "2 个鸡蛋、共 108g")
        #expect(stored.snapshot.quantityUsed == Quantity(amount: 108, unit: .gram))
        #expect(stored.snapshot.values.proteinG == dec("13.608"))
        #expect(stored.amountSource == .userMeasured)
        #expect(stored.sourceLabel == "鸡蛋（生） · Vita test fixture")
    }

    /// 场景 6：个人 Food Version 更新后，旧 Item 保持原营养快照。
    @Test func newFoodVersionDoesNotRewriteHistory() throws {
        let product = FoodProduct(name: "纯牛奶", package: Quantity(amount: 250, unit: .milliliter), now: Fixtures.now)
        let v1 = FoodVersion(
            basis: FoodVersionBasis(quantity: Quantity(amount: 100, unit: .milliliter), nutrients: NutrientValues(energyKcal: 60, proteinG: 3, fatG: 3, carbohydrateG: 5)),
            sourceKind: .nutritionLabel, now: Fixtures.now
        )
        context.insert(product)
        context.insert(v1)
        v1.product = product
        product.activeVersionID = v1.id
        try context.save()

        let item = ItemDraft(
            displayName: "纯牛奶", originalAmountText: "一盒", quantity: Quantity(amount: 250, unit: .milliliter),
            amountSource: .packageConversion, nutrition: .personalFoodVersion(v1.id), includeInSummary: true
        )
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: .lunch([item]))

        // 标签更新：新建 Version、切换生效版本、旧版本退役。
        let v2 = FoodVersion(
            basis: FoodVersionBasis(quantity: Quantity(amount: 100, unit: .milliliter), nutrients: NutrientValues(energyKcal: 70, proteinG: 4, fatG: 4, carbohydrateG: 5)),
            sourceKind: .nutritionLabel, now: Fixtures.now
        )
        context.insert(v2)
        v2.product = product
        product.activeVersionID = v2.id
        v1.retiredAt = Fixtures.now
        try context.save()

        let stored = try services.dayData.day(Fixtures.day).records[0].items[0]
        #expect(stored.snapshot.values.energyKcal == 150)
        #expect(stored.snapshot.values.proteinG == dec("7.5"))
        #expect(stored.snapshot.sourceRef == v1.id.uuidString)
        #expect(stored.sourceLabel == "纯牛奶")

        // 退役版本不能再被新记录引用。
        #expect(throws: RecordServiceError.invalidItem(index: 0, reason: .retiredFoodVersion(v1.id))) {
            try services.records.createRecord(on: Fixtures.day, expectedRevision: 1, draft: .lunch([item]))
        }
    }

    @Test func recordsSortByRepresentativeTime() throws {
        let dinner = RecordDraft(
            eventTime: try EventTime(localDate: Fixtures.day, precision: .mealPeriod, mealPeriod: .dinner, timeZoneIdentifier: "Asia/Shanghai"),
            mealLabel: "晚餐", items: [.estimate(kcal: 1)]
        )
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: dinner)
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 1, draft: .lunch([.estimate(kcal: 1)]))
        #expect(try services.dayData.day(Fixtures.day).records.map(\.mealLabel) == ["午餐", "晚餐"])
    }
}

@MainActor
struct GoalServiceTests {
    /// `ModelContext` 不持有容器；容器释放后再访问 SwiftData 会直接终止进程，所以要一并持有。
    let container: AppContainer
    let goals: GoalService

    init() throws {
        container = try AppContainer.inMemory()
        goals = GoalService(context: container.modelContainer.mainContext, now: { Fixtures.now })
    }

    @Test func goalHistoryIsAppendOnlyAndDateScoped() throws {
        let oct1 = LocalDate(isoString: "2026-10-01")!
        let oct20 = LocalDate(isoString: "2026-10-20")!
        try goals.appendGoal(GoalTargets(proteinG: 150), origin: .initialRecommendation, effectiveFrom: oct1)
        let (previous, current) = try goals.appendGoal(GoalTargets(proteinG: 180), origin: .explicitUserCommand, effectiveFrom: oct20)
        #expect(previous?.targets.proteinG == 150)
        #expect(current.targets.proteinG == 180)
        #expect(current.revision == 2)

        #expect(try goals.activeGoal(on: LocalDate(isoString: "2026-09-30")!) == nil)
        #expect(try goals.activeGoal(on: LocalDate(isoString: "2026-10-19")!)?.targets.proteinG == 150)
        #expect(try goals.activeGoal(on: Fixtures.day)?.targets.proteinG == 180)

        // 同一天再改一次（“改回 150g”）：revision 更高者生效，旧行仍在。
        try goals.appendGoal(GoalTargets(proteinG: 150), origin: .explicitUserCommand, effectiveFrom: oct20)
        #expect(try goals.activeGoal(on: Fixtures.day)?.revision == 3)
        #expect(try goals.activeGoal(on: Fixtures.day)?.targets.proteinG == 150)
    }

    @Test func rejectsEmptyOrNonPositiveTargets() {
        #expect(throws: GoalServiceError.invalidTargets) {
            try goals.appendGoal(GoalTargets(), origin: .manualOnboarding, effectiveFrom: Fixtures.day)
        }
        #expect(throws: GoalServiceError.invalidTargets) {
            try goals.appendGoal(GoalTargets(proteinG: 0), origin: .manualOnboarding, effectiveFrom: Fixtures.day)
        }
    }
}

@MainActor
struct ChatMessageTests {
    @Test func messagesBelongToSessionAndCascade() throws {
        let container = try AppContainer.inMemory()
        let context = container.modelContainer.mainContext
        let session = DaySession(localDate: Fixtures.day, timeZoneIdentifier: "Asia/Shanghai", now: Fixtures.now)
        let recordID = UUID()
        let message = ChatMessage(role: .assistant, text: "已记录", cardRef: .record(recordID), createdAt: Fixtures.now)
        context.insert(session)
        context.insert(message)
        message.session = session
        try context.save()

        #expect(session.messages.first?.cardRef == .record(recordID))
        #expect(ChatCardRef(rawValue: "pending:\(recordID.uuidString)") == .pending(recordID))
        #expect(ChatCardRef(rawValue: "bogus") == nil)

        context.delete(session)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<ChatMessage>()).isEmpty)
    }
}
