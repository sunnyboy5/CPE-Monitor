import SwiftUI
import AppKit

/// 全局单例环境。App 与 AppDelegate 都要用同一份实例，
/// 所以在这里集中创建，避免 SwiftUI 的 @StateObject 生命周期限制。
@MainActor
enum AppEnv {
    static let settings: AppSettings = {
        // 保留用户已保存的配置；命令行给了参数则临时覆盖（不写盘）
        let s = AppSettings(
            host: CLI.value(for: "--host"),
            port: CLI.value(for: "--port").flatMap(Int.init),
            password: CLI.value(for: "--password")
        )
        // 命令行开关属于一次性覆盖，不能污染用户配置
        s.withoutPersistence {
            if CommandLine.arguments.contains("--mock") { s.mockMode = true }
            // 强制走真机（关掉演示数据），用于确认确实在连设备
            if CommandLine.arguments.contains("--live") { s.mockMode = false }
            // 命令行给了密码就当作「本次会话记住」，否则引擎不会去登录，
            // 实时速率会一直是 0（引擎要求 rememberPassword 才自动换 token）
            if CLI.value(for: "--password") != nil { s.rememberPassword = true }
            // 临时打开定时清理（同样不写盘）。间隔仍按用户已保存的配置走，
            // 用来验证自动清理链路，免得上真机干等一个周期。
            if CommandLine.arguments.contains("--auto-clear") { s.autoClearEnabled = true }
        }
        return s
    }()

    static let engine: MonitorEngine = MonitorEngine(settings: settings)

    /// 把当前（可能来自命令行的）地址写进 UserDefaults，供下次启动沿用
    static func persistConnection() {
        UserDefaults.standard.set(settings.host, forKey: "conn.host")
        UserDefaults.standard.set(settings.port, forKey: "conn.port")
    }
}

/// 命令行参数读取
enum CLI {
    static func value(for flag: String) -> String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        let v = args[idx + 1]
        return v.hasPrefix("--") ? nil : v
    }
}

@main
struct CPEMonitorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings: AppSettings
    @StateObject private var engine: MonitorEngine

    /// `--window` 以独立窗口启动（便于演示、截图；菜单栏图标同时保留）
    static let windowModeRequested = CommandLine.arguments.contains("--window")

    init() {
        if SelfTest.isRequested {
            SelfTest.run()
        }
        // `--login-item status|on|off`：登录项注册链路诊断（会自己 exit）
        LaunchAtLogin.handleCLI()

        _settings = StateObject(wrappedValue: AppEnv.settings)
        _engine = StateObject(wrappedValue: AppEnv.engine)

        // 菜单栏常驻应用需要在启动时即开始轮询，不能等面板被打开
        Task { @MainActor in
            AppEnv.engine.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(settings)
                .environmentObject(engine)
        } label: {
            MenuBarLabel(engine: engine, mode: settings.menuBarMode)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 全局锁定浅色外观：整块界面是浅底白卡，跟着系统切深色会出现
        // 深色滚动条、深色原生控件，和版式不搭。
        NSApp.appearance = NSAppearance(named: .aqua)

        // 离屏渲染诊断：渲完即退出，不建任何窗口
        if Probe.isRequested {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + Probe.delay) {
                MainActor.assumeIsolated { Probe.run() }
            }
            return
        }

        // 首次运行：这个 App 是 LSUIElement（不占 Dock、不自动弹窗），
        // 新用户装完只会看到一个菜单栏小图标，很容易以为「装失败了」。
        // 所以第一次启动直接把窗口打开并停在设置页，让他先填设备地址。
        let welcomed = UserDefaults.standard.bool(forKey: AppDelegate.welcomeKey)
        if !welcomed && !AppDelegate.suppressWelcome {
            UserDefaults.standard.set(true, forKey: AppDelegate.welcomeKey)
            AppEnv.settings.pendingSettingsOpen = true
            print("[welcome] 首次启动：打开窗口并停在设置页")
            NSApp.setActivationPolicy(.regular)
            openMainWindow()
            return
        }

        guard CPEMonitorApp.windowModeRequested else {
            // 无 Dock 图标，只驻留菜单栏
            NSApp.setActivationPolicy(.accessory)
            return
        }

        NSApp.setActivationPolicy(.regular)
        openMainWindow()
    }

    /// UserDefaults 键：是否已经给用户看过首次启动引导
    static let welcomeKey = "ui.didWelcome"

    /// 诊断/自检模式不弹引导（否则每次跑 probe 都会多开一个窗口）
    static var suppressWelcome: Bool {
        CommandLine.arguments.contains("--no-welcome")
            || CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--watch")
            || CommandLine.arguments.contains("--login-item")
    }

    private func openMainWindow() {
        let root = DashboardView()
            .environmentObject(AppEnv.settings)
            .environmentObject(AppEnv.engine)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 408, height: 920)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 408, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CPE Monitor"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 408, height: 920))
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--verbose") {
            let f = window.frame
            let line = "[verbose] 窗口已创建 frame=\(Int(f.width))x\(Int(f.height)) "
                + "visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "policy=\(NSApp.activationPolicy().rawValue) "
                + "mock=\(AppEnv.settings.mockMode) "
                + "target=\(AppEnv.settings.baseURL?.absoluteString ?? "nil")\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 关掉窗口后仍驻留菜单栏，不退出进程
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

/// 菜单栏标题。读取引擎状态，按用户选择的模式展示。
struct MenuBarLabel: View {
    @ObservedObject var engine: MonitorEngine
    let mode: MenuBarMode

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            if let text = text {
                Text(text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            }
        }
    }

    private var iconName: String {
        switch engine.link {
        case .online:
            return "antenna.radiowaves.left.and.right"
        case .connecting, .idle:
            return "arrow.triangle.2.circlepath"
        case .unauthorized, .failed:
            return "exclamationmark.triangle"
        }
    }

    private var text: String? {
        let snap = engine.snapshot
        switch mode {
        case .iconOnly:
            return nil
        case .speed:
            let down = Fmt.rateCompact(snap.downloadBytesPerSecond)
            let up = Fmt.rateCompact(snap.uploadBytesPerSecond)
            return "↓\(down) ↑\(up)"
        case .signal:
            guard let rsrp = snap.band?.rsrp, rsrp != 0 else { return "--" }
            return String(format: "%.0fdBm", rsrp)
        case .temperature:
            guard let t = snap.info?.thermalTemp, t > 0 else { return "--" }
            return String(format: "%.0f°C", t)
        case .cpu:
            guard let c = snap.info?.cpuUsage else { return "--" }
            return String(format: "%.0f%%", c)
        case .memory:
            guard let m = snap.info?.memoryUsagePercent else { return "--" }
            return String(format: "%.0f%%", m)
        }
    }
}
