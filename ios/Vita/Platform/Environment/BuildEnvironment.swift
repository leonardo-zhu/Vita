import Foundation

enum BuildEnvironmentError: Error, Equatable {
    case missingAPIBaseURL
    case invalidAPIBaseURL(String)
}

/// 由构建配置决定的值。来源是 `project.yml` 中按 Debug / Release 设置的 `VITA_API_BASE_URL`，经 Info.plist 读出。
/// 2.0 起模型参数与 prompt 都在服务端，App 不再拉远程配置，也不再上报诊断日志。
struct BuildEnvironment: Equatable, Sendable {
    static let apiBaseURLKey = "VitaAPIBaseURL"

    /// Vita API（架构设计 §5）；业务数据与对话都经它。
    let apiBaseURL: URL

    static func load(from info: [String: Any]) throws -> BuildEnvironment {
        guard let raw = info[apiBaseURLKey] as? String, !raw.isEmpty else {
            throw BuildEnvironmentError.missingAPIBaseURL
        }
        // 请求携带令牌与对话内容，只允许 HTTPS；调试构建可以连本机起的 API（`VITA_API_BASE_URL=http://127.0.0.1:3014`）。
        guard let url = URL(string: raw), url.host() != nil, url.scheme == "https" || isLocalDevelopment(url) else {
            throw BuildEnvironmentError.invalidAPIBaseURL(raw)
        }
        return BuildEnvironment(apiBaseURL: url)
    }

    private static func isLocalDevelopment(_ url: URL) -> Bool {
        #if DEBUG
        url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host() ?? "")
        #else
        false
        #endif
    }

    static func current(bundle: Bundle = .main) throws -> BuildEnvironment {
        try load(from: bundle.infoDictionary ?? [:])
    }
}

/// 客户端版本（`CFBundleShortVersionString`）。
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 构建号：构建时的提交数，每次提交后构建都会变大。
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// 构建时的提交（短哈希），带 `+` 表示当时有未提交的改动。
    static var commit: String? {
        Bundle.main.object(forInfoDictionaryKey: "VitaGitCommit") as? String
    }

    /// 设置页显示：`0.2.0 (58 · 450cdd8)`。
    static var display: String {
        "\(current) (\(build)\(commit.map { " · \($0)" } ?? ""))"
    }
}
