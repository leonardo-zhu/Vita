import Foundation

/// 公共营养参考库的一条记录，格式以 reference-food-library.md §3 为准。
struct ReferenceFood: Equatable, Codable, Sendable, Identifiable {
    struct Source: Equatable, Codable, Sendable {
        var provider: String
        var dataType: String
        var externalId: String
        var retrievedFromRelease: String
        var attribution: String
        /// 以下为构建脚本补充的溯源信息，测试夹具可以没有。
        /// 采样地域，如“北京”“US”。
        var region: String?
        /// 来源中的原始名称。
        var description: String?
        /// 可食部比例（中国数据），营养值按每 100 g 可食部计。
        var edibleFraction: Decimal?
        /// 如“energyKcal：计算值”。
        var notes: [String]?
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
    /// 缺省为精选层。
    var tier: Tier?

    /// 两层收录：精选层有人工审阅的名称与别名，日常说法优先命中；扩展层是按来源名称自动整理的其余条目，
    /// 只有精选层没有命中时才参与查询（reference-food-library.md §2）。
    enum Tier: String, Codable, Sendable {
        case core, extended
    }

    var isExtended: Bool { tier == .extended }
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
    private let coreIDsByName: [String: [String]]
    private let extendedIDsByName: [String: [String]]

    /// 全部条目，按 ID 排序，供浏览页使用。
    let all: [ReferenceFood]

    var count: Int { foodsByID.count }
    var coreCount: Int { all.filter { !$0.isExtended }.count }

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
        var core: [String: Set<String>] = [:]
        var extended: [String: Set<String>] = [:]
        for food in foods {
            byID[food.id] = food
            for name in [food.canonicalName] + food.aliases {
                if food.isExtended {
                    extended[Self.normalize(name), default: []].insert(food.id)
                } else {
                    core[Self.normalize(name), default: []].insert(food.id)
                }
            }
        }
        foodsByID = byID
        coreIDsByName = core.mapValues { $0.sorted() }
        extendedIDsByName = extended.mapValues { $0.sorted() }
        all = foods.sorted { $0.id < $1.id }
    }

    func food(id: String) -> ReferenceFood? {
        foodsByID[id]
    }

    /// `query` 与可选的额外写法 `aliases` 中任一精确命中即返回，按 ID 排序、去重。
    /// 先查精选层；精选层没有命中时才查扩展层，避免日常说法冒出大量候选。
    func search(_ query: String, aliases: [String] = []) -> [ReferenceFood] {
        let names = ([query] + aliases).map(Self.normalize)
        for index in [coreIDsByName, extendedIDsByName] {
            let ids = Set(names.flatMap { index[$0] ?? [] })
            if !ids.isEmpty { return ids.sorted().compactMap { foodsByID[$0] } }
        }
        return []
    }

    /// 浏览页搜索：`exact` 与 Agent 的精确查询结果相同；`partial` 是名称或别名包含查询词、但精确查询不会返回的条目。
    func browse(_ query: String) -> (exact: [ReferenceFood], partial: [ReferenceFood]) {
        let key = Self.normalize(query)
        guard !key.isEmpty else { return ([], []) }
        let exact = search(query)
        let exactIDs = Set(exact.map(\.id))
        let partial = all.filter { food in
            !exactIDs.contains(food.id) && ([food.canonicalName] + food.aliases).contains { Self.normalize($0).contains(key) }
        }
        return (exact, partial)
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
