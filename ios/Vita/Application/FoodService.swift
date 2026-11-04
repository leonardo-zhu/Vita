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
    /// 用户的常用叫法（PRD v2.0 §4.2）。
    var aliases: [String] = []
    var activeVersion: FoodVersionSummary?
    /// 新的在前。
    var versions: [FoodVersionSummary]
}

/// 确认卡上的食品变更预览。
struct FoodChangePreview: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case createProduct, addVersion, updateProduct }

    /// updateProduct 改之前的名称、品牌、叫法。
    struct Previous: Equatable, Codable, Sendable {
        var name: String
        var brandOrSupplier: String?
        var aliases: [String]
    }

    var kind: Kind
    var productName: String
    var brandOrSupplier: String?
    var package: Quantity?
    var aliases: [String] = []
    var previous: Previous?
    var version: FoodVersionDraft
    /// 新版本取代的旧版本基准，便于对比。
    var previousBasis: FoodVersionBasis?
}

/// 个人 Nutrition DB（PRD §3.2.1），存在服务端。对话里的变更经确认卡执行；用户也可以在 App 里直接改名称、包装、营养值或删除（M4）。
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

    func product(_ id: UUID) async throws -> FoodProductSummary {
        let response: FoodProductResponseDTO = try await api.get("/v1/foods/\(id.apiString)")
        return response.product.domain
    }

    /// 改名称、品牌、常用叫法、包装。品牌、包装为空时清空。
    func update(_ id: UUID, name: String, brandOrSupplier: String?, aliases: [String], package: Quantity?) async throws -> FoodProductSummary {
        let body = FoodProductUpdateDTO(name: name, brandOrSupplier: brandOrSupplier, aliases: aliases, package: package)
        let response: FoodProductResponseDTO = try await api.send("PATCH", "/v1/foods/\(id.apiString)", body: body)
        return response.product.domain
    }

    /// 手动改营养值：存为新版本并生效，旧版本保留，已有记录不变。
    func addVersion(_ id: UUID, expectedActiveVersionID: UUID?, basis: FoodVersionBasis, sourceNote: String?) async throws -> FoodProductSummary {
        let body = FoodVersionRequestDTO(expectedActiveVersionId: expectedActiveVersionID, basis: basis, sourceNote: sourceNote)
        let response: FoodProductResponseDTO = try await api.send("POST", "/v1/foods/\(id.apiString)/versions", body: body)
        return response.product.domain
    }

    /// 删除后不再出现在食品库和模型的上下文里；已有记录不受影响。
    func delete(_ id: UUID) async throws {
        try await api.perform("DELETE", "/v1/foods/\(id.apiString)")
    }
}

struct FoodProductResponseDTO: Decodable, Sendable {
    var product: FoodProductDTO
}

/// 品牌、包装为空时要显式传 null 才会清空。
struct FoodProductUpdateDTO: Encodable, Sendable {
    var name: String
    var brandOrSupplier: String?
    var aliases: [String]
    var package: Quantity?

    enum CodingKeys: String, CodingKey { case name, brandOrSupplier, aliases, package }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(brandOrSupplier, forKey: .brandOrSupplier)
        try container.encode(package, forKey: .package)
    }
}

struct FoodVersionRequestDTO: Encodable, Sendable {
    var expectedActiveVersionId: UUID?
    var basis: FoodVersionBasis
    var sourceNote: String?

    enum CodingKeys: String, CodingKey { case expectedActiveVersionId, basis, sourceNote }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedActiveVersionId?.apiString, forKey: .expectedActiveVersionId)
        try container.encode(basis, forKey: .basis)
        try container.encodeIfPresent(sourceNote, forKey: .sourceNote)
    }
}
