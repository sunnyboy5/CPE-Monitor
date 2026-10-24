import Foundation
import Combine

/// 轮询引擎：负责拉数据、自动登录、自动启用网卡监听、维护速率历史。
@MainActor
final class MonitorEngine: ObservableObject {

    @Published private(set) var snapshot: MonitorSnapshot = .empty
    @Published private(set) var link: LinkState = .idle
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var availableInterfaces: [NetifInfo] = []
    @Published private(set) var lastError: String?

    /// vnstat 的 `-l` 是实时进程，刚启动时还没有第一行数据，
    /// 这几秒内速率显示为「采样中」，避免误报成 0。
    @Published private(set) var speedWarmingUp = false

    /// 上一次定时清缓存的时间（nil = 还没触发过）
    @Published private(set) var lastAutoClearAt: Date?
    /// 最近一次定时清缓存的错误，成功后清空
    @Published private(set) var autoClearError: String?

    private unowned let settings: AppSettings

    var usesLocalReadOnlyAPI: Bool { settings.usesLocalReadOnlyAPI }

    private var token: String?
    private var activeInterface: String?
    private var loopTask: Task<Void, Never>?
    private var tick = 0
    private var monitorStartedAt: Date?

    // MARK: project-cpe 的慢变数据缓存
    //
    // project-cpe 的 /api/network、/api/cells、/api/qos 都要串行发 AT 指令
    // （ofono 单线程），而这几个值本身变化很慢。每轮都问既慢又折腾设备，
    // 所以只每 `cpeSlowEvery` 轮刷新一次，中间用缓存顶着。
    private var cpeDevice: CPEDevice?
    private var cpeSim: CPESim?
    private var cpeNetwork: CPENetwork?
    private var cpeQos: CPEQos?
    private var cpeCells: CPECells?
    private let cpeSlowEvery = 4

    /// 实时流量累加器：用 netif/stats 的累计字节数算"今日 / 本月"，
    /// 不依赖设备端 vnstat DB（vnstatd 不在设备上跑时 DB 不会更新）。
    /// 状态持久化到 UserDefaults，Mac 重启后能继续累计。
    private let trafficAccumulator = TrafficAccumulator()

    /// 波形保留的采样点数量
    private let historyCapacity = 48
    /// 慢循环周期（按快循环次数计）
    private let slowEvery = 8
    /// 开启网卡监听后等待多久才开始采用速率（秒）
    private let warmupSeconds: TimeInterval = 4

    init(settings: AppSettings) {
        self.settings = settings
    }

    deinit {
        loopTask?.cancel()
    }

    // MARK: - 生命周期

    func start() {
        stop()
        tick = 0
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        link = .idle
    }

    func restart() {
        token = nil
        activeInterface = nil
        availableInterfaces = []
        downHistory = []
        upHistory = []
        monitorStartedAt = nil
        speedWarmingUp = false
        // 换协议/换设备后旧快照没有意义，清空让 UI 重新长出来，
        // 免得把上一台设备的运营商、频段、流量串到新设备上
        snapshot = .empty
        cpeDevice = nil
        cpeSim = nil
        cpeNetwork = nil
        cpeQos = nil
        cpeCells = nil
        start()
    }

    /// 供「立即刷新」按钮调用
    func refreshNow() async {
        tick += 1
        await refreshOnce(forceSlow: true)
    }

    // MARK: - 主循环

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshOnce(forceSlow: tick % slowEvery == 0)

            let interval = max(0.5, settings.refreshInterval)
            let nanos = UInt64(interval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)

