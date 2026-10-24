import Foundation

// MARK: - project-cpe 固件协议客户端
//
// 对接 https://github.com/1orz/project-cpe —— Rust + Axum + ofono D-Bus 的后端。
// 与旧 UDX710-TOOLS(6677) / 本地只读管理页(9527) 的差异：
//
//   1. 端口默认 3000（`--port` 的默认值，可用 `--port` 改），**没有任何鉴权**，
//      没有登录接口，也不认 Bearer token。
//   2. 所有业务响应统一包一层 `{status, message, data}`，出错时 **HTTP 仍是 200**，
//      只是 `status == "error"` —— 所以必须先看 status 再取 data。
//   3. 字段一律 snake_case（前端靠 TS 类型解，原生端用 convertFromSnakeCase）。
//   4. 信号指标（rsrp / rsrq / sinr）是 **原始值 ×100 的字符串**，要除以 100。
//      频段是带前缀的小写形式（`n78` / `B3`），不是纯数字。
//   5. QoS 的 dl_speed / ul_speed 来自 `AT+CGEQOSRDP`，单位 **kbps**。
//   6. 没有 vnstat、没有流量账单周期，只有各网卡的累计收发字节。

/// 后端能兼容的三种设备协议
enum DeviceBackend: String, CaseIterable, Identifiable {
    /// project-cpe 固件（Rust/Axum，端口 3000，无鉴权）
    case projectCPE
    /// 旧版 UDX710-TOOLS（端口 6677，Bearer token）
    case udx710Tools
    /// 9527 本地只读管理页（仅系统信息 + 温度）
    case localReadOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .projectCPE:   return "project-cpe（3000）"
        case .udx710Tools:  return "UDX710-TOOLS（6677）"
        case .localReadOnly: return "本地只读页（9527）"
        }
    }

    var shortLabel: String {
        switch self {
        case .projectCPE:   return "project-cpe"
        case .udx710Tools:  return "UDX710-TOOLS"
        case .localReadOnly: return "9527 只读"
        }
    }

    /// 该协议的惯用端口，切换协议时用来自动填端口
    var defaultPort: Int {
        switch self {
        case .projectCPE:   return 3000
        case .udx710Tools:  return 6677
        case .localReadOnly: return 9527
        }
    }

    var needsPassword: Bool { self == .udx710Tools }

    /// 首次运行 / 老配置迁移：按端口猜协议
    static func infer(fromPort port: Int) -> DeviceBackend {
        switch port {
        case 3000: return .projectCPE
        case 9527: return .localReadOnly
        case 6677, 16677: return .udx710Tools
        default:   return .projectCPE
        }
    }
}

// MARK: - 灵活数值

/// 后端有的字段一会儿给数字一会儿给字符串（PCI / ARFCN / RSRP 都是 String），
/// 还有 LTE 邻区的 SINR 直接给 `"-"`。统一收成字符串再按需转。
struct FlexNum: Decodable, Equatable {
    var raw: String

    init(raw: String = "") { self.raw = raw }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            raw = s
        } else if let i = try? c.decode(Int64.self) {
            raw = String(i)
        } else if let d = try? c.decode(Double.self) {
            raw = String(d)
        } else {
            raw = ""
        }
    }

    var int: Int? { Int(raw.trimmingCharacters(in: .whitespaces)) }
    var double: Double? { Double(raw.trimmingCharacters(in: .whitespaces)) }

    /// 信号类字段：后端给的是 ×100 的原始值
    var milli: Double? {
        guard let d = double else { return nil }
        return d / 100
    }
}

// MARK: - 响应外壳

struct CPEEnvelope<T: Decodable>: Decodable {
    var status: String?
    var message: String?
    var data: T?

    var isOK: Bool { (status ?? "ok").lowercased() == "ok" }
}

// MARK: - 各接口 payload

struct CPEDevice: Decodable, Equatable {
    var imei: String?
    var manufacturer: String?
    var model: String?
    var revision: String?
    var online: Bool?
    var powered: Bool?
}

struct CPESim: Decodable, Equatable {
    var present: Bool?
    var iccid: String?
    var imsi: String?
    var mcc: String?
    var mnc: String?
    var phoneNumbers: [String]?
    var pinRequired: String?
}

struct CPENetwork: Decodable, Equatable {
    var operatorName: String?
    var registrationStatus: String?
    var technologyPreference: String?
    var signalStrength: Double?
    var mcc: String?
    var mnc: String?
}

struct CPEQos: Decodable, Equatable {
    var qci: Int?
    /// AT+CGEQOSRDP 的 AMBR/GBR/MBR，单位 kbps
    var dlSpeed: Int?
    var ulSpeed: Int?
}

struct CPEServingCell: Decodable, Equatable {
    var tech: String?
    var cellId: Int?
    var tac: Int?
}

struct CPECell: Decodable, Equatable {
    var isServing: Bool?
    var tech: String?
    var band: String?
    var pci: FlexNum?
    var arfcn: FlexNum?
    var rsrp: FlexNum?
    var rsrq: FlexNum?
    var sinr: FlexNum?
}

