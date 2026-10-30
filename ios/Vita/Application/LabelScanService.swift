import Foundation
import SwiftData

struct LabelScanResult: Equatable, Sendable {
    var scanID: UUID
    var imageReference: String
    var candidate: NutritionLabelCandidate
}

/// `attachNutritionLabel`（client-only）：保存原图、本地识别、解析候选值并记下这次识别。
/// 之后交给模型的只有 `candidate`，原图默认不外发（agent-tools.md）。
@MainActor
final class LabelScanService {
    private let context: ModelContext
    private let images: any LabelImageStore
    private let recognizer: any TextRecognizer
    private let now: () -> Date

    init(context: ModelContext, images: any LabelImageStore, recognizer: any TextRecognizer, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.images = images
        self.recognizer = recognizer
        self.now = now
    }

    func scan(_ imageData: Data) async throws -> LabelScanResult {
        let reference = try images.save(imageData)
        do {
            let lines = try await recognizer.recognize(imageData)
            let candidate = NutritionLabelParser.parse(lines)
            let scan = NutritionLabelScan(imageReference: reference, lines: NutritionLabelParser.rows(from: lines), candidate: candidate, createdAt: now())
            context.insert(scan)
            context.insert(AuditEvent(operation: "label.scan", targetID: scan.id.uuidString, result: .success, createdAt: now()))
            try context.save()
            return LabelScanResult(scanID: scan.id, imageReference: reference, candidate: candidate)
        } catch {
            context.rollback()
            try? images.delete(reference)
            context.insert(AuditEvent(operation: "label.scan", result: .failure, errorCode: "label.recognitionFailed", createdAt: now()))
            try? context.save()
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
}
