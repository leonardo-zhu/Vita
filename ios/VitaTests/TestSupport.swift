import Foundation
@testable import Vita

private final class TestBundleToken {}

enum Fixtures {
    static let bundle = Bundle(for: TestBundleToken.self)

    /// 测试用小型参考库（不含中国来源数据），见 Fixtures/reference-foods.fixture.json。
    static func referenceFoods() throws -> ReferenceFoodCatalog {
        let catalog = try ReferenceFoodLoader.load(from: bundle, resourceName: "reference-foods.fixture")
        precondition(catalog.count > 0, "fixture missing from test bundle")
        return catalog
    }

    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let day = LocalDate(isoString: "2026-10-30")!
    /// 2026-10-30 20:00 上海时间。
    static let now = Date(timeIntervalSince1970: 1_793_361_600)
}

func dec(_ string: String) -> Decimal {
    Decimal(string: string)!
}
