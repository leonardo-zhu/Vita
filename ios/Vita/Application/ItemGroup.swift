import Foundation

/// 一条记录里的 Item 按菜品名（`groupName`）归在一起显示，如“鸭血粉丝汤”下的粉丝、鸭血、鸭肉。
/// 同名的放进第一次出现的位置，保持原来的先后；没有菜品名的各自单独一项。
struct ItemGroup: Equatable, Identifiable {
    /// nil：不属于任何菜品的单独一项。
    let name: String?
    let items: [DayData.Item]

    var id: String { name.map { "group:\($0)" } ?? "item:\(items[0].id.uuidString)" }

    /// 只有一项且名字就是菜名（如“番茄炒蛋”只记了一项）时不必再加一行菜名。
    var showsHeader: Bool {
        guard let name else { return false }
        return items.count > 1 || items[0].displayName != name
    }

    /// 计入汇总的那几项的能量。
    var energyKcal: Decimal {
        items.filter(\.includeInSummary).reduce(0) { $0 + $1.snapshot.values.energyKcal }
    }

    static func groups(_ items: [DayData.Item]) -> [ItemGroup] {
        var members: [String: [DayData.Item]] = [:]
        var result: [(key: String?, single: DayData.Item?)] = []
        for item in items {
            let name = item.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else {
                result.append((nil, item))
                continue
            }
            if members[name] == nil {
                result.append((name, nil))
            }
            members[name, default: []].append(item)
        }
        return result.map { entry in
            if let key = entry.key { ItemGroup(name: key, items: members[key] ?? []) } else { ItemGroup(name: nil, items: [entry.single!]) }
        }
    }
}
