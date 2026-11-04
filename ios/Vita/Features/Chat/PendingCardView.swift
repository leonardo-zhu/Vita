import SwiftUI

/// 确认卡（PRD §3.6）：展示提案内容，确认后才写入正式数据。数值来自客户端计算的预览。
struct PendingCardView: View {
    let pending: PendingSnapshot
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch pending.preview {
            case .record(let preview): RecordPreviewContent(preview: preview)
            case .food(let preview): FoodPreviewContent(preview: preview)
            case nil: Text("待确认").font(.headline)
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

    private var confirmTitle: String {
        switch pending.preview {
        case .record(let preview): [.deleteRecord, .removeItem].contains(preview.kind) ? "确认删除" : "确认记录"
        case .food: "确认保存"
        case nil: "确认"
        }
    }
}

private struct RecordPreviewContent: View {
    let preview: ChangePreview

    var body: some View {
        header
        ForEach(preview.items) { ItemLine(item: $0) }
        ForEach(preview.removedItemNames, id: \.self) { name in
            Text(name).strikethrough().foregroundStyle(.secondary)
        }
        if !preview.items.isEmpty {
            Divider()
            HStack {
                Text("合计").font(.subheadline.weight(.semibold))
                Spacer()
                Text(DisplayFormat.energy(preview.totals.energyKcal))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            // 三大营养素各用 Data 页圆环的颜色。
            HStack(spacing: 14) {
                ForEach([Nutrient.proteinG, .fatG, .carbohydrateG], id: \.self) { nutrient in
                    HStack(spacing: 5) {
                        Circle().fill(VitaTheme.color(for: nutrient)).frame(width: 7, height: 7)
                        Text(nutrient.label).foregroundStyle(.secondary)
                        Text(DisplayFormat.grams(nutrient.value(in: preview.totals))).monospacedDigit()
                    }
                }
            }
            .font(VitaType.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// 餐次图标与名称在左，操作类型做成右侧的彩色标签，和 Data 页的记录卡一致。
    private var header: some View {
        let slot = MealSlot(preview.eventTime)
        let name = preview.recordLabel ?? slot.period.label
        let time = DisplayFormat.eventTime(preview.eventTime)
        return HStack(spacing: 10) {
            Image(systemName: slot.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(slot.tint)
                .frame(width: 34, height: 34)
                .background(slot.tint.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(VitaType.title)
                if time != name {
                    Text(time).font(VitaType.meta).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(title)
                .font(VitaType.meta.weight(.semibold))
                .foregroundStyle(kindTint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(kindTint.opacity(0.12), in: .capsule)
        }
    }

    private var kindTint: Color {
        switch preview.kind {
        case .create, .appendItems: VitaTheme.intake
        case .replaceItem: VitaTheme.protein
        case .removeItem, .deleteRecord: VitaTheme.caution
        }
    }

    private var title: String {
        switch preview.kind {
        case .create: "新增记录"
        case .appendItems: "追加到这条记录"
        case .replaceItem: "修改一项"
        case .removeItem: "移除一项"
        case .deleteRecord: "删除整条记录"
        }
    }
}

/// 新建个人食品或新版本：与记录卡同样的标题行（图标、品名、类型标签），来源做成小标签，
/// 营养值排成四列；新版本时在新值下方划掉旧值。
private struct FoodPreviewContent: View {
    let preview: FoodChangePreview

    private var tint: Color { preview.kind == .createProduct ? VitaTheme.fat : VitaTheme.protein }

    private var badge: String {
        switch preview.kind {
        case .createProduct: "存入食品库"
        case .addVersion: "更新营养数据"
        case .updateProduct: "改名称与叫法"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.productName).font(VitaType.title).lineLimit(2)
                let detail = [preview.brandOrSupplier, preview.package.map { "包装 " + DisplayFormat.quantity($0) }].compactMap { $0 }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(VitaType.meta).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(badge)
                .font(VitaType.meta.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tint.opacity(0.12), in: .capsule)
        }
        if preview.kind == .updateProduct {
            renameRows
        } else {
            nutrition
        }
    }

    /// 改名称、品牌、叫法：只列改了什么，营养值不变就不显示。
    @ViewBuilder private var renameRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let previous = preview.previous, previous.name != preview.productName {
                Text("原名 \(previous.name)").font(VitaType.meta).strikethrough().foregroundStyle(.tertiary)
            }
            if let previous = preview.previous, previous.brandOrSupplier != preview.brandOrSupplier {
                Text("品牌：\(previous.brandOrSupplier ?? "无") → \(preview.brandOrSupplier ?? "无")").font(VitaType.meta).foregroundStyle(.secondary)
            }
            Text(preview.aliases.isEmpty ? "没有常用叫法" : "也叫：" + preview.aliases.joined(separator: "、"))
                .font(VitaType.body)
            Text("营养数据不变。").font(VitaType.meta).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var nutrition: some View {
        if !preview.aliases.isEmpty {
            Text("也叫：" + preview.aliases.joined(separator: "、")).font(VitaType.meta).foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            Label(preview.version.sourceKind.label, systemImage: preview.version.sourceKind.symbol)
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: .capsule)
            Spacer()
            Text("每 " + DisplayFormat.quantity(preview.version.basis.quantity))
                .font(VitaType.meta.weight(.medium))
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 0) {
            ForEach(Nutrient.allCases, id: \.self) { nutrient in
                VStack(spacing: 3) {
                    Text(Self.value(nutrient, preview.version.basis.nutrients))
                        .font(.headline)
                        .monospacedDigit()
                    if let previous = preview.previousBasis {
                        Text(Self.value(nutrient, previous.nutrients))
                            .font(VitaType.meta)
                            .strikethrough()
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Circle().fill(VitaTheme.color(for: nutrient)).frame(width: 6, height: 6)
                        Text(Self.unitLabel(nutrient)).font(VitaType.meta).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 14))
        let extras = ExtraNutrient.allCases.compactMap { extra in
            preview.version.basis.nutrients.value(of: extra).map { "\(extra.label) \(DisplayFormat.extra($0, extra))" }
        }
        if !extras.isEmpty {
            Text(extras.joined(separator: " · ")).font(VitaType.meta).foregroundStyle(.secondary).monospacedDigit()
        }
        if let note = preview.version.sourceNote {
            Text(note).font(VitaType.meta).foregroundStyle(.secondary)
        }
    }

    private static func value(_ nutrient: Nutrient, _ values: NutrientValues) -> String {
        DisplayFormat.number(nutrient.value(in: values), digits: nutrient == .energyKcal ? 0 : 1)
    }

    private static func unitLabel(_ nutrient: Nutrient) -> String {
        nutrient == .energyKcal ? "千卡" : nutrient.label + " g"
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
        preview: .record(ChangePreview(kind: .create, recordLabel: "加餐", eventTime: time, items: [item], removedItemNames: []))
    )
    return ZStack(alignment: .bottom) {
        LinearGradient(colors: [.orange.opacity(0.4), .blue.opacity(0.3)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        PendingCardView(pending: pending, onConfirm: {}, onCancel: {}).padding()
    }
}
#endif
