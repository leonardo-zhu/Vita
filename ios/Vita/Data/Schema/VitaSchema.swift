import Foundation
import SwiftData

/// SwiftData schema 版本。后续每个破坏性变更新增一个 VersionedSchema 并在
/// `VitaMigrationPlan` 中登记迁移阶段。首个版本发布前（尚无需要保留的真实数据）直接扩充 V1。
enum VitaSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            AuditEvent.self,
            DaySession.self, ChatMessage.self,
            ConsumptionRecord.self, ConsumptionItem.self,
            FoodProduct.self, FoodVersion.self,
            DailyGoal.self,
            PendingAction.self,
            NutritionLabelScan.self,
            HealthSyncOperation.self, HealthSyncMapping.self, ManualBodyMetricsEntry.self,
        ]
    }
}

enum VitaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [VitaSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum PersistenceStore {
    /// `inMemory` 供单元测试与预览使用，不落盘。
    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(VitaSchemaV1.models, version: VitaSchemaV1.versionIdentifier)
        return try makeContainer(schema: schema, configuration: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory))
    }

    /// 指定文件位置，供测试模拟“App 重启后从磁盘恢复”。
    static func makeContainer(url: URL) throws -> ModelContainer {
        let schema = Schema(VitaSchemaV1.models, version: VitaSchemaV1.versionIdentifier)
        return try makeContainer(schema: schema, configuration: ModelConfiguration(schema: schema, url: url))
    }

    private static func makeContainer(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        return try ModelContainer(
            for: schema,
            migrationPlan: VitaMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
