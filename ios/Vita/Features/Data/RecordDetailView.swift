import SwiftUI

/// 一条记录的详情：每个 Item 的用量来源、营养来源、是否计入汇总与计算依据（PRD §3.5、TDD §10）。
/// 可以直接改时间、改某一项的用量、删掉某一项或整条记录（M4）：用户亲手改，不经确认卡。
struct RecordDetailView: View {
    let services: AppServices
    /// 编辑后通知 Data 页刷新汇总。
    let onChange: () -> Void
    private let recordID: UUID
    @State private var day: DayData
    @State private var isEditingTime = false
    @State private var editingItem: DayData.Item?
    @State private var deletingItem: DayData.Item?
    @State private var isConfirmingDelete = false
    @State private var isSaving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(services: AppServices, day: DayData, record: DayData.Record, onChange: @escaping () -> Void) {
        self.services = services
        self.onChange = onChange
        recordID = record.id
        _day = State(initialValue: day)
    }

    private var record: DayData.Record? { day.records.first { $0.id == recordID } }

    var body: some View {
        Group {
            if let record {
                ScrollView {
                    VStack(spacing: 16) {
                        summaryCard(record)
                        ForEach(record.items) { item in
                            ItemCard(item: item, onEdit: { editingItem = item }, onDelete: { deletingItem = item })
                        }
                    }
                    .padding(16)
                }
                .navigationTitle(record.mealLabel ?? MealSlot(record.eventTime).period.label)
            } else {
                ContentUnavailableView("这条记录已删除", systemImage: "trash")
            }
        }
        .background { VitaTheme.background }
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if record != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("编辑", systemImage: "ellipsis") {
                        Button("修改时间", systemImage: "clock") { isEditingTime = true }
                        Button("删除整条记录", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                    }
                }
            }
        }
        .sheet(isPresented: $isEditingTime) {
            if let record {
                TimeEditor(eventTime: record.eventTime) { time in save { try await services.dayData.updateRecord(on: day.date, revision: day.revision, recordID: recordID, eventTime: time) } }
            }
        }
        .sheet(item: $editingItem) { item in
            AmountEditor(item: item) { quantity, factor in
                save {
                    try await services.dayData.rescaleItem(
                        on: day.date, revision: day.revision, recordID: recordID, itemID: item.id,
                        quantity: quantity, factor: factor, originalAmountText: nil
                    )
                }
            }
        }
        .confirmationDialog("删除整条记录？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteRecord() }
        } message: {
            Text("这一餐的所有内容都会删除，Apple 健康里对应的数据也会一并删除。")
        }
        .confirmationDialog(
            "删除“\(deletingItem?.displayName ?? "")”？",
            isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = deletingItem { deleteItem(item) }
            }
        }
        .alert("没有保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func summaryCard(_ record: DayData.Record) -> some View {
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

    private func deleteItem(_ item: DayData.Item) {
        // 只剩这一项时，删掉它就是删掉整条记录。
        if record?.items.count == 1 { return deleteRecord() }
        save { try await services.dayData.deleteItem(on: day.date, revision: day.revision, recordID: recordID, itemID: item.id) }
    }

    private func deleteRecord() {
        save { try await services.dayData.deleteRecord(on: day.date, revision: day.revision, recordID: recordID) }
    }

    private func save(_ operation: @escaping () async throws -> DayData) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                day = try await operation()
                onChange()
                if record == nil { dismiss() }
            } catch let error as APIError {
                failure = error.userMessage
                // 多半是别处改过（revision 变了）：取最新的，下次再改就基于它。
                if let latest = try? await services.dayData.day(day.date) { day = latest }
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

/// 改时间：只改时分，日期不变（记录不能跨出所在的那一天）。
private struct TimeEditor: View {
    let eventTime: EventTime
    let onSave: (EventTime) -> Void
    @State private var time: Date
    @Environment(\.dismiss) private var dismiss

    init(eventTime: EventTime, onSave: @escaping (EventTime) -> Void) {
        self.eventTime = eventTime
        self.onSave = onSave
        _time = State(initialValue: eventTime.representativeTimestamp)
    }

    private var timeZone: TimeZone { TimeZone(identifier: eventTime.timeZoneIdentifier) ?? .current }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            .environment(\.timeZone, timeZone)
            .navigationTitle("修改时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let updated = try? EventTime(localDate: eventTime.localDate, precision: .exact, timestamp: time, timeZoneIdentifier: eventTime.timeZoneIdentifier) {
                            onSave(updated)
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 改用量：有克数、毫升数时直接填新用量；只有“一份”这类时填倍数。
private struct AmountEditor: View {
    let item: DayData.Item
    let onSave: (Quantity?, Decimal?) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(item: DayData.Item, onSave: @escaping (Quantity?, Decimal?) -> Void) {
        self.item = item
        self.onSave = onSave
        _text = State(initialValue: item.quantity.map { "\($0.amount)" } ?? "1")
    }

    private var value: Decimal? {
        guard let number = Decimal(string: text.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
        return number
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("原来") { Text(item.originalAmountText) }
                    HStack {
                        TextField(item.quantity == nil ? "倍数" : "用量", text: $text)
                            .keyboardType(.decimalPad)
                        Text(item.quantity.map { $0.unit.rawValue } ?? "倍").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(item.quantity == nil ? "这一项没有克数，按倍数缩放营养值：吃了两份填 2，半份填 0.5。" : "营养值按这一项记录时的数据重新计算。")
                }
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let value else { return }
                        if let quantity = item.quantity {
                            onSave(Quantity(amount: value, unit: quantity.unit), nil)
                        } else {
                            onSave(nil, value)
                        }
                        dismiss()
                    }
                    .disabled(value == nil)
                }
            }
        }
        .presentationDetents([.medium])
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
    let onEdit: () -> Void
    let onDelete: () -> Void

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
                ForEach(ExtraNutrient.allCases.filter { item.snapshot.values.value(of: $0) != nil }, id: \.self) { extra in
                    DetailRow(label: extra.label, value: DisplayFormat.extra(item.snapshot.values.value(of: extra)!, extra))
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
            HStack {
                Button("改用量", systemImage: "pencil", action: onEdit)
                Spacer()
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
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
