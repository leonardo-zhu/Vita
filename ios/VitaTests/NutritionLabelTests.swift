import Foundation
import Testing
@testable import Vita

/// 标签照片上传到 Vita 服务，随消息只带 ID（ADR-016、架构设计 §10.3）。
@MainActor
struct LabelScanTests {
    @Test func uploadsTheJPEGAndCachesIt() async throws {
        let stub = APIStub()
        let id = UUID()
        stub.on("POST", "/v1/label-scans", status: 201, json: #"{"labelScanId":"\#(id.apiString)"}"#)
        let labels = LabelScanService(api: stub.client())
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

        #expect(try await labels.upload(jpeg) == id)
        let request = try #require(stub.requests.first)
        #expect(request.body == jpeg)
        #expect(request.headers["Content-Type"] == "image/jpeg")
        // 刚传的直接用缓存，不再下载。
        #expect(await labels.image(id) == jpeg)
        #expect(stub.requests.count == 1)
    }

    @Test func readsVersionPhotosByScanID() async throws {
        let stub = APIStub()
        let id = UUID()
        stub.on("GET", "/v1/label-scans/\(id.apiString)", .init(contentType: "image/jpeg", body: Data([1, 2, 3])))
        let labels = LabelScanService(api: stub.client())
        #expect(await labels.imageData(id.uuidString) == Data([1, 2, 3]))
        #expect(await labels.imageData("label:not-an-id") == nil)
    }
}
