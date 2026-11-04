import Foundation

/// 营养标签照片（ADR-016、架构设计 §10.3）：拍完上传到 Vita API，拿到 `labelScanId` 再随消息发出。
/// 服务端那份是唯一的存档，作为食品版本的来源依据；手机只缓存读过的图。
@MainActor
final class LabelScanService {
    private let api: VitaAPIClient
    private var cache: [UUID: Data] = [:]

    init(api: VitaAPIClient) {
        self.api = api
    }

    /// 上传已压缩的 JPEG，返回 `labelScanId`。
    func upload(_ jpeg: Data) async throws -> UUID {
        let response: LabelScanResponseDTO = try await api.upload("/v1/label-scans", data: jpeg, contentType: "image/jpeg")
        cache[response.labelScanId] = jpeg
        return response.labelScanId
    }

    /// 读一张标签照片；找不到时返回 nil。
    func image(_ id: UUID) async -> Data? {
        if let cached = cache[id] { return cached }
        guard let data = try? await api.data("/v1/label-scans/\(id.apiString)") else { return nil }
        cache[id] = data
        return data
    }

    /// 食品版本里的照片引用是 labelScanId 的字符串。
    func imageData(_ reference: String) async -> Data? {
        guard let id = UUID(uuidString: reference) else { return nil }
        return await image(id)
    }
}
