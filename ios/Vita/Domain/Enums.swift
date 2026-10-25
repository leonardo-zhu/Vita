/// 摄入量来源（TDD §3.3）。
enum AmountSource: String, Codable, Sendable, CaseIterable {
    case userMeasured, userStated, packageConversion, aiEstimated
}

/// 营养数据来源（TDD §3.3）。
enum NutritionSource: String, Codable, Sendable, CaseIterable {
    case personalFoodVersion, referenceFood, aiEstimated
}

enum FoodVersionSource: String, Codable, Sendable, CaseIterable {
    case nutritionLabel, manualEntry, referenceDerived
}

enum GoalOrigin: String, Codable, Sendable, CaseIterable {
    case initialRecommendation, explicitUserCommand, manualOnboarding
}

enum SyncState: String, Codable, Sendable, CaseIterable {
    case synced, pending, failedRetryable, requiresUserResolution
}

/// 标准化计量单位：内部营养计算只使用 g / ml。
enum QuantityUnit: String, Codable, Sendable, CaseIterable {
    case gram = "g"
    case milliliter = "ml"
}
