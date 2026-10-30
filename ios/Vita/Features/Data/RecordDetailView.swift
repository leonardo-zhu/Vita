import SwiftUI

/// 一条记录的详情：每个 Item 的用量来源、营养来源、是否计入汇总与计算依据（PRD §3.5、TDD §10）。
struct RecordDetailView: View {
    let record: DayData.Record

    var body: some View {
        List {
            Section {
                LabeledContent("时间", value: DisplayFormat.eventTime(record.eventTime))
                if let note = record.note {
                    LabeledContent("备注", value: note)
                }
                ForEach(Nutrient.allCases, id: \.self) { nutrient in
                    LabeledContent(nutrient.label, value: DisplayFormat.nutrient(nutrient, nutrient.value(in: record.totals)))
                        .monospacedDigit()
                }
            }
            ForEach(record.items) { item in
                Section(item.groupName.map { "\($0) · \(item.displayName)" } ?? item.displayName) {
                    ItemDetail(item: item)
                }
            }
        }
        .navigationTitle(record.mealLabel ?? "记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ItemDetail: View {
    let item: DayData.Item

    var body: some View {
        LabeledContent("原始用量", value: item.originalAmountText)
        if let quantity = item.quantity {
            LabeledContent("标准化用量", value: DisplayFormat.quantity(quantity))
        }
        LabeledContent("用量来源", value: item.amountSource.label)
        LabeledContent("营养来源") {
            VStack(alignment: .trailing) {
                Text(item.snapshot.nutritionSource.label)
                if let label = item.sourceLabel {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let basis = item.snapshot.basisQuantity, let used = item.snapshot.quantityUsed {
            LabeledContent("计算依据", value: "每 \(DisplayFormat.quantity(basis)) × \(DisplayFormat.quantity(used))")
        }
        if let estimateBasis = item.snapshot.estimateBasis {
            LabeledContent("估算依据", value: estimateBasis)
        }
        ForEach(Nutrient.allCases, id: \.self) { nutrient in
            LabeledContent(nutrient.label, value: DisplayFormat.nutrient(nutrient, nutrient.value(in: item.snapshot.values)))
                .monospacedDigit()
        }
        if !item.includeInSummary {
            Label("不计入当日汇总", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
