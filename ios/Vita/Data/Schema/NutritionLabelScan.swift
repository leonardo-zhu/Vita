import Foundation
import SwiftData

/// 一次营养标签识别（`attachNutritionLabel`）：原图只存本机，识别出的文字与候选值在这里。
/// 交给模型的只有结构化候选，原图默认不外发（TDD §8）。
@Model
final class NutritionLabelScan {
    @Attribute(.unique) var id: UUID
    /// 本地图片引用，形如 `label:<uuid>`；Food Version 用它指向原图。
    @Attribute(.unique) var imageReference: String
    var linesData: Data
    var candidateData: Data
    var createdAt: Date

    init(id: UUID = UUID(), imageReference: String, lines: [String], candidate: NutritionLabelCandidate, createdAt: Date) {
        self.id = id
        self.imageReference = imageReference
        self.linesData = JSONColumn.encode(lines)
        self.candidateData = JSONColumn.encode(candidate)
        self.createdAt = createdAt
    }

    func lines() throws -> [String] {
        try JSONColumn.decode([String].self, from: linesData)
    }

    func candidate() throws -> NutritionLabelCandidate {
        try JSONColumn.decode(NutritionLabelCandidate.self, from: candidateData)
    }
}
