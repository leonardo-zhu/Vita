import Foundation
import SwiftData

/// 一次营养标签附件（`attachNutritionLabel`）：照片存本机，随消息发给模型（ADR-016）。
@Model
final class NutritionLabelScan {
    @Attribute(.unique) var id: UUID
    /// 本地图片引用，形如 `label:<uuid>`；Food Version 用它指向原图。
    @Attribute(.unique) var imageReference: String
    /// 早期在本机识别时存的文字行与候选值。已不再使用，保留这两列是为了不必迁移已有数据。
    var linesData: Data
    var candidateData: Data
    var createdAt: Date

    init(id: UUID = UUID(), imageReference: String, createdAt: Date) {
        self.id = id
        self.imageReference = imageReference
        self.linesData = Data()
        self.candidateData = Data()
        self.createdAt = createdAt
    }
}
