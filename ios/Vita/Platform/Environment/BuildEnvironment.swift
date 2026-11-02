import Foundation

enum BuildEnvironmentError: Error, Equatable {
    case missingConduitBaseURL
    case invalidConduitBaseURL(String)
    case missingRemoteConfigURL
    case invalidRemoteConfigURL(String)
    case missingDiagnosticsURL
    case invalidDiagnosticsURL(String)
}

/// 由构建配置决定、不可远程修改的值（vita-admin.md §3.2 / §7）。来源是 `project.yml` 中按
/// Debug / Release 设置的 `CONDUIT_BASE_URL`、`REMOTE_CONFIG_URL` 与 `DIAGNOSTICS_URL`，经 Info.plist 读出。
struct BuildEnvironment: Equatable, Sendable {
    static let conduitBaseURLKey = "VitaConduitBaseURL"
    static let remoteConfigURLKey = "VitaRemoteConfigURL"
    static let diagnosticsURLKey = "VitaDiagnosticsURL"

    let conduitBaseURL: URL
    /// 远程配置只从这一个地址拉取。
    var remoteConfigURL: URL = URL(string: "https://config.invalid/stable.json")!
    /// 诊断日志只上报到这一个地址（ADR-014）。
    var diagnosticsURL: URL = URL(string: "https://diagnostics.invalid/events")!

    static func load(from info: [String: Any]) throws -> BuildEnvironment {
        guard let raw = info[conduitBaseURLKey] as? String, !raw.isEmpty else {
            throw BuildEnvironmentError.missingConduitBaseURL
        }
        // 请求携带令牌与对话内容，只允许 HTTPS。
        guard let url = URL(string: raw), url.scheme == "https", url.host() != nil else {
            throw BuildEnvironmentError.invalidConduitBaseURL(raw)
        }
        guard let rawConfig = info[remoteConfigURLKey] as? String, !rawConfig.isEmpty else {
            throw BuildEnvironmentError.missingRemoteConfigURL
        }
        guard let configURL = URL(string: rawConfig), configURL.scheme == "https", configURL.host() != nil else {
            throw BuildEnvironmentError.invalidRemoteConfigURL(rawConfig)
        }
        guard let rawDiagnostics = info[diagnosticsURLKey] as? String, !rawDiagnostics.isEmpty else {
            throw BuildEnvironmentError.missingDiagnosticsURL
        }
        guard let diagnosticsURL = URL(string: rawDiagnostics), diagnosticsURL.scheme == "https", diagnosticsURL.host() != nil else {
            throw BuildEnvironmentError.invalidDiagnosticsURL(rawDiagnostics)
        }
        return BuildEnvironment(conduitBaseURL: url, remoteConfigURL: configURL, diagnosticsURL: diagnosticsURL)
    }

    static func current(bundle: Bundle = .main) throws -> BuildEnvironment {
        try load(from: bundle.infoDictionary ?? [:])
    }
}

/// 客户端版本（`CFBundleShortVersionString`），与远程配置的 `minClientVersion` 比较。
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

    /// 系统版本，如 `27.0` 或 `27.0.1`，诊断日志用。
    static var os: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }
}
