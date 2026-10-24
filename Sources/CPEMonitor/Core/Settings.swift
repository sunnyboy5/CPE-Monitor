import Foundation
import Combine

/// 菜单栏标题展示模式
enum MenuBarMode: String, CaseIterable, Identifiable {
    case iconOnly
    case speed
    case signal
    case temperature
    case cpu
    case memory

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .speed: return "实时速率"
        case .signal: return "信号强度"
        case .temperature: return "芯片温度"
        case .cpu: return "CPU 占用"
        case .memory: return "内存占用"
        }
    }
}

/// 定时清理设备页缓存的间隔。
///
/// 清理动作是设备端的 `echo 3 > /proc/sys/vm/drop_caches`，会顺带丢掉 dentry/inode 缓存，
/// 短时间里设备要重新预热，所以最短只给到 15 分钟。
enum AutoClearInterval: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case threeHours
    case sixHours
    case twelveHours
    case daily

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fifteenMinutes: return "每 15 分钟"
        case .thirtyMinutes:  return "每 30 分钟"
        case .oneHour:        return "每 1 小时"
        case .threeHours:     return "每 3 小时"
        case .sixHours:       return "每 6 小时"
        case .twelveHours:    return "每 12 小时"
        case .daily:          return "每 24 小时"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes:  return 30 * 60
        case .oneHour:        return 60 * 60
        case .threeHours:     return 3 * 60 * 60
        case .sixHours:       return 6 * 60 * 60
        case .twelveHours:    return 12 * 60 * 60
        case .daily:          return 24 * 60 * 60
        }
    }
}

/// 用户配置，持久化到 UserDefaults；密码单独走钥匙串。
///
/// `persist: false` 时所有赋值只留在内存里，不碰 UserDefaults 也不碰钥匙串，
/// 供命令行巡检等一次性诊断场景使用，避免冲掉用户的真实配置。
final class AppSettings: ObservableObject {

    private enum Key {
        static let host = "conn.host"
        static let port = "conn.port"
        static let backend = "conn.backend"
        static let useHTTPS = "conn.useHTTPS"
        static let refreshInterval = "conn.refreshInterval"
        static let menuBarMode = "ui.menuBarMode"
        static let interfaceOverride = "conn.interfaceOverride"
        static let trafficQuota = "traffic.manualQuotaBytes"
        static let trafficUnlimited = "traffic.unlimited"
        static let rememberPassword = "auth.remember"
        static let mockMode = "dev.mockMode"
        static let showSensitive = "ui.showSensitive"
        static let panelContentHeight = "ui.panelContentHeight"
        static let autoClearEnabled = "maintenance.autoClearEnabled"
        static let autoClearInterval = "maintenance.autoClearInterval"
        /// 版式版本号，用于一次性迁移面板高度
        static let layoutVersion = "ui.layoutVersion"
    }

    private static let passwordAccount = "device-password"

    private let defaults = UserDefaults.standard
    private var persist: Bool

    /// 设备地址，例如 192.168.1.100 或 cpe.example.com
    @Published var host: String {
        didSet { store(host, Key.host) }
    }

    /// 端口。3000 是 project-cpe 固件的默认端口；9527 是本机免登录只读管理页；
    /// 6677 兼容旧版 UDX710-TOOLS。具体走哪套协议看 `backend`。
    @Published var port: Int {
        didSet { store(port, Key.port) }
    }

    /// 设备端跑的是哪套固件协议。ip:port 之外还要认协议 —— 三者接口完全不兼容。
    @Published var backend: DeviceBackend {
        didSet { store(backend.rawValue, Key.backend) }
    }

    @Published var useHTTPS: Bool {
        didSet { store(useHTTPS, Key.useHTTPS) }
    }

    /// 刷新间隔（秒）
    @Published var refreshInterval: Double {
        didSet { store(refreshInterval, Key.refreshInterval) }
    }

    @Published var menuBarMode: MenuBarMode {
        didSet { store(menuBarMode.rawValue, Key.menuBarMode) }
    }

    /// 手动指定统计实时速率的网卡；留空则自动挑选
    @Published var interfaceOverride: String {
        didSet { store(interfaceOverride, Key.interfaceOverride) }
    }

    /// 手动填写套餐总量（字节）。为 0 时表示「不限量」
    @Published var manualQuotaBytes: Int64 {
        didSet { store(manualQuotaBytes, Key.trafficQuota) }
    }

    @Published var trafficUnlimited: Bool {
        didSet { store(trafficUnlimited, Key.trafficUnlimited) }
    }

