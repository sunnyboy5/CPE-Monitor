import Foundation

// MARK: - 9527 免登录只读接口

struct LocalSysInfo: Decodable {
    struct System: Decodable {
        var uptime: Double?
        var totalMemory: Double?
        var freeMemory: Double?
    }

    struct Subscription: Decodable {
        var qci: Int?
        var dl: Int?
        var ul: Int?
    }

    var sys: System
    var ambr: Subscription?

    var deviceInfo: DeviceInfo {
        var info = DeviceInfo()
        info.uptime = sys.uptime
        // 9527 返回字节，DeviceInfo 使用 MiB。
        info.totalRam = sys.totalMemory.map { $0 / 1_048_576 }
        info.freeRam = sys.freeMemory.map { $0 / 1_048_576 }
        info.qci = ambr?.qci
        info.downlinkRate = ambr?.dl
        info.uplinkRate = ambr?.ul
        return info
    }
}

struct LocalTemperature: Decodable {
    var temp: [String: Double]?

    var celsius: Double? {
        guard let value = temp?["soc-thmzone"] ?? temp?["nrcp-thmzone"] else { return nil }
        return value > 100 ? value / 1000 : value
    }
}

// MARK: - GET /api/info

/// 设备主状态。字段名严格对应 UDX710-TOOLS `src/handlers/handlers.c` 的 `handle_info`。
struct DeviceInfo: Codable, Equatable {
    var hostname: String?
    var sysname: String?
    var release: String?
    var version: String?
    var machine: String?

    var totalRam: Double?
    var freeRam: Double?
    var cachedRam: Double?
    var cpuUsage: Double?
    var uptime: Double?

    var bridgeStatus: String?
    var simSlot: String?
    var signalStrength: String?
    var thermalTemp: Double?
    var powerStatus: String?
    var batteryHealth: String?
    var batteryCapacity: Int?

    var ssid: String?
    var selectNetworkMode: String?
    var isActivated: Int?
    var serial: String?

    var networkMode: String?
    var airplaneMode: Bool?
    var imei: String?
    var iccid: String?
    var imsi: String?
    var carrier: String?
    var networkType: String?
    var networkBand: String?

    /// QCI 签约等级
    var qci: Int?
    /// QCI 签约下行速率（Mbps），非实时吞吐
    var downlinkRate: Int?
    /// QCI 签约上行速率（Mbps），非实时吞吐
    var uplinkRate: Int?

    /// 内存占用百分比
    var memoryUsagePercent: Double? {
        guard let total = totalRam, total > 0, let free = freeRam else { return nil }
        return max(0, min(100, (1 - free / total) * 100))
    }

    static let empty = DeviceInfo()
}

// MARK: - GET /api/current_band

/// 注意：后端这个 handler 用的是首字母大写的 Code / Error / Data。
/// Foundation 的 convertFromSnakeCase 对「不含下划线」的键是原样保留的，
/// 所以必须显式声明 CodingKeys，同时兼容全小写写法。
struct BandResponse: Codable, Equatable {
    var code: Int?
    var error: String?
    var data: BandData?

    enum CodingKeys: String, CodingKey {
        case code = "Code", upperError = "Error", data = "Data"
        case lowerCode = "code", lowerError = "error", lowerData = "data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decodeIfPresent(Int.self, forKey: .code)) ?? nil
        if code == nil { code = (try? c.decodeIfPresent(Int.self, forKey: .lowerCode)) ?? nil }

        error = (try? c.decodeIfPresent(String.self, forKey: .upperError)) ?? nil
        if error == nil { error = (try? c.decodeIfPresent(String.self, forKey: .lowerError)) ?? nil }

        data = (try? c.decodeIfPresent(BandData.self, forKey: .data)) ?? nil
        if data == nil { data = (try? c.decodeIfPresent(BandData.self, forKey: .lowerData)) ?? nil }
    }

    init() {}

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(error, forKey: .upperError)
        try c.encodeIfPresent(data, forKey: .data)
    }
}

struct BandData: Codable, Equatable {
    var networkType: String?
    var band: String?
    var arfcn: Int?
    var pci: Int?
    var rsrp: Double?
    var rsrq: Double?
    var sinr: Double?

    var isEmpty: Bool {
        (rsrp ?? 0) == 0 && (sinr ?? 0) == 0 && (rsrq ?? 0) == 0 &&
        (band ?? "N/A") == "N/A"
    }
}

// MARK: - GET /api/netif/list

struct NetifListResponse: Codable, Equatable {
    var interfaces: [NetifInfo]?
}

