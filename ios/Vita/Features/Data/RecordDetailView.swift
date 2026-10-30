import SwiftUI

/// 一条记录的详情：每个 Item 的用量来源、营养来源、是否计入汇总与计算依据（PRD §3.5、TDD §10）。
struct RecordDetailView: View {
    let record: DayData.Record

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                ForEach(record.items) { ItemCard(item: $0) }
            }
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle(record.mealLabel ?? MealSlot(record.eventTime).period.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryCard: some View {
        let slot = MealSlot(record.eventTime)
        return VStack(alignment: .leading, spacing: 16) {
            CardHeader(title: DisplayFormat.eventTime(record.eventTime), systemImage: slot.symbol, tint: slot.tint)
            NutrientGrid(values: record.totals)
            if let note = record.note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .vitaCard(padding: 20)
    }
}

/// 能量与三大营养素的四格。
struct NutrientGrid: View {
    let values: NutrientValues

    var body: some View {
        HStack {
            ForEach(Nutrient.allCases, id: \.self) { nutrient in
                VStack(spacing: 4) {
                    Text(nutrient.value(in: values).formatted(.number.precision(.fractionLength(nutrient == .energyKcal ? 0 : 1)).rounded(rule: .toNearestOrAwayFromZero)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(VitaTheme.color(for: nutrient))
                    Text(nutrient == .energyKcal ? "千卡" : "\(nutrient.label) g")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ItemCard: View {
    let item: DayData.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let group = item.groupName {
                        Text(group).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.displayName).font(.headline)
                }
                Spacer()
                SourceTag(source: item.snapshot.nutritionSource)
            }
            NutrientGrid(values: item.snapshot.values)
            VStack(spacing: 10) {
                DetailRow(label: "原始用量", value: item.originalAmountText)
                if let quantity = item.quantity {
                    DetailRow(label: "标准化用量", value: DisplayFormat.quantity(quantity))
                }
                DetailRow(label: "用量来源", value: item.amountSource.label)
                if let label = item.sourceLabel {
                    DetailRow(label: "数据来源", value: label)
                }
                if let basis = item.snapshot.basisQuantity, let used = item.snapshot.quantityUsed {
                    DetailRow(label: "计算依据", value: "每 \(DisplayFormat.quantity(basis)) × \(DisplayFormat.quantity(used))")
                }
                if let estimateBasis = item.snapshot.estimateBasis {
                    DetailRow(label: "估算依据", value: estimateBasis)
                }
            }
            .font(.subheadline)
            if !item.includeInSummary {
                Label("不计入当日汇总", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .vitaCard(padding: 20)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

/// 营养来源标签；AI 估算用提醒色，与可靠来源区分开（TDD §4.2）。
struct SourceTag: View {
    let source: NutritionSource

    var body: some View {
        let tint = source == .aiEstimated ? VitaTheme.caution : VitaTheme.intake
        Label(source.label, systemImage: source == .aiEstimated ? "sparkles" : "checkmark.seal.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: .capsule)
    }
}
