import Foundation

enum BuildEnvironmentError: Error, Equatable {
    case missingConduitBaseURL
    case invalidConduitBaseURL(String)
    case missingRemoteConfigURL
    case invalidRemoteConfigURL(String)
}

/// 由构建配置决定、不可远程修改的值（vita-admin.md §3.2 / §7）。来源是 `project.yml` 中按
/// Debug / Release 设置的 `CONDUIT_BASE_URL` 与 `REMOTE_CONFIG_URL`，经 Info.plist 读出。
struct BuildEnvironment: Equatable, Sendable {
    static let conduitBaseURLKey = "VitaConduitBaseURL"
    static let remoteConfigURLKey = "VitaRemoteConfigURL"

    let conduitBaseURL: URL
    /// 远程配置只从这一个地址拉取。
    var remoteConfigURL: URL = URL(string: "https://config.invalid/stable.json")!

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
        return BuildEnvironment(conduitBaseURL: url, remoteConfigURL: configURL)
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
}
