import SwiftUI

// MARK: - 1. 运营商 / 网络信息

/// 参考图的第二张卡：运营商 + 制式标签 + 信号格，下面嵌一条「签约状态」浅底行。
struct NetworkInfoPanel: View {
    let info: DeviceInfo?
    let band: BandData?

    private var is5G: Bool {
        NetworkGeneration.is5G(band?.networkType ?? info?.networkType)
    }

    private var bandName: String {
        NetworkGeneration.band(band?.band ?? info?.networkBand, is5G: is5G)
    }

    private var signalLevel: Int {
        switch Quality.rsrp(band?.rsrp) {
        case .excellent: return 4
        case .good: return 3
        case .fair: return 2
        case .poor: return 1
        case .unknown: return 0
        }
    }

    var body: some View {
        CardBox {
            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    CarrierBadge(name: info?.carrier)

                    Text(Fmt.orDash(info?.carrier))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Pill(text: NetworkGeneration.label(band?.networkType ?? info?.networkType),
                         color: Theme.accent)

                    if bandName != "--" {
                        Pill(text: bandName, color: Theme.purple)
                    }

                    Spacer(minLength: 4)

                    SignalBars(level: signalLevel,
                               color: Quality.rsrp(band?.rsrp).color)
                }

                signedRow

                HStack(spacing: 0) {
                    miniStat(title: "工作频段", value: bandName)
                    miniDivider
                    miniStat(title: "PCI", value: Fmt.intOrDash(band?.pci))
                    miniDivider
                    miniStat(title: "ARFCN", value: Fmt.intOrDash(band?.arfcn))
                }
            }
        }
    }

    /// 签约状态条：QCI + 签约上/下行速率
    private var signedRow: some View {
        HStack(spacing: 8) {
            Text("签约状态:")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 3) {
                Text("QCI:")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text(Fmt.intOrDash(info?.qci))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            Spacer(minLength: 4)

            Pill(text: "\(Fmt.signedMbps(info?.downlinkRate))Mbps",
                 color: Theme.accent, systemImage: "arrow.down")
            Pill(text: "\(Fmt.signedMbps(info?.uplinkRate))Mbps",
                 color: Theme.purple, systemImage: "arrow.up")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panelSoft)
        )
    }

    private func miniStat(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var miniDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 0.5, height: 22)
    }
}

// MARK: - 2. 无线信号质量

/// 参考图里 RSRP / SINR / RSRQ 三列并排的写法。
struct SignalPanel: View {
    let band: BandData?

    var body: some View {
        CardBox {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    MetricColumn(
                        label: "RSRP",
                        value: band?.rsrp.map { String(format: "%.0f dBm", $0) } ?? "--",
                        quality: Quality.rsrp(band?.rsrp),
                        fraction: Quality.fraction(rsrp: band?.rsrp)
                    )
                    MetricColumn(
                        label: "SINR",
                        value: band?.sinr.map { String(format: "%.1f dB", $0) } ?? "--",
                        quality: Quality.sinr(band?.sinr),
                        fraction: Quality.fraction(sinr: band?.sinr)
                    )
                    MetricColumn(
                        label: "RSRQ",
                        value: band?.rsrq.map { String(format: "%.0f dB", $0) } ?? "--",
                        quality: Quality.rsrq(band?.rsrq),
                        fraction: Quality.fraction(rsrq: band?.rsrq)
                    )
                }
            }
        }
    }
}

// MARK: - 3. 实时网速

/// 两张并排的速率卡：圆形箭头图标 + 大数值 + 底部波形。
struct SpeedPanel: View {
    let download: Double
    let upload: Double
    let downTrend: [Double]
    let upTrend: [Double]
    let interfaceName: String?
    /// 网卡监听刚启动、还没有采样点
    var warmingUp: Bool = false

    private var sharedMax: Double {
        max(downTrend.max() ?? 0, upTrend.max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: Theme.cardSpacing) {
                SpeedCard(title: "实时下载",
                          systemName: "arrow.down",
                          color: Theme.down,
                          bytesPerSecond: download,
                          samples: downTrend,
                          sharedMax: sharedMax,
                          warmingUp: warmingUp)

                SpeedCard(title: "实时上传",
                          systemName: "arrow.up",
                          color: Theme.up,
                          bytesPerSecond: upload,
                          samples: upTrend,
                          sharedMax: sharedMax,
                          warmingUp: warmingUp)
            }

            HStack(spacing: 4) {
                Text("采样")
                Text(interfaceName ?? "--")
                    .foregroundStyle(Theme.textSecondary)
                if warmingUp {
                    Text("· 正在采样…")
                        .foregroundStyle(Theme.down)
                }
                Spacer(minLength: 0)
                Text("近 \(downTrend.count) 次 · 双卡同轴")
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 4)
        }
    }
}

