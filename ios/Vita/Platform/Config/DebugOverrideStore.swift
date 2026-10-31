import Foundation

/// L3 本地调试覆盖的存储（vita-admin.md §9）：非敏感，只存本机，不上传。
enum DebugOverrideStore {
    static let key = "vita.config.override"

    static func load(from defaults: UserDefaults = .standard) -> ConfigOverride? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ConfigOverride.self, from: data)
    }

    /// 全部字段为空时清除。
    static func save(_ override: ConfigOverride?, to defaults: UserDefaults = .standard) {
        guard let override, override != ConfigOverride(), let data = try? JSONEncoder().encode(override) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
