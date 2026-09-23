import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: MonitorEngine

    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)

            if showSettings {
                SettingsView(onClose: { showSettings = false })
                footer
            } else {
                // 这里必须给 ScrollView 一个「确定高度」而不是 maxHeight。
                // 用 maxHeight 时高度是弹性的，菜单栏面板自适应算出来接近 0，
                // 整个面板会塌成只剩头部和底部、内容区全黑（实测踩过）。
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: Theme.cardSpacing) {
                        if hasNotice { notices }

                        NetworkInfoPanel(info: engine.snapshot.info,
                                         band: engine.snapshot.band)

                        SignalPanel(band: engine.snapshot.band)

                        SpeedPanel(download: engine.snapshot.downloadBytesPerSecond,
                                   upload: engine.snapshot.uploadBytesPerSecond,
                                   downTrend: engine.downTrend,
                                   upTrend: engine.upTrend,
                                   interfaceName: engine.snapshot.interfaceName,
                                   warmingUp: engine.speedWarmingUp)

                        TrafficPanel(engine: engine)

                        HardwarePanel(info: engine.snapshot.info)

                        if let error = engine.lastError, engine.link.isOnline {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .frame(height: Theme.panelHeight(preferred: settings.panelContentHeight))

                footer
            }
        }
        .frame(width: Theme.contentWidth)
        .background(Theme.pageGradient)
        // 首次启动引导：新用户直接落在设置页填地址/密码
        .onAppear {
            if settings.pendingSettingsOpen {
                settings.pendingSettingsOpen = false
                showSettings = true
            }
        }
    }

    // MARK: - 顶部标题条

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("CPE Monitor")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            StatusPill(text: linkTitle, color: linkColor)

            IconButton(systemName: "arrow.clockwise", help: "立即刷新") {
                Task { await engine.refreshNow() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 通知条

    private var hasNotice: Bool {
        settings.mockMode || !engine.link.isOnline || keychainBlocked
    }

    private var keychainBlocked: Bool {
        settings.rememberPassword && settings.password.isEmpty
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if settings.mockMode {
                NoticeBar(kind: .info,
                          title: "演示模式",
                          detail: "当前展示的是模拟数据，没有连接真机。可在设置 → 高级里关闭。")
            }

            switch engine.link {
            case .unauthorized:
                NoticeBar(kind: .warn,
                          title: "鉴权失败，实时速率不可用",
                          detail: "免登录的运营商、信号与硬件数据仍然正常。",
                          hint: "请在设置里填入后台密码，并打开「记住」。")
            case .failed(let message):
                NoticeBar(kind: .error,
                          title: "连接失败",
                          detail: message,
                          hint: "请确认设备已开机、Mac 已连上它发出的 Wi-Fi，并检查设置里的地址与端口。")
            default:
                EmptyView()
            }

            if keychainBlocked {
                NoticeBar(kind: .warn,
                          title: "钥匙串未授权",
                          detail: "读取已保存的密码时被系统拦下了，实时速率会一直是 0。",
                          actionTitle: "去设置重输密码",
                          action: { showSettings = true })
            }
        }
    }

    // MARK: - 底部工具条

    private var footer: some View {
        HStack(spacing: 8) {
            ToolbarButton(title: "打开后台", systemName: "safari") {
                openWebConsole()
            }

            Spacer(minLength: 0)

            IconTile(systemName: "arrow.clockwise", help: "立即刷新") {
                Task { await engine.refreshNow() }
            }
            IconTile(systemName: showSettings ? "list.bullet" : "slider.horizontal.3",
                     help: showSettings ? "返回监控" : "设置") {
                showSettings.toggle()
            }
            IconTile(systemName: "power", color: Theme.error, help: "退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private func openWebConsole() {
        guard let url = settings.baseURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 派生文案

    private var linkColor: Color {
        switch engine.link {
        case .online: return Theme.ok
        case .connecting, .idle: return Theme.levelFair
        case .unauthorized: return Theme.warn
        case .failed: return Theme.error
        }
    }

    private var linkTitle: String {
        switch engine.link {
        case .online: return "在线"
        case .connecting: return "连接中…"
        case .idle: return "未连接"
        case .unauthorized: return "鉴权失败"
        case .failed: return "连接失败"
        }
    }

    private var subtitle: String {
        let host = settings.host
        if let updated = engine.lastUpdated {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "\(host):\(settings.port) · \(formatter.string(from: updated))"
        }
        return "\(host):\(settings.port)"
    }
}
