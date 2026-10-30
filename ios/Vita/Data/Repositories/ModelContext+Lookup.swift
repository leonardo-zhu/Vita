import Foundation
import SwiftData

/// 按 ID / 日期取单个实体。
extension ModelContext {
    func session(on date: LocalDate) throws -> DaySession? {
        let key = date.isoString
        var descriptor = FetchDescriptor<DaySession>(predicate: #Predicate { $0.localDateKey == key })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    func record(id: UUID) throws -> ConsumptionRecord? {
        var descriptor = FetchDescriptor<ConsumptionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    func foodVersion(id: UUID) throws -> FoodVersion? {
        var descriptor = FetchDescriptor<FoodVersion>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }
}
