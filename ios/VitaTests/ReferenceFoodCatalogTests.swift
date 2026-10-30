import Foundation
import Testing
@testable import Vita

struct ReferenceFoodCatalogTests {
    @Test func fixtureLoadsAndPassesValidation() throws {
        let catalog = try Fixtures.referenceFoods()
        #expect(catalog.count >= 10)
        let egg = try #require(catalog.food(id: "vita.reference.egg.whole.raw"))
        #expect(egg.nutrients.proteinG == dec("12.6"))
    }

    /// 必测场景 1：生/熟鸡胸肉同时命中时必须返回全部候选，不能替用户选一个。
    @Test func ambiguousAliasReturnsAllCandidates() throws {
        let catalog = try Fixtures.referenceFoods()
        let ids = catalog.search("鸡胸肉").map(\.id)
        #expect(ids == ["vita.reference.chicken-breast.cooked", "vita.reference.chicken-breast.raw"])
        #expect(catalog.search("熟鸡胸").map(\.id) == ["vita.reference.chicken-breast.cooked"])
    }

    @Test func matchingNormalizesWidthCaseAndWhitespaceButIsExact() throws {
        let catalog = try Fixtures.referenceFoods()
        #expect(catalog.search("鸡胸肉(生)").map(\.id) == ["vita.reference.chicken-breast.raw"])
        #expect(catalog.search(" 鸡胸肉 （ 生 ） ").map(\.id) == ["vita.reference.chicken-breast.raw"])
        #expect(catalog.search("鸡胸肉丁").isEmpty)
        #expect(catalog.search("不存在", aliases: ["西红柿"]).map(\.id) == ["vita.reference.tomato.raw"])
    }

    @Test func missingBuildProductYieldsEmptyCatalog() throws {
        let catalog = try ReferenceFoodLoader.load(from: Fixtures.bundle, resourceName: "does-not-exist")
        #expect(catalog.count == 0)
    }

    @Test func rejectsInvalidEntries() throws {
        let valid = try #require(try Fixtures.referenceFoods().food(id: "vita.reference.banana.raw"))

        var wrongBase = valid
        wrongBase.base = .init(quantity: 1, unit: .gram)
        #expect(throws: ReferenceFoodCatalogError.invalidEntry(id: valid.id, reason: "base must be 100 g")) {
            try ReferenceFoodCatalog(foods: [wrongBase])
        }

        var negative = valid
        negative.nutrients.fatG = -1
        #expect(throws: ReferenceFoodCatalogError.invalidEntry(id: valid.id, reason: "negative nutrient")) {
            try ReferenceFoodCatalog(foods: [negative])
        }

        var sameNameAndState = valid
        sameNameAndState.id = "vita.reference.banana.copy"
        #expect(throws: ReferenceFoodCatalogError.duplicateNameAndState(valid.canonicalName)) {
            try ReferenceFoodCatalog(foods: [valid, sameNameAndState])
        }

        #expect(throws: ReferenceFoodCatalogError.duplicateID(valid.id)) {
            var renamed = valid
            renamed.canonicalName = "芭蕉"
            return try ReferenceFoodCatalog(foods: [valid, renamed])
        }
    }
}
