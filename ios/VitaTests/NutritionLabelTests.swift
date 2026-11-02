import Foundation
import Testing
@testable import Vita

/// 按表格行生成识别结果：每列一段，模拟文字识别把同一行拆开。
private func table(_ rows: [[String]]) -> [RecognizedTextLine] {
    rows.enumerated().flatMap { index, row in
        row.enumerated().map { column, text in
            // 行内各段的纵坐标略有抖动，仍应拼回同一行。
            RecognizedTextLine(text: text, x: 0.05 + Double(column) * 0.35, y: 0.9 - Double(index) * 0.1 + Double(column) * 0.005, width: 0.3, height: 0.05)
        }
    }
}

struct NutritionLabelParserTests {
    @Test func parsesChineseLabelSplitIntoColumns() {
        let candidate = NutritionLabelParser.parse(table([
            ["项目", "每100克", "NRV%"],
            ["能量", "1720千焦", "20%"],
            ["蛋白质", "12.5克", "21%"],
            ["脂肪", "18.0克", "30%"],
            ["—饱和脂肪", "6.2克", "31%"],
            ["碳水化合物", "52.3克", "17%"],
            ["钠", "380毫克", "19%"],
        ]))
        #expect(candidate.basis == Quantity(amount: 100, unit: .gram))
        #expect(candidate.energyKJ == 1720)
        #expect(candidate.energyKcal == dec("411.1"))
        #expect(candidate.proteinG == dec("12.5"))
        #expect(candidate.fatG == 18)
        #expect(candidate.carbohydrateG == dec("52.3"))
        #expect(candidate.complete != nil)
        #expect(candidate.warnings.contains { $0.contains("千焦") })
    }

    @Test func handlesVolumeBasisKcalAndOCRQuirks() {
        let candidate = NutritionLabelParser.parse(table([
            ["营养成分表"],
            ["项目", "每100ml"],
            ["能量", "６５ 千卡"],
            ["蛋白质", "3,2 g"],
            ["脂肪", "3.6g"],
            ["碳水化合物", "4.8g"],
        ]))
        #expect(candidate.basis == Quantity(amount: 100, unit: .milliliter))
        #expect(candidate.energyKcal == 65)
        #expect(candidate.energyKJ == nil)
        #expect(candidate.proteinG == dec("3.2"))
    }

    @Test func englishLabelAndServingColumnWarning() {
        let candidate = NutritionLabelParser.parse(table([
            ["Nutrition", "Per 100 g", "Per serving (30 g)"],
            ["Energy", "1880 kJ", "564 kJ"],
            ["Protein", "8.0 g", "2.4 g"],
            ["Fat", "20 g", "6 g"],
            ["Saturated fat", "9 g", "2.7 g"],
            ["Carbohydrate", "60 g", "18 g"],
        ]))
        #expect(candidate.basis == Quantity(amount: 100, unit: .gram))
        #expect(candidate.fatG == 20)
        #expect(candidate.energyKcal == dec("449.3"))
        #expect(candidate.warnings.contains { $0.contains("每份") })
    }

    @Test func reportsMissingItemsInsteadOfGuessing() {
        let candidate = NutritionLabelParser.parse(table([["能量", "300千焦"], ["蛋白质", "2克"]]))
        #expect(candidate.basis == nil)
        #expect(candidate.complete == nil)
        #expect(candidate.warnings.contains { $0.contains("计算基准") })
        #expect(candidate.warnings.contains { $0.contains("脂肪") && $0.contains("碳水化合物") })
    }

