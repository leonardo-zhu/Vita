import Foundation

/// 公共营养参考库的一条记录，格式以 reference-food-library.md §3 为准。
struct ReferenceFood: Equatable, Codable, Sendable, Identifiable {
    struct Source: Equatable, Codable, Sendable {
        var provider: String
        var dataType: String
        var externalId: String
        var retrievedFromRelease: String
        var attribution: String
    }

    /// 计算基准，JSON 中为 `{ "quantity": 100, "unit": "g" }`。
    struct Base: Equatable, Codable, Sendable {
        var quantity: Decimal
        var unit: QuantityUnit

        var asQuantity: Quantity { Quantity(amount: quantity, unit: unit) }
    }

    var id: String
    var canonicalName: String
    var aliases: [String]
    var category: String
    var preparationState: String
    var base: Base
    var nutrients: NutrientValues
    var densityGPerMl: Decimal?
    var source: Source
}

enum ReferenceFoodCatalogError: Error, Equatable {
    case invalidEntry(id: String, reason: String)
    case duplicateID(String)
    case duplicateNameAndState(String)
}

/// 只读的公共参考库。查询只做规范化后的精确匹配，结果不唯一时原样返回全部候选，
/// 由调用方澄清，绝不替用户选（TDD §7、reference-food-library.md §5）。
struct ReferenceFoodCatalog: Sendable {
    static let empty = ReferenceFoodCatalog(validated: [])

    private let foodsByID: [String: ReferenceFood]
    private let idsByName: [String: [String]]

    var count: Int { foodsByID.count }

    init(foods: [ReferenceFood]) throws {
        for food in foods { try Self.validate(food) }
        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        for food in foods {
            guard seenIDs.insert(food.id).inserted else { throw ReferenceFoodCatalogError.duplicateID(food.id) }
            let nameKey = Self.normalize(food.canonicalName) + "|" + food.preparationState
            guard seenNames.insert(nameKey).inserted else {
                throw ReferenceFoodCatalogError.duplicateNameAndState(food.canonicalName)
            }
        }
        self.init(validated: foods)
    }

    private init(validated foods: [ReferenceFood]) {
        var byID: [String: ReferenceFood] = [:]
        var byName: [String: Set<String>] = [:]
        for food in foods {
            byID[food.id] = food
            for name in [food.canonicalName] + food.aliases {
                byName[Self.normalize(name), default: []].insert(food.id)
            }
        }
        foodsByID = byID
        idsByName = byName.mapValues { $0.sorted() }
    }

    func food(id: String) -> ReferenceFood? {
        foodsByID[id]
    }

    /// `query` 与可选的额外写法 `aliases` 中任一精确命中即返回，按 ID 排序、去重。
    func search(_ query: String, aliases: [String] = []) -> [ReferenceFood] {
        let ids = Set(([query] + aliases).flatMap { idsByName[Self.normalize($0)] ?? [] })
        return ids.sorted().compactMap { foodsByID[$0] }
    }

    /// 统一全半角、大小写与空白。不做模糊匹配。
    static func normalize(_ name: String) -> String {
        let halfWidth = name.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? name
        return halfWidth.lowercased().filter { !$0.isWhitespace }
    }

    private static func validate(_ food: ReferenceFood) throws {
        func fail(_ reason: String) -> ReferenceFoodCatalogError { .invalidEntry(id: food.id, reason: reason) }
        guard food.id.hasPrefix("vita.reference.") else { throw fail("id must start with vita.reference.") }
        guard !normalize(food.canonicalName).isEmpty else { throw fail("empty canonicalName") }
        guard !food.preparationState.isEmpty else { throw fail("empty preparationState") }
        guard food.base == ReferenceFood.Base(quantity: 100, unit: .gram) else { throw fail("base must be 100 g") }
        guard food.nutrients.isValid else { throw fail("negative nutrient") }
        if let density = food.densityGPerMl, density <= 0 { throw fail("non-positive density") }
        guard !food.source.provider.isEmpty, !food.source.externalId.isEmpty, !food.source.attribution.isEmpty else {
            throw fail("incomplete source")
        }
    }
}
