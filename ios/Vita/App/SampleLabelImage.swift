#if DEBUG
import UIKit

/// 调试与测试用：画一张中国格式的营养成分表图片。各列分开绘制，模拟文字识别把同一行拆成多段的情况。
enum SampleLabelImage {
    /// 1720 千焦 ≈ 411.1 千卡。
    static let rows: [[String]] = [
        ["项目", "每100克", "营养素参考值%"],
        ["能量", "1720千焦", "20%"],
        ["蛋白质", "12.5克", "21%"],
        ["脂肪", "18.0克", "30%"],
        ["—饱和脂肪", "6.2克", "31%"],
        ["碳水化合物", "52.3克", "17%"],
        ["钠", "380毫克", "19%"],
    ]

    static func render() -> Data {
        let size = CGSize(width: 1000, height: 820)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: UIColor.black]
            ("营养成分表" as NSString).draw(at: CGPoint(x: 60, y: 40), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black]
            let columns: [CGFloat] = [60, 420, 720]
            for (index, row) in rows.enumerated() {
                let y = 150 + CGFloat(index) * 92
                for (column, text) in row.enumerated() {
                    (text as NSString).draw(at: CGPoint(x: columns[column], y: y), withAttributes: body)
                }
                UIColor.black.setFill()
                context.fill(CGRect(x: 40, y: y + 72, width: 920, height: 2))
            }
        }
        return image.pngData()!
    }
}
#endif
