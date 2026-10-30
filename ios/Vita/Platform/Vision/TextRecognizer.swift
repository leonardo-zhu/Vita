import Foundation
import Vision

/// 本地文字识别。图片不离开设备（TDD §8）。
protocol TextRecognizer: Sendable {
    func recognize(_ imageData: Data) async throws -> [RecognizedTextLine]
}

struct VisionTextRecognizer: TextRecognizer {
    func recognize(_ imageData: Data) async throws -> [RecognizedTextLine] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            // 数字与单位不需要语言纠错，纠错反而会把“6.0g”改坏。
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(data: imageData).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return RecognizedTextLine(text: text, x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
        }.value
    }
}

/// 测试替身：返回预设的识别结果。
struct StubTextRecognizer: TextRecognizer {
    var lines: [RecognizedTextLine]

    func recognize(_ imageData: Data) async throws -> [RecognizedTextLine] {
        lines
    }
}
