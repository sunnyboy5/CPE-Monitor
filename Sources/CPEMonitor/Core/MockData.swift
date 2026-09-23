import Foundation

/// 离线演示数据。用于没有设备在手时预览界面，也可验证 UI 的边界情况。
enum MockData {

    static func info(tick: Int) -> DeviceInfo {
        let wave = sin(Double(tick) / 9.0)
        var d = DeviceInfo()
        d.hostname = "UDX710-CPE"
        d.sysname = "Linux"
        d.release = "5.10.110"
        d.version = "#1 SMP PREEMPT"
        d.machine = "aarch64"
        // RAM 三个字段单位是 MB，和真机 /api/info 保持一致
        // （sysinfo.c 把 /proc/meminfo 的 kB 除以了 1024）。
        // 早期这里写的是字节，会在演示模式里把 cached_ram 放大 1024 倍。
        d.totalRam = 512
        d.freeRam = 512 * (0.42 + 0.05 * wave)
        d.cachedRam = 96
        d.cpuUsage = 24.6 + 9 * wave
        d.uptime = 372_400 + Double(tick) * 2
        d.bridgeStatus = "connected"
        d.simSlot = "1"
        d.signalStrength = "78"
        d.thermalTemp = 46.2 + 1.6 * wave
        d.powerStatus = "charging"
        d.batteryHealth = "good"
        d.batteryCapacity = 86
        d.ssid = "CPE-5G-8F2A"
        d.selectNetworkMode = "auto"
        d.isActivated = 1
        d.serial = "SN20260812A0091"
        d.networkMode = "5G"
        d.airplaneMode = false
        d.imei = "867962051234567"
        d.iccid = "89860600123456789012"
        d.imsi = "460001234567890"
        d.carrier = "中国移动"
        d.networkType = "5G NR"
        d.networkBand = "N78"
        d.qci = 6
        d.downlinkRate = 1000
        d.uplinkRate = 200
        return d
    }

    static func band(tick: Int) -> BandData {
        let a = sin(Double(tick) / 11.0)
        let b = cos(Double(tick) / 7.0)
        var d = BandData()
        d.networkType = "5G NR"
        d.band = "78"
        d.arfcn = 633_984
        d.pci = 431
        d.rsrp = -78.0 - 5 * a
        d.rsrq = -11.0 - 1.5 * b
        d.sinr = 22.5 + 4 * b
        return d
    }

    static func stats(tick: Int) -> NetifStats {
        // 制造一段有起伏但不规律的波形，接近真实浏览/下载场景
        let base = 4_200_000.0
        let burst = abs(sin(Double(tick) / 5.0)) * 9_000_000
        let jitter = Double((tick * 7919) % 1000) / 1000.0 * 2_400_000
        let down = base + burst + jitter
        let up = 320_000 + abs(cos(Double(tick) / 8.0)) * 900_000

        var rx = NetifDirection()
        rx.bytespersecond = Int64(down)
        rx.totalbytes = 41_800_000_000
        var tx = NetifDirection()
        tx.bytespersecond = Int64(up)
        tx.totalbytes = 3_200_000_000

        var s = NetifStats()
        s.index = 3
        s.seconds = 5
        s.rx = rx
        s.tx = tx
        return s
    }

    static let trafficTotal = TrafficTotalResponse(
        rx: "38.921 GB",
        tx: "2.981 GB",
        total: "41.902 GB"
    )

    static let trafficConfig = TrafficConfigResponse(much: 100 * 1024 * 1024 * 1024, trafficSwitch: 1)

    static let interfaces: [NetifInfo] = [
        NetifInfo(name: "lo", hwaddr: "00:00:00:00:00:00", inetAddr: "127.0.0.1",
                  inet6Addr: "::1", mask: "255.0.0.0", isUp: true, monitoring: false),
        NetifInfo(name: "sipa_eth0", hwaddr: "A2:9C:41:0F:8B:22", inetAddr: "192.168.42.129",
                  inet6Addr: "fe80::a09c:41ff:fe0f:8b22", mask: "255.255.255.0",
                  isUp: true, monitoring: true),
        NetifInfo(name: "wlan0", hwaddr: "B4:0F:3B:7A:11:05", inetAddr: "192.168.43.1",
                  inet6Addr: nil, mask: "255.255.255.0", isUp: true, monitoring: false)
    ]
}
