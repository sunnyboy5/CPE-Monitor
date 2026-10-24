#!/usr/bin/env python3
"""
project-cpe 固件协议仿真服务。

字段名与返回结构照抄 https://github.com/1orz/project-cpe 的
backend/src/handlers.rs + backend/src/utils.rs：

  * 所有业务接口都包一层 {"status","message","data"}；
  * 出错时 HTTP 仍是 200，只有 status == "error"；
  * 信号类字段（rsrp/rsrq/sinr）是 **原始值 ×100 的字符串**；
  * 频段带前缀且小写（NR 是 "n78"，LTE 是 "B3"）；
  * /api/stats 在服务端要同步采样 1 秒才算出速率，这里也 sleep 1s。

启动:  python3 mock_project_cpe.py [port]     默认 13000

然后：
  ./dist/CPE\\ Monitor.app/Contents/MacOS/CPEMonitor \\
      --selftest --backend projectCPE --host 127.0.0.1 --port 13000
"""
import json
import math
import random
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.time()

BASE_RX = 41_800_000_000
BASE_TX = 3_200_000_000

INTERFACES = ["lo", "wwan0", "eth0"]
# 累计字节必须按「速率 × 实际经过时间」积分，不能拿速率乘秒数再叠加，
# 否则每次采样都会把基数放大一截，前端算 delta 会得到几十 GB 的假增量。
ACC = {"rx": BASE_RX, "tx": BASE_TX, "last": None}

STATE = {"rebooted": False}


def ok(data, message="Success"):
    return {"status": "ok", "message": message, "data": data}


def err(message):
    return {"status": "error", "message": message, "data": None}


def device_payload():
    return {
        "imei": "868267066364452",
        "manufacturer": "UNISOC",
        "model": "UDX710",
        "revision": "project-cpe-1.2.0",
        "online": True,
        "powered": True,
    }


def sim_payload():
    return {
        "present": True,
        "iccid": "89860600123456789012",
        "imsi": "460001234567890",
        "phone_numbers": ["+8613800000000"],
        "sms_center": "+8613800000500",
        "mcc": "460",
        "mnc": "00",
        "pin_required": "none",
        "preferred_languages": ["zh"],
    }


def network_payload(tick):
    return {
        "operator_name": "中国移动",
        "registration_status": "registered",
        "technology_preference": "nr",
        "signal_strength": int(72 + 6 * math.sin(tick / 13.0)),
        "mcc": "460",
        "mnc": "00",
    }


def qos_payload():
    # AT+CGEQOSRDP：GBR/MBR/AMBR，单位 kbps
    return {"qci": 9, "dl_speed": 1073000, "ul_speed": 104000}


def cells_payload(tick):
    a = math.sin(tick / 11.0)
    b = math.cos(tick / 7.0)
    # rsrp/rsrq/sinr 都是 ×100 的字符串，直接照真机格式给
    serving = {
        "is_serving": True,
        "tech": "nr",
        "band": "n41",
        "pci": "21",
        "arfcn": "504990",
        "rsrp": str(int(round((-75.7 - 5 * a) * 100))),
        "rsrq": str(int(round((-4.9 - 1.5 * b) * 100))),
        "sinr": str(int(round((15.1 + 4 * b) * 100))),
        "ssb_rsrp": None,
        "ssb_rsrq": None,
        "ssb_sinr": None,
    }
    neighbors = []
    for i, (pci, rsrp) in enumerate([(823, -69.8), (479, -77.0), (167, -81.0)]):
        neighbors.append({
            "is_serving": False,
            "tech": "nr",
            "band": "n41",
            "pci": str(pci),
            "arfcn": "504990",
            "rsrp": str(int(round(rsrp * 100))),
            "rsrq": "-380",
            "sinr": str(int(round((11.8 - i) * 100))),
        })
    return {
        "serving_cell": {"tech": "nr", "cell_id": 12345, "tac": 100},
        "cells": [serving] + neighbors,
    }


