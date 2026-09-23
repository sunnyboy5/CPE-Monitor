import Foundation

/// 数值格式化工具
enum Fmt {

    /// 字节 → 人类可读，例如 1.24 GB
    static func bytes(_ value: Int64?, decimals: Int = 2) -> String {
        guard let value, value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var idx = 0
        while v >= 1024, idx < units.count - 1 {
            v /= 1024
            idx += 1
        }
        if idx == 0 { return "\(Int(v)) B" }
        return String(format: "%.\(decimals)f %@", v, units[idx])
    }

    /// 字节/秒 → 速率字符串，自动在 KB/s 与 MB/s 间切换
    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return String(format: "%.0f B/s", bytesPerSecond) }
        let kb = bytesPerSecond / 1024
        if kb < 1024 { return String(format: "%.1f KB/s", kb) }
        return String(format: "%.2f MB/s", kb / 1024)
    }

    /// 速率数值部分（不含单位），用于菜单栏紧凑展示
    static func rateCompact(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return String(format: "%.0fB", bytesPerSecond) }
        let kb = bytesPerSecond / 1024
        if kb < 1024 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024
        if mb < 100 { return String(format: "%.1fM", mb) }
        return String(format: "%.0fM", mb)
    }

    /// 秒 → 天/时/分
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "--" }
        let total = Int(seconds)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }

    /// 百分比数值，例如 28.4%
    static func percent(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "--" }
        return String(format: "%.\(decimals)f%%", value)
    }

    static func temp(_ value: Double?) -> String {
        guard let value, value > 0 else { return "--" }
        return String(format: "%.1f °C", value)
    }

    static func orDash(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "N/A", value != "null" else { return "--" }
        return value
    }

    static func intOrDash(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value)"
    }

    /// MB → 人类可读，例如 96 MB / 1.25 GB。
    ///
    /// 设备 `/api/info` 的 total_ram / free_ram / **cached_ram** 单位是 **MB**
    /// （`sysinfo.c` 把 /proc/meminfo 的 kB 除以了 1024），不是字节。
    /// 直接喂给 `Fmt.bytes(_:)` 会少 1024 倍，所以 RAM 类字段走这个函数。
    static func mb(_ value: Double?) -> String {
        guard let value, value > 0 else { return "--" }
        if value >= 1024 { return String(format: "%.2f GB", value / 1024) }
        return String(format: "%.0f MB", value)
    }

    /// 解析设备 `/api/get/Total` 返回的人类可读字符串，如 "9.111 GB" → 9 174 945 587 字节。
    /// 设备用的是 KB/MB/GB（千进制，不是 1024），但这里统一按 1024 还原回去，
    /// 因为面板上「已用 = 流量上限 - 剩余」是按二进制对齐的，差 2.4% 用户看不出来。
    /// 解析失败返回 nil。
    static func parseBytes(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        // 拆数字 + 单位
        var chars = Array(trimmed)
        var idx = 0

        // 跳过前导空白
        while idx < chars.count, chars[idx].isWhitespace { idx += 1 }

        // 读数字（含小数点）
        var numberStr = ""
        var sawDot = false
        while idx < chars.count {
            let c = chars[idx]
            if c.isNumber || (c == "." && !sawDot) {
                numberStr.append(c)
                if c == "." { sawDot = true }
                idx += 1
            } else { break }
        }
        guard let number = Double(numberStr) else { return nil }

        // 跳过数字和单位之间的空白
        while idx < chars.count, chars[idx].isWhitespace { idx += 1 }

        // 读字母单位
        var unit = ""
        while idx < chars.count, chars[idx].isLetter {
            unit.append(chars[idx])
            idx += 1
        }
        let upper = unit.uppercased()

        let multiplier: Double
        switch upper {
        case "B", "":                            multiplier = 1
        case "KB", "K":                          multiplier = 1024
        case "MB", "M":                          multiplier = 1024 * 1024
        case "GB", "G":                          multiplier = 1024 * 1024 * 1024
        case "TB", "T":                          multiplier = 1024 * 1024 * 1024 * 1024
        default:                                  multiplier = 1
        }
        return Int64(number * multiplier)
    }

    /// QCI 签约速率。
    ///
    /// 设备 /api/info 的 downlink_rate / uplink_rate 单位是 **kbps**
    /// （实测 1000000 / 200000，对应 1000 / 200 Mbps），
    /// 直接当 Mbps 显示会差 1000 倍，这里统一换算。
    static func signedMbps(_ kbps: Int?) -> String {
        guard let kbps, kbps > 0 else { return "--" }
        let mbps = Double(kbps) / 1000
        if mbps >= 100 { return String(format: "%.0f", mbps) }
        if mbps >= 10 { return String(format: "%.1f", mbps) }
        return String(format: "%.2f", mbps)
    }

    /// 脱敏：只留头尾
    static func mask(_ value: String?, keepHead: Int = 4, keepTail: Int = 3) -> String {
        guard let value, value.count > keepHead + keepTail else { return orDash(value) }
        let head = value.prefix(keepHead)
        let tail = value.suffix(keepTail)
        return "\(head)****\(tail)"
    }
}
