#!/usr/bin/env python3
"""
UDX710-TOOLS 协议仿真服务。

字段名与返回结构严格照抄 src/handlers/handlers.c 与 src/system/netif.c、traffic.c，
用于在没有真机的情况下验证 CPE Monitor 的解析链路。

启动:  python3 mock_server.py [port]     默认 16677
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.time()
TOKEN = "mock-token-8f2a41c9"
PASSWORD = "admin"
MONITORED: set[str] = set()

# 可变状态。clear_cache 之后 cached_ram 必须能看到下降、set/total 无参调用之后
# total 必须归零，否则这两个接口在仿真环境下验证不出任何东西。
STATE = {"cached_ram_mb": 96, "vnstat_total": "41.902 GB"}


def info_payload(tick: int) -> dict:
    wave = __import__("math").sin(tick / 9.0)
    return {
        "hostname": "UDX710-CPE",
        "sysname": "Linux",
        "release": "5.10.110",
        "version": "#1 SMP PREEMPT",
        "machine": "aarch64",
        # RAM 三个字段真机返回的是 MB（sysinfo.c 把 /proc/meminfo 的 kB 除以 1024），
        # 不是字节。早期这里写成字节，会让演示/联调时的内存占用显示全部对不上。
        "total_ram": 512,
        "free_ram": int(512 * (0.42 + 0.05 * wave)),
        "cached_ram": STATE["cached_ram_mb"],
        "cpu_usage": round(24.6 + 9 * wave, 2),
        "uptime": 372400.0 + tick * 2,
        "bridge_status": "connected",
        "sim_slot": "1",
        "signal_strength": "78",
        "thermal_temp": round(46.2 + 1.6 * wave, 2),
        "power_status": "charging",
        "battery_health": "good",
        "battery_capacity": 86,
        "ssid": "CPE-5G-8F2A",
        "passwd": "12345678",
        "select_network_mode": "auto",
        "is_activated": 1,
        "serial": "SN20260812A0091",
        "network_mode": "5G",
        "airplane_mode": False,
        "imei": "867962051234567",
        "iccid": "89860600123456789012",
        "imsi": "460001234567890",
        "carrier": "中国移动",
        "network_type": "5G NR",
        "network_band": "N78",
        "qci": 6,
        # 真机是 kbps（实测 1000000 / 200000，对应 1000 / 200 Mbps），
        # Fmt.signedMbps 会按 kbps 换算，这里别写 Mbps。
        "downlink_rate": 1000000,
        "uplink_rate": 200000,
    }


def band_payload(tick: int) -> dict:
    math = __import__("math")
    a = math.sin(tick / 11.0)
    b = math.cos(tick / 7.0)
    return {
        "Code": 0,
        "Error": "",
        "Data": {
            "network_type": "5G NR",
            "band": "78",
            "arfcn": 633984,
            "pci": 431,
            "rsrp": round(-78.0 - 5 * a, 2),
            "rsrq": round(-11.0 - 1.5 * b, 2),
            "sinr": round(22.5 + 4 * b, 2),
        },
    }


def netif_list() -> dict:
    return {
        "interfaces": [
            {"name": "lo", "hwaddr": "00:00:00:00:00:00", "inet_addr": "127.0.0.1",
             "inet6_addr": "::1", "mask": "255.0.0.0", "is_up": True, "monitoring": False},
            {"name": "sipa_eth0", "hwaddr": "A2:9C:41:0F:8B:22", "inet_addr": "192.168.42.129",
             "inet6_addr": "fe80::a09c:41ff:fe0f:8b22", "mask": "255.255.255.0",
             "is_up": True, "monitoring": "sipa_eth0" in MONITORED},
            {"name": "wlan0", "hwaddr": "B4:0F:3B:7A:11:05", "inet_addr": "192.168.43.1",
             "inet6_addr": "", "mask": "255.255.255.0", "is_up": True, "monitoring": False},
        ]
    }


def stats_payload() -> dict:
    math = __import__("math")
    t = time.time() - START
    down = 4_200_000.0 + abs(math.sin(t / 5.0)) * 9_000_000
    up = 320_000 + abs(math.cos(t / 8.0)) * 900_000
    return {
        "index": 3,
        "seconds": 5,
        "rx": {"ratestring": f"{down/1048576:.2f} MiB/s",
               "bytespersecond": int(down), "packetspersecond": 812,
               "bytes": 41943040, "packets": 30412,
               "totalbytes": 41800000000, "totalpackets": 31200000},
        "tx": {"ratestring": f"{up/1024:.2f} KiB/s",
               "bytespersecond": int(up), "packetspersecond": 96,
               "bytes": 3145728, "packets": 12044,
               "totalbytes": 3200000000, "totalpackets": 4100000},
    }


def vnstat_output() -> str:
    month = 45_200_000_000
    day = 1_330_000_000
    return json.dumps({
        "vnstatversion": "2.11",
        "jsonversion": "1",
        "interfaces": [{
            "name": "sipa_eth0",
            "traffic": {
                "month": [
                    {"date": {"year": 2026, "month": 8}, "rx": 9000000000, "tx": 400000000},
                    {"date": {"year": 2026, "month": 9}, "rx": month - 400000000, "tx": 400000000},
                ],
                "day": [
                    {"date": {"year": 2026, "month": 9, "day": 11}, "rx": 800000000, "tx": 40000000},
                    {"date": {"year": 2026, "month": 9, "day": 12}, "rx": day - 40000000, "tx": 40000000},
                ],
            },
        }],
    })


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _log(self, method: str, path: str, body=None) -> None:
        """每个请求打一行：核对 App 实际发出的方法、鉴权头与请求体。"""
        auth = "token" if self._authorized() else "-"
        note = json.dumps(body, ensure_ascii=False) if isinstance(body, dict) and body else ""
        print(f"[REQ] {method:<5} {path:<22} auth={auth:<6} {note}", flush=True)

    def _send(self, code: int, payload):
        body = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return {}

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {TOKEN}"

    def do_GET(self):
        tick = int(time.time() - START)
        path = self.path.split("?")[0]
        self._log("GET", path)

        # 免认证白名单
        if path == "/api/info":
            return self._send(200, info_payload(tick))
        if path == "/api/current_band":
            return self._send(200, band_payload(tick))
        if path == "/api/auth/status":
            return self._send(200, {"logged_in": self._authorized(), "auth_required": True})

        if not self._authorized():
            return self._send(401, {"status": "error", "message": "未授权，请先登录"})

        if path == "/api/netif/list":
            return self._send(200, netif_list())
        if path == "/api/netif/monitor":
            interfaces = [{"interface": n, "enabled": n in MONITORED}
                          for n in ("lo", "sipa_eth0", "wlan0")]
            return self._send(200, {"monitors": interfaces})
        if path == "/api/get/Total":
            return self._send(200, {"rx": "38.921 GB", "tx": "2.981 GB",
                                    "total": STATE["vnstat_total"]})
        if path == "/api/get/set":
            return self._send(200, {"much": 107374182400, "switch": 1})

        return self._send(404, {"status": "error", "message": f"未知路径 {path}"})

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._body()
        self._log("POST", path, body)

        if path == "/api/auth/login":
            if body.get("password") == PASSWORD:
                return self._send(200, {"status": "success", "message": "登录成功", "token": TOKEN})
            return self._send(401, {"status": "error", "message": "密码错误"})

        if not self._authorized():
            return self._send(401, {"status": "error", "message": "未授权，请先登录"})

        # 内核页缓存：对应设备端 exec_utils.c 的 sync + drop_caches
        if path == "/api/clear_cache":
            before = STATE["cached_ram_mb"]
            STATE["cached_ram_mb"] = 21
            print(f"       └ drop_caches: cached_ram {before} → {STATE['cached_ram_mb']} MB",
                  flush=True)
            return self._send(200, {"status": "success", "message": "Cache cleared successfully"})

        # 流量统计：带 switch/much 是设置上限；两个都没有才是「清空 vnstat 库」，
        # 对应设备端 traffic.c 里 rm -f vnstat.db + init_vnstat_db()
        if path == "/api/set/total":
            if "switch" not in body and "much" not in body:
                STATE["vnstat_total"] = "0.000 B"
                print("       └ 无参调用：设备端会删除并重建 vnstat.db，统计归零", flush=True)
                return self._send(200, {"success": True, "msg": "Clean ok"})
            return self._send(200, {"success": True, "msg": "added ok"})

        if path == "/api/netif/monitor":
            ifname = body.get("interface", "")
            if body.get("enabled"):
                MONITORED.add(ifname)
            else:
                MONITORED.discard(ifname)
            return self._send(200, {"status": "success", "interface": ifname,
                                    "enabled": ifname in MONITORED})

        if path == "/api/netif/stats":
            ifname = body.get("interface", "")
            if ifname not in MONITORED:
                return self._send(503, {"status": "error", "message": "监听未启动"})
            return self._send(200, stats_payload())

        if path == "/api/shell":
            cmd = body.get("command", "")
            if "vnstat" in cmd:
                return self._send(200, {"Code": 0, "Error": "", "Data": vnstat_output()})
            return self._send(200, {"Code": 0, "Error": "", "Data": ""})

        return self._send(404, {"status": "error", "message": f"未知路径 {path}"})

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 16677
    print(f"UDX710-TOOLS 仿真服务已启动: http://127.0.0.1:{port}")
    print(f"后台密码: {PASSWORD}")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