    /// 真机拍的圣农鸡腿块标签（2026-11-02）：项目名称字小，只识别出“项目”“质”和错字“露水化合物”，数值列完整。
    @Test func fallsBackToStandardOrderWhenItemNamesAreUnreadable() {
        let line = { (text: String, x: Double, y: Double, width: Double) in
            RecognizedTextLine(text: text, x: x, y: y, width: width, height: 0.015)
        }
        let candidate = NutritionLabelParser.parse([
            line("营养成分表", 0.438, 0.294, 0.129),
            line("每100克（g）", 0.439, 0.269, 0.098),
            line("营养素参考值%", 0.546, 0.275, 0.111),
            line("项目", 0.335, 0.256, 0.044),
            line("523千焦（K）", 0.439, 0.245, 0.093),
            line("6%", 0.628, 0.253, 0.025),
            line("16.9克（g）", 0.439, 0.229, 0.083),
            line("28%", 0.620, 0.238, 0.037),
            line("质", 0.370, 0.221, 0.023),
            line("6.3克（9）", 0.442, 0.217, 0.070),
            line("10%", 0.622, 0.224, 0.035),
            line("0克（g）", 0.442, 0.203, 0.060),
            line("0%", 0.632, 0.209, 0.029),
            line("露水化合物", 0.335, 0.179, 0.093),
            line("74毫克（mg）", 0.440, 0.186, 0.103),
            line("4%", 0.634, 0.193, 0.029),
        ])
        #expect(candidate.basis == Quantity(amount: 100, unit: .gram))
        #expect(candidate.energyKJ == 523)
        #expect(candidate.energyKcal == 125)
        #expect(candidate.proteinG == dec("16.9"))
        #expect(candidate.fatG == dec("6.3"))
        #expect(candidate.carbohydrateG == 0)
        #expect(candidate.warnings.contains { $0.contains("国标顺序") })
        #expect(!candidate.warnings.contains { $0.contains("没有识别到") })
    }

    @Test func standardOrderFallbackSkipsColumnsWithExtraRows() {
        let rows = [["每100克"], ["1720千焦"], ["12.5克"], ["18.0克"], ["6.2克"], ["52.3克"], ["380毫克"]]
        let candidate = NutritionLabelParser.parse(table(rows))
        #expect(candidate.complete == nil)
        #expect(!candidate.warnings.contains { $0.contains("国标顺序") })
    }

    /// 真实的 Vision 识别：渲染一张标签图片再识别，验证拼行与解析在实际输出上成立。
    @Test func visionRecognizesRenderedSampleLabel() async throws {
        let lines = try await VisionTextRecognizer().recognize(SampleLabelImage.render())
        let candidate = NutritionLabelParser.parse(lines)
        #expect(candidate.basis == Quantity(amount: 100, unit: .gram))
        #expect(candidate.energyKcal == dec("411.1"))
        #expect(candidate.proteinG == dec("12.5"))
        #expect(candidate.fatG == 18)
        #expect(candidate.carbohydrateG == dec("52.3"))
    }
}

@MainActor
struct LabelScanServiceTests {
    @Test func keepsImageLocallyAndRecordsScan() async throws {
        let images = InMemoryLabelImageStore()
        var container = try AppContainer.inMemory()
        container.labelImages = images
        container.textRecognizer = StubTextRecognizer(lines: table([["每100克"], ["能量", "100千卡"], ["蛋白质", "1克"], ["脂肪", "1克"], ["碳水化合物", "1克"]]))
        let services = AppServices(container: container)

        let result = try await services.labels.scan(Data("image".utf8))
        #expect(try images.load(result.imageReference) == Data("image".utf8))
        #expect(result.candidate.complete?.nutrients.energyKcal == 100)
        #expect(try services.labels.imageReference(forScan: result.scanID) == result.imageReference)
    }

    @Test func failedRecognitionDropsTheImage() async throws {
        struct Failing: TextRecognizer {
            func recognize(_ imageData: Data) async throws -> [RecognizedTextLine] { throw CocoaError(.featureUnsupported) }
        }
        let images = InMemoryLabelImageStore()
        var container = try AppContainer.inMemory()
        container.labelImages = images
        container.textRecognizer = Failing()
        let services = AppServices(container: container)
        await #expect(throws: CocoaError.self) { try await services.labels.scan(Data("x".utf8)) }
    }
}
