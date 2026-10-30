import SwiftUI

/// Data 面板的 Nutrition 部分（PRD §3.5）：个人 Nutrition DB 与公共参考库的收录情况。只读，修改走对话。
struct NutritionLibraryView: View {
    let services: AppServices
    @State private var products: [FoodProductSummary] = []
    @State private var failure: String?

    /// 最近添加或更新版本的几项。
    private var recent: [FoodProductSummary] {
        Array(products.sorted { ($0.activeVersion?.createdAt ?? .distantPast) > ($1.activeVersion?.createdAt ?? .distantPast) }.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("个人食品库").font(.title3.weight(.semibold)).padding(.horizontal, 4)
                // 首页只放摘要：总数与最近添加的几项；完整列表与搜索在下一页，食品多了这里也不会变长。
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(title: products.isEmpty ? "还没有个人食品" : "共 \(products.count) 个食品", systemImage: "takeoutbag.and.cup.and.straw")
                        .padding(.bottom, 8)
                    if products.isEmpty {
                        Text("拍下营养标签或在对话里告诉 Vita 即可添加。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recent) { product in
                        Divider()
                        NavigationLink {
                            FoodProductDetailView(product: product, labels: services.labels)
                        } label: {
                            ProductRow(product: product).padding(.vertical, 12).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if products.count > recent.count {
                        Divider()
                        NavigationLink {
                            PersonalFoodListView(products: products, labels: services.labels)
                        } label: {
                            HStack {
                                Text("查看全部 \(products.count) 个").foregroundStyle(VitaTheme.intake)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.top, 12)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .vitaCard(padding: 16)
                Text("只收录有可靠营养数据的具体产品；AI 估算不会存进这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                Text("公共营养参考库").font(.title3.weight(.semibold)).padding(.horizontal, 4).padding(.top, 8)
                NavigationLink {
                    ReferenceLibraryView(catalog: services.container.referenceFoods)
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "精选 \(services.container.referenceFoods.coreCount) · 扩展 \(services.container.referenceFoods.count - services.container.referenceFoods.coreCount)", systemImage: "books.vertical") {
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        // reference-food-library.md §6 要求的署名。
                        Text("公共营养参考值来源于条目所标示的食物成分数据源；USDA FoodData Central 数据采用 CC0 1.0。数值仅作通用食材参考，不等同于具体商品营养标签或医疗建议。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .vitaCard()
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle("营养库")
        .onAppear(perform: reload)
        .overlay {
            if let failure {
                ContentUnavailableView("无法读取营养库", systemImage: "exclamationmark.triangle", description: Text(failure))
            }
        }
    }

    private func reload() {
        do {
            products = try services.foods.products()
            failure = nil
        } catch {
            failure = String(describing: error)
        }
    }
}

private struct ProductRow: View {
    let product: FoodProductSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(product.name).font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            let details = [product.brandOrSupplier, product.package.map { "包装 " + DisplayFormat.quantity($0) }].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let basis = product.activeVersion?.basis {
                Text("每 \(DisplayFormat.quantity(basis.quantity))：\(DisplayFormat.energy(basis.nutrients.energyKcal)) · 蛋白质 \(DisplayFormat.grams(basis.nutrients.proteinG))")
                    .font(.subheadline)
                    .monospacedDigit()
            }
        }
    }
}

/// 个人食品库完整列表，按名称拼音排序，可搜索名称或品牌。
private struct PersonalFoodListView: View {
    let products: [FoodProductSummary]
    let labels: LabelScanService
    @State private var query = ""

    private var filtered: [FoodProductSummary] {
        let key = ReferenceFoodCatalog.normalize(query)
        let sorted = products.sorted { $0.name.compare($1.name, locale: DisplayFormat.locale) == .orderedAscending }
        guard !key.isEmpty else { return sorted }
        return sorted.filter { [$0.name, $0.brandOrSupplier ?? ""].contains { ReferenceFoodCatalog.normalize($0).contains(key) } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(filtered) { product in
                    NavigationLink {
                        FoodProductDetailView(product: product, labels: labels)
                    } label: {
                        ProductRow(product: product).padding(.vertical, 12).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if product.id != filtered.last?.id { Divider() }
                }
            }
            .vitaCard(padding: 16)
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle("个人食品库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索名称或品牌")
    }
}

private struct FoodProductDetailView: View {
    let product: FoodProductSummary
    let labels: LabelScanService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let note = product.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                ForEach(product.versions) { version in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(version.retiredAt == nil ? "当前版本" : "历史版本 · \(version.createdAt.formatted(.dateTime.year().month().day().locale(DisplayFormat.locale)))")
                                .font(.headline)
                            Spacer()
                            Label(version.sourceKind.label, systemImage: version.sourceKind.symbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let reference = version.labelImageReference,
                           let data = try? labels.imageData(reference),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(.rect(cornerRadius: 12))
                        }
                        Text("每 " + DisplayFormat.quantity(version.basis.quantity)).font(.subheadline).foregroundStyle(.secondary)
                        NutrientGrid(values: version.basis.nutrients)
                        if let note = version.sourceNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .vitaCard(padding: 20)
                    .opacity(version.retiredAt == nil ? 1 : 0.7)
                }
            }
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle(product.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
