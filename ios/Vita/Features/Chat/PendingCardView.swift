import SwiftUI

/// 确认卡（PRD §3.6）：展示提案内容，确认后才写入正式数据。数值来自客户端计算的预览。
struct PendingCardView: View {
    let pending: PendingSnapshot
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let preview = pending.preview {
                ForEach(preview.items) { ItemLine(item: $0) }
                ForEach(preview.removedItemNames, id: \.self) { name in
                    Text(name)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                }
                if !preview.items.isEmpty {
                    Divider()
                    totals(preview.totals)
                }
            }
            HStack {
                Button("取消", role: .cancel, action: onCancel)
                    .glassButton()
                Spacer()
                Text(timerInterval: Date()...max(Date(), pending.expiresAt), countsDown: true)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("剩余有效时间")
                Spacer()
                Button(confirmTitle, action: onConfirm)
                    .glassButton(prominent: true)
            }
        }
        .padding(16)
        .glassCard()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let preview = pending.preview {
                Text([preview.recordLabel, DisplayFormat.eventTime(preview.eventTime)].compactMap { $0 }.uniqued().joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch pending.preview?.kind {
        case .create: "新增记录"
        case .appendItems: "追加到这条记录"
        case .replaceItem: "修改一项"
        case .removeItem: "移除一项"
        case .deleteRecord: "删除整条记录"
        case nil: "待确认"
        }
    }

    private var confirmTitle: String {
        pending.preview?.kind == .deleteRecord || pending.preview?.kind == .removeItem ? "确认删除" : "确认记录"
    }

    private func totals(_ values: NutrientValues) -> some View {
        HStack {
            Text("合计").font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(DisplayFormat.energy(values.energyKcal)) · 蛋白质 \(DisplayFormat.grams(values.proteinG))")
                .font(.subheadline)
                .monospacedDigit()
        }
    }
}

private struct ItemLine: View {
    let item: DayData.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayName)
                Text(item.originalAmountText).foregroundStyle(.secondary)
                Spacer()
                Text(DisplayFormat.energy(item.snapshot.values.energyKcal))
                    .monospacedDigit()
                    .strikethrough(!item.includeInSummary)
            }
            HStack(spacing: 6) {
                SourceBadge(source: item.snapshot.nutritionSource)
                if let quantity = item.quantity {
                    Text(DisplayFormat.quantity(quantity))
                }
                if !item.includeInSummary {
                    Text("不计入汇总")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let basis = item.snapshot.estimateBasis {
                Text(basis).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// AI 估算必须与可靠来源区分开（TDD §4.2）。
private struct SourceBadge: View {
    let source: NutritionSource

    var body: some View {
        Label(source.label, systemImage: source == .aiEstimated ? "sparkles" : "checkmark.seal")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(source == .aiEstimated ? Color.orange : Color.secondary)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

#if DEBUG
#Preview("确认卡") {
    let time = try! EventTime(localDate: LocalDate(isoString: "2026-10-30")!, precision: .mealPeriod, mealPeriod: .snack, timeZoneIdentifier: "Asia/Shanghai")
    let item = DayData.Item(
        id: UUID(), displayName: "原味酸奶", groupName: nil, originalAmountText: "1 杯", quantity: nil,
        amountSource: .aiEstimated, includeInSummary: true,
        snapshot: NutritionCalculator.estimatedSnapshot(
            values: NutrientValues(energyKcal: 140, proteinG: 6, fatG: 5, carbohydrateG: 16),
            estimateBasis: "按常见一杯 200g 原味酸奶估算", quantity: nil
        ),
        sourceLabel: nil
    )
    let pending = PendingSnapshot(
        id: UUID(), sessionDate: time.localDate, status: .readyForConfirmation, createdAt: .now,
        expiresAt: .now.addingTimeInterval(30 * 60),
        preview: ChangePreview(kind: .create, recordLabel: "加餐", eventTime: time, items: [item], removedItemNames: [])
    )
    return ZStack(alignment: .bottom) {
        LinearGradient(colors: [.orange.opacity(0.4), .blue.opacity(0.3)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        PendingCardView(pending: pending, onConfirm: {}, onCancel: {}).padding()
    }
}
#endif
