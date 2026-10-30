import Foundation

/// 从 bundle 读取公共营养参考库构建产物（reference-food-library.md §3）。
enum ReferenceFoodLoader {
    static let resourceName = "reference-foods"

    /// 产物不存在时返回空库（个人构建尚未生成时 App 仍可用）；存在但不合规则直接报错，
    /// 不带着坏数据运行。
    static func load(from bundle: Bundle = .main, resourceName: String = resourceName) throws -> ReferenceFoodCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            return .empty
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> ReferenceFoodCatalog {
        try ReferenceFoodCatalog(foods: JSONDecoder().decode([ReferenceFood].self, from: data))
    }
}