struct NetifInfo: Codable, Equatable, Identifiable {
    var name: String
    var hwaddr: String?
    var inetAddr: String?
    var inet6Addr: String?
    var mask: String?
    var isUp: Bool?
    var monitoring: Bool?

    var id: String { name }

    /// 挑选用于统计实时速率的网卡：优先承载蜂窝数据的那几张
    static let preferredOrder = ["sipa_eth0", "eth0", "usb0", "rmnet0", "wwan0", "wlan0"]

    static func pick(from list: [NetifInfo]) -> NetifInfo? {
        let usable = list.filter { $0.name != "lo" }
        for candidate in preferredOrder {
            if let hit = usable.first(where: { $0.name == candidate }) { return hit }
        }
        return usable.first(where: { $0.isUp == true }) ?? usable.first
    }
}

// MARK: - POST /api/netif/stats

struct NetifStats: Codable, Equatable {
    var index: Int?
    var seconds: Int?
    var rx: NetifDirection?
    var tx: NetifDirection?
}

struct NetifDirection: Codable, Equatable {
    var ratestring: String?
    var bytespersecond: Int64?
    var packetspersecond: Int64?
    var bytes: Int64?
    var packets: Int64?
    var totalbytes: Int64?
    var totalpackets: Int64?

    var bytesPerSecond: Double { Double(bytespersecond ?? 0) }
}

// MARK: - GET /api/get/Total

struct TrafficTotalResponse: Codable, Equatable {
    var rx: String?
    var tx: String?
    var total: String?

    /// 把 total / rx / tx 解析为字节数（Int64）。任一字段解析失败返回 nil。
    var totalBytes: Int64? { Fmt.parseBytes(total) }
    var rxBytes: Int64? { Fmt.parseBytes(rx) }
    var txBytes: Int64? { Fmt.parseBytes(tx) }
}

// MARK: - GET /api/get/set

struct TrafficConfigResponse: Codable, Equatable {
    var much: Int64?
    var trafficSwitch: Int?

    enum CodingKeys: String, CodingKey {
        case much
        case trafficSwitch = "switch"
    }

    /// switch == 1 表示启用了流量上限，即「固定流量」套餐
    var isLimited: Bool { (trafficSwitch ?? 0) == 1 }
}

// MARK: - POST /api/auth/login

struct LoginResponse: Codable, Equatable {
    var status: String?
    var message: String?
    var token: String?
}

// MARK: - POST /api/shell

/// 同样使用首字母大写的 Code / Error / Data
struct ShellResponse: Codable, Equatable {
    var code: Int?
    var error: String?
    var data: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code", upperError = "Error", data = "Data"
        case lowerCode = "code", lowerError = "error", lowerData = "data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decodeIfPresent(Int.self, forKey: .code)) ?? nil
        if code == nil { code = (try? c.decodeIfPresent(Int.self, forKey: .lowerCode)) ?? nil }

        error = (try? c.decodeIfPresent(String.self, forKey: .upperError)) ?? nil
        if error == nil { error = (try? c.decodeIfPresent(String.self, forKey: .lowerError)) ?? nil }

        data = (try? c.decodeIfPresent(String.self, forKey: .data)) ?? nil
        if data == nil { data = (try? c.decodeIfPresent(String.self, forKey: .lowerData)) ?? nil }
    }

    init() {}

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(error, forKey: .upperError)
        try c.encodeIfPresent(data, forKey: .data)
    }
}

// MARK: - 后端返回的统一错误体

struct APIErrorBody: Codable {
    var status: String?
    var message: String?
    var error: String?
}

// MARK: - 聚合快照：UI 只读这一个对象

struct MonitorSnapshot: Equatable {
    var info: DeviceInfo?
    var band: BandData?
    var stats: NetifStats?
    var trafficTotal: TrafficTotalResponse?
    var trafficConfig: TrafficConfigResponse?
    var monthlyBytes: Int64?
    var dailyBytes: Int64?
    /// 当日明细实际归属的日期，例如 "9-11"。
    /// 正常情况下累加器按 Mac 本地日历日划分，dailyLabel 为 nil；
    /// 只有首次启动、累加器还没拿到第一次采样时，fallback 到 vnstat 的旧 DB 数据，
    /// 此时可能标 "9-11" 等过期日期提示用户。
    var dailyLabel: String?
    var interfaceName: String?

    var downloadBytesPerSecond: Double { stats?.rx?.bytesPerSecond ?? 0 }
    var uploadBytesPerSecond: Double { stats?.tx?.bytesPerSecond ?? 0 }

    static let empty = MonitorSnapshot()
}

// MARK: - 连接状态

enum LinkState: Equatable {
    case idle
    case connecting
    case online
    case unauthorized
    case failed(String)

    var isOnline: Bool { self == .online }
}
