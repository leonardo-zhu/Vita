import Foundation

/// 调 Vita API 出错（《Vita 2.0 架构设计》§8、§12）。`userMessage` 可以直接展示：服务端的说明本来就是给人看的。
enum APIError: Error, Equatable, Sendable {
    /// 本机还没有设备令牌。
    case missingToken
    /// 令牌无效或已在 Admin 里吊销。
    case unauthorized
    /// 连不上服务端（没网、只有 IPv4 的 Wi-Fi、服务挂了）。
    case offline(String)
    /// 服务端拒绝了这次请求，`code` 是机器码（如 revisionConflict、expired）。
    case server(status: Int, code: String, message: String)
    /// 响应格式与契约不符。
    case invalidResponse(String)

    var code: String? {
        if case .server(_, let code, _) = self { code } else { nil }
    }

    var userMessage: String {
        switch self {
        case .missingToken: "还没有连接 Vita 服务，请先在设置里填写设备令牌。"
        case .unauthorized: "设备令牌无效或已被吊销，请在设置里重新填写。"
        case .offline: "连不上 Vita 服务，请检查网络后再试。"
        case .server(_, _, let message): message
        case .invalidResponse: "Vita 服务返回了无法识别的数据，请更新 App 后再试。"
        }
    }
}

/// Vita API 的 HTTP 客户端：带设备令牌、按契约编解码 JSON，对话的进度经 SSE 推回（`stream`）。
/// 接口定义见 `packages/contract/src/index.ts`，这里的 Swift 模型按它手写（架构设计 §4）。
struct VitaAPIClient: Sendable {
    let baseURL: URL
    let token: @Sendable () throws -> String?
    var session: URLSession = .shared
    /// 普通请求的超时；对话是长连接，单独放宽。
    var timeout: TimeInterval = 30

    // MARK: - JSON

    /// 服务端的时间是 ISO 8601（`toISOString()`，带毫秒、UTC）；EventTime 的时刻可能带偏移。
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(raw)"))
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }()

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// 契约里的 `z.iso.datetime()` 只接受 UTC 的 `Z`。
    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - 请求

    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: Response.Type = Response.self) async throws -> Response {
        try decode(await perform(request("GET", path, query: query)))
    }

    func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], as type: Response.Type = Response.self) async throws -> Response {
        try decode(await perform(request(method, path, query: query)))
    }

    func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body, as type: Response.Type = Response.self) async throws -> Response {
        try decode(await perform(request(method, path, json: body)))
    }

    /// 没有响应体的请求（204）。
    func perform<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        _ = try await perform(request(method, path, json: body))
    }

    func perform(_ method: String, _ path: String) async throws {
        _ = try await perform(request(method, path))
    }

    /// 上传原始字节（标签照片）。
    func upload<Response: Decodable>(_ path: String, data: Data, contentType: String, as type: Response.Type = Response.self) async throws -> Response {
        var request = try request("POST", path)
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        request.httpBody = data
        return try decode(await perform(request))
    }

    /// 读取原始字节（标签照片）。
    func data(_ path: String) async throws -> Data {
        try await perform(request("GET", path))
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let token = try token(), !token.isEmpty else { throw APIError.missingToken }
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    private func request<Body: Encodable>(_ method: String, _ path: String, json body: Body) throws -> URLRequest {
        var request = try request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.offline(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse("not HTTP") }
        try Self.check(status: http.statusCode, body: data)
        return data
    }

    static func check(status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }
        if status == 401 { throw APIError.unauthorized }
        if let failure = try? decoder.decode(ErrorBody.self, from: body) {
            throw APIError.server(status: status, code: failure.error.code, message: failure.error.message)
        }
        throw APIError.server(status: status, code: "http\(status)", message: "Vita 服务暂时不可用（\(status)），请稍后再试。")
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse(String(describing: error))
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    // MARK: - SSE

    /// 发起一轮对话，逐个返回 SSE 事件（`ChatEvent`）。取消这个流会断开连接；服务端那一轮照样跑完，停止要另调取消接口。
    func stream<Body: Encodable>(_ path: String, body: Body?) -> AsyncThrowingStream<ChatEventDTO, Error> {
        // 先编码好：Body 不一定是 Sendable，不带进任务里。
        let encoded = Result { try body.map { try Self.encoder.encode($0) } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try request("POST", path)
                    request.timeoutInterval = 300
                    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    if let data = try encoded.get() {
                        request.setValue("application/json", forHTTPHeaderField: "content-type")
                        request.httpBody = data
                    }
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw APIError.offline(String(describing: error))
                    }
                    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse("not HTTP") }
                    if !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        try Self.check(status: http.statusCode, body: body)
                    }
                    var parser = SSEParser()
                    // 不能用 `bytes.lines`：它会把空行吞掉，而空行正是事件的分隔符。
                    var line = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if let payload = parser.feed(String(decoding: line, as: UTF8.self)) {
                                continuation.yield(try Self.decodeEvent(payload))
                            }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if let payload = parser.finish() { continuation.yield(try Self.decodeEvent(payload)) }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as APIError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: APIError.offline(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func decodeEvent(_ payload: String) throws -> ChatEventDTO {
        do {
            return try decoder.decode(ChatEventDTO.self, from: Data(payload.utf8))
        } catch {
            throw APIError.invalidResponse(String(describing: error))
        }
    }
}

/// 按行解析 Server-Sent Events：`data:` 行拼起来，遇到空行算一个事件。`event:`、`id:` 与注释行不需要，忽略。
struct SSEParser {
    private var data: [String] = []

    /// 喂一行（不含换行符），一个事件结束时返回它的 data。
    mutating func feed(_ rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { data.removeAll() }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            data.append(String(value))
        }
        return nil
    }

    /// 流结束时还没遇到空行的最后一个事件。
    mutating func finish() -> String? {
        defer { data.removeAll() }
        return data.isEmpty ? nil : data.joined(separator: "\n")
    }
}
