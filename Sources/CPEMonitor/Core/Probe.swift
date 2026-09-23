import SwiftUI
import AppKit

/// 离屏渲染诊断：把界面直接渲成 PNG。
///
/// 本机 screencapture 没有权限、菜单栏面板又截不到，所以用两条渲染通道来
/// 「看到」真实版式，而不是靠猜：
///   1. ImageRenderer —— 纯 SwiftUI 路径，快，但渲染不了 ScrollView / NSViewRepresentable
///   2. 真实 NSWindow + cacheDisplay —— 走 AppKit 绘制路径，能验证上面渲染不了的东西
///
/// 用法：
///   CPEMonitor --probe --live --host ... --out /tmp/cpe-probe
///   CPEMonitor --probe-window --live --out /tmp/cpe-probe
enum Probe {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--probe")
            || CommandLine.arguments.contains("--probe-window")
            || CommandLine.arguments.contains("--probe-maintenance")
            || CommandLine.arguments.contains("--diag-panel")
    }

    private static func value(for flag: String) -> String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// 等待数据到位的秒数
    static var delay: Double {
        Double(value(for: "--probeDelay") ?? "4") ?? 4
    }

    private static var outputDir: String {
        value(for: "--out") ?? "/tmp/cpe-probe"
    }

    @MainActor
    static func run() {
        let dir = outputDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let settings = AppEnv.settings
        let engine = AppEnv.engine
        printSnapshot(engine: engine, settings: settings)

        if CommandLine.arguments.contains("--diag-panel") {
            panelDiag(dir: dir)
        } else if CommandLine.arguments.contains("--probe-window") {
            windowCases(dir: dir, settings: settings, engine: engine)
        } else if CommandLine.arguments.contains("--probe-maintenance") {
            // 维护接口是异步 + 会自己退出，走单独分支
            Task { @MainActor in
                await maintenanceCases(settings: settings, engine: engine)
                exit(0)
            }
            return
        } else {
            imageCases(dir: dir, settings: settings, engine: engine)
        }

        print("[probe] 输出目录：\(dir)")
        exit(0)
    }

    // MARK: - 维护接口联调（清缓存 / 重置统计）

    /// 验证 POST /api/clear_cache 与 POST /api/set/total 的鉴权、请求体与响应解析。
    /// 用法：
    ///   CPEMonitor --probe-maintenance --host <ip> --port 6677 --password <pwd>
    /// 前置：engine 已在 App 启动时开始轮询，这里等它拿够数据再动手。
    @MainActor
    private static func maintenanceCases(settings: AppSettings, engine: MonitorEngine) async {
        // 等首轮轮询完成，确保 token 就绪、snapshot 里有真实 cached_ram
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        let before = Fmt.mb(engine.snapshot.info?.cachedRam)
        print("[maint] 清理前 cached_ram = \(before)  link=\(engine.link)")
        print("[maint] 定时清理：\(engine.autoClearStatusText)"
              + (engine.autoClearError.map { "  错误：\($0)" } ?? ""))

        do {
            try await engine.clearDeviceCache()
            print("[maint] ✅ clear_cache 成功 → cached_ram = \(Fmt.mb(engine.snapshot.info?.cachedRam))")
        } catch {
            print("[maint] ❌ clear_cache 失败：\(error.localizedDescription)")
        }

        let monthlyBefore = engine.snapshot.monthlyBytes.map(String.init) ?? "nil"
        print("[maint] 重置前 monthlyBytes = \(monthlyBefore)")

        do {
            try await engine.resetDeviceTraffic()
            print("[maint] ✅ set/total 成功 → monthlyBytes = "
                  + "\(engine.snapshot.monthlyBytes.map(String.init) ?? "nil")")
        } catch {
            print("[maint] ❌ set/total 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 实测真实菜单栏面板

    /// 模拟点击菜单栏图标把面板打开，然后测量并截图真实面板窗口。
    ///
    /// 菜单栏面板的尺寸不看 SwiftUI 的自适应高度（实测两者不一致），
    /// 只能真开一次量。这是唯一能确认「面板到底多高」的办法。
    @MainActor
    private static func panelDiag(dir: String) {
        dumpWindows("点击前")

        guard let statusWindow = NSApp.windows.first(where: {
            String(describing: type(of: $0)).contains("StatusBar")
        }) else {
            print("[diag] ❌ 没找到菜单栏窗口")
            return
        }
        print("[diag] 菜单栏窗口 = \(Int(statusWindow.frame.width))x\(Int(statusWindow.frame.height))pt")
        dumpView(statusWindow.contentView, depth: 0)

        // SwiftUI 的 MenuBarExtra 不一定用 NSStatusBarButton，找不到就注入鼠标事件
        if let button = findStatusButton(in: statusWindow.contentView) {
            print("[diag] 找到 \(type(of: button))，performClick…")
            button.performClick(nil)
        } else {
            print("[diag] 没有 NSStatusBarButton，改为注入鼠标事件…")
            postClick(on: statusWindow)
        }

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        dumpWindows("点击后")

        let candidates = NSApp.windows.filter {
            $0.isVisible && $0.frame.height > 40 && $0.frame.width > 200
        }
        guard let panel = candidates.first else {
            print("[diag] ⚠️ 没捕获到可见面板窗口")
            return
        }
        print("[diag] ✅ 面板尺寸 = \(Int(panel.frame.width))x\(Int(panel.frame.height))pt "
              + "class=\(type(of: panel))")

        if let cv = panel.contentView {
            print("[diag] 面板内容视图 = \(type(of: cv)) \(Int(cv.bounds.width))x\(Int(cv.bounds.height))pt")
            shoot(cv, name: "30-real-panel-top", dir: dir)

            // 内容比视口高时必须能滚到底，否则下面的模块够不着
            let scrolls = findScrollViews(in: cv)
            print("[diag] 视图树里的 NSScrollView 数量 = \(scrolls.count)")
            for s in scrolls {
                let docH = s.documentView?.frame.height ?? 0
                print("[diag]   document=\(Int(docH))pt 视口=\(Int(s.contentView.bounds.height))pt "
                      + "可滚动=\(docH > s.contentView.bounds.height)")
            }
            if let s = scrolls.first, let doc = s.documentView {
                let maxY = max(0, doc.frame.height - s.contentView.bounds.height)
                s.contentView.scroll(to: NSPoint(x: 0, y: maxY))
                s.reflectScrolledClipView(s.contentView)
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                print("[diag] 已滚到底部 y=\(Int(maxY))，当前 clip y=\(Int(s.contentView.bounds.origin.y))")
                shoot(cv, name: "31-real-panel-bottom", dir: dir)
            }
        }
    }

    @MainActor
    private static func shoot(_ view: NSView, name: String, dir: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let path = "\(dir)/\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("[diag] 截图 → \(path)")
        }
    }

    @MainActor
    private static func findScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let s = view as? NSScrollView { found.append(s) }
        for sub in view.subviews { found.append(contentsOf: findScrollViews(in: sub)) }
        return found
    }

    @MainActor
    private static func postClick(on window: NSWindow) {
        let p = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let now = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            NSApp.postEvent(e, atStart: true)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    @MainActor
    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews {
            if let b = findStatusButton(in: sub) { return b }
        }
        return nil
    }

    @MainActor
    private static func dumpView(_ view: NSView?, depth: Int) {
        guard let view else { return }
        let pad = String(repeating: "  ", count: depth + 1)
        print("[diag]\(pad)\(type(of: view)) \(Int(view.frame.width))x\(Int(view.frame.height))")
        guard depth < 4 else { return }
        for sub in view.subviews { dumpView(sub, depth: depth + 1) }
    }

    @MainActor
    private static func dumpWindows(_ tag: String) {
        print("[diag] \(tag) 窗口数=\(NSApp.windows.count)")
        for w in NSApp.windows {
            print("[diag]   \(type(of: w)) \(Int(w.frame.width))x\(Int(w.frame.height)) "
                  + "visible=\(w.isVisible) level=\(w.level.rawValue)")
        }
    }

    @MainActor
    private static func statusButton() -> NSStatusBarButton? {
        for w in NSApp.windows {
            if let b = w.contentView as? NSStatusBarButton { return b }
            if let b = w.contentView?.subviews.compactMap({ $0 as? NSStatusBarButton }).first {
                return b
            }
        }
        return nil
    }

    @MainActor
    private static func printSnapshot(engine: MonitorEngine, settings: AppSettings) {
        let snap = engine.snapshot
        print("[probe] 链路=\(engine.link) mock=\(settings.mockMode) 目标=\(settings.baseURL?.absoluteString ?? "nil")")
        print("[probe] 记住密码=\(settings.rememberPassword) 密码已填=\(!settings.password.isEmpty) "
              + "面板高=\(Int(settings.panelContentHeight))pt 不限量=\(settings.trafficUnlimited)")
        print("[probe] 开机自启=\(LaunchAtLogin.shared.state.label) "
              + "在Applications=\(LaunchAtLogin.shared.installedInApplications)")
        print("[probe] 运营商=\(Fmt.orDash(snap.info?.carrier)) "
              + "网络=\(Fmt.orDash(snap.band?.networkType ?? snap.info?.networkType)) "
              + "频段=\(Fmt.orDash(snap.band?.band)) "
              + "RSRP=\(snap.band?.rsrp.map { String(format: "%.1f", $0) } ?? "nil") "
              + "签约下/上=\(snap.info?.downlinkRate.map(String.init) ?? "nil")/\(snap.info?.uplinkRate.map(String.init) ?? "nil")")
        print("[probe] 下行=\(Fmt.rate(snap.downloadBytesPerSecond)) "
              + "上行=\(Fmt.rate(snap.uploadBytesPerSecond)) "
              + "网卡=\(snap.interfaceName ?? "nil") 采样=\(engine.downTrend.count)")
    }

    // MARK: - 通道 1：ImageRenderer（纯 SwiftUI）

    @MainActor
    private static func imageCases(dir: String, settings: AppSettings, engine: MonitorEngine) {
        let dashboard = DashboardView()
            .environmentObject(settings)
            .environmentObject(engine)
        let settingsView = SettingsView(onClose: {})
            .environmentObject(settings)
            .environmentObject(engine)

        render(AnyView(dashboard), name: "01-dashboard", dir: dir, height: nil)
        render(AnyView(settingsView), name: "02-settings", dir: dir, height: nil)
    }

    @MainActor
    private static func render(_ view: AnyView, name: String, dir: String, height: CGFloat?) {
        var content = AnyView(view.frame(width: Theme.contentWidth))
        if let height {
            content = AnyView(content.frame(height: height))
        }
        let renderer = ImageRenderer(content: content.background(Theme.background))
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[probe] \(name): ❌ 渲染失败")
            return
        }
        let path = "\(dir)/\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("[probe] \(name): \(Int(image.size.width))x\(Int(image.size.height))pt → \(path)")
    }

    // MARK: - 通道 2：真实 NSWindow（能渲染 ScrollView / NSViewRepresentable）

    @MainActor
    private static func windowCases(dir: String, settings: AppSettings, engine: MonitorEngine) {
        let tail = AnyView(
            VStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { i in
                    InfoRow(label: "行 \(i + 1)", value: "值 \(i + 1)")
                }
            }
        )
        let scrollProbe = AnyView(
            ScrollView(.vertical, showsIndicators: false) {
                CardBox(title: "② SwiftUI ScrollView（300pt 视口内 8 行）") { tail }
                    .padding(10)
            }
            .frame(height: 300)
        )
        let plainProbe = AnyView(
            CardBox(title: "① 纯 VStack（8 行，无滚动）") { tail }
                .padding(10)
        )
        let dashboard = AnyView(
            DashboardView()
                .environmentObject(settings)
                .environmentObject(engine)
        )
        let settingsView = AnyView(
            SettingsView(onClose: {})
                .environmentObject(settings)
                .environmentObject(engine)
        )

        renderInWindow(plainProbe, name: "20-w-plain", dir: dir, height: 300)
        renderInWindow(scrollProbe, name: "21-w-scroll", dir: dir, height: 300)
        renderInWindow(dashboard, name: "22-w-dashboard", dir: dir, height: 980)

        // 设置页有 7 个卡片，一屏（720pt，还要受屏幕可用高度兜底）装不下，改设置页时
        // 会看不到下面那块。离屏窗口没有这个限制，这里临时铺满出整页图。
        // 用户的 panelContentHeight 全程不动 —— 不然图里那个高度滑块会显示成假值。
        Theme.heightCapOverride = 1250
        renderInWindow(settingsView, name: "23-w-settings", dir: dir, height: 1250)
        Theme.heightCapOverride = nil
    }

    @MainActor
    private static func renderInWindow(_ view: AnyView, name: String,
                                       dir: String, height: CGFloat?) {
        let width = Theme.contentWidth
        let hosting = NSHostingView(
            rootView: view.frame(width: width).background(Theme.background)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 100)

        // 关键数值：菜单栏面板就是按 SWiftUI 的「自适应高度」决定窗口高度的。
        // 之前 ScrollView 用 maxHeight 时这个值会塌到接近 0，面板就只剩头尾。
        let fit = hosting.fittingSize
        let renderHeight = height ?? max(60, fit.height)
        print("[probe] \(name): 自适应高度 = \(Int(fit.width))x\(Int(fit.height))pt，按 \(Int(renderHeight))pt 出图")

        hosting.frame = NSRect(x: 0, y: 0, width: width, height: renderHeight)

        // 放到屏幕外，避免干扰用户
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: width, height: renderHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()

        // 让 AppKit 完成一轮布局与绘制
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("[probe] \(name): ❌ 无法创建位图")
            window.orderOut(nil)
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        if let png = rep.representation(using: .png, properties: [:]) {
            let path = "\(dir)/\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("[probe] \(name): → \(path)")
        } else {
            print("[probe] \(name): ❌ 编码失败")
        }
        window.orderOut(nil)
    }
}
