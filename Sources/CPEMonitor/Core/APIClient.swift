import Foundation

enum APIError: LocalizedError {
    case badURL
    case transport(String)
    case unauthorized
    case decoding(String)
    case server(Int, String)
    case disabled(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效，请检查设置"
        case .transport(let m): return "连接失败：\(m)"
        case .unauthorized: return "未授权，请检查后台密码"
        case .decoding(let m): return "数据解析失败：\(m)"
        case .server(let code, let m): return "服务返回 \(code)：\(m)"
        case .disabled(let m): return m
        }
    }
}

/// UDX710-TOOLS HTTP 客户端
struct APIClient {

    let baseURL: URL
    var token: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - 底层请求

    /// 统一的 JSON 编码。
    ///
    /// ⚠️ 必须带 `.withoutEscapingSlashes`。Foundation 默认会把 `/` 转义成 `\/`，
    /// 而设备端 mongoose 的 `mg_json_get_str` **不认这个转义**，解析直接失败：
    /// `/api/shell` 会当成空命令返回 `{"Code":1,"Error":"命令不能为空"}`。
    /// 因为只有带路径的命令才会踩到，`echo` 之类的小命令看不出来。
    private static func encode(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    private func perform<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        authorized: Bool = true,
        as type: T.Type
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, authorized {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if status == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(status, text.isEmpty ? "无响应内容" : text)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // MARK: - 诊断

    /// 返回原始响应文本，不经过模型解码。
    /// 用于排查「服务端有数据但模型解不出来」这类问题。
    func rawBody(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> String {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encode(body)
        }
        let (data, _) = try await Self.session.data(for: request)
        return String(data: data, encoding: .utf8) ?? "<非 UTF-8，\(data.count) 字节>"
    }

    /// 有些 handler 在异常时返回非 2xx 但仍是 JSON，这里做一次兜底
    private func performLenient<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        authorized: Bool = true,
        as type: T.Type
    ) async throws -> T {
        do {
            return try await perform(path, method: method, body: body,
                                     authorized: authorized, as: type)
        } catch let error as APIError {
            if case .unauthorized = error { throw error }
            if case .server(let code, let text) = error {
                if let data = text.data(using: .utf8),
                   let decoded = try? JSONDecoder.decodeSnakeCase(T.self, from: data) {
                    return decoded
                }
                throw APIError.server(code, text)
            }
            throw error
        } catch {
            throw error
        }
    }

    // MARK: - 免登录接口

    /// 9527 的独立管理服务。仅使用已确认的 GET 接口。
    func localSysInfo() async throws -> LocalSysInfo {
        try await perform("/api/sysinfo", authorized: false, as: LocalSysInfo.self)
    }

    func localTemperature() async throws -> LocalTemperature {
        try await perform("/api/sys/temp", authorized: false, as: LocalTemperature.self)
    }

    /// GET /api/info —— 免认证白名单，不带 Authorization
    func info() async throws -> DeviceInfo {
        try await performLenient("/api/info", authorized: false, as: DeviceInfo.self)
    }

    /// GET /api/current_band —— 免认证白名单，不带 Authorization
    func currentBand() async throws -> BandResponse {
        try await performLenient("/api/current_band", authorized: false, as: BandResponse.self)
    }

    // MARK: - 需要认证的接口

    /// POST /api/auth/login
    func login(password: String) async throws -> String {
        let res: LoginResponse = try await perform(
            "/api/auth/login",
            method: "POST",
            body: ["password": password],
            authorized: false,
            as: LoginResponse.self
        )
        guard let token = res.token, !token.isEmpty else {
            throw APIError.unauthorized
        }
        return token
    }

    /// GET /api/netif/list
    func netifList() async throws -> [NetifInfo] {
        let res: NetifListResponse = try await perform("/api/netif/list", as: NetifListResponse.self)
        return res.interfaces ?? []
    }

    /// POST /api/netif/monitor —— 必须先开启监听，/api/netif/stats 才有数据
    func setNetifMonitor(interface: String, enabled: Bool) async throws {
        struct Ack: Decodable {
            var status: String?
            var interface: String?
            var enabled: Bool?
        }
        let _: Ack = try await performLenient(
            "/api/netif/monitor",
            method: "POST",
            body: ["interface": interface, "enabled": enabled],
            as: Ack.self
        )
    }

    /// POST /api/netif/stats —— 实时速率来源（vnstat）
    func netifStats(interface: String) async throws -> NetifStats {
        try await perform(
            "/api/netif/stats",
            method: "POST",
            body: ["interface": interface],
            as: NetifStats.self
        )
    }

    /// GET /api/get/Total —— vnstat 累计流量
    func trafficTotal() async throws -> TrafficTotalResponse {
        try await perform("/api/get/Total", as: TrafficTotalResponse.self)
    }

    /// GET /api/get/set —— 流量上限配置
    func trafficConfig() async throws -> TrafficConfigResponse {
        try await perform("/api/get/set", as: TrafficConfigResponse.self)
    }

    // MARK: - 设备维护

    /// POST /api/clear_cache —— 设备端执行 `sync` + `echo 3 > /proc/sys/vm/drop_caches`。
    ///
    /// 清的是**内核页缓存**（/proc/meminfo 的 Cached，也就是 /api/info 的 cached_ram），
    /// 不碰任何正在运行的进程；设备只有 200MB 内存，释放出来的量是可感知的。
    /// 返回体形如 `{"status":"success","message":"Cache cleared successfully"}`。
    func clearCache() async throws {
        struct Ack: Decodable {
            var status: String?
            var message: String?
        }
        let ack: Ack = try await performLenient(
            "/api/clear_cache", method: "POST", as: Ack.self
        )
        // 设备端失败时会回 500 + Failed to clear cache，能走到这里基本就是成功；
        // 但仍校验一次 status，避免把异常当成功报给用户。
        if let status = ack.status, status != "success" {
            throw APIError.server(200, ack.message ?? "设备未确认清理成功")
        }
    }

    /// POST /api/set/total（空 body）—— 删除并重建设备上的 vnstat 数据库。
    ///
    /// ⚠️ 这是**不可撤销**的操作：设备端 `handle_set_traffic_limit` 发现请求里
    /// 没有 switch / much 参数时，会 `rm -f /var/lib/vnstat/vnstat.db` 再重建，
    /// 历史流量统计全部归零。返回体形如 `{"success":true,"msg":"Clean ok"}`。
    ///
    /// 注意别和 `TrafficAccumulator.reset()` 搞混：那个只清 Mac 本地的
    /// UserDefaults 累计值，完全碰不到设备端数据。
    func resetTrafficStats() async throws {
        struct Ack: Decodable {
            var success: Bool?
            var msg: String?
        }
        let ack: Ack = try await performLenient(
            "/api/set/total", method: "POST", body: [:], as: Ack.self
        )
        if let success = ack.success, !success {
            throw APIError.server(200, ack.msg ?? "设备未确认重置成功")
        }
    }

    /// POST /api/shell —— 用于取 vnstat 的当月/当日明细
    func shell(_ command: String) async throws -> ShellResponse {
        try await perform(
            "/api/shell",
            method: "POST",
            body: ["command": command],
            as: ShellResponse.self
        )
    }

    /// 用 vnstat 取当月/当日流量（字节）
    ///
    /// ⚠️ 设备上是 vnStat 2.11，`--json` **不接受逗号分隔的多个模式**：
    /// `--json m,d` 会被 vnstat 当成接口名，报
    /// `Error: No interface matching "m,d" found in database.`
    /// 所以这里分成两次调用，各自输出只有几百字节。
    func vnstatDetail(interface: String, vnstatPath: String = "/home/root/6677/vnstat")
        async throws -> VnstatDetail
    {
        // 两次请求必须串行：设备端是单线程 Mongoose，shell 又是同步阻塞执行，
        // 并发发出去会有一个拿不到结果。任一项失败也不影响另一项。
        var detail = VnstatDetail()
        var problems: [String] = []

        do {
            let res = try await shell("\(vnstatPath) -i \(interface) --json m")
            let m = try Self.parseVnstat(res, key: "month")
            detail.monthBytes = m.bytes
            if let d = m.date {
                detail.monthLabel = "\(d.year)-\(d.month)"
                let now = Calendar.current.dateComponents([.year, .month], from: Date())
                detail.monthIsCurrent = (d.year == now.year && d.month == now.month)
            }
        } catch {
            problems.append("m: \(error)")
        }

        do {
            let res = try await shell("\(vnstatPath) -i \(interface) --json d")
            let d = try Self.parseVnstat(res, key: "day")
            detail.dayBytes = d.bytes
            // 标注当日数据的实际日期，用来识别 vnstatd 停摆导致的「日期停在昨天」
            if let date = d.date {
                let label = date.day > 0 ? "\(date.month)-\(date.day)" : "\(date.month)"
                detail.dayLabel = label
                let now = Calendar.current.dateComponents([.month, .day], from: Date())
                detail.dayIsToday = (date.month == now.month && date.day == now.day)
            }
        } catch {
            problems.append("d: \(error)")
        }

        guard detail.monthBytes > 0 || detail.dayBytes > 0 else {
            throw APIError.disabled("vnstat 无输出（\(problems.joined(separator: " | "))）")
        }
        return detail
    }

    /// 解析 vnstat JSON 里 `interfaces[0].traffic.<key>` 的最后一条
    private static func parseVnstat(
        _ res: ShellResponse, key: String
    ) throws -> (bytes: Int64, date: (year: Int, month: Int, day: Int)?) {
        guard let text = res.data, let data = text.data(using: .utf8) else {
            throw APIError.disabled("vnstat 无输出")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let interfaces = root["interfaces"] as? [[String: Any]],
              let first = interfaces.first,
              let traffic = first["traffic"] as? [String: Any],
              let rows = traffic[key] as? [[String: Any]],
              let last = rows.last else {
            throw APIError.decoding("vnstat 结构异常（缺少 traffic.\(key)）")
        }

        let rx = (last["rx"] as? NSNumber)?.int64Value ?? 0
        let tx = (last["tx"] as? NSNumber)?.int64Value ?? 0

        var date: (Int, Int, Int)?
        if let d = last["date"] as? [String: Any] {
            date = (d["year"] as? Int ?? 0, d["month"] as? Int ?? 0, d["day"] as? Int ?? 0)
        }
        return (rx + tx, date)
    }
}

/// vnstat 当月/当日明细
struct VnstatDetail {
    var monthBytes: Int64 = 0
    var dayBytes: Int64 = 0
    /// 形如 "9-11"；vnstatd 停摆时会停在最后一天
    var dayLabel: String?
    /// 形如 "2026-9"
    var monthLabel: String?
    var dayIsToday = true
    var monthIsCurrent = true
}

extension JSONDecoder {
    static func decodeSnakeCase<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
