import Charts
import SwiftUI

/// 周视图：每日摄入柱状图与目标线、周平均，以及跳到某一天的入口。
struct WeekOverview: View {
    let week: WeekData
    let today: LocalDate
    let onSelectDay: (LocalDate) -> Void

    private var energyTarget: Decimal? {
        week.days.last { $0.date <= today }?.summary.goal?.targets.energyKcal
    }

    var body: some View {
        VStack(spacing: 16) {
            chartCard
            averagesCard
            daysCard
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(title: "每日摄入", systemImage: "chart.bar.fill") {
                Text("千卡").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(week.days) { day in
                    BarMark(
                        x: .value("日期", Self.weekday(day.date)),
                        y: .value("能量", NSDecimalNumber(decimal: day.summary.totals.energyKcal).doubleValue)
                    )
                    .foregroundStyle(barColor(day))
                    .cornerRadius(6)
                }
                if let energyTarget {
                    RuleMark(y: .value("目标", NSDecimalNumber(decimal: energyTarget).doubleValue))
                        .foregroundStyle(VitaTheme.intake.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("目标").font(.caption2).foregroundStyle(VitaTheme.intake)
                        }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
        .vitaCard(padding: 20)
    }

    private func barColor(_ day: DayData) -> Color {
        guard let target = day.summary.goal?.targets.energyKcal else { return VitaTheme.intake }
        return day.summary.totals.energyKcal > target ? VitaTheme.caution : VitaTheme.intake
    }

    private var averagesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(title: "本周平均", systemImage: "chart.line.uptrend.xyaxis") {
                Text("记录 \(week.recordedDays.count)/7 天").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                ForEach(Nutrient.allCases, id: \.self) { nutrient in
                    VStack(spacing: 4) {
                        Text(week.average(nutrient).map { $0.formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)) } ?? "--")
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
            Text("只按有记录的日子计算平均值。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .vitaCard(padding: 20)
    }

    private var daysCard: some View {
        VStack(spacing: 0) {
            ForEach(week.days.filter { $0.date <= today }.reversed()) { day in
                Button { onSelectDay(day.date) } label: {
                    HStack {
                        Text(DisplayFormat.date(day.date))
                        Spacer()
                        if day.records.isEmpty {
                            Text("未记录").foregroundStyle(.tertiary)
                        } else {
                            Text(DisplayFormat.energy(day.summary.totals.energyKcal)).monospacedDigit()
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if day.date != week.start { Divider() }
            }
        }
        .vitaCard(padding: 16)
    }

    private static func weekday(_ date: LocalDate) -> String {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        let offset = (0..<7).first { date.startOfWeek.adding(days: $0) == date } ?? 0
        return names[offset]
    }
}