def stats_payload(tick):
    """服务端要采样 1 秒才算速率，这里真的 sleep 一次，跟真机一致。"""
    time.sleep(1.0)
    now = time.time() - START

    down = 4_200_000.0 + abs(math.sin(now / 5.0)) * 9_000_000
    up = 320_000 + abs(math.cos(now / 8.0)) * 900_000

    # 用真实经过时间积分累计字节，保持单调递增且增量合理
    if ACC["last"] is None:
        ACC["last"] = now
    dt = max(0.0, now - ACC["last"])
    ACC["rx"] += int(down * dt)
    ACC["tx"] += int(up * dt)
    ACC["last"] = now

    elapsed = 1.0
    interfaces = []
    for name in INTERFACES:
        if name == "lo":
            continue
        if name == "wwan0":
            interfaces.append({
                "interface": name,
                "rx_bytes_per_sec": int(down),
                "tx_bytes_per_sec": int(up),
                # 累计值单调递增，前端靠 delta 算当日流量
                "total_rx_bytes": ACC["rx"],
                "total_tx_bytes": ACC["tx"],
            })
        else:
            interfaces.append({
                "interface": name,
                "rx_bytes_per_sec": 12_000,
                "tx_bytes_per_sec": 4_000,
                "total_rx_bytes": 900_000_000,
                "total_tx_bytes": 120_000_000,
            })

    total_mem = 204_853_248
    available = 61_702_144
    return {
        "network_speed": {"interfaces": interfaces, "interval_seconds": elapsed},
        "memory": {
            "total_bytes": total_mem,
            "available_bytes": available,
            "used_bytes": total_mem - available,
            "used_percent": (total_mem - available) / total_mem * 100,
            "cached_bytes": 96 * 1024 * 1024,
            "buffers_bytes": 8 * 1024 * 1024,
        },
        "disk": [{
            "mount_point": "/",
            "fs_type": "ext4",
            "total_bytes": 4 * 1024 ** 3,
            "used_bytes": int(1.2 * 1024 ** 3),
            "available_bytes": int(2.8 * 1024 ** 3),
            "used_percent": 30.0,
        }],
        "cpu_load": {
            "load_1min": 0.42,
            "load_5min": 0.38,
            "load_15min": 0.31,
            "core_count": 4,
            "load_percent": round(24.6 + 9 * math.sin(tick / 9.0), 2),
        },
        "uptime": {
            "uptime_seconds": 372_400 + now,
            "idle_seconds": 300_000,
            "uptime_formatted": "4 天 7 小时",
        },
        "system_info": {
            "sysname": "Linux",
            "nodename": "UDX710-CPE",
            "release": "4.14.98",
            "version": "#1 SMP PREEMPT",
            "machine": "aarch64",
            "full_info": "Linux UDX710-CPE 4.14.98 aarch64",
        },
        # 后端已经把毫摄氏度除以 1000，这里直接给摄氏度
        "temperature": [
            {"zone": "thermal_zone0", "type": "soc-thmzone", "temperature": round(46.2 + 1.6 * math.sin(tick / 9.0), 1)},
            {"zone": "thermal_zone1", "type": "pa-thmzone", "temperature": 38.5},
            {"zone": "thermal_zone2", "type": "nrcp-thmzone", "temperature": 44.0},
        ],
        "usb_mode": {
            "current_mode": 3,
            "current_mode_name": "NCM",
            "permanent_mode": 3,
            "temporary_mode": None,
            "needs_reboot": False,
            "read_mode": "hardware",
        },
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, payload, code=200):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        tick = int(time.time() - START)
        print(f"[REQ] GET  {path}", flush=True)

        if path == "/api/health":
            # 注意：health 不走 data 包装
            return self._send({"status": "ok", "message": "Service is running",
                               "version": "1.2.0"})
        if path == "/api/device":
            return self._send(ok(device_payload()))
        if path == "/api/sim":
            return self._send(ok(sim_payload()))
        if path == "/api/network":
            return self._send(ok(network_payload(tick)))
        if path == "/api/qos":
            return self._send(ok(qos_payload()))
        if path == "/api/cells":
            return self._send(ok(cells_payload(tick)))
        if path == "/api/stats":
            return self._send(ok(stats_payload(tick)))

        return self._send(err(f"未知路径 {path}"))

    def do_POST(self):
        path = self.path.split("?")[0]
        print(f"[REQ] POST {path}", flush=True)

        if path == "/api/system/reboot":
            STATE["rebooted"] = True
            return self._send(ok(None, "Rebooting"))
        return self._send(err(f"未知路径 {path}"))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 13000
    print(f"project-cpe 仿真服务已启动: http://127.0.0.1:{port}")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
