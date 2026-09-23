import AppKit

// 生成 AppIcon.icns（不依赖 Xcode）
//   swift tools/make_icon.swift Resources [bars|antenna|wifi]
//
// 设计：蓝色渐变圆角方 + 白色信号柱（cellularbars），和面板里的信号格同一套语言。
//
// 为什么用信号柱而不是天线符号：图标要在 16px 下也能认出来。
// 天线符号有 5 个细元素（点+杆+两对弧），16px 会被压成一团糊；
// 信号柱只有 4 个粗块，小尺寸下依然清晰。
//
// 两个清晰度关键：
//   1. 几何量**直接按目标像素算**，符号也按目标像素配置，全程不缩放 CTM。
//      在 1024 坐标系里画完再让 CTM 缩到 16px，等于把 1024 级栅格图暴力缩 64 倍，小图标必糊。
//   2. 按符号的**实际墨迹范围**而不是 NSImage 的 bounds 居中。
//      bounds 含上下留白，直接居中会让图形整体偏下、显得小。

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let variantName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "bars"

enum Variant: String {
    case bars, antenna, wifi

    var symbol: String {
        switch self {
        case .bars: return "cellularbars"
        case .antenna: return "antenna.radiowaves.left.and.right"
        case .wifi: return "wifi"
        }
    }
}

let variant = Variant(rawValue: variantName) ?? .bars

/// macOS 图标网格：圆角方内缩约 9.8%，圆角半径约为边长的 22.5%
let insetRatio: CGFloat = 0.0977
let cornerRatio: CGFloat = 0.225
/// 图形墨迹的最大边相对圆角方的比例
let glyphRatio: CGFloat = 0.66

/// 符号墨迹范围（相对图像尺寸的比例）。
///
/// 只在参考字号上量一次：SF Symbol 是矢量的，这些比例与字号无关。
/// 参考字号故意选小（64pt）—— 上面那个逐像素扫描用 colorAt，图越大越慢。
func inkMetrics() -> (w: CGFloat, h: CGFloat, cx: CGFloat, cy: CGFloat) {
    let fallback: (CGFloat, CGFloat, CGFloat, CGFloat) = (1, 1, 0.5, 0.5)
    guard let base = NSImage(systemSymbolName: variant.symbol, accessibilityDescription: nil),
          let symbol = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)) else { return fallback }

    let nat = symbol.size
    let w = Int(ceil(nat.width)), h = Int(ceil(nat.height))
    guard w > 0, h > 0,
          let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return fallback }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    symbol.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            if a > 0.06 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return fallback }

    let cx = (CGFloat(minX) + CGFloat(maxX) + 1) / 2 / CGFloat(w)
    // 位图 y 向下增长，绘制坐标 y 向上，这里翻回来
    let cyBitmap = (CGFloat(minY) + CGFloat(maxY) + 1) / 2 / CGFloat(h)
    return (CGFloat(maxX - minX + 1) / CGFloat(w),
            CGFloat(maxY - minY + 1) / CGFloat(h),
            cx, 1 - cyBitmap)
}

let ink = inkMetrics()

func makeIcon(pixels: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 不做任何 CTM 缩放，下面全是真实像素
    let inset = pixels * insetRatio
    let box = NSRect(x: inset, y: inset,
                     width: pixels - inset * 2, height: pixels - inset * 2)

    // 1. 圆角方 + 渐变
    let squircle = NSBezierPath(roundedRect: box,
                                xRadius: box.width * cornerRatio,
                                yRadius: box.width * cornerRatio)
    NSGradient(colors: [
        NSColor(srgbRed: 0.42, green: 0.62, blue: 1.00, alpha: 1),   // 顶部 #6B9EFF
        NSColor(srgbRed: 0.13, green: 0.31, blue: 0.85, alpha: 1)    // 底部 #2150D9
    ])!.draw(in: squircle, angle: -90)

    // 2. 极淡顶部高光
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        squircle.addClip()
        NSGradient(colors: [
            NSColor(white: 1, alpha: 0.20),
            NSColor(white: 1, alpha: 0.0)
        ])!.draw(in: NSRect(x: box.minX, y: box.midY,
                            width: box.width, height: box.height / 2),
                 angle: -90)
        ctx.restoreGState()
    }

    // 3. 白色符号：按墨迹居中 + 按目标像素栅格化
    if let base = NSImage(systemSymbolName: variant.symbol, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: box.width * glyphRatio * 1.6,
                                                 weight: .bold)
        if let symbol = base.withSymbolConfiguration(config) {
            let nat = symbol.size
            let inkW = ink.w * nat.width
            let inkH = ink.h * nat.height
            let scale = (box.width * glyphRatio) / max(inkW, inkH)

            // 画布放大 scale 倍后，让墨迹中心落在 box 中心
            let drawSize = NSSize(width: nat.width * scale, height: nat.height * scale)
            let origin = NSPoint(x: box.midX - ink.cx * nat.width * scale,
                                 y: box.midY - ink.cy * nat.height * scale)
            let rect = NSRect(origin: origin, size: drawSize)

            let ctx = NSGraphicsContext.current!.cgContext
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill()
            ctx.setBlendMode(.sourceAtop)
            rect.fill()
            ctx.setBlendMode(.normal)
            ctx.endTransparencyLayer()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = "\(outDir)/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// iconutil 要求的固定命名与尺寸（逐尺寸原生绘制，不是缩图）
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, px) in variants {
    let rep = makeIcon(pixels: px)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("❌ \(name) 编码失败")
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

if let png = makeIcon(pixels: 1024).representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-preview.png"))
}

// 直接把 iconset 打成 icns —— 这一步不能忘，否则资源目录里留的是上一次的旧 icns，
// 构建出来的 App 图标就还是老的（踩过：只重跑 iconset，忘记 iconutil）。
let icnsPath = "\(outDir)/AppIcon.icns"
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", icnsPath]
try? FileManager.default.removeItem(atPath: icnsPath)
do {
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        print("❌ iconutil 失败（退出码 \(iconutil.terminationStatus)）")
        exit(1)
    }
} catch {
    print("❌ 无法执行 iconutil：\(error)")
    exit(1)
}

// 顺手验证 icns 能解析回 10 个尺寸
let verify = Process()
verify.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
let verifyDir = NSTemporaryDirectory() + "icns-verify.iconset"
try? FileManager.default.removeItem(atPath: verifyDir)
verify.arguments = ["-c", "iconset", icnsPath, "-o", verifyDir]
var count = 0
do {
    try verify.run()
    verify.waitUntilExit()
    count = (try? FileManager.default.contentsOfDirectory(atPath: verifyDir).count) ?? 0
    try? FileManager.default.removeItem(atPath: verifyDir)
} catch { /* 校验失败不影响主流程 */ }

print("✅ \(icnsPath) 已生成（\(count) 个尺寸）")
print("   符号=\(variant.symbol)  墨迹比例 w=\(String(format: "%.3f", ink.w)) "
      + "h=\(String(format: "%.3f", ink.h)) 中心=(\(String(format: "%.3f", ink.cx)), "
      + "\(String(format: "%.3f", ink.cy)))")
