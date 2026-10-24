//
//  TrafficAccumulator.swift
//  CPEMonitor
//
//  流量实时累加器：基于 netif/monitor 返回的实时累计字节数自己算「今日已用」。
//
//  历史背景：之前本类同时算「今日」和「本月」，本月从 netif/stats.totalbytes delta 来。
//  后来发现 netif 的 totalbytes 是网卡物理收发计数（设备启动起算），与
//  `/api/get/Total` 接口返回的运营商账单口径累计差 3.5 GB。两套数据不能混用。
//  现在「当月已用」改用 `/api/get/Total` 接口直接读取（见 MonitorEngine.refreshTraffic），
//  本累加器只保留「当日已用」一项职责。`monthBytes` 字段保留仅为兼容旧持久化状态。
//
//  设计要点：
//  - 每次 update 算 delta（max(0, current - last)），跨日时把累加器归零，
//    新周期的首个 delta 作为新周期第一笔。
//  - 状态持久化到 UserDefaults（JSON 编码），Mac 重启后能继续累加，
//    不会把"今日已用"清零。
//  - 跨日判断用本地日历日（设备时间和 Mac 时间可能有漂移，
//    用户看到的是 Mac 上的"今天"，以 Mac 为准）。
//
//  非 actor 隔离：本类只是个状态机，所有调用都在 MonitorEngine 主线程串行执行。
//  测试用例也是单线程，无竞争。
//

import Foundation

final class TrafficAccumulator {

    struct State: Codable, Equatable {
        var lastRxBytes: Int64
        var lastTxBytes: Int64
        var dayTotalBytes: Int64
        var monthTotalBytes: Int64
        var dayKey: String
        var monthKey: String
        var hasInitial: Bool
        var updatedAt: TimeInterval
        /// 这组计数来自哪台设备/哪个网卡（host:port:protocol:iface）。
        /// 换设备后累计基数完全不同，必须先归零再累加，否则会出现
        /// 「今日用量突然多出几十 GB」——那是新基数减旧基数算出来的假增量。
        var sourceKey: String?

        static let empty = State(
            lastRxBytes: 0, lastTxBytes: 0,
            dayTotalBytes: 0, monthTotalBytes: 0,
            dayKey: "", monthKey: "",
            hasInitial: false, updatedAt: 0, sourceKey: nil
        )
    }

    private(set) var state: State
    private let defaults: UserDefaults
    private let key: String
    private let clock: () -> Date

    init(defaults: UserDefaults = .standard,
         key: String = "traffic.accumulator.v1",
         clock: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.key = key
        self.clock = clock

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = .empty
        }
    }

    /// 当前"今日"累计字节数（rx + tx）。还没拿到首次采样时为 nil。
    var todayBytes: Int64? {
        guard state.hasInitial else { return nil }
        return state.dayTotalBytes
    }

    /// 当前"本月"累计字节数（rx + tx）。还没拿到首次采样时为 nil。
    var monthBytes: Int64? {
        guard state.hasInitial else { return nil }
        return state.monthTotalBytes
    }

    /// 喂一次新的累计字节数。会自动处理跨日 / 跨月归零。
    ///
    /// - Parameter source: 计数来源标识（设备 + 协议 + 网卡）。与上一次不同时
    ///   会先归零再重新记起点 —— 换了设备以后两套计数器没有任何可比性。
    func update(rxBytes: Int64?, txBytes: Int64?, source: String = "") {
        guard let rx = rxBytes, let tx = txBytes else { return }

        let now = clock()
        let nowDay = Self.dayKey(for: now)
        let nowMonth = Self.monthKey(for: now)

        // 换了设备 / 固件协议 / 网卡：旧基数作废，按首次采样重新来
        if state.hasInitial {
            if let old = state.sourceKey {
                if old != source { state = .empty }
            } else {
                // 老版本存的状态没有来源标识，判断不了是不是同一台设备 —— 归零重来。
                // 宁可丢掉一次累计，也不要显示一个凭空的几十 GB。
                state = .empty
            }
        }

        // 首次：只记录起点，不算"过去已用"。
        if !state.hasInitial {
            state.lastRxBytes = rx
            state.lastTxBytes = tx
            state.dayKey = nowDay
            state.monthKey = nowMonth
            state.dayTotalBytes = 0
            state.monthTotalBytes = 0
            state.hasInitial = true
            state.sourceKey = source
            state.updatedAt = now.timeIntervalSince1970
            persist()
            return
        }

        state.sourceKey = source

        // 设备重启 / 接口切换：rx/tx 可能倒退，按 0 算 delta。
        let rxDelta = max(Int64(0), rx - state.lastRxBytes)
        let txDelta = max(Int64(0), tx - state.lastTxBytes)
        let totalDelta = rxDelta + txDelta

        // 跨日：本次 delta 算进新一天；如果新一天还没记录，从 0 起算。
        if state.dayKey == nowDay {
            state.dayTotalBytes += totalDelta
        } else {
            state.dayTotalBytes = totalDelta
            state.dayKey = nowDay
        }

        // 跨月：同上。
        if state.monthKey == nowMonth {
            state.monthTotalBytes += totalDelta
        } else {
            state.monthTotalBytes = totalDelta
            state.monthKey = nowMonth
        }

        state.lastRxBytes = rx
        state.lastTxBytes = tx
        state.updatedAt = now.timeIntervalSince1970
        persist()
    }

    /// 清空所有状态（用户手动重置 / 设置变更时调）。
    func reset() {
        state = .empty
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    private static func dayKey(for date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func monthKey(for date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }
}