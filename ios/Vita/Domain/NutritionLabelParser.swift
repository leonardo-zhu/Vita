import Foundation

/// 文字识别得到的一行，坐标为 0–1 的归一化值，原点在左下（与 Vision 一致）。
struct RecognizedTextLine: Equatable, Codable, Sendable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// 从营养成分表中解析出的候选值。只是候选：交给模型或用户核对，经确认卡后才会成为 Food Version。
struct NutritionLabelCandidate: Equatable, Codable, Sendable {
    /// 计算基准，如每 100 g；没找到时为空。
    var basis: Quantity?
    /// 标签上的原始能量值（千焦），有的话保留，便于核对换算。
    var energyKJ: Decimal?
    var energyKcal: Decimal?
    var proteinG: Decimal?
    var fatG: Decimal?
    var carbohydrateG: Decimal?
    /// 需要人工留意的地方，如缺项、能量由千焦换算、同时存在每份与每 100g 两列。
    var warnings: [String]

    /// 四项齐全且有基准时才能直接作为版本草稿。
    var complete: FoodVersionBasis? {
        guard let basis, let energyKcal, let proteinG, let fatG, let carbohydrateG else { return nil }
        return FoodVersionBasis(
            quantity: basis,
            nutrients: NutrientValues(energyKcal: energyKcal, proteinG: proteinG, fatG: fatG, carbohydrateG: carbohydrateG)
        )
    }
}

/// 解析中国预包装食品营养成分表（GB 28050 格式：项目 / 每 100 克 / NRV%），兼容英文标签。
/// 文字识别常把同一行的各列识别成多段，因此先按坐标拼回表格行再匹配。
enum NutritionLabelParser {
    static let kilojoulesPerKilocalorie = Decimal(string: "4.184")!

    static func parse(_ lines: [RecognizedTextLine]) -> NutritionLabelCandidate {
        let rows = rows(from: lines).map(normalize)
        var candidate = NutritionLabelCandidate(warnings: [])

        candidate.basis = basis(in: rows)
        if candidate.basis == nil { candidate.warnings.append("没有找到“每100克/毫升”等计算基准") }
        if rows.contains(where: { $0.contains("每份") || $0.lowercased().contains("per serving") }),
           rows.contains(where: { $0.contains("每100") || $0.lowercased().contains("per 100") }) {
            candidate.warnings.append("标签同时有每份与每100克两列，已取每100克一列，请核对")
        }

        if let (value, unit) = value(in: rows, keywords: ["能量", "energy"], excluding: []) {
            if unit == "kj" {
                candidate.energyKJ = value
                candidate.energyKcal = rounded(value / kilojoulesPerKilocalorie, scale: 1)
                candidate.warnings.append("能量由千焦换算为千卡（÷4.184）")
            } else if unit == "kcal" {
                candidate.energyKcal = value
            }
        }
        candidate.proteinG = grams(in: rows, keywords: ["蛋白质", "protein"], excluding: [])
        candidate.fatG = grams(in: rows, keywords: ["脂肪", "fat"], excluding: ["饱和", "反式", "saturated", "trans"])
        candidate.carbohydrateG = grams(in: rows, keywords: ["碳水化合物", "碳水", "carbohydrate"], excluding: [])

        if candidate.complete == nil, let column = standardColumn(lines) {
            if candidate.energyKcal == nil {
                candidate.energyKJ = column.energyKJ
                candidate.energyKcal = column.energyKcal
                if column.energyKJ != nil { candidate.warnings.append("能量由千焦换算为千卡（÷4.184）") }
            }
            candidate.proteinG = candidate.proteinG ?? column.proteinG
            candidate.fatG = candidate.fatG ?? column.fatG
            candidate.carbohydrateG = candidate.carbohydrateG ?? column.carbohydrateG
            candidate.warnings.append("项目名称没认清，按国标顺序（能量、蛋白质、脂肪、碳水化合物）对应数值，请核对")
        }

        let missing = [
            ("能量", candidate.energyKcal), ("蛋白质", candidate.proteinG),
            ("脂肪", candidate.fatG), ("碳水化合物", candidate.carbohydrateG),
        ].filter { $0.1 == nil }.map(\.0)
        if !missing.isEmpty { candidate.warnings.append("没有识别到：" + missing.joined(separator: "、")) }
        return candidate
    }

    // MARK: - 拼行

