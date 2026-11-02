import Foundation
import ImageIO
import Testing
import UIKit
@testable import Vita

struct LabelImageTests {
    /// 测试用的 JPEG 照片。
    static func photo(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private static func size(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    @Test func shrinksTheLongEdgeAndKeepsTheAspectRatio() throws {
        let jpeg = try #require(LabelImageEncoder.jpeg(Self.photo(width: 2000, height: 1500), maxDimension: 800, quality: 0.8))
        let (width, height) = try #require(Self.size(jpeg))
        #expect(width == 800)
        #expect(height == 600)
    }

    @Test func doesNotEnlargeSmallPhotos() throws {
        let jpeg = try #require(LabelImageEncoder.jpeg(Self.photo(width: 400, height: 300), maxDimension: 1600, quality: 0.8))
        let (width, _) = try #require(Self.size(jpeg))
        #expect(width == 400)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(LabelImageEncoder.jpeg(Data("not an image".utf8), maxDimension: 800, quality: 0.8) == nil)
    }
}

@MainActor
struct LabelScanServiceTests {
    @Test func keepsImageLocallyAndRecordsScan() throws {
        let images = InMemoryLabelImageStore()
        var container = try AppContainer.inMemory()
        container.labelImages = images
        let services = AppServices(container: container)

        let photo = LabelImageTests.photo(width: 1000, height: 800)
        let result = try services.labels.scan(photo)
        #expect(try images.load(result.imageReference) == photo)
        #expect(try services.labels.imageReference(forScan: result.scanID) == result.imageReference)
    }

    @Test func modelImageFollowsTheConfiguredSettings() throws {
        let services = AppServices(container: try AppContainer.inMemory())
        let scan = try services.labels.scan(LabelImageTests.photo(width: 3000, height: 2000))
        let settings = VitaConfig.LabelImage(maxDimension: 600, jpegQuality: 0.7, detail: "low")

        let image = try #require(services.labels.modelImage(forScan: scan.scanID, settings: settings))
        #expect(image.detail == "low")
        let base64 = String(try #require(image.dataURL.split(separator: ",").last))
        let jpeg = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 600)
    }

    @Test func unknownScanHasNoModelImage() throws {
        let services = AppServices(container: try AppContainer.inMemory())
        let settings = VitaConfig.LabelImage(maxDimension: 600, jpegQuality: 0.7, detail: "high")
        #expect(services.labels.modelImage(forScan: UUID(), settings: settings) == nil)
    }
}
