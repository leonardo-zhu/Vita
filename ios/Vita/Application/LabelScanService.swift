import Foundation
import SwiftData

struct LabelScanResult: Equatable, Sendable {
    var scanID: UUID
    var imageReference: String
}

/// `attachNutritionLabel`（client-only）：保存照片并记下这次附件。照片随用户消息发给模型，由模型读标签
/// （ADR-016）；本机这份原图是 Food Version 的来源依据，模型只拿到 `labelScanId`，拿不到本地路径。
@MainActor
final class LabelScanService {
    private let context: ModelContext
    private let images: any LabelImageStore
    private let now: () -> Date

    init(context: ModelContext, images: any LabelImageStore, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.images = images
        self.now = now
    }

    func scan(_ imageData: Data) throws -> LabelScanResult {
        let reference = try images.save(imageData)
        do {
            let scan = NutritionLabelScan(imageReference: reference, createdAt: now())
            context.insert(scan)
            context.insert(AuditEvent(operation: "label.scan", targetID: scan.id.uuidString, result: .success, createdAt: now()))
            try context.save()
            return LabelScanResult(scanID: scan.id, imageReference: reference)
        } catch {
            context.rollback()
            try? images.delete(reference)
            throw error
        }
    }

    /// 工具层用 scan ID 找到图片引用，模型无从得知或伪造本地路径。
    func imageReference(forScan id: UUID) throws -> String? {
        var descriptor = FetchDescriptor<NutritionLabelScan>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.imageReference
    }

    func imageData(_ reference: String) throws -> Data? {
        try images.load(reference)
    }

    /// 发给模型的图片：按配置缩放、压成 JPEG。找不到图片或无法解码时返回 nil。
    func modelImage(forScan id: UUID, settings: VitaConfig.LabelImage) -> LLMImage? {
        guard let reference = try? imageReference(forScan: id),
              let data = try? images.load(reference),
              let jpeg = LabelImageEncoder.jpeg(data, maxDimension: settings.maxDimension, quality: settings.jpegQuality)
        else { return nil }
        return LLMImage(dataURL: "data:image/jpeg;base64," + jpeg.base64EncodedString(), detail: settings.detail)
    }
}
