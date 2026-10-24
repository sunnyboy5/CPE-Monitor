import Foundation

/// 命令行自检：不开界面，直接把整条数据链路跑一遍。
///
/// 用法：
///   CPEMonitor --selftest --host 127.0.0.1 --port 16677 --password admin
///
/// 它会依次验证免登录接口、鉴权、网卡挑选、实时速率、流量明细，
/// 并打印每一项的解码结果。用来在没有真机时确认协议适配是否正确。
enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--watch")
    }

    private static func value(for flag: String) -> String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private final class Box: @unchecked Sendable {
        var failures = 0
    }

    static func run() -> Never {
        let host = value(for: "--host") ?? "127.0.0.1"
        let port = Int(value(for: "--port") ?? "16677") ?? 16677
        let password = value(for: "--password") ?? "admin"

        // 无人值守巡检：真实跑一遍轮询引擎
        if CommandLine.arguments.contains("--watch") {
            let seconds = Int(value(for: "--seconds") ?? "12") ?? 12
            MainActor.assumeIsolated {
                watch(host: host, port: port, password: password, seconds: seconds)
            }
        }

        guard let base = URL(string: "http://\(host):\(port)") else {
            print("地址无效")
            exit(2)
        }

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        // 走哪套协议：默认按端口推断，也可以用 --backend 显式指定
        let backend = value(for: "--backend").flatMap(DeviceBackend.init(rawValue:))
            ?? DeviceBackend.infer(fromPort: port)
        print("目标协议: \(backend.label)\n")

        Task.detached {
            if backend == .projectCPE {
                box.failures = await executeProjectCPE(base: base)
            } else {
                box.failures = await execute(base: base, password: password)
            }
            semaphore.signal()
        }
        semaphore.wait()

        print("")
        if box.failures == 0 {
            print("全部通过 ✅")
            exit(0)
        } else {
            print("\(box.failures) 项失败 ❌")
            exit(1)
        }
    }

    // MARK: - 轮询引擎巡检

    /// 用真实引擎跑 N 秒，观察连接状态、速率曲线与流量明细是否稳定。
    /// 覆盖自动登录、自动挑选并启用网卡、快慢双循环这三块最容易出问题的逻辑。
    @MainActor
    private static func watch(host: String, port: Int, password: String, seconds: Int) -> Never {
        // persist: false —— 巡检是只读诊断，不改动用户已保存的连接配置与钥匙串
        let settings = AppSettings(persist: false, host: host, port: port, password: password)
        settings.rememberPassword = true
        // `--mock` 时不连设备，用演示数据跑一遍引擎（验证 UI 数据链路本身）
        if CommandLine.arguments.contains("--mock") {
            settings.mockMode = true
        }

        let engine = MonitorEngine(settings: settings)
        engine.start()

        // 9527 只读页没有速率/流量接口，巡检时的判定和列显示都得放宽
        let readOnly = DeviceBackend.infer(fromPort: port) == .localReadOnly

        print("轮询引擎巡检：\(host):\(port)，持续 \(seconds) 秒\n")
        print("  时刻      链路        下载            上传            采样  本月          当日")
        print("  " + String(repeating: "-", count: 78))

        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"

        let deadline = Date().addingTimeInterval(Double(seconds))
        var ticks = 0
        var sawSpeed = false

        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            ticks += 1
            guard ticks % 2 == 0 else { continue }

            let snap = engine.snapshot
            let down = snap.downloadBytesPerSecond
            let up = snap.uploadBytesPerSecond
            if down > 0 { sawSpeed = true }

            var link = "未知"
            switch engine.link {
            case .online: link = "在线"
            case .connecting: link = "连接中"
            case .idle: link = "空闲"
            case .unauthorized: link = "鉴权失败"
            case .failed: link = "失败"
            }

            let pad = { (s: String, n: Int) -> String in
                s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
            }
            print("  \(clock.string(from: Date()))  "
                  + pad(link, 10)
                  + pad(readOnly ? "--" : Fmt.rate(down), 16)
                  + pad(readOnly ? "--" : Fmt.rate(up), 16)
                  + pad("\(engine.downTrend.count)", 6)
                  + pad(readOnly ? "--" : Fmt.bytes(snap.monthlyBytes), 14)
                  + (readOnly ? "--" : Fmt.bytes(snap.dailyBytes)))

            if let err = engine.lastError {
                print("            最近错误：\(err)")
            }
        }

        print("")
        let passed: Bool
        if readOnly {
            // 9527 只提供系统信息与温度；没有实时速率接口。
            passed = engine.link == .online
                && engine.snapshot.info?.totalRam != nil
                && engine.snapshot.info?.thermalTemp != nil
        } else {
            passed = engine.link == .online && sawSpeed && engine.downTrend.count >= 3
        }
        if passed {
            print("轮询引擎巡检通过 ✅")
        } else {
            print("轮询引擎巡检未通过 ❌ 链路=\(engine.link) 内存=\(String(describing: engine.snapshot.info?.totalRam)) 温度=\(String(describing: engine.snapshot.info?.thermalTemp))")
        }
        if readOnly {
            print("  最终快照：内存=\(Fmt.mb(engine.snapshot.info?.totalRam)) "
                  + "温度=\(Fmt.temp(engine.snapshot.info?.thermalTemp)) "
                  + "QCI=\(Fmt.intOrDash(engine.snapshot.info?.qci))")
        } else {
            print("  最终快照：运营商=\(Fmt.orDash(engine.snapshot.info?.carrier)) "
                  + "频段=\(Fmt.orDash(engine.snapshot.band?.band)) "
                  + "网卡=\(engine.snapshot.interfaceName ?? "nil")")
        }
        exit(passed ? 0 : 1)
    }

    // MARK: - 逐项检查

    private static func execute(base: URL, password: String) async -> Int {
        var failures = 0
        let client = APIClient(baseURL: base, token: nil)

        func check(_ title: String, _ passed: Bool, _ detail: String) {
            print(passed ? "  ✅ \(title)" : "  ❌ \(title)")
            print("     \(detail)")
            if !passed { failures += 1 }
        }

        print("目标: \(base.absoluteString)\n")

        // 1. 主状态
        print("[1] GET /api/info（免登录）")
        do {
            let info = try await client.info()
            check("运营商 / QCI 解码", info.carrier != nil && info.qci != nil,
                  "carrier=\(info.carrier ?? "nil")  qci=\(info.qci.map(String.init) ?? "nil")")
            check("网络模式 / 频段", info.networkType != nil && info.networkBand != nil,
                  "networkType=\(info.networkType ?? "nil")  networkBand=\(info.networkBand ?? "nil")")
            check("CPU / 温度 / 内存",
                  info.cpuUsage != nil && info.thermalTemp != nil && info.memoryUsagePercent != nil,
                  "cpu=\(Fmt.percent(info.cpuUsage))  temp=\(Fmt.temp(info.thermalTemp))  内存=\(Fmt.percent(info.memoryUsagePercent))")
            check("QCI 签约速率",
                  (info.downlinkRate ?? 0) > 0 && (info.uplinkRate ?? 0) > 0,
                  "下行 \(info.downlinkRate ?? 0) Mbps / 上行 \(info.uplinkRate ?? 0) Mbps")
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 2. 射频指标
        print("\n[2] GET /api/current_band（免登录）")
        do {
            let band = try await client.currentBand()
            let data = band.data
            check("Data 包装层解码", data != nil,
                  "Code=\(band.code.map(String.init) ?? "nil")  network_type=\(data?.networkType ?? "nil")")
            check("RSRP / SINR / RSRQ",
                  data?.rsrp != nil && data?.sinr != nil && data?.rsrq != nil,
                  "RSRP=\(data?.rsrp ?? 0) SINR=\(data?.sinr ?? 0) RSRQ=\(data?.rsrq ?? 0)")
            check("评级映射",
                  Quality.rsrp(data?.rsrp) != .unknown,
                  "RSRP→\(Quality.rsrp(data?.rsrp).rawValue)  SINR→\(Quality.sinr(data?.sinr).rawValue)  RSRQ→\(Quality.rsrq(data?.rsrq).rawValue)")
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 3. 未授权访问受保护接口
        print("\n[3] 未登录访问 /api/netif/stats（应被拒绝）")
        var authed = client
        do {
            _ = try await authed.netifStats(interface: "sipa_eth0")
            check("应返回 401", false, "居然成功了，说明鉴权判断有问题")
        } catch APIError.unauthorized {
            check("正确返回 401", true, "鉴权中间件行为符合预期")
        } catch {
            check("应返回 401", false, "收到了 \(error.localizedDescription)")
        }

        // 4. 登录
        print("\n[4] POST /api/auth/login")
        do {
            let token = try await client.login(password: password)
            authed.token = token
            check("拿到 token", !token.isEmpty, "token=\(token.prefix(12))…")
        } catch {
            check("登录成功", false, error.localizedDescription)
            print("\n登录失败，后续需要鉴权的检查跳过")
            return failures
        }

        // 5. 网卡
        print("\n[5] GET /api/netif/list")
        var picked = "sipa_eth0"
        do {
            let list = try await authed.netifList()
            check("网卡列表解码", !list.isEmpty,
                  list.map { "\($0.name)(up=\($0.isUp ?? false))" }.joined(separator: ", "))
            if let best = NetifInfo.pick(from: list) {
                picked = best.name
                check("自动挑选可用网卡", best.name != "lo", "选中 \(best.name)")
            } else {
                check("自动挑选可用网卡", false, "没有可用网卡")
            }
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 6. 开启监听并取实时速率
        print("\n[6] POST /api/netif/monitor + /api/netif/stats")
        do {
            try await authed.setNetifMonitor(interface: picked, enabled: true)
            // vnstat -l 是新 fork 出来的实时进程，冷启动时还没有采样点，
            // 立刻读会拿到 0。这里给它几秒产出第一行。
            print("     已开启监听，等待 vnstat 采样…")
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            var stats = try await authed.netifStats(interface: picked)
            var down = stats.rx?.bytesPerSecond ?? 0
            var tries = 0
            while down == 0 && tries < 3 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                stats = try await authed.netifStats(interface: picked)
                down = stats.rx?.bytesPerSecond ?? 0
                tries += 1
            }
            let up = stats.tx?.bytesPerSecond ?? 0
            check("实时速率解码", down > 0,
                  "下行 \(Fmt.rate(down)) / 上行 \(Fmt.rate(up))  接口=\(picked)")
        } catch {
            check("实时速率", false, error.localizedDescription)
        }

        // 7. 流量汇总与套餐
        print("\n[7] GET /api/get/Total + /api/get/set")
        do {
            let total = try await authed.trafficTotal()
            check("累计流量", total.total != nil,
                  "rx=\(total.rx ?? "nil") tx=\(total.tx ?? "nil") total=\(total.total ?? "nil")")

            // 解析回字节数，让 UI 能直接拿去算"已用/套餐"
            let parsed = total.totalBytes
            check("Total 字符串解析为字节", parsed != nil && (parsed ?? 0) > 0,
                  "解析后 \(Fmt.bytes(parsed))  原值=\(total.total ?? "nil")")

            let config = try await authed.trafficConfig()
            check("套餐配置解码（含 switch 关键字字段）", config.much != nil,
                  "much=\(Fmt.bytes(config.much))  switch=\(config.trafficSwitch ?? -1)  → \(config.isLimited ? "固定流量" : "不限量")")
        } catch {
            check("流量接口", false, error.localizedDescription)
        }

        // 8. vnstat 当月/当日
        print("\n[8] POST /api/shell → vnstat --json m / --json d")
        do {
            // 先探 shell 通道本身是否通，便于把「通道问题」和「命令问题」分开
            let probe = try await authed.shell("echo shell-ok")
            let echoed = (probe.data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            check("shell 通道", echoed.contains("shell-ok"), "回显=\(echoed)")
        } catch {
            check("shell 通道", false, error.localizedDescription)
        }
        do {
            let raw = try await authed.rawBody(
                "/api/shell", method: "POST",
                body: ["command": "/home/root/6677/vnstat -i \(picked) --json m"])
            print("     原始响应 \(raw.count) 字节：")
            print("     " + String(raw.prefix(260)))
            print("     …尾部：" + String(raw.suffix(80)))
        } catch {
            print("     原始响应获取失败：\(error)")
        }
        do {
            let detail = try await authed.vnstatDetail(interface: picked)
            var note = ""
            if !detail.dayIsToday {
                note = "  ⚠️ 当日数据归属 \(detail.dayLabel ?? "?")(今天还没入库)"
            }
            check("本月/当日明细解析", detail.monthBytes > 0,
                  "本月 \(Fmt.bytes(detail.monthBytes)) / 当日 \(Fmt.bytes(detail.dayBytes))\(note)")
        } catch {
            check("vnstat 明细", false, error.localizedDescription)
        }

        // ============ 流量累加器单元测试（不依赖设备） ============
        failures += runAccumulatorUnitTests()

        if failures == 0 {
            print("\n全部通过 ✅")
        } else {
            print("\n❌ 共 \(failures) 项失败")
        }
        return failures
    }

    // MARK: - project-cpe 协议检查

    /// 逐项验证 project-cpe 固件的整条链路：探活、设备、SIM、网络、QoS、小区、系统统计，
    /// 最后再验证一遍映射到 UI 模型的结果对不对（尤其是信号值 ÷100 和接口挑选）。
    private static func executeProjectCPE(base: URL) async -> Int {
        var failures = 0
        let client = ProjectCPEClient(baseURL: base)

        func check(_ title: String, _ passed: Bool, _ detail: String) {
            print(passed ? "  ✅ \(title)" : "  ❌ \(title)")
            print("     \(detail)")
            if !passed { failures += 1 }
        }

        print("目标: \(base.absoluteString)\n")

        // 1. 探活
        print("[1] GET /api/health（无鉴权）")
        do {
            let version = try await client.health()
            check("服务存活", true, "version=\(version)")
        } catch {
            check("服务存活", false, error.localizedDescription)
            print("\n探活失败，后续检查跳过")
            return failures + 1
        }

        // 2. 设备
        print("\n[2] GET /api/device")
        var device: CPEDevice?
        do {
            let d = try await client.device()
            device = d
            check("IMEI / 型号", d.imei != nil && d.model != nil,
                  "imei=\(d.imei ?? "nil")  model=\(d.model ?? "nil")  "
                  + "online=\(d.online.map(String.init) ?? "nil")")
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 3. SIM
        print("\n[3] GET /api/sim")
        do {
            let s = try await client.sim()
            check("ICCID / IMSI", s.iccid != nil && s.imsi != nil,
                  "iccid=\(Fmt.mask(s.iccid))  imsi=\(Fmt.mask(s.imsi))  present=\(s.present.map(String.init) ?? "nil")")
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 4. 网络注册
        print("\n[4] GET /api/network")
        do {
            let n = try await client.network()
            check("运营商 / 注册状态", n.operatorName != nil && n.registrationStatus != nil,
                  "operator=\(n.operatorName ?? "nil")  status=\(n.registrationStatus ?? "nil")  "
                  + "tech=\(n.technologyPreference ?? "nil")")
            check("信号强度落在 0–100",
                  (n.signalPercent ?? -1) >= 0 && (n.signalPercent ?? 101) <= 100,
                  "signal=\(n.signalStrength.map { String(format: "%.0f", $0) } ?? "nil") "
                  + "→ \(n.signalPercent.map { String(format: "%.0f%%", $0) } ?? "nil")")
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 5. QoS
        print("\n[5] GET /api/qos（AT+CGEQOSRDP，单位 kbps）")
        do {
            let q = try await client.qos()
            check("QCI / 签约速率", q.qci != nil && (q.dlSpeed ?? 0) > 0,
                  "qci=\(q.qci.map(String.init) ?? "nil")  "
                  + "dl=\(q.dlSpeed ?? 0) kbps（\(Fmt.signedMbps(q.dlSpeed)) Mbps）  "
                  + "ul=\(q.ulSpeed ?? 0) kbps（\(Fmt.signedMbps(q.ulSpeed)) Mbps）")
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 6. 小区（信号值 ×100 的字符串，重点验证 ÷100）
        print("\n[6] GET /api/cells")
        var cells: CPECells?
        do {
            let c = try await client.cells()
            cells = c
            check("服务小区解码", c.serving != nil,
                  "tech=\(c.servingCell?.tech ?? "nil")  cells=\(c.cells?.count ?? 0) 个")

            let raw = c.serving?.rsrp?.raw ?? "nil"
            let band = c.bandData
            check("RSRP ÷100 后落在合理区间",
                  (band.rsrp ?? 0) < 0 && (band.rsrp ?? -200) > -160,
                  "原始=\(raw) → \(band.rsrp.map { String(format: "%.2f dBm", $0) } ?? "nil")")
            check("频段 / PCI / ARFCN",
                  band.band != nil && band.pci != nil && band.arfcn != nil,
                  "band=\(band.band ?? "nil")  pci=\(band.pci.map(String.init) ?? "nil")  "
                  + "arfcn=\(band.arfcn.map(String.init) ?? "nil")")
            check("评级映射可用", Quality.rsrp(band.rsrp) != .unknown,
                  "RSRP→\(Quality.rsrp(band.rsrp).rawValue)  "
                  + "SINR→\(Quality.sinr(band.sinr).rawValue)  "
                  + "RSRQ→\(Quality.rsrq(band.rsrq).rawValue)")
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 7. 系统统计
        print("\n[7] GET /api/stats（服务端同步采样 1 秒）")
        var stats: CPEStats?
        do {
            let started = Date()
            let s = try await client.stats()
            stats = s
            let cost = Date().timeIntervalSince(started)
            check("耗时在合理范围", cost > 0.5 && cost < 20,
                  String(format: "%.2f 秒（服务端固定采样 1s）", cost))

            check("内存 / CPU / 运行时长",
                  s.memory?.totalBytes != nil && s.cpuLoad?.loadPercent != nil
                  && s.uptime?.uptimeSeconds != nil,
                  "内存 \(Fmt.bytes(s.memory?.usedBytes)) / \(Fmt.bytes(s.memory?.totalBytes))"
                  + "（\(String(format: "%.1f", s.memory?.usedPercent ?? 0))%）  "
                  + "CPU \(String(format: "%.1f", s.cpuLoad?.loadPercent ?? 0))%  "
                  + "运行 \(s.uptime?.uptimeFormatted ?? "--")")

            check("温度传感器", (s.temperature?.count ?? 0) > 0,
                  "\(s.temperature?.count ?? 0) 个温区，主温区 "
                  + (s.mainTemperature.map { String(format: "%.1f °C", $0) } ?? "nil"))

            let names = s.networkSpeed?.interfaces?.compactMap(\.interface) ?? []
            check("网卡列表", !names.isEmpty, names.joined(separator: ", "))
        } catch {
            check("请求成功", false, error.localizedDescription)
        }

        // 8. 映射到 UI 模型
        print("\n[8] 映射到界面模型")
        if let stats {
            let mapped = stats.netifStats(interface: nil)
            check("实时速率映射", mapped.stats.rx != nil && mapped.stats.tx != nil,
                  "下行 \(Fmt.rate(mapped.stats.rx?.bytesPerSecond ?? 0)) / "
                  + "上行 \(Fmt.rate(mapped.stats.tx?.bytesPerSecond ?? 0))  接口=\(mapped.name ?? "nil")")

            check("网卡挑选不是回环", (mapped.name ?? "lo") != "lo", "选中 \(mapped.name ?? "nil")")

            let total = stats.trafficTotal(interface: mapped.name)
            check("累计流量映射", total != nil,
                  "rx=\(total?.rx ?? "nil") tx=\(total?.tx ?? "nil") total=\(total?.total ?? "nil")")

            let info = stats.hardwareInfo(into: DeviceInfo())
            check("硬件字段齐全（内存走 MiB 口径）",
                  info.totalRam != nil && info.cpuUsage != nil && info.thermalTemp != nil,
                  "RAM=\(Fmt.mb(info.totalRam))  CPU=\(Fmt.percent(info.cpuUsage))  "
                  + "温度=\(Fmt.temp(info.thermalTemp))  页缓存=\(Fmt.mb(info.cachedRam))")
        }

        _ = device
        _ = cells

        failures += runAccumulatorUnitTests()

        if failures == 0 {
            print("\n全部通过 ✅")
        } else {
            print("\n❌ 共 \(failures) 项失败")
        }
        return failures
    }

    /// 流量累加器的纯逻辑测试：首次采样、delta 累加、跨日、跨月、设备重启回退、负数保护。
    /// 返回失败计数。
    private static func runAccumulatorUnitTests() -> Int {
        print("\n--- 流量累加器单元测试 ---")
        var failures = 0
        func check(_ title: String, _ passed: Bool, _ detail: String) {
            print(passed ? "  ✅ \(title)" : "  ❌ \(title)")
            print("     \(detail)")
            if !passed { failures += 1 }
        }

        let key = "selftest.traffic.accumulator.\(UUID().uuidString)"

        // 测试 1：首次 update 不算"过去已用"，只设基线
        do {
            let defaults = UserDefaults(suiteName: "selftest-\(UUID().uuidString)")!
            let clock = TestClock(date: Self.testDate(year: 2026, month: 9, day: 12, hour: 10))
            let acc = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            acc.update(rxBytes: 1_000_000_000, txBytes: 500_000_000)
            check("累加器首次 update 不算过去", {
                acc.todayBytes == 0 && acc.monthBytes == 0
            }(), "today=\(acc.todayBytes ?? -1) month=\(acc.monthBytes ?? -1)")
        }

        // 测试 2：连续 delta 累加
        do {
            let defaults = UserDefaults(suiteName: "selftest-\(UUID().uuidString)")!
            let clock = TestClock(date: Self.testDate(year: 2026, month: 9, day: 12, hour: 10))
            let acc = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            acc.update(rxBytes: 1_000_000_000, txBytes: 500_000_000)
            acc.update(rxBytes: 1_000_000_500, txBytes: 500_000_250)
            let expected = Int64(500 + 250)
            check("累加器 delta 累加", acc.todayBytes == expected && acc.monthBytes == expected,
                  "today=\(acc.todayBytes ?? -1) month=\(acc.monthBytes ?? -1) 期望=\(expected)")
        }

        // 测试 3：设备重启（rx 回退）按 0 算 delta，不报负
        do {
            let defaults = UserDefaults(suiteName: "selftest-\(UUID().uuidString)")!
            let clock = TestClock(date: Self.testDate(year: 2026, month: 9, day: 12, hour: 10))
            let acc = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            acc.update(rxBytes: 1_000_000_000, txBytes: 500_000_000)
            acc.update(rxBytes: 1_000_001_000, txBytes: 500_000_500)  // +1500
            acc.update(rxBytes: 100, txBytes: 50)                       // 设备重启，totalbytes 回退
            let expected = Int64(1500)  // 重启那次按 0 算，不报负
            check("设备重启不报负", acc.todayBytes == expected,
                  "today=\(acc.todayBytes ?? -1) 期望=\(expected)")
        }

        // 测试 4：跨日归零
        do {
            let defaults = UserDefaults(suiteName: "selftest-\(UUID().uuidString)")!
            let day1 = Self.testDate(year: 2026, month: 9, day: 12, hour: 23, minute: 59)
            let day2 = Self.testDate(year: 2026, month: 9, day: 13, hour: 0, minute: 1)
            let clock = TestClock(date: day1)
            let acc = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            acc.update(rxBytes: 1_000_000_000, txBytes: 500_000_000)
            acc.update(rxBytes: 1_000_500_000, txBytes: 500_250_000)  // 当天累计 750 KB
            let before = acc.todayBytes ?? 0
            clock.advance(to: day2)
            acc.update(rxBytes: 1_001_000_000, txBytes: 500_500_000)  // 跨日后第一次
            // rx 增 500_000 + tx 增 250_000 = 750_000，新一天首笔
            check("跨日归零 + 新一天首笔", before > 0 && acc.todayBytes == Int64(750_000),
                  "昨天=\(before) 今天首笔=\(acc.todayBytes ?? -1) 期望=750000")
        }

        // 测试 5：跨月归零
        do {
            let defaults = UserDefaults(suiteName: "selftest-\(UUID().uuidString)")!
            let dayA = Self.testDate(year: 2026, month: 9, day: 30, hour: 23)
            let dayB = Self.testDate(year: 2026, month: 10, day: 1, hour: 1)
            let clock = TestClock(date: dayA)
            let acc = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            acc.update(rxBytes: 1_000_000_000, txBytes: 500_000_000)
            acc.update(rxBytes: 1_001_000_000, txBytes: 500_500_000)
            let before = acc.monthBytes ?? 0
            clock.advance(to: dayB)
            acc.update(rxBytes: 1_001_200_000, txBytes: 500_700_000)
            check("跨月归零", before > 0 && acc.monthBytes == Int64(400_000),
                  "上月=\(before) 本月首笔=\(acc.monthBytes ?? -1) 期望=400000")
        }

        // 测试 6：持久化恢复后能继续累计
        do {
            let defaults = UserDefaults(suiteName: "selftest-\(UUID().uuidString)")!
            let clock = TestClock(date: Self.testDate(year: 2026, month: 9, day: 12, hour: 10))
            let acc1 = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            acc1.update(rxBytes: 1_000_000_000, txBytes: 500_000_000)
            acc1.update(rxBytes: 1_000_300_000, txBytes: 500_150_000)  // +450 KB
            // 模拟重启：新建累加器实例，状态从持久化恢复
            let acc2 = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            check("持久化恢复后继续累计", acc2.todayBytes == Int64(450_000),
                  "today=\(acc2.todayBytes ?? -1) 期望=450000")
        }

        // 测试 7：reset() 清空
        do {
            let defaults = UserDefaults(suiteName: "selftest-\(UUID().uuidString)")!
            let clock = TestClock(date: Self.testDate(year: 2026, month: 9, day: 12, hour: 10))
            let acc = TrafficAccumulator(defaults: defaults, key: key, clock: clock.now)
            acc.update(rxBytes: 1_000_000_000, txBytes: 500_000_000)
            acc.update(rxBytes: 1_000_500_000, txBytes: 500_250_000)
            acc.reset()
            check("reset 清空", acc.todayBytes == nil && acc.monthBytes == nil,
                  "重置后 today=\(String(describing: acc.todayBytes))")
        }

        if failures == 0 {
            print("  累加器单元测试：全部通过 ✅")
        } else {
            print("  累加器单元测试：\(failures) 项失败 ❌")
        }
        return failures
    }

    /// 生成指定日期（Mac 本地时区）
    private static func testDate(year: Int, month: Int, day: Int,
                                 hour: Int = 0, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = 0
        return Calendar.current.date(from: c) ?? Date()
    }

    /// 测试用时钟：可手动拨动到指定时间
    private final class TestClock: @unchecked Sendable {
        private var current: Date
        init(date: Date) { self.current = date }
        func now() -> Date { current }
        func advance(to date: Date) { current = date }
    }
}