            if Task.isCancelled { return }
            tick += 1
        }
    }

    private func refreshOnce(forceSlow: Bool) async {
        if settings.mockMode {
            applyMock()
            return
        }

        guard settings.baseURL != nil else {
            link = .failed("地址无效，请到设置里填写设备 IP")
            return
        }

        if link == .idle { link = .connecting }

        if settings.usesLocalReadOnlyAPI {
            await refreshLocalReadOnly()
            return
        }

        if settings.usesProjectCPE {
            await refreshProjectCPE(forceSlow: forceSlow)
            return
        }

        do {
            let client = try await authedClient()

            // 免登录接口：一次拿全主状态与射频指标
            async let infoCall = client.info()
            async let bandCall = client.currentBand()
            let info = try await infoCall
            let band = try await bandCall

            var next = snapshot
            next.info = info
            if let data = band.data, !data.isEmpty { next.band = data }
            snapshot = next
            link = .online
            lastError = nil

            // 实时速率：需要 token + 网卡监听
            await refreshSpeed()

            if forceSlow {
                await refreshTraffic()
                await maybeAutoClearCache()
            }

            lastUpdated = Date()
        } catch APIError.unauthorized {
            token = nil
            link = .unauthorized
            lastError = "登录失败或密码未配置，实时速率不可用"
        } catch {
            link = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    /// 9527 与 UDX710-TOOLS/6677 的路由不同，且不需要令牌。
    /// 这里只访问设备管理页实际提供的两个只读 GET 接口。
    private func refreshLocalReadOnly() async {
        guard let base = settings.baseURL else { return }
        let client = APIClient(baseURL: base, token: nil)
        do {
            let system = try await client.localSysInfo()
            var info = system.deviceInfo
            if let temperature = try? await client.localTemperature() {
                info.thermalTemp = temperature.celsius
            }
            var next = MonitorSnapshot.empty
            next.info = info
            snapshot = next
            link = .online
            lastError = nil
            lastUpdated = Date()
        } catch {
            link = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    // MARK: - project-cpe 固件（Axum / 端口 3000 / 无鉴权）

    /// 一轮 project-cpe 采样。
    ///
    /// 只有 `/api/stats` 是每轮必打：它一次给齐网速、内存、CPU、温度、运行时长，
    /// 但服务端要**同步采样 1 秒**才能算出速率，所以它天然就是个慢接口
    /// （刷新间隔 2s + 服务端 1s ≈ 3s 一次更新）。
    /// 运营商 / 小区 / QoS / IMEI 这些走慢循环，靠 `cpeSlowEvery` 控制。
    private func refreshProjectCPE(forceSlow: Bool) async {
        guard let base = settings.baseURL else { return }
        let client = ProjectCPEClient(baseURL: base)

        do {
            let stats = try await client.stats()

            if forceSlow || tick % cpeSlowEvery == 0 {
                // 这五个接口都要串行发 AT（ofono 单线程），并发发出去也只是排队，
                // 但异步发起能让每个请求各自独立失败，一项挂掉不影响其它项。
                async let networkTask = client.network()
                async let qosTask = client.qos()
                async let cellsTask = client.cells()
                async let deviceTask = client.device()
                async let simTask = client.sim()

                // 拿不到就沿用上一次的值（小区信息本来就几十秒才变一次）
                if let v = try? await networkTask { cpeNetwork = v }
                if let v = try? await qosTask { cpeQos = v }
                if let v = try? await cellsTask { cpeCells = v }
                if let v = try? await deviceTask { cpeDevice = v }
                if let v = try? await simTask { cpeSim = v }
            }

            // ---- 硬件 + 系统信息（/api/stats）----
            var info = stats.hardwareInfo(into: DeviceInfo())

            // ---- 设备 / SIM / 网络 / QoS（慢循环缓存）----
            if let dev = cpeDevice {
                info.imei = dev.imei
                info.isActivated = (dev.online ?? false) ? 1 : 0
                info.airplaneMode = (dev.online ?? true) ? false : true
            }
            if let sim = cpeSim {
                info.iccid = sim.iccid
                info.imsi = sim.imsi
                info.simSlot = (sim.present ?? false) ? "1" : nil
            }
            if let net = cpeNetwork {
                info.carrier = net.operatorName
                info.selectNetworkMode = net.technologyPreference
                // 信号格用 0–100 的百分比；RSRP 走 cells
                info.signalStrength = net.signalPercent.map { String(Int($0.rounded())) }
            }
            if let qos = cpeQos {
                info.qci = qos.qci
                // AT+CGEQOSRDP 给的是 kbps，和旧固件同量纲，Fmt.signedMbps 直接可用
                info.downlinkRate = qos.dlSpeed
                info.uplinkRate = qos.ulSpeed
            }

            // ---- 小区 / 射频（慢循环缓存）----
            var band: BandData?
            if let cells = cpeCells {
                let mapped = cells.bandData
                if !mapped.isEmpty { band = mapped }
                info.networkType = cells.displayTech ?? info.networkType
                info.networkBand = mapped.band
                info.networkMode = NetworkGeneration.is5G(mapped.networkType) ? "5G" : "4G"
            }

            // ---- 实时速率 + 累计流量 ----
            let preferred = settings.interfaceOverride.isEmpty ? nil : settings.interfaceOverride
            let mapped = stats.netifStats(interface: preferred)
            let total = stats.trafficTotal(interface: mapped.name)

            var next = snapshot
            next.info = info
            if let band { next.band = band }
            next.trafficTotal = total
            // project-cpe 没有账单周期概念，「当月已用」无源可依 —— 保持 nil，
            // 面板会自动退到「设备总流量」那一列，而不是拿开机累计冒充月度用量。
            next.monthlyBytes = nil

            if mapped.stats.rx != nil || mapped.stats.tx != nil {
                next.stats = mapped.stats
                if let name = mapped.name { next.interfaceName = name }

                // 当日流量只能靠本机累加器：设备端没有 vnstat，也没有按日接口
                trafficAccumulator.update(rxBytes: mapped.stats.rx?.totalbytes,
                                          txBytes: mapped.stats.tx?.totalbytes,
                                          source: trafficSource(mapped.name))
                if let today = trafficAccumulator.todayBytes {
                    next.dailyBytes = today
                    next.dailyLabel = nil
                }
            }

            // 设置页的「设备上的网卡」提示
            if let list = stats.networkSpeed?.interfaces {
                availableInterfaces = list.compactMap { item in
                    guard let name = item.interface, !name.isEmpty else { return nil }
                    return NetifInfo(name: name, hwaddr: nil, inetAddr: nil, inet6Addr: nil,
                                     mask: nil, isUp: true, monitoring: nil)
                }
            }

            let down = next.downloadBytesPerSecond
            let up = next.uploadBytesPerSecond

            snapshot = next
            pushHistory(down: down, up: up)
            speedWarmingUp = false
            link = .online
            lastError = nil
            lastUpdated = Date()
        } catch {
            link = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }


    // MARK: - 鉴权

    private func authedClient() async throws -> APIClient {
        guard let base = settings.baseURL else { throw APIError.badURL }
        var client = APIClient(baseURL: base, token: token)
        if client.token == nil, canLogin {
            client.token = try await client.login(password: settings.password)
            token = client.token
        }
        return client
    }

    private var canLogin: Bool {
        settings.rememberPassword && !settings.password.isEmpty
    }

    /// 遇到 401 时清掉旧 token 重登一次
    private func withReauth<T>(_ operation: (APIClient) async throws -> T) async throws -> T {
        var client = try await authedClient()
        do {
            return try await operation(client)
        } catch APIError.unauthorized {
            guard canLogin else { throw APIError.unauthorized }
            token = nil
            guard let base = settings.baseURL else { throw APIError.badURL }
            client = APIClient(baseURL: base, token: nil)
            client.token = try await client.login(password: settings.password)
            token = client.token
            return try await operation(client)
        }
    }

    // MARK: - 设备维护

    /// 清理设备端内核页缓存（POST /api/clear_cache）。
    /// 走 withReauth，token 过期会自动重登一次。
    ///
    /// project-cpe 固件没有这个接口（它把维护入口收进了 /api/system/reboot + OTA），
    /// 所以这里直接拒绝，而不是发一个必然 404 的请求。
    func clearDeviceCache() async throws {
        guard !settings.usesLocalReadOnlyAPI else {
            throw APIError.disabled("9527 仅支持只读监控")
        }
        guard !settings.usesProjectCPE else {
            throw APIError.disabled("project-cpe 固件没有清理缓存接口")
        }
        try await withReauth { client in
            try await client.clearCache()
        }
        // 清完立刻回读一次 /api/info，让界面上的 cached_ram 马上反映释放结果
        await refreshNow()
    }

    /// 重置设备端 vnstat 统计（POST /api/set/total 空参，**不可撤销**）。
    func resetDeviceTraffic() async throws {
        guard !settings.usesLocalReadOnlyAPI else {
            throw APIError.disabled("9527 仅支持只读监控")
        }
        guard !settings.usesProjectCPE else {
            throw APIError.disabled("project-cpe 固件没有 vnstat 流量库")
        }
        try await withReauth { client in
            try await client.resetTrafficStats()
        }
        // 设备端库已清空：monthlyBytes 是从 /api/get/Total（vnstat total）来的，
        // 必须手动归零。不能指望 refreshTraffic 覆盖 —— 那条路径对
        // 「解析出 0」的处理是"保留旧值"，否则平时设备短暂返回 0 时会把界面清零。
        var next = snapshot
        next.monthlyBytes = 0
        next.trafficTotal = nil
        snapshot = next
        await refreshNow()
    }

    /// 重启设备（POST /api/system/reboot，project-cpe 专属）。
    ///
    /// 只有这个固件提供；发出去之后设备会立刻断开，接口多半不会正常返回，
    /// 所以这里按「请求已送达」处理，不等响应体。
    func rebootDevice() async throws {
        guard settings.usesProjectCPE else {
            throw APIError.disabled("只有 project-cpe 固件支持重启接口")
        }
        guard let base = settings.baseURL else { throw APIError.badURL }
        try await ProjectCPEClient(baseURL: base).reboot()

        // 主动置成失败态：设备正在重启，接下来几轮必然连不上，
        // 让 UI 立刻显示「连接失败」比等超时更诚实。
        link = .failed("设备正在重启…")
        lastError = "已下发重启指令"
    }

    // MARK: - 定时清理缓存

    /// 到点就清一次设备页缓存。
    ///
    /// 挂在慢循环上（每 slowEvery 轮检查一次，默认约 16 秒），不另起 Timer：
    /// 间隔最短也是 15 分钟，这个检查频率足够了。
    private func maybeAutoClearCache() async {
        // project-cpe 没有 drop_caches 接口，定时清理对它无意义
        guard settings.autoClearEnabled, !settings.mockMode, !settings.usesProjectCPE else { return }
        let interval = settings.autoClearInterval.seconds
        if let last = lastAutoClearAt, Date().timeIntervalSince(last) < interval { return }

        // ⚠️ 时间戳在发请求**之前**推进。
        // 清理是写操作，设备端 drop_caches 期间有概率超时；如果失败时不推进时间戳，
        // 慢循环每 16 秒就会重试一次，等于拿 drop_caches 反复砸这台 200MB 内存的设备。
        // 宁可漏掉一轮，也不能形成重试风暴 —— 下一轮慢循环本来也会再看一眼。
        lastAutoClearAt = Date()
        do {
            try await withReauth { client in
                try await client.clearCache()
            }
            autoClearError = nil
        } catch {
            autoClearError = error.localizedDescription
        }
    }

    /// 设置页显示的定时清理状态。engine 每轮都会发新 snapshot（@Published），
    /// 所以这个文案会跟着轮询自然刷新，不需要单独的计时器。
    var autoClearStatusText: String {
        guard settings.autoClearEnabled else { return "已关闭" }
        guard let last = lastAutoClearAt else { return "等待首次触发" }
        let elapsed = Date().timeIntervalSince(last)
        let remain = max(0, settings.autoClearInterval.seconds - elapsed)
        return "上次 \(Self.shortDuration(elapsed))前 · 下次约 \(Self.shortDuration(remain))后"
    }

    private static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分钟" }
        return "\(total / 3600) 小时"
    }

    // MARK: - 实时速率

    private func refreshSpeed() async {
        do {
            let name = try await ensureInterface()

            // vnstat -l 刚 fork 出来时还没有采样点，直接读会得到 0
            if let started = monitorStartedAt,
               Date().timeIntervalSince(started) < warmupSeconds {
                speedWarmingUp = true
                return
            }
            speedWarmingUp = false

            let stats = try await withReauth { client in
                try await client.netifStats(interface: name)
            }

            var next = snapshot
            next.stats = stats
            next.interfaceName = name
            // 实时流量累加：每次拿到累计字节数就算 delta，跨日时自动归零。
            // 注意：用 totalbytes 不是 bytes —— bytes 是 vnstat 窗口内累计，会被重置；
            // totalbytes 才是设备启动以来的总累计，单调递增，累加器才稳。
            //
            // ⚠️ 只更新「当日」。`monthlyBytes` 归 refreshTraffic 管（走 /api/get/Total），
            // 这里若也用累加器的 monthBytes 覆盖，会把设备真实当月值冲掉（差 3.5 GB）。
            trafficAccumulator.update(rxBytes: stats.rx?.totalbytes,
                                      txBytes: stats.tx?.totalbytes,
                                      source: trafficSource(name))
            next.dailyBytes = trafficAccumulator.todayBytes ?? next.dailyBytes
            // 累加器已经按 Mac 本地日历日划分，标签无需再打 "归属 X-X"
            if trafficAccumulator.todayBytes != nil {
                next.dailyLabel = nil
            }
            snapshot = next

            pushHistory(down: stats.rx?.bytesPerSecond ?? 0,
                        up: stats.tx?.bytesPerSecond ?? 0)
        } catch APIError.unauthorized {
            // 交给外层处理
        } catch {
            // 监听重启中（503）等情况属于常态，不影响主状态展示
            lastError = error.localizedDescription
        }
    }

    private func ensureInterface() async throws -> String {
        if !settings.interfaceOverride.isEmpty { return settings.interfaceOverride }
        if let cached = activeInterface { return cached }

        let list = try await withReauth { client in
            try await client.netifList()
        }
        availableInterfaces = list

        guard let picked = NetifInfo.pick(from: list) else {
            throw APIError.disabled("设备上没有可统计的网卡")
        }
        // /api/netif/stats 只在监听开启后才返回数据，这里顺带开一次
        try? await withReauth { client in
            try await client.setNetifMonitor(interface: picked.name, enabled: true)
        }
        // 记下开启时刻，前几秒不采信速率读数
        monitorStartedAt = Date()
        activeInterface = picked.name
        return picked.name
    }

    /// 告知累加器"这组计数属于谁"。换设备/换协议/换网卡时它会自动归零重算，
    /// 否则新设备的累计基数减旧设备的基数会凭空冒出几十 GB 的「今日用量」。
    private func trafficSource(_ interface: String?) -> String {
        "\(settings.host):\(settings.port):\(settings.backend.rawValue):\(interface ?? "-")"
    }

    private func pushHistory(down: Double, up: Double) {
        downHistory.append(down)
        upHistory.append(up)
        if downHistory.count > historyCapacity {
            downHistory.removeFirst(downHistory.count - historyCapacity)
        }
        if upHistory.count > historyCapacity {
            upHistory.removeFirst(upHistory.count - historyCapacity)
        }
    }

    // MARK: - 流量统计

    private func refreshTraffic() async {
        do {
            // /api/get/Total 是设备从运营商拉回的累计流量（与账单口径一致），
            // 直接作为"当月已用"的权威值，不再用 netif/stats delta 自己算：
            // netif 的 totalbytes 是网卡物理收发计数（设备启动起算），
            // 与 Total 接口差 3.5 GB，两套数据不能混用。
            let total = try await withReauth { (c: APIClient) in try await c.trafficTotal() }
            let config = try await withReauth { (c: APIClient) in try await c.trafficConfig() }

            var next = snapshot
            next.trafficTotal = total
            next.trafficConfig = config

            // 当月已用：直接采用设备 Total 接口解析后的字节数
            if let deviceTotalBytes = total.totalBytes, deviceTotalBytes > 0 {
                next.monthlyBytes = deviceTotalBytes
            }
            // Total 接口解析失败时，保留旧 monthlyBytes 不变（不覆盖）

            // 当日明细：设备没有专门的日接口，只能用累加器（netif/stats delta）
            // 累加器还没初始化时，临时回退到 vnstat 旧 DB（可能在 9-11 那种旧日期上）
            if trafficAccumulator.todayBytes == nil {
                let ifname = activeInterface ?? settings.interfaceOverride
                if !ifname.isEmpty,
                   let detail = try? await withReauth({ client in
                    try await client.vnstatDetail(interface: ifname)
                }) {
                    next.dailyBytes = detail.dayBytes
                    next.dailyLabel = detail.dayIsToday ? nil : detail.dayLabel
                }
            } else {
                next.dailyBytes = trafficAccumulator.todayBytes
                next.dailyLabel = nil
            }

            snapshot = next
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 演练模式

    private func applyMock() {
        tick += 1
        var next = MonitorSnapshot.empty
        next.info = MockData.info(tick: tick)
        next.band = MockData.band(tick: tick)
        next.stats = MockData.stats(tick: tick)
        next.trafficTotal = MockData.trafficTotal
        next.trafficConfig = MockData.trafficConfig
        next.monthlyBytes = 45_200_000_000 + Int64(tick) * 2_400_000
        next.dailyBytes = 1_330_000_000 + Int64(tick) * 1_800_000
        next.interfaceName = "sipa_eth0"

        snapshot = next
        availableInterfaces = MockData.interfaces
        pushHistory(down: next.downloadBytesPerSecond, up: next.uploadBytesPerSecond)

        link = .online
        lastError = nil
        lastUpdated = Date()
    }

    // MARK: - 派生展示值

    /// 套餐总量（字节）：优先用设备上的上限配置，其次用用户手填
    var quotaBytes: Int64 {
        if settings.trafficUnlimited { return 0 }
        if let much = snapshot.trafficConfig?.much, much > 0 { return much }
        return settings.manualQuotaBytes
    }

    var isUnlimitedPlan: Bool {
        if settings.trafficUnlimited { return true }
        return !(snapshot.trafficConfig?.isLimited ?? false)
    }

    /// 本月用量（字节）。拿不到 vnstat 明细时退回累计值文本。
    var monthlyUsedBytes: Int64? {
        if let m = snapshot.monthlyBytes { return m }
        return nil
    }

    var monthlyFallbackText: String? {
        guard snapshot.monthlyBytes == nil else { return nil }
        return snapshot.trafficTotal?.total
    }

    var monthlyProgress: Double {
        guard quotaBytes > 0, let used = monthlyUsedBytes else { return 0 }
        return min(1, max(0, Double(used) / Double(quotaBytes)))
    }

    var downTrend: [Double] { downHistory }
    var upTrend: [Double] { upHistory }
}
