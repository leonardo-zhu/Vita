import Foundation
import SwiftData

/// 调试用的清空数据（设置页调试卡片）。可以按分组清，也可以全部清空，回到刚装好 App 的状态。
/// 不动 Apple 健康：Vita 写进去的 Sample 留在健康里，清空后不再由 Vita 管理。
enum DataResetPart: String, CaseIterable, Identifiable, Sendable {
    /// 饮食记录、会话、确认卡、个人食品库、营养标签与图片、审计事件，以及本地的健康同步队列与映射。
    case records
    /// 每日目标、补录的身体数据、首次引导完成标记。
    case goals
    /// 本地调试覆盖（vita-admin.md §9）。
    case debugOverride
    /// Keychain 里的 Conduit 令牌。
    case token

    var id: String { rawValue }

    /// 不勾选全部清空时的默认选择：令牌留着，省得每次重填。
    static let defaultSelection: Set<DataResetPart> = [.records, .goals, .debugOverride]
}

@MainActor
final class DataResetService {
    private let context: ModelContext
    private let secrets: any SecretStore
    private let labelImages: any LabelImageStore
    private let defaults: UserDefaults

    init(context: ModelContext, secrets: any SecretStore, labelImages: any LabelImageStore, defaults: UserDefaults = .standard) {
        self.context = context
        self.secrets = secrets
        self.labelImages = labelImages
        self.defaults = defaults
    }

    func reset(_ parts: Set<DataResetPart>) throws {
        if parts.contains(.records) {
            try deleteAll(HealthSyncOperation.self)
            try deleteAll(HealthSyncMapping.self)
            try deleteAll(PendingAction.self)
            try deleteAll(ChatMessage.self)
            try deleteAll(DaySession.self)
            try deleteAll(ConsumptionItem.self)
            try deleteAll(ConsumptionRecord.self)
            try deleteAll(FoodVersion.self)
            try deleteAll(FoodProduct.self)
            try deleteAll(NutritionLabelScan.self)
            try deleteAll(AuditEvent.self)
            try labelImages.deleteAll()
        }
        if parts.contains(.goals) {
            try deleteAll(DailyGoal.self)
            try deleteAll(ManualBodyMetricsEntry.self)
            defaults.removeObject(forKey: OnboardingState.key)
        }
        try context.save()
        if parts.contains(.debugOverride) {
            DebugOverrideStore.save(nil, to: defaults)
        }
        if parts.contains(.token) {
            try secrets.delete(.conduitToken)
        }
    }

    /// 全部清空：所有分组，再清掉本 App 的整个 UserDefaults 域，相当于删掉重装。
    /// Apple 健康的数据与授权都不动。
    func resetEverything() throws {
        try reset(Set(DataResetPart.allCases))
        defaults.dictionaryRepresentation().keys.forEach(defaults.removeObject)
    }

    private func deleteAll<Model: PersistentModel>(_ type: Model.Type) throws {
        try context.fetch(FetchDescriptor<Model>()).forEach(context.delete)
    }
}
