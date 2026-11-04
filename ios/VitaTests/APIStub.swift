import Foundation
@testable import Vita

/// 假的 Vita API：按“方法 + 路径”返回写好的响应，并记下收到的请求。每个替身用自己的 URLSession，
/// 靠请求头里的 ID 找到自己，测试并行跑也不会串。
final class APIStub: @unchecked Sendable {
    struct Response {
        var status = 200
        var contentType = "application/json"
        var body: Data
    }

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data
        var headers: [String: String]

        func json() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        }
    }

    let id = UUID().uuidString
    private let lock = NSLock()
    private var routes: [String: [Response]] = [:]
    private var _requests: [Request] = []
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.header: id]
        session = URLSession(configuration: configuration)
        StubURLProtocol.register(self)
    }

    var requests: [Request] { lock.withLock { _requests } }

    /// 同一路由给多次时按顺序返回，最后一个一直重复。
    func on(_ method: String, _ path: String, status: Int = 200, json: String) {
        on(method, path, Response(status: status, body: Data(json.utf8)))
    }

    func on(_ method: String, _ path: String, _ response: Response) {
        lock.withLock { routes["\(method) \(path)", default: []].append(response) }
    }

    /// SSE：每个事件一个 JSON。
    func onStream(_ path: String, events: [String]) {
        let body = events.map { event -> String in
            let type = (try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])?["type"] as? String ?? "message"
            return "event: \(type)\ndata: \(event)\n\n"
        }.joined()
        on("POST", path, Response(contentType: "text/event-stream", body: Data(body.utf8)))
    }

    func client(token: String? = "test-token") -> VitaAPIClient {
        VitaAPIClient(baseURL: URL(string: "https://vita-api.test")!, token: { token }, session: session)
    }

    fileprivate func respond(to request: URLRequest) -> Response {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let method = request.httpMethod ?? "GET"
        return lock.withLock {
            _requests.append(Request(method: method, path: url.path(), query: query, body: body, headers: request.allHTTPHeaderFields ?? [:]))
            let key = "\(method) \(url.path())"
            guard var queue = routes[key], let first = queue.first else {
                return Response(status: 404, body: Data(#"{"error":{"code":"notFound","message":"no stub for \#(key)"}}"#.utf8))
            }
            if queue.count > 1 { queue.removeFirst(); routes[key] = queue }
            return first
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let header = "x-vita-stub"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: APIStub] = [:]

    static func register(_ stub: APIStub) {
        lock.withLock { stubs[stub.id] = stub }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        guard let stub = Self.lock.withLock({ Self.stubs[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = stub.respond(to: request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["content-type": response.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 契约里的一条 DayResponse，测试按需改。
enum APIFixtures {
    static func day(_ date: String, kcal: Int, protein: Int = 0, recordID: UUID = UUID()) -> String {
        """
        {"date":"\(date)","revision":1,"records":[{"id":"\(recordID.apiString)","eventTime":{"localDate":"\(date)","precision":"mealPeriod","timestamp":null,"mealPeriod":"lunch","timeZone":"Asia/Shanghai"},
        "mealLabel":"午餐","note":null,"revision":0,"items":[{"id":"\(UUID().apiString)","displayName":"外卖","groupName":null,"originalAmountText":"一份","quantity":null,
        "amountSource":"aiEstimated","includeInSummary":true,"snapshot":{"nutritionSource":"aiEstimated","sourceRef":null,"basisQuantity":null,"basisNutrients":null,"quantityUsed":null,
        "computedBy":"model","estimateBasis":"按一份估算","values":{"energyKcal":\(kcal),"proteinG":\(protein),"fatG":0,"carbohydrateG":0}},"sourceLabel":null}],
        "totals":{"energyKcal":\(kcal),"proteinG":\(protein),"fatG":0,"carbohydrateG":0}}],
        "summary":{"totals":{"energyKcal":\(kcal),"proteinG":\(protein),"fatG":0,"carbohydrateG":0},"includedItemCount":1,"excludedItemCount":0,"estimatedItemCount":1,
        "goal":null,"energy":null,"balance":null}}
        """
    }

    static func emptyDay(_ date: String) -> String {
        """
        {"date":"\(date)","revision":0,"records":[],"summary":{"totals":{"energyKcal":0,"proteinG":0,"fatG":0,"carbohydrateG":0},
        "includedItemCount":0,"excludedItemCount":0,"estimatedItemCount":0,"goal":null,"energy":null,"balance":null}}
        """
    }
}