struct CPECells: Decodable, Equatable {
    var servingCell: CPEServingCell?
    var cells: [CPECell]?

    var serving: CPECell? {
        guard let cells, !cells.isEmpty else { return nil }
        return cells.first(where: { $0.isServing == true }) ?? cells.first
    }
}

struct CPENetworkSpeed: Decodable, Equatable {
    var interface: String?
    var rxBytesPerSec: Int64?
    var txBytesPerSec: Int64?
    var totalRxBytes: Int64?
    var totalTxBytes: Int64?
}

struct CPENetworkSpeedBlock: Decodable, Equatable {
    var interfaces: [CPENetworkSpeed]?
    var intervalSeconds: Double?
}

struct CPEMemory: Decodable, Equatable {
    var totalBytes: Int64?
    var availableBytes: Int64?
    var usedBytes: Int64?
    var usedPercent: Double?
    var cachedBytes: Int64?
    var buffersBytes: Int64?
}

struct CPUDisk: Decodable, Equatable {
    var mountPoint: String?
    var totalBytes: Int64?
    var usedBytes: Int64?
    var usedPercent: Double?
}

struct CPULoad: Decodable, Equatable {
    var load1min: Double?
    var load5min: Double?
    var load15min: Double?
    var coreCount: Int?
    var loadPercent: Double?
}

struct CPEUptime: Decodable, Equatable {
    var uptimeSeconds: Double?
    var idleSeconds: Double?
    var uptimeFormatted: String?
}

struct CPESystemInfo: Decodable, Equatable {
    var sysname: String?
    var nodename: String?
    var release: String?
    var version: String?
    var machine: String?
}

struct CPEThermalZone: Decodable, Equatable {
    var zone: String?
    var type: String?
    /// 后端已经把毫摄氏度除以 1000，这里是摄氏度
    var temperature: Double?
}

struct CPEStats: Decodable, Equatable {
    var networkSpeed: CPENetworkSpeedBlock?
    var memory: CPEMemory?
    var disk: [CPUDisk]?
    var cpuLoad: CPULoad?
    var uptime: CPEUptime?
    var systemInfo: CPESystemInfo?
    var temperature: [CPEThermalZone]?

    /// 挑一张网卡统计实时速率。优先蜂窝口，其次累计字节最多的那张。
    func pickInterface(preferred name: String?) -> CPENetworkSpeed? {
        guard let list = networkSpeed?.interfaces, !list.isEmpty else { return nil }
        let usable = list.filter { ($0.interface ?? "") != "lo" && !($0.interface ?? "").isEmpty }
        guard !usable.isEmpty else { return list.first }

        if let name, !name.isEmpty,
           let hit = usable.first(where: { $0.interface == name }) {
            return hit
        }
        for candidate in Self.preferredOrder {
            if let hit = usable.first(where: { $0.interface == candidate }) { return hit }
        }
        // 兜底：累计字节最多的那张，通常是真正在跑流量的
        return usable.max { lhs, rhs in
            let l = (lhs.totalRxBytes ?? 0) + (lhs.totalTxBytes ?? 0)
            let r = (rhs.totalRxBytes ?? 0) + (rhs.totalTxBytes ?? 0)
            return l < r
        }
    }

    /// 芯片温度：优先 soc / ap 这类主温区，否则取最热的那个
    var mainTemperature: Double? {
        guard let zones = temperature, !zones.isEmpty else { return nil }
        let valid = zones.filter { ($0.temperature ?? 0) > 0 }
        guard !valid.isEmpty else { return nil }

        let keys = ["soc", "ap", "cpu", "cluster"]
        for key in keys {
            if let hit = valid.first(where: { ($0.type ?? "").lowercased().contains(key) }) {
                return hit.temperature
            }
        }
        return valid.map { $0.temperature ?? 0 }.max()
    }

    private static let preferredOrder = ["wwan0", "rmnet0", "sipa_eth0", "usb0", "eth0", "wlan0"]
}

// MARK: - 客户端

struct ProjectCPEClient {

    let baseURL: URL

