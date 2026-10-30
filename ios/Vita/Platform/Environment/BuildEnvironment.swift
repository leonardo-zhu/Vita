import Foundation

enum BuildEnvironmentError: Error, Equatable {
    case missingConduitBaseURL
    case invalidConduitBaseURL(String)
}

/// 由构建配置决定、不可远程修改的值（vita-admin.md §3.2）。来源是 `project.yml` 中按
/// Debug / Release 设置的 `CONDUIT_BASE_URL`，经 Info.plist 的 `VitaConduitBaseURL` 读出。
struct BuildEnvironment: Equatable, Sendable {
    static let conduitBaseURLKey = "VitaConduitBaseURL"

    let conduitBaseURL: URL

    static func load(from info: [String: Any]) throws -> BuildEnvironment {
        guard let raw = info[conduitBaseURLKey] as? String, !raw.isEmpty else {
            throw BuildEnvironmentError.missingConduitBaseURL
        }
        // 请求携带令牌与对话内容，只允许 HTTPS。
        guard let url = URL(string: raw), url.scheme == "https", url.host() != nil else {
            throw BuildEnvironmentError.invalidConduitBaseURL(raw)
        }
        return BuildEnvironment(conduitBaseURL: url)
    }

    static func current(bundle: Bundle = .main) throws -> BuildEnvironment {
        try load(from: bundle.infoDictionary ?? [:])
    }
}