    /// 是否记住后台密码（存钥匙串），用于拿实时速率
    @Published var rememberPassword: Bool {
        didSet { store(rememberPassword, Key.rememberPassword) }
    }

    /// 离线演示模式，用假数据跑 UI
    @Published var mockMode: Bool {
        didSet { store(mockMode, Key.mockMode) }
    }

    /// 是否明文显示 IMEI/ICCID
    @Published var showSensitive: Bool {
        didSet { store(showSensitive, Key.showSensitive) }
    }

    /// 面板内容区高度（pt）。浅色卡片版式五个模块全展开实测 707pt，默认 720 正好不滚动。
    @Published var panelContentHeight: Double {
        didSet { store(panelContentHeight, Key.panelContentHeight) }
    }

    /// 定时自动清理设备页缓存（drop_caches）。默认关闭 —— 这是个有副作用的写操作，
    /// 不该在用户没主动打开时替他做决定。
    @Published var autoClearEnabled: Bool {
        didSet { store(autoClearEnabled, Key.autoClearEnabled) }
    }

    /// 定时清理的间隔
    @Published var autoClearInterval: AutoClearInterval {
        didSet { store(autoClearInterval.rawValue, Key.autoClearInterval) }
    }

    /// 首次启动引导：让界面打开时直接停在设置页。
    /// 只活在内存里，读完即清零，不落盘（也不需要 didSet 持久化）。
    var pendingSettingsOpen = false

    /// 内存中的密码副本（按需同步到钥匙串）
    @Published var password: String {
        didSet {
            guard persist, !suppressPasswordSync else { return }
            if rememberPassword {
                Keychain.save(password, account: Self.passwordAccount)
            } else {
                Keychain.delete(account: Self.passwordAccount)
            }
        }
    }

    /// 从钥匙串回填密码时置位，避免又写回钥匙串
    private var suppressPasswordSync = false

