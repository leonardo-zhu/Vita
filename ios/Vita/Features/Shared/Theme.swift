import SwiftUI
import UIKit

/// Vita 的视觉基调：暖色渐变背景、大圆角卡片、每类数据一种主题色。浅色与深色各有一套取值。
enum VitaTheme {
    /// 能量与饮食的主色：偏暖的绿。
    static let intake = Color(light: 0x2BA866, dark: 0x4CD38A)
    static let protein = Color(light: 0x3B82F6, dark: 0x6EA8FF)
    static let fat = Color(light: 0xF59E0B, dark: 0xFBBF4A)
    static let carbohydrate = Color(light: 0xA855F7, dark: 0xC48BFF)
    /// 超出目标、AI 估算等需要留意的状态。
    static let caution = Color(light: 0xF97316, dark: 0xFF9A4D)

    static let backgroundTop = Color(light: 0xDDF5E4, dark: 0x0E2418)
    static let backgroundBottom = Color(light: 0xF7F8F3, dark: 0x0B0D0C)
    static let card = Color(light: 0xFFFFFF, dark: 0x1A1D1B)
    static let cardTint = Color(light: 0xF2FAF4, dark: 0x1F2A23)

    static func color(for nutrient: Nutrient) -> Color {
        switch nutrient {
        case .energyKcal: intake
        case .proteinG: protein
        case .fatG: fat
        case .carbohydrateG: carbohydrate
        }
    }

    static var background: some View {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
    }
}

extension Color {
    /// 由十六进制 RGB 构造随浅色 / 深色模式切换的颜色。
    init(light: UInt32, dark: UInt32) {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

extension View {
    /// 内容卡片：实色底、大圆角、很淡的阴影。浮在内容上方的元素用 `glassCard`。
    func vitaCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VitaTheme.card, in: .rect(cornerRadius: 24))
            .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
    }
}

/// 卡片标题：图标 + 文字 + 右侧附加内容。
struct CardHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = VitaTheme.intake
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: .circle)
            Text(title).font(.headline)
            Spacer()
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, systemImage: String, tint: Color = VitaTheme.intake) {
        self.init(title: title, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// 圆环进度。`fraction` 超过 1 时整圈显示并换成提醒色。
struct ProgressRing: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(fraction > 1 ? VitaTheme.caution : tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // 圆角线帽在进度为 0 时仍会画出一个点。
                .opacity(fraction > 0 ? 1 : 0)
        }
        .animation(.smooth, value: fraction)
    }
}

/// 卡片里的字号层级，所有卡片共用，避免同类文字大小不一。
enum VitaType {
    /// 卡片标题。
    static let title = Font.headline
    /// 卡片里的说明文字。
    static let body = Font.subheadline
    /// 次要说明、行内按钮。
    static let secondary = Font.footnote
    /// 数字下方的标签、时间等元信息。
    static let meta = Font.caption
}

/// 引导卡：左侧图标块，右侧一两行标题与说明，需要用户行动时下方放通栏主按钮。
/// 用于连接健康、生成目标、权限被拒、空记录等状态，保持同一种左对齐版式。
struct InvitationCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 14)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(VitaType.title)
                    Text(message)
                        .font(VitaType.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton(prominent: true)
                .tint(tint)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VitaTheme.card, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.05), radius: 16, y: 6)
    }
}

/// Apple 健康的权限不在 Vita 自己的设置页里（那里只有“无线数据”），只能在健康 App 或系统设置的健康分区里改。
enum HealthApp {
    /// 告诉用户在哪里改权限；健康 App 的路径在各版本 iOS 上最稳定。
    static let permissionPath = "健康 App › 右上角头像 › 隐私 › App › Vita"

    static func open() {
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }
}
