import SwiftUI

/// 信号质量评级
enum Quality: String, CaseIterable {
    case excellent = "极佳"
    case good = "良好"
    case fair = "一般"
    case poor = "较差"
    case unknown = "未知"

    var color: Color {
        switch self {
        case .excellent: return Theme.levelExcellent
        case .good: return Theme.levelGood
        case .fair: return Theme.levelFair
        case .poor: return Theme.levelPoor
        case .unknown: return Theme.textTertiary
        }
    }

    /// RSRP 参考信号接收功率（dBm），越大越好
    static func rsrp(_ value: Double?) -> Quality {
        guard let v = value, v != 0 else { return .unknown }
        switch v {
        case (-80)...: return .excellent
        case (-90)..<(-80): return .good
        case (-100)..<(-90): return .fair
        default: return .poor
        }
    }

    /// SINR 信噪比（dB），越大越好
    static func sinr(_ value: Double?) -> Quality {
        guard let v = value, v != 0 else { return .unknown }
        switch v {
        case 20...: return .excellent
        case 13..<20: return .good
        case 0..<13: return .fair
        default: return .poor
        }
    }

    /// RSRQ 参考信号接收质量（dB），越大越好
    static func rsrq(_ value: Double?) -> Quality {
        guard let v = value, v != 0 else { return .unknown }
        switch v {
        case (-10)...: return .excellent
        case (-15)..<(-10): return .good
        case (-20)..<(-15): return .fair
        default: return .poor
        }
    }

    /// 把指标映射成 0...1 的进度，用于进度条
    static func fraction(rsrp value: Double?) -> Double {
        guard let v = value, v != 0 else { return 0 }
        return clamp((v + 120) / 60)
    }

    static func fraction(sinr value: Double?) -> Double {
        guard let v = value, v != 0 else { return 0 }
        return clamp((v + 10) / 40)
    }

    static func fraction(rsrq value: Double?) -> Double {
        guard let v = value, v != 0 else { return 0 }
        return clamp((v + 20) / 15)
    }

    /// 负载类指标（CPU/内存占用）越高越差
    static func load(_ percent: Double?) -> Quality {
        guard let v = percent else { return .unknown }
        switch v {
        case ..<50: return .good
        case 50..<75: return .fair
        default: return .poor
        }
    }

    /// 温度（摄氏度）
    static func temperature(_ value: Double?) -> Quality {
        guard let v = value, v > 0 else { return .unknown }
        switch v {
        case ..<50: return .excellent
        case 50..<65: return .good
        case 65..<80: return .fair
        default: return .poor
        }
    }

    private static func clamp(_ v: Double) -> Double {
        min(1, max(0, v))
    }
}

/// 网络制式标签，用于给 5G / 4G 上色
enum NetworkGeneration {
    static func label(_ type: String?) -> String {
        guard let type, !type.isEmpty, type != "N/A" else { return "--" }
        if type.contains("5G") { return "5G SA" }
        if type.contains("LTE") || type.contains("4G") { return "4G LTE" }
        return type
    }

    static func is5G(_ type: String?) -> Bool {
        guard let type else { return false }
        return type.contains("5G") || type.uppercased().contains("NR")
    }

    /// 频段前缀补齐
    ///
    /// 各固件给的写法不统一：旧 6677 给 "78"、project-cpe 给 "n78"/"B3"。
    /// 统一输出大写（N78 / B3），避免同一个频段在演示数据和真机里长得不一样。
    static func band(_ raw: String?, is5G: Bool) -> String {
        guard let raw, !raw.isEmpty, raw != "N/A" else { return "--" }
        let upper = raw.uppercased()
        if upper.hasPrefix("N") || upper.hasPrefix("B") { return upper }
        return (is5G ? "N" : "B") + upper
    }
}
