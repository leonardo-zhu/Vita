import Foundation

/// 值对象以 JSON 存进 SwiftData 的 `Data` 列。营养数值是 `Decimal`，不交给 SwiftData 的
/// 数值列或组合属性去存，避免精度与谓词行为随系统版本变化（TDD §3.2）。
enum JSONColumn {
    static func encode<T: Encodable>(_ value: T) -> Data {
        // 只用于本模块内定义的值类型，编码不会失败。
        try! JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
