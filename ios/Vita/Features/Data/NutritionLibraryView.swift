import SwiftUI

/// Data 面板的 Nutrition 部分（PRD §3.5）：个人 Nutrition DB 与公共参考库的收录情况。个人食品可以在详情页直接改或删除（M4）。
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
                            FoodProductDetailView(product: product, services: services) { Task { await reload() } }
                        } label: {
                            ProductRow(product: product).padding(.vertical, 12).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if products.count > recent.count {
                        Divider()
                        NavigationLink {
                            PersonalFoodListView(products: products, services: services) { Task { await reload() } }
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
        .task { await reload() }
        .overlay {
            if let failure {
                ContentUnavailableView("无法读取营养库", systemImage: "exclamationmark.triangle", description: Text(failure))
            }
        }
    }

    private func reload() async {
        do {
            products = try await services.foods.products()
            failure = nil
        } catch let error as APIError {
            failure = error.userMessage
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
    let services: AppServices
    let onChange: () -> Void
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
                        FoodProductDetailView(product: product, services: services, onChange: onChange)
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
    let services: AppServices
    let onChange: () -> Void
    @State private var product: FoodProductSummary
    @State private var isEditingInfo = false
    @State private var isEditingNutrition = false
    @State private var isConfirmingDelete = false
    @State private var isSaving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(product: FoodProductSummary, services: AppServices, onChange: @escaping () -> Void) {
        self.services = services
        self.onChange = onChange
        _product = State(initialValue: product)
    }

    private var labels: LabelScanService { services.labels }

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
                        if let reference = version.labelImageReference {
                            LabelImage(reference: reference, labels: labels)
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
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("编辑", systemImage: "ellipsis") {
                    Button("修改名称与包装", systemImage: "pencil") { isEditingInfo = true }
                    Button("修改营养值", systemImage: "chart.bar.doc.horizontal") { isEditingNutrition = true }
                    Button("删除这个食品", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                }
            }
        }
        .sheet(isPresented: $isEditingInfo) {
            FoodInfoEditor(product: product) { name, brand, package in
                save { try await services.foods.update(product.id, name: name, brandOrSupplier: brand, package: package) }
            }
        }
        .sheet(isPresented: $isEditingNutrition) {
            FoodNutritionEditor(basis: product.activeVersion?.basis) { basis, note in
                save { try await services.foods.addVersion(product.id, expectedActiveVersionID: product.activeVersion?.id, basis: basis, sourceNote: note) }
            }
        }
        .confirmationDialog("删除“\(product.name)”？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { delete() }
        } message: {
            Text("删除后不再出现在食品库里，Vita 也不会再用它；已经记下的饮食不受影响。")
        }
        .alert("没有保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func save(_ operation: @escaping () async throws -> FoodProductSummary) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                product = try await operation()
                onChange()
            } catch let error as APIError {
                failure = error.userMessage
                if let latest = try? await services.foods.product(product.id) { product = latest }
            } catch {
                failure = String(describing: error)
            }
        }
    }

    private func delete() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await services.foods.delete(product.id)
                onChange()
                dismiss()
            } catch let error as APIError {
                failure = error.userMessage
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

/// 改名称、品牌、包装规格。
private struct FoodInfoEditor: View {
    let onSave: (String, String?, Quantity?) -> Void
    @State private var name: String
    @State private var brand: String
    @State private var packageAmount: String
    @State private var packageUnit: QuantityUnit
    @Environment(\.dismiss) private var dismiss

    init(product: FoodProductSummary, onSave: @escaping (String, String?, Quantity?) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: product.name)
        _brand = State(initialValue: product.brandOrSupplier ?? "")
        _packageAmount = State(initialValue: product.package.map { "\($0.amount)" } ?? "")
        _packageUnit = State(initialValue: product.package?.unit ?? .gram)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var package: Quantity? {
        Decimal(string: packageAmount.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? Quantity(amount: $0, unit: packageUnit) : nil }
    }
    /// 包装填了但不是正数时不让保存。
    private var isValid: Bool { !trimmedName.isEmpty && (packageAmount.trimmingCharacters(in: .whitespaces).isEmpty || package != nil) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                TextField("品牌（可不填）", text: $brand)
                Section("包装规格（可不填）") {
                    HStack {
                        TextField("如 950", text: $packageAmount).keyboardType(.decimalPad)
                        UnitPicker(unit: $packageUnit)
                    }
                }
            }
            .navigationTitle("修改名称与包装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmedName, trimmedBrand.isEmpty ? nil : trimmedBrand, package)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

/// 手动改营养值：存为新版本，旧版本保留在历史里，已有记录不变。
private struct FoodNutritionEditor: View {
    let onSave: (FoodVersionBasis, String?) -> Void
    @State private var basisAmount: String
    @State private var basisUnit: QuantityUnit
    @State private var values: [Nutrient: String]
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    init(basis: FoodVersionBasis?, onSave: @escaping (FoodVersionBasis, String?) -> Void) {
        self.onSave = onSave
        _basisAmount = State(initialValue: basis.map { "\($0.quantity.amount)" } ?? "100")
        _basisUnit = State(initialValue: basis?.quantity.unit ?? .gram)
        var initial: [Nutrient: String] = [:]
        for nutrient in Nutrient.allCases {
            initial[nutrient] = basis.map { "\(nutrient.value(in: $0.nutrients))" } ?? ""
        }
        _values = State(initialValue: initial)
    }

    private func number(_ text: String?) -> Decimal? {
        guard let text, let value = Decimal(string: text.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }

    private var basis: FoodVersionBasis? {
        guard let amount = number(basisAmount), amount > 0,
              let energy = number(values[.energyKcal]), let protein = number(values[.proteinG]),
              let fat = number(values[.fatG]), let carbohydrate = number(values[.carbohydrateG])
        else { return nil }
        return FoodVersionBasis(
            quantity: Quantity(amount: amount, unit: basisUnit),
            nutrients: NutrientValues(energyKcal: energy, proteinG: protein, fatG: fat, carbohydrateG: carbohydrate)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("每") {
                    HStack {
                        TextField("100", text: $basisAmount).keyboardType(.decimalPad)
                        UnitPicker(unit: $basisUnit)
                    }
                }
                Section("含") {
                    ForEach(Nutrient.allCases, id: \.self) { nutrient in
                        HStack {
                            Text(nutrient.label)
                            TextField("0", text: Binding(get: { values[nutrient] ?? "" }, set: { values[nutrient] = $0 }))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text(nutrient == .energyKcal ? "千卡" : "g").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    TextField("改动说明（可不填）", text: $note)
                } footer: {
                    Text("保存为新版本并立即生效；旧版本留在历史里，已经记下的饮食不变。")
                }
            }
            .navigationTitle("修改营养值")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let basis else { return }
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(basis, trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                    .disabled(basis == nil)
                }
            }
        }
    }
}

private struct UnitPicker: View {
    @Binding var unit: QuantityUnit

    var body: some View {
        Picker("单位", selection: $unit) {
            ForEach(QuantityUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 110)
    }
}

/// 食品版本的标签照片，从 Vita 服务读取。
private struct LabelImage: View {
    let reference: String
    let labels: LabelScanService
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(.rect(cornerRadius: 12))
            }
        }
        .task(id: reference) {
            if let data = await labels.imageData(reference) { image = UIImage(data: data) }
        }
    }
}
