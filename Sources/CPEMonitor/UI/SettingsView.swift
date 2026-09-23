import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: MonitorEngine
    @ObservedObject private var launch = LaunchAtLogin.shared

    let onClose: () -> Void

    @State private var probing = false
    @State private var probeResult: String?
    @State private var probeOK = false

    @State private var clearingCache = false
    @State private var cacheMessage: String?
    @State private var cacheOK = true

    @State private var confirmReset = false
    @State private var resettingTraffic = false
    @State private var resetMessage: String?
    @State private var resetOK = true

    var body: some View {
        // 同 DashboardView：必须给确定高度，不能用 maxHeight（面板会塌掉）
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Theme.cardSpacing) {
                connectionPanel
                authPanel
                displayPanel
                startupPanel
                trafficPanel
                maintenancePanel
                advancedPanel
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 10)
        }
        .frame(height: Theme.panelHeight(preferred: settings.panelContentHeight))
        // 用户可能在系统设置里直接改过登录项，每次进来重新读一遍真实状态
        .onAppear { launch.refresh() }
    }

    // MARK: - 连接

    private var connectionPanel: some View {
        CardBox(title: "设备连接") {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("地址")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    TextField("192.168.1.1", text: $settings.host)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(fieldBackground)
                }

                HStack(spacing: 6) {
                    Text("端口")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    TextField("6677", value: $settings.port, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(fieldBackground)
                        .frame(width: 86)
                    Toggle("HTTPS", isOn: $settings.useHTTPS)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text("间隔")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    Slider(value: $settings.refreshInterval, in: 1...10, step: 0.5)
                        .controlSize(.mini)
                    Text(String(format: "%.1fs", settings.refreshInterval))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 38, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Button {
                        probe()
                    } label: {
                        HStack(spacing: 4) {
                            if probing {
                                ProgressView().controlSize(.mini)
                            }
                            Text("测试连接")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.accentSoft)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(probing)

                    if let probeResult {
                        Text(probeResult)
                            .font(.system(size: 11))
                            .foregroundStyle(probeOK ? Theme.ok : Theme.error)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 鉴权

    private var authPanel: some View {
        CardBox(title: "后台密码") {
            VStack(alignment: .leading, spacing: 8) {
                Text("实时速率走 /api/netif/stats，需要登录令牌。其余数据免登录直读。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    SecureField("密码", text: $settings.password)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(fieldBackground)
                        .disabled(!settings.rememberPassword)
                        .opacity(settings.rememberPassword ? 1 : 0.45)

                    Toggle("记住", isOn: $settings.rememberPassword)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 8) {
                    Button {
                        Task {
                            let ok = await loginProbe()
                            probeOK = ok
                            probeResult = ok ? "登录成功" : "登录失败"
                        }
                    } label: {
                        Text("验证登录")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.accentSoft)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!settings.rememberPassword || settings.password.isEmpty)

                    Button {
                        settings.forgetPassword()
                    } label: {
                        Text("清除已存密码")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 显示

    private var displayPanel: some View {
        CardBox(title: "菜单栏显示") {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("内容")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    Picker("", selection: $settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }

                Toggle("明文显示 IMEI / ICCID", isOn: $settings.showSensitive)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 6) {
                    Text("高度")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    Slider(value: $settings.panelContentHeight, in: 400...1100, step: 20)
                        .controlSize(.mini)
                    Text("\(Int(settings.panelContentHeight))pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Text("面板内容区高度。浅色卡片版式全展开实测 707pt（默认 720 正好不滚动）；本设置页更长，需要滚动。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.showSensitive, let info = engine.snapshot.info {
                    VStack(spacing: 5) {
                        InfoRow(label: "IMEI", value: Fmt.orDash(info.imei), mono: true)
                        InfoRow(label: "ICCID", value: Fmt.orDash(info.iccid), mono: true)
                        InfoRow(label: "IMSI", value: Fmt.orDash(info.imsi), mono: true)
                    }
                }
            }
        }
    }

    // MARK: - 开机自启

    private var startupPanel: some View {
        CardBox(title: "开机自启", systemImage: "power", iconColor: Theme.accent) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("登录时自动启动", isOn: launchBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(!launch.isAvailable)

                HStack(spacing: 5) {
                    Circle()
                        .fill(launchOk ? Theme.ok : Theme.textTertiary)
                        .frame(width: 5, height: 5)
                    Text(launch.state.label)
                        .font(.system(size: 10))
                        .foregroundStyle(launchOk ? Theme.ok : Theme.textTertiary)
                    Spacer(minLength: 0)
                }

                if let error = launch.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if launch.state == .requiresApproval {
                    Button {
                        launch.openSystemLoginItems()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10, weight: .semibold))
                            Text("打开「登录项」设置")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                // ad-hoc 签名的 App 换位置 / 重新构建后，已注册的登录项会失效
                Text(launch.installedInApplications
                     ? "开关直接改系统「登录项」，可随时在 系统设置 → 通用 → 登录项 里关掉。"
                     : "当前 App 不在 /Applications 下。建议先 ./build.sh --install 装过去再开启，"
                       + "否则移动位置或重新构建后登录项会失效（重新拨一次开关即可恢复）。")
                    .font(.system(size: 10))
                    .foregroundStyle(launch.installedInApplications
                                     ? Theme.textTertiary : Theme.levelFair)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchOk: Bool {
        launch.state == .enabled
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launch.state == .enabled || launch.state == .requiresApproval },
            set: { launch.setEnabled($0) }
        )
    }

    // MARK: - 套餐

    private var trafficPanel: some View {
        CardBox(title: "套餐设置") {
            VStack(alignment: .leading, spacing: 8) {
                Text("设备侧未上报账单周期时，本月/当日由 vnstat 明细提供。这里可覆盖套餐口径。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("不限量套餐", isOn: $settings.trafficUnlimited)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                if !settings.trafficUnlimited {
                    HStack(spacing: 6) {
                        Text("套餐总量")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        TextField("100", value: quotaBinding, format: .number)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(fieldBackground)
                            .frame(width: 86)
                        Text("GB")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - 设备维护

    /// 两个真正落在设备上的维护动作：
    /// 「清理设备缓存」= POST /api/clear_cache（内核 drop_caches）
    /// 「重置流量统计」= POST /api/set/total 传空参（删 vnstat 库并重建，不可撤销）
    private var maintenancePanel: some View {
        CardBox(title: "设备维护", systemImage: "wrench.and.screwdriver",
                iconColor: Theme.textSecondary) {
            VStack(alignment: .leading, spacing: 8) {
                Text("设备只有 200MB 内存，内核页缓存会长期占住一部分。清理走设备端 drop_caches，不打断任何正在运行的进程。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                InfoRow(label: "页缓存占用", value: Fmt.mb(info?.cachedRam), mono: true)

                HStack(spacing: 8) {
                    Button {
                        clearCache()
                    } label: {
                        HStack(spacing: 4) {
                            if clearingCache {
                                ProgressView().controlSize(.mini)
                            }
                            Text("清理设备缓存")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.accentSoft)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(clearingCache || settings.mockMode)

                    if let cacheMessage {
                        Text(cacheMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(cacheOK ? Theme.ok : Theme.error)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                Toggle("定时自动清理", isOn: $settings.autoClearEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                if settings.autoClearEnabled {
                    HStack(spacing: 6) {
                        Text("间隔")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 46, alignment: .leading)
                        Picker("", selection: $settings.autoClearInterval) {
                            ForEach(AutoClearInterval.allCases) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        Spacer(minLength: 0)
                    }

                    HStack(alignment: .top, spacing: 5) {
                        Circle()
                            .fill(engine.autoClearError == nil ? Theme.ok : Theme.error)
                            .frame(width: 5, height: 5)
                            .padding(.top, 4)
                        Text(engine.autoClearError ?? engine.autoClearStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(engine.autoClearError == nil
                                             ? Theme.textTertiary : Theme.error)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)

                if confirmReset {
                    Text("会删除设备上的 vnstat 数据库并重建，历史流量统计全部归零，无法撤销。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.error)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            resetTraffic()
                        } label: {
                            HStack(spacing: 4) {
                                if resettingTraffic {
                                    ProgressView().controlSize(.mini)
                                }
                                Text("确认重置")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.error)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.errorBg)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(resettingTraffic)

                        Button {
                            confirmReset = false
                        } label: {
                            Text("取消")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            confirmReset = true
                            resetMessage = nil
                        } label: {
                            Text("重置流量统计")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.mockMode)

                        if let resetMessage {
                            Text(resetMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(resetOK ? Theme.ok : Theme.error)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if settings.mockMode {
                    Text("演示模式下不会真的连设备：上面两个按钮不可用，定时清理也不会触发。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var info: DeviceInfo? { engine.snapshot.info }

    // MARK: - 高级

    private var advancedPanel: some View {
        CardBox(title: "高级") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("网卡")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    TextField("自动", text: $settings.interfaceOverride)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(fieldBackground)
                    Spacer(minLength: 0)
                }

                if !engine.availableInterfaces.isEmpty {
                    Text("设备上的网卡：" + engine.availableInterfaces.map(\.name).joined(separator: "、"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("离线演示模式（用假数据）", isOn: $settings.mockMode)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 8) {
                    Button {
                        engine.restart()
                    } label: {
                        Text("重连设备")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.accentSoft)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onClose()
                    } label: {
                        Text("返回监控")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Text(versionText)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - 辅助

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.panelSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
    }

    /// 版本号从 Info.plist 读。以前这里是硬编码的 "v0.1.0"，而 Resources/Info.plist
    /// 里写的是 1.0.0 —— 改 plist 打包后界面还显示旧版本，两处长期对不上。
    /// 未打包的 `swift build` 产物没有 Info.plist，落到 "dev"。
    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v" + (short ?? "dev")
    }

    private var quotaBinding: Binding<Double> {
        Binding(
            get: { Double(settings.manualQuotaBytes) / 1_073_741_824 },
            set: { settings.manualQuotaBytes = Int64($0 * 1_073_741_824) }
        )
    }

    private func probe() {
        guard let base = settings.baseURL else {
            probeOK = false
            probeResult = "地址无效"
            return
        }
        probing = true
        probeResult = nil

        Task {
            let client = APIClient(baseURL: base, token: nil)
            do {
                let info = try await client.info()
                probeOK = true
                probeResult = "已连通 · \(Fmt.orDash(info.hostname))"
            } catch {
                probeOK = false
                probeResult = error.localizedDescription
            }
            probing = false
        }
    }

    private func loginProbe() async -> Bool {
        guard let base = settings.baseURL else { return false }
        let client = APIClient(baseURL: base, token: nil)
        do {
            _ = try await client.login(password: settings.password)
            engine.restart()
            return true
        } catch {
            return false
        }
    }

    /// 清设备内核页缓存。engine 那侧清完会立刻回读一次 /api/info，
    /// 所以这里直接读 snapshot 就能拿到释放后的值。
    private func clearCache() {
        clearingCache = true
        cacheMessage = nil
        Task {
            do {
                try await engine.clearDeviceCache()
                cacheOK = true
                cacheMessage = "已清理 · 当前 \(Fmt.mb(engine.snapshot.info?.cachedRam))"
            } catch {
                cacheOK = false
                cacheMessage = error.localizedDescription
            }
            clearingCache = false
        }
    }

    /// 重置设备端 vnstat 统计。进这个函数前，按钮已经让用户二次确认过。
    private func resetTraffic() {
        resettingTraffic = true
        resetMessage = nil
        Task {
            do {
                try await engine.resetDeviceTraffic()
                resetOK = true
                resetMessage = "已重置"
                confirmReset = false
            } catch {
                resetOK = false
                resetMessage = error.localizedDescription
            }
            resettingTraffic = false
        }
    }
}
