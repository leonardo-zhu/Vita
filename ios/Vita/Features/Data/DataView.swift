import Observation
import SwiftUI

@MainActor
@Observable
final class DayDataModel {
    enum State {
        case loading
        case loaded(DayData)
        case failed(String)
    }

    private let service: DayDataService
    private let timeZone: () -> TimeZone
    private let now: () -> Date

    var date: LocalDate
    private(set) var state: State = .loading

    init(service: DayDataService, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.service = service
        self.now = now
        self.timeZone = timeZone
        self.date = LocalDate(date: now(), timeZone: timeZone())
    }

    var today: LocalDate { LocalDate(date: now(), timeZone: timeZone()) }

    func reload() {
        do {
            state = .loaded(try service.day(date))
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func shift(days: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let current = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        let next = calendar.date(byAdding: .day, value: days, to: current)!
        date = LocalDate(date: next, timeZone: calendar.timeZone)
    }
}

/// 只读的 Data 页（PRD §3.5）：当日摄入与目标、按时间排列的记录。修改走对话，不提供编辑表单。
struct DataView: View {
    @State private var model: DayDataModel
    @State private var isPickingDate = false

    init(service: DayDataService) {
        _model = State(initialValue: DayDataModel(service: service))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.date == model.today ? "今天" : DisplayFormat.date(model.date))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { dateToolbar }
                .sheet(isPresented: $isPickingDate) { datePicker }
        }
        .onAppear { model.reload() }
        .onChange(of: model.date) { model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("无法读取当天数据", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded(let day):
            List {
                Section("摄入与目标") {
                    ForEach(day.summary.progress, id: \.nutrient) { NutrientProgressRow(progress: $0) }
                    if day.summary.goal == nil {
                        Text("尚未设置目标").foregroundStyle(.secondary)
                    }
                    if day.summary.estimatedItemCount > 0 {
                        Label("其中 \(day.summary.estimatedItemCount) 项为 AI 估算", systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("记录") {
                    if day.records.isEmpty {
                        Text("这一天还没有记录").foregroundStyle(.secondary)
                    }
                    ForEach(day.records) { record in
                        NavigationLink {
                            RecordDetailView(record: record)
                        } label: {
                            RecordRow(record: record)
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var dateToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("前一天", systemImage: "chevron.left") { model.shift(days: -1) }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("选择日期", systemImage: "calendar") { isPickingDate = true }
            Button("后一天", systemImage: "chevron.right") { model.shift(days: 1) }
                .disabled(model.date >= model.today)
        }
    }

    private var datePicker: some View {
        NavigationStack {
            DatePicker(
                "日期",
                selection: Binding(
                    get: { Calendar.current.date(from: DateComponents(year: model.date.year, month: model.date.month, day: model.date.day)) ?? Date() },
                    set: { model.date = LocalDate(date: $0, timeZone: .current) }
                ),
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("今天") { model.date = model.today; isPickingDate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPickingDate = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct NutrientProgressRow: View {
    let progress: DaySummary.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress.nutrient.label)
                Spacer()
                Text(DisplayFormat.nutrient(progress.nutrient, progress.consumed))
                    .monospacedDigit()
                if let target = progress.target {
                    Text("/ " + DisplayFormat.nutrient(progress.nutrient, target))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = progress.fraction {
                ProgressView(value: min(NSDecimalNumber(decimal: fraction).doubleValue, 1))
                    .tint(fraction > 1 ? .orange : .accentColor)
                    .accessibilityValue(DisplayFormat.percent(fraction))
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RecordRow: View {
    let record: DayData.Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.mealLabel ?? DisplayFormat.eventTime(record.eventTime)).font(.headline)
                Spacer()
                Text(DisplayFormat.energy(record.totals.energyKcal))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let mealLabel = record.mealLabel, mealLabel != DisplayFormat.eventTime(record.eventTime) {
                Text(DisplayFormat.eventTime(record.eventTime)).font(.caption).foregroundStyle(.secondary)
            }
            Text(record.items.map(\.displayName).joined(separator: "、"))
                .font(.subheadline)
                .lineLimit(2)
        }
    }
}
