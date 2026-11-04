import Foundation

struct FoodVersionSummary: Equatable, Codable, Sendable, Identifiable {
    var id: UUID
    var basis: FoodVersionBasis
    var sourceKind: FoodVersionSource
    var labelImageReference: String?
    var derivedFromReferenceID: String?
    var sourceNote: String?
    var createdAt: Date
    var retiredAt: Date?
}

struct FoodProductSummary: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var brandOrSupplier: String?
    var package: Quantity?
    var note: String?
    var activeVersion: FoodVersionSummary?
    /// 新的在前。
    var versions: [FoodVersionSummary]
}

/// 确认卡上的食品变更预览。
struct FoodChangePreview: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case createProduct, addVersion }

    var kind: Kind
    var productName: String
    var brandOrSupplier: String?
    var package: Quantity?
    var version: FoodVersionDraft
    /// 新版本取代的旧版本基准，便于对比。
    var previousBasis: FoodVersionBasis?
}

/// 个人 Nutrition DB（PRD §3.2.1），存在服务端。变更只经确认卡执行（服务端的 Agent 提案、用户确认），App 里只读。
@MainActor
final class FoodService {
    private let api: VitaAPIClient

    init(api: VitaAPIClient) {
        self.api = api
    }

    func products() async throws -> [FoodProductSummary] {
        let response: FoodsResponseDTO = try await api.get("/v1/foods")
        return response.products.map(\.domain)
    }
}