    /// - Parameters:
    ///   - persist: 为 false 时只写内存，不落盘
    ///   - host/port/password: 一次性覆盖值，仅在 persist 为 false 时有意义
    init(persist: Bool = true, host overrideHost: String? = nil,
         port overridePort: Int? = nil, password overridePassword: String? = nil) {
        self.persist = persist

        if persist {
            defaults.register(defaults: [
                Key.host: "192.168.66.1",
                // project-cpe 固件的后端默认监听 3000（`--port` 的默认值）。
                // 老用户已保存的 9527 / 6677 不会被这条默认值覆盖。
                //
                // ⚠️ 这里**不能**给 Key.backend 注册默认值：register 写的是
                // registration domain，读出来和「真的存过」无法区分，
                // 迁移逻辑会以为用户已经选过协议，从而永远不触发。
                Key.port: 3000,
                Key.useHTTPS: false,
                Key.refreshInterval: 2.0,
                Key.menuBarMode: MenuBarMode.speed.rawValue,
                Key.interfaceOverride: "",
                Key.trafficQuota: 0,
                Key.trafficUnlimited: true,
                Key.rememberPassword: false,
                Key.mockMode: false,
                Key.showSensitive: false,
                Key.panelContentHeight: 720.0,
                Key.autoClearEnabled: false,
                Key.autoClearInterval: AutoClearInterval.thirtyMinutes.rawValue
            ])

            // 版式换代时按实测高度校准一次面板高度（浅色卡片版式全展开实测 707pt，
            // 留一点余量，避免运营商角标换真图标后长出 2pt 就要滚动）。
            // 只迁移一次，之后尊重用户自己的调整。
            if defaults.integer(forKey: Key.layoutVersion) < 4 {
                defaults.set(720.0, forKey: Key.panelContentHeight)
                defaults.set(4, forKey: Key.layoutVersion)
            }
        }

        // didSet 在 init 阶段不会触发，所以这里直接读、直接赋。
        //
        // 协议和端口是两件事：固件协议决定调哪套接口，端口只是它的监听位置，
        // 允许把 project-cpe 跑在非 3000 端口上。所以协议单独存一个键。
        let storedBackendRaw = persist ? defaults.string(forKey: Key.backend) : nil
        let knownBackend = storedBackendRaw.flatMap(DeviceBackend.init(rawValue:))

        let resolvedPort: Int
        let resolvedBackend: DeviceBackend

        if let overridePort {
            // 命令行临时指定端口（--port）：按端口猜协议，一次性覆盖，不落盘
            resolvedPort = overridePort
            resolvedBackend = knownBackend ?? DeviceBackend.infer(fromPort: overridePort)
        } else if let knownBackend {
            resolvedPort = persist ? defaults.integer(forKey: Key.port) : knownBackend.defaultPort
            resolvedBackend = knownBackend
        } else {
            // 老配置里没有 conn.backend：这台设备接下来要刷 project-cpe 固件，
            // 一次性切过去（默认端口 3000）。用户随时能在设置里改回来。
            resolvedPort = DeviceBackend.projectCPE.defaultPort
            resolvedBackend = .projectCPE
            if persist {
                defaults.set(resolvedPort, forKey: Key.port)
                defaults.set(resolvedBackend.rawValue, forKey: Key.backend)
            }
        }

        host = overrideHost ?? (persist ? (defaults.string(forKey: Key.host) ?? "192.168.66.1")
                                        : "192.168.66.1")
        port = resolvedPort
        backend = resolvedBackend

        useHTTPS = persist ? defaults.bool(forKey: Key.useHTTPS) : false
        refreshInterval = persist ? defaults.double(forKey: Key.refreshInterval) : 2.0
        menuBarMode = persist
            ? (MenuBarMode(rawValue: defaults.string(forKey: Key.menuBarMode) ?? "") ?? .speed)
            : .speed
        interfaceOverride = persist ? (defaults.string(forKey: Key.interfaceOverride) ?? "") : ""
        manualQuotaBytes = persist ? Int64(defaults.integer(forKey: Key.trafficQuota)) : 0
        trafficUnlimited = persist ? defaults.bool(forKey: Key.trafficUnlimited) : true
        rememberPassword = persist ? defaults.bool(forKey: Key.rememberPassword) : false
        mockMode = persist ? defaults.bool(forKey: Key.mockMode) : false
        showSensitive = persist ? defaults.bool(forKey: Key.showSensitive) : false
        panelContentHeight = persist
            ? (defaults.object(forKey: Key.panelContentHeight) == nil
                ? 720.0 : defaults.double(forKey: Key.panelContentHeight))
            : 720.0
        autoClearEnabled = persist ? defaults.bool(forKey: Key.autoClearEnabled) : false
        autoClearInterval = persist
            ? (AutoClearInterval(rawValue: defaults.string(forKey: Key.autoClearInterval) ?? "")
                ?? .thirtyMinutes)
            : .thirtyMinutes

        if let overridePassword {
            password = overridePassword
        } else if persist {
            // 钥匙串读取会阻塞：重建后 ad-hoc 签名变了，或者这项是别的工具建的，
            // macOS 都会弹系统授权框等用户点确认，期间 SecItemCopyMatching 一直不返回。
            // 如果在 init 里同步读，菜单栏图标会迟迟不出现（看起来像根本没启动），
            // 所以改成后台线程读，读完再回主线程赋值 —— App 界面先出来，授权框慢慢点。
            password = ""
            Task.detached(priority: .utility) { [weak self] in
                let saved = Keychain.read(account: AppSettings.passwordAccount) ?? ""
                guard !saved.isEmpty else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.suppressPasswordSync = true
                    self.password = saved
                    self.suppressPasswordSync = false
                }
            }
        } else {
            password = ""
        }
    }

    private func store(_ value: Any, _ key: String) {
        guard persist else { return }
        defaults.set(value, forKey: key)
    }

    /// 临时关闭持久化执行一段赋值，结束后恢复。
    ///
    /// 命令行参数（`--mock` / `--host` 等）只是一次性的启动覆盖，
    /// 不应该写进 UserDefaults 污染用户的常规配置。
    func withoutPersistence(_ body: () -> Void) {
        let saved = persist
        persist = false
        body()
        persist = saved
    }

    /// 组装 base URL
    var usesLocalReadOnlyAPI: Bool { backend == .localReadOnly }
    var usesProjectCPE: Bool { backend == .projectCPE }
    /// 只有旧版 6677 需要后台密码换令牌
    var requiresPassword: Bool { backend.needsPassword }

    /// 切协议时顺手把端口带过去（用户仍可手动改）。已经在目标端口上就不动。
    func applyBackend(_ next: DeviceBackend) {
        backend = next
        if port != next.defaultPort { port = next.defaultPort }
    }

    var baseURL: URL? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return URL(string: text)
        }
        let scheme = useHTTPS ? "https" : "http"
        // 80/443 可以省略端口
        let needsPort = !((port == 80 && !useHTTPS) || (port == 443 && useHTTPS))
        text = needsPort ? "\(scheme)://\(text):\(port)" : "\(scheme)://\(text)"
        return URL(string: text)
    }

    /// 清除已保存的密码
    func forgetPassword() {
        Keychain.delete(account: Self.passwordAccount)
        rememberPassword = false
        password = ""
    }
}
