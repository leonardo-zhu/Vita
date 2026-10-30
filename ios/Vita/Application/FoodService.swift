import Foundation
import SwiftData

enum FoodServiceError: Error, Equatable {
    case emptyName
    case invalidPackage
    case invalidBasis
    /// nutritionLabel 必须指向一张已在本地识别过的标签。
    case unknownLabel
    /// referenceDerived 必须指向存在的参考条目，且营养值与之一致。
    case unknownReferenceFood(String)
    case basisDiffersFromReference
    case productNotFound
    /// 提案之后产品的生效版本已经变化，提案作废。
    case activeVersionChanged

    var auditCode: String {
        switch self {
        case .emptyName: "food.emptyName"
        case .invalidPackage: "food.invalidPackage"
        case .invalidBasis: "food.invalidBasis"
        case .unknownLabel: "food.unknownLabel"
        case .unknownReferenceFood: "food.unknownReferenceFood"
        case .basisDiffersFromReference: "food.basisDiffersFromReference"
        case .productNotFound: "food.productNotFound"
        case .activeVersionChanged: "food.activeVersionChanged"
        }
    }
}

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

/// 个人 Nutrition DB（PRD §3.2.1）。变更只经 Pending 确认后执行；Food Version 一经创建不再修改。
@MainActor
final class FoodService {
    private let context: ModelContext
    private let referenceFoods: ReferenceFoodCatalog
    private let now: () -> Date

    init(context: ModelContext, referenceFoods: ReferenceFoodCatalog, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.referenceFoods = referenceFoods
        self.now = now
    }

    func products() throws -> [FoodProductSummary] {
        try context.fetch(FetchDescriptor<FoodProduct>(sortBy: [SortDescriptor(\.name)])).map(summary)
    }

    /// 名称或品牌包含查询词（忽略全半角、大小写与空白）。个人库很小，不做索引。
    func search(_ query: String) throws -> [FoodProductSummary] {
        let key = ReferenceFoodCatalog.normalize(query)
        guard !key.isEmpty else { return [] }
        return try products().filter { product in
            [product.name, product.brandOrSupplier ?? ""].contains { ReferenceFoodCatalog.normalize($0).contains(key) }
        }
    }

    func preview(_ change: FoodChange) throws -> FoodChangePreview {
        try prepare(change).preview
    }

    /// 执行变更；`alongside` 与之同一事务。返回产品 ID。
    @discardableResult
    func apply(_ change: FoodChange, requestID: UUID? = nil, alongside: (UUID) throws -> Void = { _ in }) throws -> UUID {
        do {
            let productID = try prepare(change).commit()
            try alongside(productID)
            context.insert(AuditEvent(operation: change.auditOperation, targetID: productID.uuidString, result: .success, requestID: requestID, createdAt: now()))
            try context.save()
            return productID
        } catch {
            context.rollback()
            let code = (error as? FoodServiceError)?.auditCode ?? "food.persistence"
            context.insert(AuditEvent(operation: change.auditOperation, result: .failure, errorCode: code, requestID: requestID, createdAt: now()))
            try? context.save()
            throw error
        }
    }

    // MARK: - 校验与执行

    private struct Prepared {
        var preview: FoodChangePreview
        var commit: () -> UUID
    }

    private func prepare(_ change: FoodChange) throws -> Prepared {
        switch change {
        case .createProduct(let product, let version):
            guard !product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FoodServiceError.emptyName }
            if let package = product.package, package.amount <= 0 { throw FoodServiceError.invalidPackage }
            try validate(version)
            let preview = FoodChangePreview(
                kind: .createProduct, productName: product.name, brandOrSupplier: product.brandOrSupplier,
                package: product.package, version: version, previousBasis: nil
            )
            return Prepared(preview: preview) {
                let timestamp = self.now()
                let created = FoodProduct(name: product.name, brandOrSupplier: product.brandOrSupplier, package: product.package, note: product.note, now: timestamp)
                self.context.insert(created)
                self.insertVersion(version, into: created, now: timestamp)
                return created.id
            }

        case .addVersion(let productID, let expectedActive, let version):
            var descriptor = FetchDescriptor<FoodProduct>(predicate: #Predicate { $0.id == productID })
            descriptor.fetchLimit = 1
            guard let product = try context.fetch(descriptor).first else { throw FoodServiceError.productNotFound }
            guard product.activeVersionID == expectedActive else { throw FoodServiceError.activeVersionChanged }
            try validate(version)
            let previous = try product.activeVersionID.flatMap { try context.foodVersion(id: $0) }
            let preview = FoodChangePreview(
                kind: .addVersion, productName: product.name, brandOrSupplier: product.brandOrSupplier,
                package: try product.package(), version: version, previousBasis: try previous?.basis()
            )
            return Prepared(preview: preview) {
                let timestamp = self.now()
                previous?.retiredAt = timestamp
                self.insertVersion(version, into: product, now: timestamp)
                return product.id
            }
        }
    }

    private func validate(_ version: FoodVersionDraft) throws {
        guard version.basis.quantity.amount > 0, version.basis.nutrients.isValid else { throw FoodServiceError.invalidBasis }
        switch version.sourceKind {
        case .nutritionLabel:
            guard let reference = version.labelImageReference else { throw FoodServiceError.unknownLabel }
            var descriptor = FetchDescriptor<NutritionLabelScan>(predicate: #Predicate { $0.imageReference == reference })
            descriptor.fetchLimit = 1
            guard try context.fetch(descriptor).first != nil else { throw FoodServiceError.unknownLabel }
        case .referenceDerived:
            guard let id = version.derivedFromReferenceID, let food = referenceFoods.food(id: id) else {
                throw FoodServiceError.unknownReferenceFood(version.derivedFromReferenceID ?? "")
            }
            guard version.basis == FoodVersionBasis(quantity: food.base.asQuantity, nutrients: food.nutrients) else {
                throw FoodServiceError.basisDiffersFromReference
            }
        case .manualEntry:
            break
        }
    }

    private func insertVersion(_ draft: FoodVersionDraft, into product: FoodProduct, now: Date) {
        let version = FoodVersion(
            basis: draft.basis, sourceKind: draft.sourceKind, labelImageReference: draft.labelImageReference,
            derivedFromReferenceID: draft.derivedFromReferenceID, sourceNote: draft.sourceNote, now: now
        )
        context.insert(version)
        version.product = product
        product.activeVersionID = version.id
        product.updatedAt = now
    }

    private func summary(_ product: FoodProduct) throws -> FoodProductSummary {
        let versions = try product.versions
            .sorted { $0.createdAt > $1.createdAt }
            .map { version in
                FoodVersionSummary(
                    id: version.id, basis: try version.basis(), sourceKind: version.sourceKind,
                    labelImageReference: version.labelImageReference, derivedFromReferenceID: version.derivedFromReferenceID,
                    sourceNote: version.sourceNote, createdAt: version.createdAt, retiredAt: version.retiredAt
                )
            }
        return FoodProductSummary(
            id: product.id, name: product.name, brandOrSupplier: product.brandOrSupplier,
            package: try product.package(), note: product.note,
            activeVersion: versions.first { $0.id == product.activeVersionID },
            versions: versions
        )
    }
}
