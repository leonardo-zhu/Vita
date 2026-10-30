import Foundation
import Testing
@testable import Vita

/// 以假 Agent（fixture JSON 中的工具调用序列）驱动 create / append / replace / remove / delete 全部分支。
@MainActor
struct ScriptedAgentTests {
    struct Step {
        var note: String
        var tool: String
        /// 原样保留的参数 JSON，含 `$LAST_RECORD` 等占位符。
        var arguments: String
        var expectOK: Bool
        var expectedError: String?
        var then: String

        static func load() throws -> [Step] {
            let url = try #require(Fixtures.bundle.url(forResource: "agent-script.fixture", withExtension: "json"))
            let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            return try raw.map { step in
                let expect = try #require(step["expect"] as? [String: Any])
                let arguments = try JSONSerialization.data(withJSONObject: try #require(step["arguments"]))
                return Step(
                    note: step["note"] as? String ?? "",
                    tool: try #require(step["tool"] as? String),
                    arguments: String(decoding: arguments, as: UTF8.self),
                    expectOK: try #require(expect["ok"] as? Bool),
                    expectedError: expect["errorCode"] as? String,
                    then: step["then"] as? String ?? "none"
                )
            }
        }
    }

    @Test func scriptDrivesEveryBranchThroughTheConfirmGate() throws {
        let container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        let services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let handler = ProposalToolHandler(pending: services.pending, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let steps = try Step.load()
        #expect(steps.count >= 10)

        for step in steps {
            let day = try services.dayData.day(Fixtures.day)
            let active = try services.pending.active(on: Fixtures.day)
            var text = step.arguments
            let replacements: [String: String] = [
                "\"$REV\"": "\(day.revision)",
                "$UUID": UUID().uuidString,
                "$DATE": Fixtures.day.isoString,
                "$YESTERDAY": "2026-10-29",
                "$FIRST_RECORD": day.records.first?.id.uuidString ?? "",
                "$LAST_RECORD": day.records.last?.id.uuidString ?? "",
                "$LAST_ITEM": day.records.last?.items.last?.id.uuidString ?? "",
                "$PENDING": active?.id.uuidString ?? "",
            ]
            for (key, value) in replacements { text = text.replacingOccurrences(of: key, with: value) }

            let result = handler.handle(tool: step.tool, arguments: Data(text.utf8), sessionDate: Fixtures.day)
            #expect(result.ok == step.expectOK, "\(step.note): \(String(describing: result.error))")
            #expect(result.error?.code == step.expectedError, "\(step.note)")
            // 模型的工具调用本身从不产生正式写入。
            #expect(try services.dayData.day(Fixtures.day).revision == day.revision, "\(step.note)")

            switch step.then {
            case "confirm": try services.pending.confirm(try #require(result.pendingId))
            case "cancel": try services.pending.cancel(try #require(result.pendingId))
            default: break
            }
        }

        // 午餐被删除，只剩按录入时刻记下的鸡蛋，营养由客户端按参考库计算。
        let day = try services.dayData.day(Fixtures.day)
        #expect(day.records.count == 1)
        let egg = try #require(day.records.first)
        #expect(egg.eventTime.precision == .defaultedEntryTime)
        #expect(egg.eventTime.timestamp == Fixtures.now)
        #expect(egg.items.first?.originalAmountText == "2 个鸡蛋、共 108g")
        #expect(egg.items.first?.snapshot.values.proteinG == dec("13.608"))
        #expect(try services.pending.active(on: Fixtures.day) == nil)
    }

    @Test func clientRecomputesReferenceNutritionAndNormalizesUnits() throws {
        let container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        let services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let handler = ProposalToolHandler(pending: services.pending, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let json = """
        {"requestId":"\(UUID().uuidString)","sessionDate":"2026-10-30","expectedRevision":0,"payload":{"intent":"create","record":{
          "items":[{"displayName":"牛奶","originalAmountText":"一杯 250ml","quantity":{"amount":250,"unit":"毫升"},"amountSource":"userStated",
                    "nutrition":{"source":"referenceFood","referenceFoodId":"vita.reference.milk.whole","values":{"energyKcal":1,"proteinG":1,"fatG":1,"carbohydrateG":1}}}]}}}
        """
        let result = handler.handle(tool: "proposeRecordChange", arguments: Data(json.utf8), sessionDate: Fixtures.day)
        let pending = try services.pending.pending(try #require(result.pendingId))
        let item = try #require(pending.preview?.items.first)
        #expect(item.quantity == Quantity(amount: 250, unit: .milliliter))
        // 250ml × 1.03 g/ml = 257.5g；61 kcal/100g → 157.075 kcal。
        #expect(item.snapshot.quantityUsed == Quantity(amount: dec("257.5"), unit: .gram))
        #expect(item.snapshot.values.energyKcal == dec("157.075"))
    }

    @Test func malformedAndUnknownCallsAreRejectedReadably() throws {
        let container = try AppContainer.inMemory()
        let services = AppServices(container: container)
        let handler = ProposalToolHandler(pending: services.pending)
        #expect(handler.handle(tool: "deleteEverything", arguments: Data("{}".utf8), sessionDate: Fixtures.day).error?.code == "unknownTool")
        #expect(handler.handle(tool: "proposeRecordChange", arguments: Data("{}".utf8), sessionDate: Fixtures.day).error?.code == "malformedArguments")
    }
}
