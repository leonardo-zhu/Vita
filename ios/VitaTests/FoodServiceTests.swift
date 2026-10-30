import Foundation
import SwiftData
import Testing
@testable import Vita

@MainActor
struct FoodServiceTests {
    let clock = TestClock(Fixtures.now)
    let services: AppServices

    init() throws {
        var container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        container.textRecognizer = StubTextRecognizer(lines: [])
        let clock = clock
        services = AppServices(container: container, now: { clock.now }, timeZone: { Fixtures.shanghai })
    }

    private let milk = FoodProductDraft(name: "纯牛奶", brandOrSupplier: "某乳业", package: Quantity(amount: 250, unit: .milliliter))

    private func manual(_ kcal: Decimal, protein: Decimal = 3) -> FoodVersionDraft {
        FoodVersionDraft(
            basis: FoodVersionBasis(quantity: Quantity(amount: 100, unit: .milliliter), nutrients: NutrientValues(energyKcal: kcal, proteinG: protein, fatG: 3, carbohydrateG: 5)),
            sourceKind: .manualEntry
        )
    }

    @discardableResult
    private func confirm(_ change: FoodChange) throws -> UUID {
        let pending = try services.pending.propose(food: change, on: Fixtures.day)
        return try services.pending.confirm(pending.id)
    }

    @Test func foodIsCreatedOnlyAfterConfirmation() throws {
        let pending = try services.pending.propose(food: .createProduct(milk, version: manual(60)), on: Fixtures.day)
        #expect(pending.foodPreview?.productName == "纯牛奶")
        #expect(try services.foods.products().isEmpty)
        let productID = try services.pending.confirm(pending.id)
        let product = try #require(try services.foods.products().first)
        #expect(product.id == productID)
        #expect(product.package == Quantity(amount: 250, unit: .milliliter))
        #expect(product.activeVersion?.basis.nutrients.energyKcal == 60)
    }

    /// 验收：历史 Item 的营养不随 Food Version 更新而改变；旧版本退役后只能引用新版本。
    @Test func newVersionRetiresOldOneAndKeepsHistory() throws {
        let productID = try confirm(.createProduct(milk, version: manual(60)))
        let v1 = try #require(try services.foods.products().first?.activeVersion)
        let drink = ItemDraft(
            displayName: "纯牛奶", originalAmountText: "一盒", quantity: Quantity(amount: 250, unit: .milliliter),
            amountSource: .packageConversion, nutrition: .personalFoodVersion(v1.id), includeInSummary: true
        )
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([drink]))

        let pending = try services.pending.propose(food: .addVersion(productID: productID, expectedActiveVersionID: v1.id, version: manual(70, protein: 4)), on: Fixtures.day)
        #expect(pending.foodPreview?.previousBasis?.nutrients.energyKcal == 60)
        try services.pending.confirm(pending.id)

        let product = try #require(try services.foods.products().first)
        #expect(product.versions.count == 2)
        #expect(product.activeVersion?.basis.nutrients.energyKcal == 70)
        #expect(product.versions.first { $0.id == v1.id }?.retiredAt != nil)
        #expect(try services.dayData.day(Fixtures.day).summary.totals.energyKcal == 150)
        #expect(throws: RecordServiceError.invalidItem(index: 0, reason: .retiredFoodVersion(v1.id))) {
            try services.records.createRecord(on: Fixtures.day, expectedRevision: 1, draft: try .lunch([drink]))
        }
    }

    @Test func staleVersionProposalIsVoided() throws {
        let productID = try confirm(.createProduct(milk, version: manual(60)))
        let v1 = try #require(try services.foods.products().first?.activeVersion?.id)
        let stale = try services.pending.propose(food: .addVersion(productID: productID, expectedActiveVersionID: v1, version: manual(65)), on: Fixtures.day)
        // 另一个日期上先确认了一个新版本。
        let other = LocalDate(isoString: "2026-10-29")!
        let first = try services.pending.propose(food: .addVersion(productID: productID, expectedActiveVersionID: v1, version: manual(70)), on: other)
        try services.pending.confirm(first.id)
        #expect(throws: PendingServiceError.revisionConflict) { try services.pending.confirm(stale.id) }
        #expect(try services.foods.products().first?.activeVersion?.basis.nutrients.energyKcal == 70)
    }

    @Test func labelSourceMustPointToALocalScan() async throws {
        var version = manual(60)
        version.sourceKind = .nutritionLabel
        version.labelImageReference = "label:\(UUID().uuidString)"
        #expect(throws: FoodServiceError.unknownLabel) {
            try services.pending.propose(food: .createProduct(milk, version: version), on: Fixtures.day)
        }
        let scan = try await services.labels.scan(Data("img".utf8))
        version.labelImageReference = scan.imageReference
        try confirm(.createProduct(milk, version: version))
        #expect(try services.foods.products().first?.activeVersion?.labelImageReference == scan.imageReference)
    }

    @Test func referenceDerivedMustMatchTheReferenceValues() throws {
        let egg = try #require(try Fixtures.referenceFoods().food(id: "vita.reference.egg.whole.raw"))
        var version = FoodVersionDraft(
            basis: FoodVersionBasis(quantity: egg.base.asQuantity, nutrients: egg.nutrients),
            sourceKind: .referenceDerived, derivedFromReferenceID: egg.id
        )
        version.basis.nutrients.proteinG += 5
        let product = FoodProductDraft(name: "土鸡蛋")
        #expect(throws: FoodServiceError.basisDiffersFromReference) {
            try services.pending.propose(food: .createProduct(product, version: version), on: Fixtures.day)
        }
        version.basis.nutrients = egg.nutrients
        try confirm(.createProduct(product, version: version))
        #expect(try services.foods.products().first?.activeVersion?.derivedFromReferenceID == egg.id)
    }

    @Test func packageConversionNeedsAMatchingPackage() throws {
        try confirm(.createProduct(milk, version: manual(60)))
        let version = try #require(try services.foods.products().first?.activeVersion?.id)
        func record(_ quantity: Quantity, _ nutrition: NutritionInput) throws {
            try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([
                ItemDraft(displayName: "x", originalAmountText: "半盒", quantity: quantity, amountSource: .packageConversion, nutrition: nutrition, includeInSummary: true),
            ]))
        }
        #expect(throws: RecordServiceError.invalidItem(index: 0, reason: .packageUnavailable)) {
            try record(Quantity(amount: 125, unit: .gram), .personalFoodVersion(version))
        }
        #expect(throws: RecordServiceError.invalidItem(index: 0, reason: .packageUnavailable)) {
            try record(Quantity(amount: 50, unit: .gram), .referenceFood("vita.reference.egg.whole.raw"))
        }
        try record(Quantity(amount: 125, unit: .milliliter), .personalFoodVersion(version))
        #expect(try services.dayData.day(Fixtures.day).summary.totals.energyKcal == 75)
    }

    @Test func searchMatchesNameOrBrandIgnoringWidthAndCase() throws {
        try confirm(.createProduct(FoodProductDraft(name: "Oatly 燕麦奶", brandOrSupplier: "Oatly"), version: manual(50)))
        #expect(try services.foods.search("ｏａｔｌｙ").count == 1)
        #expect(try services.foods.search("燕麦").count == 1)
        #expect(try services.foods.search("牛奶").isEmpty)
    }
}

