#if DEBUG
import Foundation
import SwiftData

/// 调试用样例数据：以启动参数 `-VitaSeedSampleData` 在今天为空时写入，便于在模拟器里查看 Data 页。
/// 只走正式的 Service 写入路径，不绕过校验。
@MainActor
enum SampleData {
    static let launchArgument = "-VitaSeedSampleData"

    /// Xcode Previews 用：内存数据库加今天的样例数据。
    static func previewServices() -> AppServices {
        let services = AppServices(container: try! AppContainer.inMemory())
        try? seedToday(services)
        return services
    }

    static func seedToday(_ services: AppServices) throws {
        let timeZone = TimeZone.current
        let today = LocalDate(date: Date(), timeZone: timeZone)
        let day = try services.dayData.day(today)
        guard day.records.isEmpty else { return }

        let context = services.container.modelContainer.mainContext
        // 跨天再次写入样例时复用已有的样例食品，不重复建产品。
        if let existing = try context.fetch(FetchDescriptor<FoodProduct>()).first(where: { $0.name == "纯牛奶" && $0.brandOrSupplier == "样例品牌" }),
           let versionID = existing.activeVersionID {
            return try seedRecords(services, on: today, timeZone: timeZone, milkVersionID: versionID)
        }
        let milk = FoodProduct(name: "纯牛奶", brandOrSupplier: "样例品牌", package: Quantity(amount: 250, unit: .milliliter), now: Date())
        let version = FoodVersion(
            basis: FoodVersionBasis(
                quantity: Quantity(amount: 100, unit: .milliliter),
                nutrients: NutrientValues(energyKcal: 65, proteinG: Decimal(string: "3.2")!, fatG: Decimal(string: "3.6")!, carbohydrateG: Decimal(string: "4.8")!)
            ),
            sourceKind: .manualEntry,
            now: Date()
        )
        context.insert(milk)
        context.insert(version)
        version.product = milk
        milk.activeVersionID = version.id
        try context.save()
        try seedRecords(services, on: today, timeZone: timeZone, milkVersionID: version.id)
    }

    private static func seedRecords(_ services: AppServices, on today: LocalDate, timeZone: TimeZone, milkVersionID: UUID) throws {
        if try services.goals.activeGoal(on: today) == nil {
            // 能量目标随活动计算（BMR 1650、平时活动 450、减脂 85%）；模拟器没有健康数据时按平时活动估算。
            try services.goals.appendGoal(
                GoalTargets(energyKcal: 1790, proteinG: 130, fatG: 60, carbohydrateG: 180),
                energyPlan: EnergyPlan(kind: .lose, adjustment: .fraction(EnergyTargetPolicy.defaultLoseFraction), bmrKcal: 1650, baselineActivityKcal: 450, baselineEstimated: false),
                origin: .manualOnboarding,
                effectiveFrom: today
            )
        }

        try services.records.createRecord(on: today, expectedRevision: 0, draft: RecordDraft(
            eventTime: try EventTime(localDate: today, precision: .mealPeriod, mealPeriod: .breakfast, timeZoneIdentifier: timeZone.identifier),
            mealLabel: "早餐",
            items: [
                ItemDraft(
                    displayName: "纯牛奶", originalAmountText: "一盒", quantity: Quantity(amount: 250, unit: .milliliter),
                    amountSource: .packageConversion, nutrition: .personalFoodVersion(milkVersionID), includeInSummary: true
                ),
                ItemDraft(
                    displayName: "水煮蛋", originalAmountText: "2 个，共 108g", quantity: Quantity(amount: 108, unit: .gram),
                    amountSource: .userMeasured,
                    nutrition: .aiEstimated(
                        NutrientValues(energyKcal: 167, proteinG: Decimal(string: "13.6")!, fatG: Decimal(string: "11.4")!, carbohydrateG: Decimal(string: "1.2")!),
                        estimateBasis: "按常见水煮蛋每 100g 约 155 kcal 估算"
                    ),
                    includeInSummary: true
                ),
            ]
        ))

        try services.records.createRecord(on: today, expectedRevision: 1, draft: RecordDraft(
            eventTime: try EventTime(localDate: today, precision: .mealPeriod, mealPeriod: .lunch, timeZoneIdentifier: timeZone.identifier),
            mealLabel: "午餐",
            items: [
                ItemDraft(
                    displayName: "宫保鸡丁饭", groupName: "外卖", originalAmountText: "一份", quantity: nil,
                    amountSource: .aiEstimated,
                    nutrition: .aiEstimated(
                        NutrientValues(energyKcal: 720, proteinG: 32, fatG: 26, carbohydrateG: 88),
                        estimateBasis: "按常见外卖一份约 450g 估算"
                    ),
                    includeInSummary: true
                ),
                ItemDraft(
                    displayName: "辣椒油", groupName: "外卖", originalAmountText: "少许", quantity: nil,
                    amountSource: .aiEstimated,
                    nutrition: .aiEstimated(NutrientValues(energyKcal: 45, proteinG: 0, fatG: 5, carbohydrateG: 0), estimateBasis: "约 5g 油"),
                    includeInSummary: false
                ),
            ]
        ))
    }
}
#endif
