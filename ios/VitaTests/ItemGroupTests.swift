import Foundation
import Testing
@testable import Vita

struct ItemGroupTests {
    private func item(_ name: String, group: String?, kcal: Decimal, counted: Bool = true) -> DayData.Item {
        DayData.Item(
            id: UUID(), displayName: name, groupName: group, originalAmountText: name, quantity: nil,
            amountSource: .aiEstimated, includeInSummary: counted,
            snapshot: NutritionCalculator.estimatedSnapshot(
                values: NutrientValues(energyKcal: kcal, proteinG: 0, fatG: 0, carbohydrateG: 0),
                estimateBasis: "测试", quantity: nil
            ),
            sourceLabel: nil
        )
    }

    @Test func itemsOfOneDishAreGroupedInFirstAppearanceOrder() {
        let items = [
            item("红薯粉条", group: "鸭血粉丝汤", kcal: 351),
            item("嫩鸭血", group: "鸭血粉丝汤", kcal: 79),
            item("健怡可口可乐", group: nil, kcal: 0),
            item("油豆腐果", group: " 鸭血粉丝汤 ", kcal: 74),
            item("盐", group: "鸭血粉丝汤", kcal: 5, counted: false),
        ]
        let groups = ItemGroup.groups(items)
        #expect(groups.map(\.name) == ["鸭血粉丝汤", nil])
        #expect(groups[0].items.map(\.displayName) == ["红薯粉条", "嫩鸭血", "油豆腐果", "盐"])
        #expect(groups[0].energyKcal == 504)
        #expect(groups[0].showsHeader)
        #expect(!groups[1].showsHeader)
    }

    @Test func singleItemNamedAfterItsDishNeedsNoHeader() {
        let groups = ItemGroup.groups([item("番茄炒蛋", group: "番茄炒蛋", kcal: 200), item("米饭", group: "", kcal: 230)])
        #expect(groups.count == 2)
        #expect(!groups[0].showsHeader)
        #expect(groups[1].name == nil)
    }
}
