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

struct ReferenceBrowseTests {
    @Test func browseSeparatesExactCandidatesFromPartialMatches() throws {
        let catalog = try Fixtures.referenceFoods()
        let chicken = catalog.browse("鸡胸肉")
        #expect(chicken.exact.map(\.id) == ["vita.reference.chicken-breast.cooked", "vita.reference.chicken-breast.raw"])
        #expect(chicken.partial.isEmpty)

        // “鸡”不是任何条目的名称或别名：精确查询为空，浏览页仍能列出包含它的条目。
        let partial = catalog.browse("鸡")
        #expect(partial.exact.isEmpty)
        #expect(Set(partial.partial.map(\.id)).isSuperset(of: ["vita.reference.chicken-breast.raw", "vita.reference.egg.whole.raw"]))
        #expect(catalog.browse("  ").exact.isEmpty && catalog.browse("  ").partial.isEmpty)
    }
}

struct ReferenceTierTests {
    @Test func extendedTierOnlyAnswersWhenCoreHasNoMatch() throws {
        let fixture = try Fixtures.referenceFoods()
        var redSkin = try #require(fixture.food(id: "vita.reference.egg.whole.raw"))
        redSkin.id = "vita.reference.cfct6.111109"
        redSkin.canonicalName = "鸡蛋（红皮）"
        redSkin.aliases = ["鸡蛋", "红皮鸡蛋"]
        redSkin.tier = .extended
        let catalog = try ReferenceFoodCatalog(foods: fixture.all + [redSkin])

        // “鸡蛋”在精选层有候选，扩展层的同名别名不会混进来。
        #expect(!catalog.search("鸡蛋").contains { $0.isExtended })
        // 说得更具体时，精选层没有命中，才由扩展层回答。
        #expect(catalog.search("红皮鸡蛋").map(\.id) == ["vita.reference.cfct6.111109"])
        #expect(catalog.coreCount == fixture.count)
    }
}

/// 本地构建了正式参考库时，App bundle 里的产物必须能通过 App 端同一套校验。
struct BundledReferenceLibraryTests {
    @Test func bundledBuildProductPassesValidation() throws {
        let catalog = try ReferenceFoodLoader.load(from: .main)
        guard catalog.count > 0 else { return }
        #expect(catalog.search("鸡胸肉").count >= 2)
        #expect(catalog.search("牛奶").count >= 2)
    }
}