    /// /api/stats 在服务端要采样 1 秒（补足到 1s 再算速率），
    /// 所以超时不能沿用 6677 那套 6 秒——留足余量，但也不能无限等。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    // MARK: 底层

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(status, text.isEmpty ? "无响应内容" : text)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(path): \(error.localizedDescription)")
        }
    }

    /// project-cpe 出错也是 HTTP 200 + status:"error"，必须单独判一次
    private func getData<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let envelope = try await get(path, as: CPEEnvelope<T>.self)
        guard envelope.isOK else {
            throw APIError.disabled(envelope.message ?? "\(path) 返回 \(envelope.status ?? "error")")
        }
        guard let data = envelope.data else {
            throw APIError.decoding("\(path) 无 data 字段")
        }
        return data
    }

    // MARK: 探活

    /// GET /api/health —— 返回 `{status:"ok", message, version}`，没有 data 包装
    func health() async throws -> String {
        struct Health: Decodable {
            var status: String?
            var message: String?
            var version: String?
        }
        let h = try await get("/api/health", as: Health.self)
        guard (h.status ?? "").lowercased() == "ok" else {
            throw APIError.disabled(h.message ?? "健康检查未通过")
        }
        return h.version ?? "ok"
    }

    // MARK: 各业务接口

    func device() async throws -> CPEDevice { try await getData("/api/device", as: CPEDevice.self) }
    func sim() async throws -> CPESim { try await getData("/api/sim", as: CPESim.self) }
    func network() async throws -> CPENetwork { try await getData("/api/network", as: CPENetwork.self) }
    func qos() async throws -> CPEQos { try await getData("/api/qos", as: CPEQos.self) }
    func cells() async throws -> CPECells { try await getData("/api/cells", as: CPECells.self) }
    func stats() async throws -> CPEStats { try await getData("/api/stats", as: CPEStats.self) }

    /// POST /api/system/reboot —— 不可撤销的写操作，只在用户二次确认后调用
    func reboot() async throws {
        guard let url = URL(string: "/api/system/reboot", relativeTo: baseURL) else {
            throw APIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.server(status, String(data: data, encoding: .utf8) ?? "")
        }
        // 重启一旦受理，设备会立刻断连，响应也未必回得来 —— 到这个位置就算成功
    }
}

// MARK: - 映射到 App 内的统一模型

extension CPECells {

    /// 服务小区的制式 → App 里用于配色/标签的文案
    var displayTech: String? {
        let tech = (servingCell?.tech ?? serving?.tech ?? "").lowercased()
        if tech.contains("nr") || tech.contains("5g") { return "5G NR" }
        if tech.contains("lte") || tech.contains("4g") { return "4G LTE" }
        if tech.contains("wcdma") || tech.contains("umts") { return "3G WCDMA" }
        return tech.isEmpty ? nil : tech.uppercased()
    }

    /// 映射成界面用的 BandData。信号值是 ×100 的原始值，这里统一除以 100。
    var bandData: BandData {
        var d = BandData()
        d.networkType = displayTech
        guard let c = serving else { return d }

        if let band = c.band, !band.isEmpty, band != "0" { d.band = band }
        d.arfcn = c.arfcn?.int
        d.pci = c.pci?.int
        d.rsrp = c.rsrp?.milli
        d.rsrq = c.rsrq?.milli
        d.sinr = c.sinr?.milli
        return d
    }
}

extension CPEStats {

    /// 映射成界面用的 DeviceInfo（信息量最小的那部分：硬件）
    func hardwareInfo(into base: DeviceInfo) -> DeviceInfo {
        var info = base

        if let sys = systemInfo {
            info.hostname = sys.nodename
            info.sysname = sys.sysname
            info.release = sys.release
            info.version = sys.version
            info.machine = sys.machine
        }
        if let m = memory {
            // DeviceInfo 的 RAM 字段约定是 MiB（见 Fmt.mb 的注释）
            info.totalRam = m.totalBytes.map { Double($0) / 1_048_576 }
            info.freeRam = m.availableBytes.map { Double($0) / 1_048_576 }
            info.cachedRam = m.cachedBytes.map { Double($0) / 1_048_576 }
        }
        if let load = cpuLoad?.loadPercent { info.cpuUsage = load }
        if let up = uptime?.uptimeSeconds { info.uptime = up }
        if let t = mainTemperature { info.thermalTemp = t }
        return info
    }

    /// 映射成界面用的 NetifStats（实时速率 + 累计字节）
    func netifStats(interface name: String?) -> (stats: NetifStats, name: String?) {
        var s = NetifStats()
        guard let net = pickInterface(preferred: name) else {
            return (s, nil)
        }

        s.seconds = networkSpeed?.intervalSeconds.map { Int($0.rounded()) } ?? 1

        var rx = NetifDirection()
        rx.bytespersecond = net.rxBytesPerSec
        rx.totalbytes = net.totalRxBytes

        var tx = NetifDirection()
        tx.bytespersecond = net.txBytesPerSec
        tx.totalbytes = net.totalTxBytes

        s.rx = rx
        s.tx = tx
        return (s, net.interface)
    }

    /// 累计流量。project-cpe 没有账单周期，只能给「开机以来的网卡累计」。
    func trafficTotal(interface name: String?) -> TrafficTotalResponse? {
        guard let net = pickInterface(preferred: name) else { return nil }
        let rx = net.totalRxBytes ?? 0
        let tx = net.totalTxBytes ?? 0
        guard rx > 0 || tx > 0 else { return nil }
        return TrafficTotalResponse(
            rx: Fmt.bytes(rx),
            tx: Fmt.bytes(tx),
            total: Fmt.bytes(rx + tx)
        )
    }
}

extension CPENetwork {
    /// 信号格用的 0–100（后端给的就是这个量纲；个别固件给负数 dBm，夹一下）
    var signalPercent: Double? {
        guard let s = signalStrength else { return nil }
        if s < 0 { return max(0, min(100, (s + 120) / 60 * 100)) }
        return max(0, min(100, s))
    }
}
