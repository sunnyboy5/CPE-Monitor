import SwiftUI
import AppKit

// MARK: - 基础文本行

/// 左标签右数值的一行
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary
    var mono: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium,
                              design: mono ? .monospaced : .default))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - 进度条

/// 细进度条：浅槽 + 圆角填充
struct MeterBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 小标签

/// 圆角胶囊标签：5G SA / n78 / 1000Mbps
struct Pill: View {
    let text: String
    var color: Color = Theme.accent
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .fixedSize()
    }
}

/// 顶部链路状态胶囊
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
        .fixedSize()
    }
}

// MARK: - 图标

/// 圆形图标底座（实时下载 / 上传 左侧那个渐变圆）
struct GlyphCircle: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    LinearGradient(colors: [color.opacity(0.95), color.opacity(0.72)],
                                   startPoint: .top, endPoint: .bottom)
                )
            )
    }
}

/// 状态圆点
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// 信号格：四根递增高的小棒
struct SignalBars: View {
    /// 0...4
    let level: Int
    var color: Color = Theme.levelExcellent

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < level ? color : Theme.track)
                    .frame(width: 3.5, height: 6 + CGFloat(i) * 3.5)
            }
        }
        .frame(height: 17, alignment: .bottom)
    }
}

// MARK: - 运营商角标

/// 运营商真图标（`Resources/Carriers/<name>.png`，打包进 .app 的 Contents/Resources）。
///
/// 图片只解码一次并缓存：面板每 2 秒重绘一轮，每次都重新读盘解码太浪费。
final class CarrierIconStore {
    static let shared = CarrierIconStore()

    private var cache: [String: NSImage?] = [:]

    func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image: NSImage? = {
            // 图标放在 .app/Contents/Resources/Carriers/ 下
            guard let url = Bundle.main.url(forResource: name,
                                            withExtension: "png",
                                            subdirectory: "Carriers"),
                  let loaded = NSImage(contentsOf: url) else { return nil }
            return loaded
        }()
        cache[name] = image
        return image
    }
}

enum CarrierBrand {
    case unicom, telecom, mobile, broadcast, unknown

    init(carrier: String?) {
        let text = carrier ?? ""
        if text.contains("联通") { self = .unicom }
        else if text.contains("移动") { self = .mobile }
        else if text.contains("电信") { self = .telecom }
        else if text.contains("广电") { self = .broadcast }
        else { self = .unknown }
    }

    /// 资源文件名，nil 表示没有对应图标
    var assetName: String? {
        switch self {
        case .unicom: return "unicom"
        case .telecom: return "telecom"
        case .mobile: return "mobile"
        case .broadcast: return "broadcast"
        case .unknown: return nil
        }
    }

    var short: String {
        switch self {
        case .unicom: return "联通"
        case .telecom: return "电信"
        case .mobile: return "移动"
        case .broadcast: return "广电"
        case .unknown: return ""
        }
    }

    /// 图标缺失时的兜底色
    var tint: Color {
        switch self {
        case .unicom: return Color(hex: 0xE4002B)
        case .mobile: return Color(hex: 0x0086D1)
        case .telecom: return Color(hex: 0x0A5FB4)
        case .broadcast: return Color(hex: 0x1B9BE0)
        case .unknown: return Theme.textTertiary
        }
    }

    var image: NSImage? {
        guard let assetName else { return nil }
        return CarrierIconStore.shared.image(named: assetName)
    }
}

/// 运营商角标：优先用真图标，资源缺失时退回色块 + 简称
struct CarrierBadge: View {
    let name: String?
    var size: CGFloat = 26

    private var brand: CarrierBrand { CarrierBrand(carrier: name) }