/// 单张速率卡
struct SpeedCard: View {
    let title: String
    let systemName: String
    let color: Color
    let bytesPerSecond: Double
    let samples: [Double]
    let sharedMax: Double
    var warmingUp: Bool = false

    private var parts: (value: String, unit: String) {
        let text = Fmt.rate(bytesPerSecond)
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[text.startIndex..<space]),
                String(text[text.index(after: space)...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                GlyphCircle(systemName: systemName, color: color, size: 24)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if warmingUp {
                    Text("采样中…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text(parts.value)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(parts.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 26, alignment: .leading)

            Sparkline(samples: samples, color: color, sharedMax: sharedMax)
                .frame(height: 30)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: - 4. 流量统计

struct TrafficPanel: View {
    @ObservedObject var engine: MonitorEngine

    private var usedText: String {
        if let used = engine.monthlyUsedBytes { return Fmt.bytes(used) }
        return engine.monthlyFallbackText ?? "--"
    }

    /// 参考图是「不限」；有套餐上限时显示总量
    private var quotaText: String {
        guard !engine.isUnlimitedPlan, engine.quotaBytes > 0 else { return "不限" }
        return Fmt.bytes(engine.quotaBytes)
    }

    private var barColor: Color {
        guard !engine.isUnlimitedPlan else { return Theme.accent }
        let ratio = engine.monthlyProgress
        if ratio > 0.9 { return Theme.levelPoor }
        if ratio > 0.7 { return Theme.levelFair }
        return Theme.accent
    }

    var body: some View {
        CardBox(title: "套餐流量", systemImage: "chart.bar.fill", iconColor: Theme.accent) {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("剩余:")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text(quotaText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer(minLength: 8)

                    // 有套餐上限时才显示「已用 / 总量」对照；不限量时已用无意义，
                    // 且与下方「设备总流量」同源，重复显示反而不清爽。
                    if !engine.isUnlimitedPlan, engine.quotaBytes > 0 {
                        Text("已用:")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Text(usedText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("/ \(quotaText)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                MeterBar(fraction: engine.isUnlimitedPlan ? 1 : engine.monthlyProgress,
                         color: barColor,
                         height: 5)

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)

                HStack(spacing: 0) {
                    dayColumn(
                        icon: "sun.max.fill",
                        iconColor: Theme.orange,
                        title: "当日流量",
                        value: Fmt.bytes(engine.snapshot.dailyBytes),
                        note: engine.snapshot.dailyLabel.map { "归属 \($0)" }
                    )

                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 0.5, height: 34)

                    dayColumn(
                        icon: "calendar",
                        iconColor: Theme.purple,
                        title: "设备总流量",
                        value: engine.snapshot.trafficTotal?.total ?? "--",
                        note: nil,
                        alignment: .leading
                    )
                }
            }
        }
    }

    private func dayColumn(icon: String, iconColor: Color, title: String,
                           value: String, note: String?,
                           alignment: HorizontalAlignment = .leading) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: alignment, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconColor)
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    if let note {
                        Text("(\(note))")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.levelFair)
                    }
                }
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, alignment == .leading ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 5. 设备硬件状态

/// 2×2 小格子：CPU / 内存 / 温度 / 运行时长
struct HardwarePanel: View {
    let info: DeviceInfo?

    var body: some View {
        VStack(spacing: Theme.cardSpacing) {
            HStack(spacing: Theme.cardSpacing) {
                StatTile(
                    label: "CPU 占用率",
                    value: Fmt.percent(info?.cpuUsage),
                    valueColor: Quality.load(info?.cpuUsage).color,
                    fraction: min(1, max(0, (info?.cpuUsage ?? 0) / 100)),
                    barColor: Quality.load(info?.cpuUsage).color
                )
                StatTile(
                    label: "内存 占用率",
                    value: memoryText,
                    valueColor: Quality.load(info?.memoryUsagePercent).color,
                    fraction: min(1, max(0, (info?.memoryUsagePercent ?? 0) / 100)),
                    barColor: Quality.load(info?.memoryUsagePercent).color
                )
            }

            HStack(spacing: Theme.cardSpacing) {
                StatTile(
                    label: "芯片温度",
                    value: Fmt.temp(info?.thermalTemp),
                    valueColor: Quality.temperature(info?.thermalTemp).color,
                    systemImage: "thermometer.medium",
                    iconColor: Theme.orange,
                    fraction: nil
                )
                StatTile(
                    label: "运行时长",
                    value: Fmt.uptime(info?.uptime),
                    valueColor: Theme.textPrimary,
                    systemImage: "clock",
                    iconColor: Theme.purple,
                    fraction: nil
                )
            }
        }
    }

    private var memoryText: String {
        guard let percent = info?.memoryUsagePercent else { return "--" }
        return String(format: "%.1f%%", percent)
    }
}
