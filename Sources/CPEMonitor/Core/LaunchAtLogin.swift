import Foundation
import ServiceManagement
import Combine

/// 开机自启。走系统「登录项」（macOS 13+ 的 `SMAppService`），
/// 而不是往 `~/Library/LaunchAgents` 塞 plist：
///
///   - 不需要 sudo、不需要用户授权脚本，系统直接认这个 App
///   - 系统设置 → 通用 → 登录项 里能看到、随时能关，用户有掌控感
///   - 关掉时干净卸载，不留残留文件
///
/// 注意：构建脚本用的是 **ad-hoc 签名**（`codesign --sign -`），每次重新构建
/// 签名都会变，系统可能认不出旧记录 —— 表现为「开了但重启后没起来」，
/// 重新拨一次开关即可。把 App 装到 `/Applications` 会更稳。
final class LaunchAtLogin: ObservableObject {

    static let shared = LaunchAtLogin()

    enum State: Equatable {
        /// 已加入登录项
        case enabled
        /// 未加入
        case disabled
        /// 已注册，但被系统要求在「登录项」里手动放行
        case requiresApproval
        /// 系统里找不到这个 App（比如从临时目录跑起来的）
        case notFound
        /// macOS 13 以下
        case unsupported

        var label: String {
            switch self {
            case .enabled: return "已加入登录项，登录后自动启动"
            case .disabled: return "未加入登录项"
            case .requiresApproval: return "已被系统拦下，需要在「登录项」里允许"
            case .notFound: return "系统没能定位到这个 App"
            case .unsupported: return "需要 macOS 13 及以上"
            }
        }
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var lastError: String?

    private init() {
        refresh()
    }

    var isAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// 读取系统真实状态。用户可能在系统设置里改过，所以每次显示设置页都要刷一次。
    func refresh() {
        guard #available(macOS 13.0, *) else {
            state = .unsupported
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:          state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notFound:         state = .notFound
        case .notRegistered:    state = .disabled
        @unknown default:       state = .disabled
        }
    }

    func setEnabled(_ on: Bool) {
        guard #available(macOS 13.0, *) else {
            lastError = "需要 macOS 13 及以上"
            return
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemLoginItems() {
        guard #available(macOS 13.0, *) else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// App 是否装在 /Applications 下 —— 换位置会让已注册的登录项失效
    var installedInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    // MARK: - 命令行诊断

    /// `CPEMonitor --login-item status|on|off`
    ///
    /// 用来在不点界面的情况下验证登录项注册链路（确认到底是系统不给注册、
    /// 还是只是界面状态没刷新）。
    @discardableResult
    static func handleCLI() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--login-item"),
              idx + 1 < args.count else { return false }

        let action = args[idx + 1]
        let item = LaunchAtLogin.shared

        print("[login-item] bundle = \(Bundle.main.bundlePath)")
        print("[login-item] 在 /Applications 下 = \(item.installedInApplications)")

        switch action {
        case "status":
            break
        case "on":
            item.setEnabled(true)
        case "off":
            item.setEnabled(false)
        default:
            print("[login-item] ❌ 未知动作：\(action)（可用 status / on / off）")
            exit(2)
        }

        print("[login-item] 动作=\(action)  状态=\(item.state.label)  "
              + "错误=\(item.lastError ?? "无")")

        let ok: Bool
        switch action {
        case "status": ok = true
        case "on":     ok = item.state == .enabled
        case "off":    ok = item.state == .disabled
        default:       ok = false
        }
        exit(ok ? 0 : 1)
    }
}