    var body: some View {
        Group {
            if let image = brand.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if brand.short.isEmpty {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                            .fill(brand.tint)
                    )
            } else {
                Text(brand.short)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                            .fill(brand.tint)
                    )
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 指标列（参考图里 RSRP / SINR / RSRQ 那三列）

struct MetricColumn: View {
    let label: String
    let value: String
    let quality: Quality
    let fraction: Double

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            MeterBar(fraction: fraction, color: quality.color, height: 5)

            Text(quality.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(quality.color)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 小格子统计块：标签 + 数值 (+ 可选进度条)
struct StatTile: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary
    var systemImage: String? = nil
    var iconColor: Color = Theme.accent
    var fraction: Double? = nil
    var barColor: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            // 没给进度条的格子也占住这一行，保证四块等高
            if let fraction {
                MeterBar(fraction: fraction, color: barColor, height: 4)
            } else {
                Color.clear.frame(height: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 12, fill: Theme.panelSoft, shadow: false)
    }
}

// MARK: - 通知条

/// 浅底通知条：连接失败 / 鉴权失败 / 演示模式
struct NoticeBar: View {
    enum Kind { case warn, error, info }

    let kind: Kind
    let title: String
    var detail: String? = nil
    var hint: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    private var foreground: Color {
        switch kind {
        case .warn: return Theme.warn
        case .error: return Theme.error
        case .info: return Theme.accent
        }
    }

    private var background: Color {
        switch kind {
        case .warn: return Theme.warnBg
        case .error: return Theme.errorBg
        case .info: return Theme.infoBg
        }
    }

    private var border: Color {
        switch kind {
        case .warn: return Theme.warnBorder
        case .error: return Theme.errorBorder
        case .info: return Theme.infoBorder
        }
    }

    private var icon: String {
        switch kind {
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foreground)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }

            if let hint {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(hint)
                        .font(.system(size: 11))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.accent)
                .padding(.leading, 18)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(actionTitle)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(border, lineWidth: 0.5)
        )
    }
}

// MARK: - 按钮

/// 顶部图标按钮
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var color: Color = Theme.textSecondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : color)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Theme.track : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// 底部工具条图标方块
struct IconTile: View {
    let systemName: String
    var color: Color = Theme.textSecondary
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 38, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hovering ? Theme.track : Theme.panelSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// 底部带文字的胶囊按钮（参考图的「打开后台」）
struct ToolbarButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Theme.accentSoft.opacity(0.7) : Theme.accentSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.accent.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 速率波形

/// 速率曲线。用真实采样点连成平滑曲线 + 底部渐变填充，不做等高条形。
struct Sparkline: View {
    let samples: [Double]
    var color: Color
    /// 与另一条曲线共用纵轴上限，避免两条线各自归一化后失真
    var sharedMax: Double?

    private var peak: Double {
        let own = samples.max() ?? 0
        let external = sharedMax ?? 0
        let top = max(own, external)
        return top > 0 ? top : 1
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if samples.count < 2 {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 1))
                    p.addLine(to: CGPoint(x: w, y: h - 1))
                }
                .stroke(Theme.track, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            } else {
                let step = w / CGFloat(samples.count - 1)
                let points: [CGPoint] = samples.enumerated().map { idx, value in
                    let ratio = min(1, max(0, value / peak))
                    // 留一点上下余量，0 值不会贴死在底边
                    let y = h - (CGFloat(ratio) * (h - 3)) - 1.5
                    return CGPoint(x: CGFloat(idx) * step, y: y)
                }

                ZStack {
                    curve(points, width: w, height: h, close: true)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.26), color.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    curve(points, width: w, height: h, close: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6,
                                                          lineCap: .round,
                                                          lineJoin: .round))

                    if let last = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .position(x: min(last.x, w - 2.5), y: last.y)
                    }
                }
            }
        }
    }

    /// 用二次贝塞尔在相邻点中点处转折，得到参考图那种圆滑的水波感
    private func curve(_ pts: [CGPoint], width w: CGFloat,
                       height h: CGFloat, close: Bool) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }

        if close {
            path.move(to: CGPoint(x: pts[0].x, y: h))
            path.addLine(to: pts[0])
        } else {
            path.move(to: pts[0])
        }

        for i in 1..<(pts.count - 1) {
            let current = pts[i]
            let next = pts[i + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2,
                              y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }

        if let last = pts.last {
            path.addLine(to: last)
            if close {
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
            }
        }
        return path
    }
}
