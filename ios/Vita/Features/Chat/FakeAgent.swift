#if DEBUG
import Foundation

/// 调试用假 Agent：生成与真实模型相同格式的工具调用，走完整的解析、校验与 Pending 流程。
/// 记录类提议只用 AI 估算，避免依赖尚未构建的公共参考库。
enum FakeAgent {
    enum Step: CaseIterable {
        case createSnack, appendBanana, replaceFirstItem, removeLastItem, deleteLastRecord, correctPending
        case createFood, newVersionOfFirstFood, drinkHalfOfFirstFood

        var title: String {
            switch self {
            case .createSnack: "提议：加餐一杯酸奶"
            case .appendBanana: "提议：最后一条追加香蕉"
            case .replaceFirstItem: "提议：替换最后一条的第一项"
            case .removeLastItem: "提议：移除最后一条的末项"
            case .deleteLastRecord: "提议：删除最后一条记录"
            case .correctPending: "修正当前卡片：酸奶改两杯"
            case .createFood: "提议：新建个人食品（手动提供）"
            case .newVersionOfFirstFood: "提议：第一个食品换新标签"
            case .drinkHalfOfFirstFood: "提议：喝了第一个食品半盒"
            }
        }
    }

    struct Call {
        var tool: String
        var arguments: Data
    }

    enum FakeAgentError: Error {
        case noRecord
        case noFood
        case incompleteLabel([String])
    }

    static func call(_ step: Step, day: DayData, products: [FoodProductSummary], replacing: UUID?) throws -> Call {
        let last = day.records.last
        var payload: [String: Any]
        var tool = "proposeRecordChange"
        switch step {
        case .createSnack, .correctPending:
            let cups = step == .correctPending ? 2 : 1
            payload = [
                "intent": "create",
                "record": [
                    "eventTime": ["precision": "mealPeriod", "mealPeriod": "snack"],
                    "mealLabel": "加餐",
                    "items": [estimate("原味酸奶", "\(cups) 杯", kcal: 140 * cups, protein: 6 * cups, basis: "按常见一杯 200g 原味酸奶估算")],
                ],
            ]
            if step == .correctPending, let replacing { payload["replacesPendingId"] = replacing.uuidString }
        case .appendBanana:
            guard let last else { throw FakeAgentError.noRecord }
            payload = ["intent": "appendItems", "recordId": last.id.uuidString, "items": [estimate("香蕉", "一根", kcal: 105, protein: 1, basis: "按中等大小一根约 120g 估算")]]
        case .replaceFirstItem:
            guard let last, let first = last.items.first else { throw FakeAgentError.noRecord }
            payload = [
                "intent": "replaceItem", "recordId": last.id.uuidString, "itemId": first.id.uuidString,
                "item": estimate(first.displayName, "半份", kcal: 200, protein: 10, basis: "按原估算的一半"),
            ]
        case .removeLastItem:
            guard let last, let item = last.items.last else { throw FakeAgentError.noRecord }
            payload = ["intent": "removeItem", "recordId": last.id.uuidString, "itemId": item.id.uuidString]
        case .deleteLastRecord:
            guard let last else { throw FakeAgentError.noRecord }
            tool = "proposeRecordDeletion"
            payload = ["recordId": last.id.uuidString]
        case .createFood:
            tool = "proposeFoodChange"
            payload = [
                "intent": "createProduct",
                "product": ["name": "高蛋白牛奶", "brandOrSupplier": "样例乳业", "package": ["amount": 250, "unit": "ml"]],
                "version": [
                    "source": "manualEntry",
                    "basis": ["amount": 100, "unit": "ml"],
                    "values": ["energyKcal": 72, "proteinG": 6, "fatG": 3.2, "carbohydrateG": 4.8],
                    "note": "用户口述包装上的数值",
                ],
            ]
        case .newVersionOfFirstFood:
            guard let product = products.first, let basis = product.activeVersion?.basis else { throw FakeAgentError.noFood }
            tool = "proposeFoodChange"
            var nutrients = basis.nutrients
            nutrients.proteinG += 1
            payload = [
                "intent": "addVersion",
                "productId": product.id.uuidString,
                "expectedActiveVersionId": product.activeVersion?.id.uuidString ?? NSNull(),
                "version": [
                    "source": "manualEntry",
                    "basis": ["amount": basis.quantity.amount, "unit": basis.quantity.unit.rawValue],
                    "values": numbers(nutrients),
                    "note": "包装改版，蛋白质 +1g",
                ],
            ]
        case .drinkHalfOfFirstFood:
            guard let product = products.first, let package = product.package, let version = product.activeVersion else { throw FakeAgentError.noFood }
            payload = [
                "intent": "create",
                "record": [
                    "items": [[
                        "displayName": product.name,
                        "originalAmountText": "半盒",
                        "quantity": ["amount": package.amount / 2, "unit": package.unit.rawValue],
                        "amountSource": "packageConversion",
                        "nutrition": ["source": "personalFoodVersion", "foodVersionId": version.id.uuidString],
                    ]],
                ],
            ]
        }
        return try envelope(tool: tool, day: day, payload: payload)
    }

    /// 识别完营养标签后，模型会用候选值提出新建食品；这里直接照搬候选值。
    static func foodFromLabel(_ scan: LabelScanResult, day: DayData) throws -> Call {
        guard let basis = scan.candidate.complete else { throw FakeAgentError.incompleteLabel(scan.candidate.warnings) }
        let payload: [String: Any] = [
            "intent": "createProduct",
            "product": ["name": "扫描的食品", "note": "来自营养标签识别"],
            "version": [
                "source": "nutritionLabel",
                "labelScanId": scan.scanID.uuidString,
                "basis": ["amount": basis.quantity.amount, "unit": basis.quantity.unit.rawValue],
                "values": numbers(basis.nutrients),
                "note": scan.candidate.warnings.joined(separator: "；"),
            ],
        ]
        return try envelope(tool: "proposeFoodChange", day: day, payload: payload)
    }

    private static func envelope(tool: String, day: DayData, payload: [String: Any]) throws -> Call {
        let envelope: [String: Any] = [
            "requestId": UUID().uuidString,
            "sessionDate": day.date.isoString,
            "expectedRevision": day.revision,
            "payload": payload,
        ]
        return Call(tool: tool, arguments: try JSONSerialization.data(withJSONObject: envelope))
    }

    private static func numbers(_ values: NutrientValues) -> [String: Any] {
        ["energyKcal": values.energyKcal, "proteinG": values.proteinG, "fatG": values.fatG, "carbohydrateG": values.carbohydrateG]
    }

    private static func estimate(_ name: String, _ amount: String, kcal: Int, protein: Int, basis: String) -> [String: Any] {
        [
            "displayName": name,
            "originalAmountText": amount,
            "amountSource": "aiEstimated",
            "nutrition": [
                "source": "aiEstimated",
                "values": ["energyKcal": kcal, "proteinG": protein, "fatG": 0, "carbohydrateG": 0],
                "estimateBasis": basis,
            ],
        ]
    }
}
#endif
