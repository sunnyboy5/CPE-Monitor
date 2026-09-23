import SwiftUI
import AppKit

/// 全局视觉规范。所有颜色集中在这里，换配色只改这个文件。
///
/// 版式对齐用户给的 F50 Monitor 参考图：
/// 浅灰蓝底 + 纯白圆角卡片 + 极轻投影 + 蓝/绿点缀色。
enum Theme {

    // MARK: - 页面与卡片

    /// 页面底色（顶部略亮，做一层极浅的纵向渐变增加层次）
    static let background    = Color(hex: 0xF1F4F8)
    static let backgroundTop = Color(hex: 0xF8FAFD)

    /// 卡片
    static let panel         = Color(hex: 0xFFFFFF)
    /// 卡片内嵌浅底（签约状态条、底部工具按钮）
    static let panelSoft     = Color(hex: 0xF5F7FB)
    /// 兼容旧命名：输入框底色
    static let panelRaised   = Color(hex: 0xF5F7FB)
    /// 进度条/信号格底槽
    static let track         = Color(hex: 0xE9EDF3)

    static let hairline      = Color(hex: 0xEDF0F5)
    static let border        = Color(hex: 0xE5E9F0)

    // MARK: - 文字

    static let textPrimary   = Color(hex: 0x171A21)
    static let textSecondary = Color(hex: 0x6A7280)
    static let textTertiary  = Color(hex: 0x9BA3B0)

    // MARK: - 强调色

    static let accent     = Color(hex: 0x2F6BFF)
    static let accentSoft = Color(hex: 0xE9F0FF)
    /// 实时下载
    static let down       = Color(hex: 0x16C46A)
    /// 实时上传
    static let up         = Color(hex: 0x3B82F6)
    static let purple     = Color(hex: 0x7C5CFC)
    static let orange     = Color(hex: 0xF59E0B)

    // MARK: - 评级（绿 → 绿 → 琥珀 → 红）

    static let levelExcellent = Color(hex: 0x16A34A)
    static let levelGood      = Color(hex: 0x22C55E)
    static let levelFair      = Color(hex: 0xF59E0B)
    static let levelPoor      = Color(hex: 0xEF4444)

    static let ok    = levelExcellent
    static let warn  = levelFair
    static let error = Color(hex: 0xE5484D)

    // MARK: - 通知条

    static let warnBg      = Color(hex: 0xFDF4E9)
    static let warnBorder  = Color(hex: 0xF7E5CE)
    static let errorBg     = Color(hex: 0xFDEEEE)
    static let errorBorder = Color(hex: 0xF8DADA)
    static let infoBg      = Color(hex: 0xEBF1FF)
    static let infoBorder  = Color(hex: 0xD9E5FF)

    // MARK: - 尺寸

    static let cardRadius: CGFloat = 14
    /// 兼容旧命名
    static let panelRadius: CGFloat = 14
    static let contentWidth: CGFloat = 384
    static let cardSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 14
    static let pagePadding: CGFloat = 10

    static let cardShadow = Color.black.opacity(0.05)

    static var pageGradient: LinearGradient {
        LinearGradient(colors: [backgroundTop, background],
                       startPoint: .top, endPoint: .bottom)
    }

    /// 面板内容区高度。
    ///
    /// 必须是一个「确定值」：菜单栏面板如果拿到弹性高度（maxHeight），
    /// 窗口会塌成只剩头部和底部、内容区全黑（实测踩过这个坑）。
    /// 这里按用户设定值，再用屏幕可用高度兜底，避免面板超出屏幕。
    ///
    /// 诊断（Probe）离屏渲染用：设了就按这个高度出图，忽略用户设定值和屏幕兜底，
    /// 好让一整页（设置页有 7 个卡片）一次装得下。正常运行时它是 nil，行为与以前一致。
    static var heightCapOverride: CGFloat?

    static func panelHeight(preferred: Double) -> CGFloat {
        if let override = heightCapOverride { return override }
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, min(CGFloat(preferred), visible - 120))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension View {

    /// 白卡片质感：圆角 + 细描边 + 极轻投影
    func cardSurface(radius: CGFloat = Theme.cardRadius,
                     fill: Color = Theme.panel,
                     border: Color = Theme.border,
                     shadow: Bool = true) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 0.5)
            )
            .shadow(color: shadow ? Theme.cardShadow : .clear,
                    radius: shadow ? 6 : 0, x: 0, y: shadow ? 2 : 0)
    }
}

/// 卡片容器。标题可选，标题左侧可带一个小图标（参考图里的「套餐流量」）。
struct CardBox<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    var iconColor: Color = Theme.accent
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                    if let title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
            }
            content()
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