    /// 中心纵坐标相近的片段视为同一行，行内按横坐标排序。
    static func rows(from lines: [RecognizedTextLine]) -> [String] {
        let sorted = lines.sorted { $0.y + $0.height / 2 > $1.y + $1.height / 2 }
        var rows: [[RecognizedTextLine]] = []
        for line in sorted {
            let mid = line.y + line.height / 2
            if let last = rows.last?.last, abs((last.y + last.height / 2) - mid) < min(last.height, line.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
    }

    /// 全角转半角、数字间的逗号视作小数点（“6,0 克”）。
    private static func normalize(_ row: String) -> String {
        let half = row.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? row
        return half.replacingOccurrences(of: #"(\d)[,，](\d)"#, with: "$1.$2", options: .regularExpression)
    }

    // MARK: - 按列兜底

    /// 项目名称常因字小或倾斜识别不出，数值列却清楚。GB 28050 规定按能量、蛋白质、脂肪、碳水化合物、钠排列，
    /// 所以“每100”表头下的数值列恰好是 能量 / 克 / 克 / 克（/ 毫克）时可以按顺序对应。
    /// 多出饱和脂肪、糖等子项时顺序对不上，宁可不填。
    private static func standardColumn(_ lines: [RecognizedTextLine]) -> NutritionLabelCandidate? {
        guard let header = lines.first(where: {
            let text = normalize($0.text).lowercased()
            return text.contains("每100") || text.contains("per 100")
        }) else { return nil }
        let pattern = #"^\s*(\d+(?:\.\d+)?)\s*(千焦|kj|千卡|大卡|kcal|毫克|mg|克|g)"#
        let cells: [(Decimal, String)] = lines
            .filter { line in
                let center = line.x + line.width / 2
                return line.y < header.y && center > header.x && center < header.x + header.width
            }
            .sorted { $0.y > $1.y }
            .compactMap { line in
                guard let match = normalize(line.text).lowercased().firstMatch(of: pattern),
                      let value = Decimal(string: match[0]) else { return nil }
                let unit = switch match[1] {
                case "千焦", "kj": "kj"
                case "千卡", "大卡", "kcal": "kcal"
                case "毫克", "mg": "mg"
                default: "g"
                }
                return (value, unit)
            }
        let units = cells.map(\.1)
        guard ["kj", "kcal"].contains(units.first), units.dropFirst().prefix(3) == ["g", "g", "g"],
              units.count == 4 || (units.count == 5 && units[4] == "mg")
        else { return nil }
        var column = NutritionLabelCandidate(warnings: [])
        if units[0] == "kj" {
            column.energyKJ = cells[0].0
            column.energyKcal = rounded(cells[0].0 / kilojoulesPerKilocalorie, scale: 1)
        } else {
            column.energyKcal = cells[0].0
        }
        column.proteinG = cells[1].0
        column.fatG = cells[2].0
        column.carbohydrateG = cells[3].0
        return column
    }

    // MARK: - 匹配

    private static func basis(in rows: [String]) -> Quantity? {
        let pattern = #"(?:每|per)\s*(\d+(?:\.\d+)?)\s*(克|g|毫升|ml)"#
        for row in rows {
            guard let match = row.lowercased().firstMatch(of: pattern) else { continue }
            guard let amount = Decimal(string: match[0]) else { continue }
            return Quantity(amount: amount, unit: ["毫升", "ml"].contains(match[1]) ? .milliliter : .gram)
        }
        return nil
    }

    private static func grams(in rows: [String], keywords: [String], excluding: [String]) -> Decimal? {
        guard let (value, unit) = value(in: rows, keywords: keywords, excluding: excluding) else { return nil }
        switch unit {
        case "g": return value
        case "mg": return value / 1000
        default: return nil
        }
    }

    /// 在含关键词的行里取关键词之后的第一个“数值 + 单位”。单位统一为 kj / kcal / g / mg。
    private static func value(in rows: [String], keywords: [String], excluding: [String]) -> (Decimal, String)? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(千焦|kj|千卡|大卡|kcal|毫克|mg|克|g)"#
        for row in rows {
            let lower = row.lowercased()
            guard let keyword = keywords.first(where: { lower.contains($0) }),
                  !excluding.contains(where: { lower.contains($0) }),
                  let range = lower.range(of: keyword)
            else { continue }
            let rest = String(lower[range.upperBound...])
            guard let match = rest.firstMatch(of: pattern), let value = Decimal(string: match[0]) else { continue }
            let unit = switch match[1] {
            case "千焦", "kj": "kj"
            case "千卡", "大卡", "kcal": "kcal"
            case "毫克", "mg": "mg"
            default: "g"
            }
            return (value, unit)
        }
        return nil
    }

    private static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }
}

private extension String {
    /// 返回第一个匹配的各捕获组。
    func firstMatch(of pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
