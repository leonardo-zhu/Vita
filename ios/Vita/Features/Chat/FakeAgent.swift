#if DEBUG
import Foundation

/// 调试用假 Agent：生成与真实模型相同格式的工具调用，走完整的解析、校验与 Pending 流程。
/// 只用 AI 估算，避免依赖尚未构建的公共参考库。
enum FakeAgent {
    enum Step: CaseIterable {
        case createSnack, appendBanana, replaceFirstItem, removeLastItem, deleteLastRecord, correctPending

        var title: String {
            switch self {
            case .createSnack: "提议：加餐一杯酸奶"
            case .appendBanana: "提议：最后一条追加香蕉"
            case .replaceFirstItem: "提议：替换最后一条的第一项"
            case .removeLastItem: "提议：移除最后一条的末项"
            case .deleteLastRecord: "提议：删除最后一条记录"
            case .correctPending: "修正当前卡片：酸奶改两杯"
            }
        }
    }

    struct Call {
        var tool: String
        var arguments: Data
    }

    enum FakeAgentError: Error {
        case noRecord
    }

    static func call(_ step: Step, day: DayData, replacing: UUID?) throws -> Call {
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
        }
        let envelope: [String: Any] = [
            "requestId": UUID().uuidString,
            "sessionDate": day.date.isoString,
            "expectedRevision": day.revision,
            "payload": payload,
        ]
        return Call(tool: tool, arguments: try JSONSerialization.data(withJSONObject: envelope))
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
