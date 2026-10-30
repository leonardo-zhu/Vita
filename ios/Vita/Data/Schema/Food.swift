import Foundation
import SwiftData

/// 用户 Nutrition DB 中的具体食品（PRD §3.2.1）。创建与版本管理流程在 Phase 3 实现。
@Model
final class FoodProduct {
    @Attribute(.unique) var id: UUID
    var name: String
    var brandOrSupplier: String?
    /// 包装规格，如 250 ml，用于理解“一盒、半瓶”。
    var packageData: Data?
    var note: String?
    var activeVersionID: UUID?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \FoodVersion.product)
    var versions: [FoodVersion] = []

    init(id: UUID = UUID(), name: String, brandOrSupplier: String? = nil, package: Quantity? = nil, note: String? = nil, now: Date) {
        self.id = id
        self.name = name
        self.brandOrSupplier = brandOrSupplier
        self.packageData = package.map(JSONColumn.encode)
        self.note = note
        self.createdAt = now
        self.updatedAt = now
    }

    func package() throws -> Quantity? {
        try packageData.map { try JSONColumn.decode(Quantity.self, from: $0) }
    }
}

/// 每基准量的营养值。
struct FoodVersionBasis: Equatable, Codable, Sendable {
    var quantity: Quantity
    var nutrients: NutrientValues
}

/// 不可变的营养版本（TDD §4.3）：创建后不修改，纠正时新建版本并切换 `activeVersionID`。
@Model
final class FoodVersion {
    @Attribute(.unique) var id: UUID
    var product: FoodProduct?
    var basisData: Data
    var sourceKindRaw: String
    var labelImageReference: String?
    var sourceNote: String?
    var createdAt: Date
    var retiredAt: Date?

    init(id: UUID = UUID(), basis: FoodVersionBasis, sourceKind: FoodVersionSource, sourceNote: String? = nil, now: Date) {
        self.id = id
        self.basisData = JSONColumn.encode(basis)
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceNote = sourceNote
        self.createdAt = now
    }

    var sourceKind: FoodVersionSource {
        FoodVersionSource(rawValue: sourceKindRaw) ?? .manualEntry
    }

    func basis() throws -> FoodVersionBasis {
        try JSONColumn.decode(FoodVersionBasis.self, from: basisData)
    }
}
