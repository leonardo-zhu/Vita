import SwiftUI

/// 公共营养参考库浏览（只读）：按层与类别分组；搜索时先列出 Agent 精确查询会得到的候选，再列出名称包含查询词的条目。
struct ReferenceLibraryView: View {
    enum Tier: String, CaseIterable {
        case core = "精选"
        case extended = "扩展"
    }

    typealias Group = (category: String, foods: [ReferenceFood])

    let catalog: ReferenceFoodCatalog
    /// 分组与拼音排序只算一次；扩展层有上千条。
    private let coreGroups: [Group]
    private let extendedGroups: [Group]
    @State private var tier: Tier = .core
    @State private var query = ""

    init(catalog: ReferenceFoodCatalog) {
        self.catalog = catalog
        func groups(_ foods: [ReferenceFood]) -> [Group] {
            Dictionary(grouping: foods, by: \.category)
                .map { ($0.key, $0.value.sorted { $0.canonicalName.compare($1.canonicalName, locale: DisplayFormat.locale) == .orderedAscending }) }
                .sorted { ReferenceCategory.order($0.category) < ReferenceCategory.order($1.category) }
        }
        coreGroups = groups(catalog.all.filter { !$0.isExtended })
        extendedGroups = groups(catalog.all.filter(\.isExtended))
    }

    private static let partialLimit = 60

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if trimmed.isEmpty {
                    Picker("收录层", selection: $tier) {
                        ForEach(Tier.allCases, id: \.self) { tier in
                            Text("\(tier.rawValue) \(count(tier))").tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(tier == .core
                         ? "精选条目有人工整理的名称和别名，日常说法会优先命中这里。"
                         : "扩展条目按《中国食物成分表》原名自动整理，只有精选条目没有命中时才会用到，需要说出较完整的名称。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    ForEach(tier == .core ? coreGroups : extendedGroups, id: \.category) { group in
                        section(title: "\(ReferenceCategory.label(group.category)) · \(group.foods.count)", foods: group.foods)
                    }
                } else {
                    let results = catalog.browse(trimmed)
                    if results.exact.isEmpty && results.partial.isEmpty {
                        ContentUnavailableView.search(text: trimmed)
                    }
                    if !results.exact.isEmpty {
                        section(
                            title: "精确命中 \(results.exact.count) 条",
                            footer: results.exact.count > 1 ? "Agent 遇到多个候选时会先请你确认是哪一种。" : nil,
                            foods: results.exact
                        )
                    }
                    if !results.partial.isEmpty {
                        section(
                            title: "名称包含“\(trimmed)” · \(results.partial.count) 条",
                            footer: results.partial.count > Self.partialLimit
                                ? "只显示前 \(Self.partialLimit) 条，请输入更完整的名称。"
                                : "这些条目需要说出更完整的名称才会被 Agent 匹配到。",
                            foods: Array(results.partial.prefix(Self.partialLimit))
                        )
                    }
                }
            }
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle("公共营养参考库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索食材，如 鸡胸肉")
    }

    private func count(_ tier: Tier) -> Int {
        (tier == .core ? coreGroups : extendedGroups).reduce(0) { $0 + $1.foods.count }
    }

    private func section(title: String, footer: String? = nil, foods: [ReferenceFood]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 4)
            LazyVStack(spacing: 0) {
                ForEach(foods) { food in
                    NavigationLink {
                        ReferenceFoodDetailView(food: food)
                    } label: {
                        ReferenceFoodRow(food: food).padding(.vertical, 10).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if food.id != foods.last?.id { Divider() }
                }
            }
            .vitaCard(padding: 16)
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

private struct ReferenceFoodRow: View {
    let food: ReferenceFood

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(food.canonicalName)
                Text(ReferenceCategory.sourceLabel(food.source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(DisplayFormat.energy(food.nutrients.energyKcal)).monospacedDigit()
                Text("蛋白质 \(DisplayFormat.grams(food.nutrients.proteinG))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct ReferenceFoodDetailView: View {
    let food: ReferenceFood

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("每 100 g\(food.source.edibleFraction != nil ? " 可食部" : "")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ReferenceCategory.stateLabel(food.preparationState))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(VitaTheme.intake.opacity(0.12), in: .capsule)
                            .foregroundStyle(VitaTheme.intake)
                    }
                    NutrientGrid(values: food.nutrients)
                }
                .vitaCard(padding: 20)

                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "名称与别名", systemImage: "character.book.closed") {
                        Text(food.isExtended ? "扩展" : "精选").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(([food.canonicalName] + food.aliases).joined(separator: "、")).font(.subheadline)
                    Text(food.isExtended ? "精选条目都没有命中时，说出这些名称会命中这个条目。" : "说出这些名称时，Agent 会命中这个条目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .vitaCard(padding: 20)

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "数据来源", systemImage: "doc.text.magnifyingglass")
                    InfoRow(label: "来源", value: food.source.provider)
                    if let description = food.source.description {
                        InfoRow(label: "原始名称", value: description)
                    }
                    InfoRow(label: "编号", value: food.source.externalId)
                    InfoRow(label: "版本", value: food.source.retrievedFromRelease)
                    if let region = food.source.region {
                        InfoRow(label: "采样地", value: region)
                    }
                    if let edible = food.source.edibleFraction {
                        InfoRow(label: "可食部", value: DisplayFormat.percent(edible))
                    }
                    if let density = food.densityGPerMl {
                        InfoRow(label: "密度", value: "\(density.formatted()) g/ml")
                    }
                    ForEach(food.source.notes ?? [], id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(food.source.attribution)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .font(.subheadline)
                .vitaCard(padding: 20)
            }
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle(food.canonicalName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InfoRow: View {
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

/// 参考库类别与状态的中文名。
enum ReferenceCategory {
    private static let categories: [(key: String, label: String)] = [
        ("grain", "谷物主食"), ("tuber", "薯类"), ("legume", "豆类及豆制品"),
        ("poultry", "禽肉"), ("pork", "猪肉"), ("beef", "牛肉"), ("egg", "蛋类"),
        ("fish", "鱼类"), ("seafood", "虾蟹贝"), ("dairy", "奶类"),
        ("vegetable", "蔬菜"), ("mushroom", "菌菇"), ("fruit", "水果"),
        ("lamb", "羊肉"), ("meat", "其他畜肉"),
        ("nut", "坚果种子"), ("oil", "油脂"), ("condiment", "调味品"), ("other", "其他"),
    ]

    static func label(_ key: String) -> String {
        categories.first { $0.key == key }?.label ?? key
    }

    static func order(_ key: String) -> Int {
        categories.firstIndex { $0.key == key } ?? categories.count
    }

    static func stateLabel(_ state: String) -> String {
        switch state {
        case "raw": "生"
        case "cooked": "熟"
        case "roasted": "烤"
        case "boiled": "水煮"
        case "canned": "罐头"
        case "dried": "干制"
        case "asSold": "成品"
        default: state
        }
    }

    static func sourceLabel(_ source: ReferenceFood.Source) -> String {
        source.provider.hasPrefix("中国") ? "中国食物成分表" : source.provider
    }
}