@MainActor
struct FoodToolTests {
    @Test func aiEstimateCannotBecomeAFoodVersion() throws {
        let services = AppServices(container: try AppContainer.inMemory(), now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let handler = ProposalToolHandler(pending: services.pending, labels: services.labels, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let json = """
        {"requestId":"\(UUID().uuidString)","sessionDate":"2026-10-30","expectedRevision":0,"payload":{"intent":"createProduct",
          "product":{"name":"外卖宫保鸡丁"},
          "version":{"source":"aiEstimated","basis":{"amount":100,"unit":"g"},"values":{"energyKcal":180,"proteinG":12,"fatG":10,"carbohydrateG":9}}}}
        """
        let result = handler.handle(tool: "proposeFoodChange", arguments: Data(json.utf8), sessionDate: Fixtures.day)
        #expect(result.error?.code == "estimateNotAllowed")
        #expect(try services.pending.active(on: Fixtures.day) == nil)
    }

    @Test func referenceDerivedCopiesValuesFromTheCatalog() throws {
        let catalog = try Fixtures.referenceFoods()
        let services = AppServices(container: try AppContainer.inMemory(referenceFoods: catalog), now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let handler = ProposalToolHandler(pending: services.pending, referenceFoods: catalog, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let json = """
        {"requestId":"\(UUID().uuidString)","sessionDate":"2026-10-30","expectedRevision":0,"payload":{"intent":"createProduct",
          "product":{"name":"常买的鸡胸肉","package":{"amount":1,"unit":"斤"}},
          "version":{"source":"referenceDerived","referenceFoodId":"vita.reference.chicken-breast.raw","values":{"energyKcal":1,"proteinG":99,"fatG":0,"carbohydrateG":0}}}}
        """
        let result = handler.handle(tool: "proposeFoodChange", arguments: Data(json.utf8), sessionDate: Fixtures.day)
        let pendingID = try #require(result.pendingId)
        let preview = try #require(try services.pending.pending(pendingID).foodPreview)
        #expect(preview.package == Quantity(amount: 500, unit: .gram))
        #expect(preview.version.basis.nutrients.proteinG == dec("22.5"))
    }

    @Test func labelSourceNeedsAKnownScanID() throws {
        let services = AppServices(container: try AppContainer.inMemory(), now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let handler = ProposalToolHandler(pending: services.pending, labels: services.labels, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let json = """
        {"requestId":"\(UUID().uuidString)","sessionDate":"2026-10-30","expectedRevision":0,"payload":{"intent":"createProduct",
          "product":{"name":"薯片"},
          "version":{"source":"nutritionLabel","labelScanId":"\(UUID().uuidString)","basis":{"amount":100,"unit":"g"},"values":{"energyKcal":540,"proteinG":6,"fatG":34,"carbohydrateG":52}}}}
        """
        #expect(handler.handle(tool: "proposeFoodChange", arguments: Data(json.utf8), sessionDate: Fixtures.day).error?.code == "invalidField")
    }
}
