#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
droidbridge — 把一台安卓设备（真机 / AVD 模拟器）变成 iPhone 可以遥控的「安卓运行时」。

用法（Windows / macOS / Linux 都一样，只要有 python3 和 adb）：

    # 真机或 AVD，自动挑第一台设备
    python droidbridge.py

    # 指定设备 + 端口 + 访问码
    python droidbridge.py --serial emulator-5554 --port 8770 --code 1234

    # 没有安卓设备时，先跑 mock 看链路是否通
    python droidbridge.py --mock

iPhone 端填： ws://<这台电脑的局域网 IP>:8770/ws

协议：
    HTTP  GET  /status          → {"ok":true,...}
    HTTP  GET  /screen.png      → 最近一帧
    HTTP  POST /install         → 直接上传 APK 安装（X-Package / X-Activity 头可选）
    WS    /ws                   → 二进制 = PNG 画面帧；文本 = JSON 控制指令
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import math
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

CONFIG = {
    "adb": "adb",
    "serial": "",
    "fps": 4.0,
    "mock": False,
    "code": "",
    "verbose": False,
}

STATE = {
    "clients": [],
    "last_frame": None,
    "width": 0,
    "height": 0,
    "serial": "mock",
    "frame_count": 0,
    "lock": threading.Lock(),
    "mock_start": time.time(),
}


def log(*args):
    print(time.strftime("[%H:%M:%S]"), *args, flush=True)


def vlog(*args):
    if CONFIG["verbose"]:
        log(*args)


# --------------------------------------------------------------------------- adb


def adb_base():
    cmd = [CONFIG["adb"]]
    if CONFIG["serial"]:
        cmd += ["-s", CONFIG["serial"]]
    return cmd


def adb_run(args, timeout=15, binary=False):
    cmd = adb_base() + args
    try:
        completed = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except FileNotFoundError:
        raise RuntimeError("找不到 adb，请安装 Android platform-tools 并确保 adb 在 PATH 里")
    except subprocess.TimeoutExpired:
        raise RuntimeError("adb 超时: %s" % " ".join(args))
    if binary:
        return completed.stdout
    return (
        completed.stdout.decode("utf-8", "replace").strip(),
        completed.stderr.decode("utf-8", "replace").strip(),
        completed.returncode,
    )


def detect_serial():
    out, err, code = adb_run(["devices"])
    if code != 0:
        raise RuntimeError("adb devices 失败: %s" % err)
    devices = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            devices.append(parts[0])
    if not devices:
        raise RuntimeError("没有处于 device 状态的安卓设备，先 adb connect 或启动 AVD")
    return devices[0]


def png_size(data):
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return (0, 0)
    return struct.unpack(">II", data[16:24])


# --------------------------------------------------------------------- mock 画面


def png_bytes(width, height, rows):
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


def mock_frame(t):
    width, height = 270, 480
    cx = width / 2 + 90 * math.sin(t * 1.4)
    cy = height / 2 + 130 * math.cos(t * 1.1)
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            r = 12 + int(28 * (x / width))
            g = 20 + int(46 * (y / height))
            b = 26 + int(18 * (0.5 + 0.5 * math.sin(t)))
            if abs(x - cx) < 46 and abs(y - cy) < 46:
                r, g, b = 60, 220, 140
            elif y < 52:
                r, g, b = 24, 26, 30
            row += bytes((r, g, b))
        rows.append(bytes(row))
    return png_bytes(width, height, rows)


# ------------------------------------------------------------------- WebSocket


def build_frame(opcode, payload):
    header = bytearray()
    header.append(0x80 | opcode)
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < (1 << 16):
        header.append(126)
        header += struct.pack(">H", length)
    else:
        header.append(127)
        header += struct.pack(">Q", length)
    return bytes(header) + payload


class WSClient:
    def __init__(self, conn, address, code):
        self.conn = conn
        self.address = address
        self.code = code
        self.alive = True
        self.lock = threading.Lock()
        self.sent_frames = 0

    def _send(self, opcode, payload):
        if not self.alive:
            return False
        try:
            with self.lock:
                self.conn.sendall(build_frame(opcode, payload))
            return True
        except Exception:
            self.alive = False
            return False

    def send_text(self, text):
        return self._send(0x1, text.encode("utf-8"))

    def send_json(self, obj):
        return self.send_text(json.dumps(obj, ensure_ascii=False))

    def send_binary(self, payload):
        self.sent_frames += 1
        return self._send(0x2, payload)


def read_exact(rfile, count):
    buffer = b""
    while len(buffer) < count:
        chunk = rfile.read(count - len(buffer))
        if not chunk:
            return None
        buffer += chunk
    return buffer


def read_ws_message(rfile):
    header = read_exact(rfile, 2)
    if not header or len(header) < 2:
        return None
    b1, b2 = header[0], header[1]
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        raw = read_exact(rfile, 2)
        if raw is None:
            return None
        length = struct.unpack(">H", raw)[0]
    elif length == 127:
        raw = read_exact(rfile, 8)
        if raw is None:
            return None
        length = struct.unpack(">Q", raw)[0]
    mask = b"\x00\x00\x00\x00"
    if masked:
        mask = read_exact(rfile, 4)
        if mask is None:
            return None
    payload = read_exact(rfile, length) if length else b""
    if payload is None:
        return None
    if masked:
        payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    return opcode, payload


# ------------------------------------------------------------------ 画面采集线程


def capture_loop():
    while True:
        started = time.time()
        frame = None
        try:
            if CONFIG["mock"]:
                frame = mock_frame(time.time() - STATE["mock_start"])
            else:
                frame = adb_run(["exec-out", "screencap", "-p"], timeout=8, binary=True)
                if not frame or len(frame) < 64 or frame[:8] != b"\x89PNG\r\n\x1a\n":
                    frame = None
        except Exception as exc:
            vlog("截图失败:", exc)
            frame = None

        if frame:
            width, height = png_size(frame)
            with STATE["lock"]:
                STATE["last_frame"] = frame
                STATE["width"] = width
                STATE["height"] = height
                STATE["frame_count"] += 1
                clients = list(STATE["clients"])
            for client in clients:
                if not client.send_binary(frame):
                    drop_client(client)

        elapsed = time.time() - started
        delay = max(0.02, (1.0 / max(CONFIG["fps"], 0.5)) - elapsed)
        time.sleep(delay)


def drop_client(client):
    client.alive = False
    with STATE["lock"]:
        if client in STATE["clients"]:
            STATE["clients"].remove(client)


# ------------------------------------------------------------------- 控制指令


def screen_dims():
    with STATE["lock"]:
        return STATE["width"], STATE["height"]


def to_pixels(nx, ny):
    width, height = screen_dims()
    if width <= 0 or height <= 0:
        width, height = 1080, 1920
    x = int(max(0.0, min(1.0, float(nx))) * (width - 1))
    y = int(max(0.0, min(1.0, float(ny))) * (height - 1))
    return x, y


KEY_MAP = {
    "BACK": "KEYCODE_BACK",
    "HOME": "KEYCODE_HOME",
    "APP_SWITCH": "KEYCODE_APP_SWITCH",
    "MENU": "KEYCODE_MENU",
    "POWER": "KEYCODE_POWER",
    "VOLUME_UP": "KEYCODE_VOLUME_UP",
    "VOLUME_DOWN": "KEYCODE_VOLUME_DOWN",
    "ENTER": "KEYCODE_ENTER",
    "DEL": "KEYCODE_DEL",
}


def handle_command(client, message):
    kind = message.get("t", "")

    if kind == "ping":
        client.send_json({"t": "pong"})
        return

    if kind == "hello":
        incoming = message.get("code", "")
        if CONFIG["code"] and incoming != CONFIG["code"]:
            client.send_json({"t": "error", "v": "访问码不对"})
            drop_client(client)
            return
        width, height = screen_dims()
        client.send_json({
            "t": "meta",
            "w": width,
            "h": height,
            "serial": STATE["serial"],
            "mock": CONFIG["mock"],
            "fps": CONFIG["fps"],
        })
        return

    if kind == "frame":
        with STATE["lock"]:
            frame = STATE["last_frame"]
        if frame:
            client.send_binary(frame)
        return

    if CONFIG["mock"]:
        if kind == "tap":
            x, y = to_pixels(message.get("x", 0.5), message.get("y", 0.5))
            log("mock tap ->", x, y)
            client.send_json({"t": "ok", "v": "tap %d,%d (mock)" % (x, y)})
        else:
            client.send_json({"t": "ok", "v": "%s (mock 模式不执行)" % kind})
        return

    try:
        if kind == "tap":
            x, y = to_pixels(message.get("x", 0.5), message.get("y", 0.5))
            adb_run(["shell", "input", "tap", str(x), str(y)])
            client.send_json({"t": "ok", "v": "tap %d,%d" % (x, y)})

        elif kind == "swipe":
            x1, y1 = to_pixels(message.get("x1", 0.5), message.get("y1", 0.5))
            x2, y2 = to_pixels(message.get("x2", 0.5), message.get("y2", 0.5))
            duration = int(message.get("ms", 180))
            adb_run(["shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(duration)])
            client.send_json({"t": "ok", "v": "swipe %d,%d -> %d,%d" % (x1, y1, x2, y2)})

        elif kind == "key":
            code = KEY_MAP.get(str(message.get("v", "")), str(message.get("v", "")))
            adb_run(["shell", "input", "keyevent", code])
            client.send_json({"t": "ok", "v": "key " + code})

        elif kind == "text":
            text = str(message.get("v", ""))
            escaped = text.replace(" ", "%s").replace("'", "")
            adb_run(["shell", "input", "text", escaped])
            client.send_json({"t": "ok", "v": "text ok"})

        elif kind == "launch":
            package = str(message.get("package", ""))
            activity = str(message.get("activity", ""))
            output = launch_app(package, activity)
            client.send_json({"t": "ok", "v": output})

        elif kind == "install":
            path = str(message.get("path", ""))
            output = install_apk(path)
            client.send_json({"t": "ok", "v": output})

        else:
            client.send_json({"t": "error", "v": "未知指令 " + kind})

    except Exception as exc:
        client.send_json({"t": "error", "v": str(exc)})


def launch_app(package, activity):
    if not package:
        raise RuntimeError("缺少包名")
    if activity and not activity.startswith("."):
        component = "%s/%s" % (package, activity)
        out, err, code = adb_run(["shell", "am", "start", "-n", component])
        if code == 0 and "Error" not in out:
            return "am start %s" % component
    elif activity.startswith("."):
        component = "%s/%s" % (package, activity)
        out, err, code = adb_run(["shell", "am", "start", "-n", component])
        if code == 0 and "Error" not in out:
            return "am start %s" % component

    out, err, code = adb_run([
        "shell", "monkey", "-p", package,
        "-c", "android.intent.category.LAUNCHER", "1",
    ])
    if "No activities found" in out or code != 0:
        raise RuntimeError("启动失败：%s %s" % (out, err))
    return "monkey -p %s" % package


def install_apk(path):
    if not os.path.exists(path):
        raise RuntimeError("文件不存在: " + path)
    out, err, code = adb_run(["install", "-r", "-d", path], timeout=300)
    if code != 0 or "Success" not in out:
        raise RuntimeError("安装失败: %s %s" % (out, err))
    return "installed " + os.path.basename(path)


# ------------------------------------------------------------------ HTTP 服务


class Handler(BaseHTTPRequestHandler):
    server_version = "droidbridge/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        vlog("http:", fmt % args)

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]

        if path in ("/", "/status"):
            with STATE["lock"]:
                clients = len(STATE["clients"])
                frames = STATE["frame_count"]
                width = STATE["width"]
                height = STATE["height"]
            self._json({
                "ok": True,
                "service": "droidbridge",
                "mock": CONFIG["mock"],
                "serial": STATE["serial"],
                "adb": CONFIG["adb"],
                "clients": clients,
                "frames": frames,
                "screen": [width, height],
                "fps_target": CONFIG["fps"],
            })
            return

        if path == "/screen.png":
            with STATE["lock"]:
                frame = STATE["last_frame"]
            if not frame:
                self._json({"ok": False, "error": "还没有画面"}, 503)
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(frame)))
            self.end_headers()
            self.wfile.write(frame)
            return

        if path == "/ws" and "websocket" in self.headers.get("Upgrade", "").lower():
            self.handle_websocket()
            return

        self._json({"ok": False, "error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]
        if path != "/install":
            self._json({"ok": False, "error": "not found"}, 404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0:
                self._json({"ok": False, "error": "空上传"}, 400)
                return
            package = self.headers.get("X-Package", "")
            activity = self.headers.get("X-Activity", "")
            handle, temp_path = tempfile.mkstemp(prefix="droidbox-", suffix=".apk")
            os.close(handle)
            remaining = length
            with open(temp_path, "wb") as sink:
                while remaining > 0:
                    chunk = self.rfile.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    sink.write(chunk)
                    remaining -= len(chunk)
            log("收到 APK %.1f MB -> %s" % (length / 1048576.0, temp_path))

            if CONFIG["mock"]:
                self._json({"ok": True, "log": "mock 模式：已接收 %d 字节" % length,
                            "package": package})
                return

            result = install_apk(temp_path)
            launched = ""
            if package:
                try:
                    launched = launch_app(package, activity)
                except Exception as exc:
                    launched = "启动失败: %s" % exc
            self._json({"ok": True, "log": result, "launch": launched, "package": package})
        except Exception as exc:
            self._json({"ok": False, "error": str(exc)}, 500)

    def handle_websocket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        if not key:
            self._json({"ok": False, "error": "bad websocket handshake"}, 400)
            return
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()

        client = WSClient(self.connection, self.client_address, CONFIG["code"])
        with STATE["lock"]:
            STATE["clients"].append(client)
        log("客户端接入:", self.client_address)

        width, height = screen_dims()
        client.send_json({
            "t": "meta",
            "w": width,
            "h": height,
            "serial": STATE["serial"],
            "mock": CONFIG["mock"],
            "fps": CONFIG["fps"],
        })

        self.close_connection = True
        try:
            while client.alive:
                message = read_ws_message(self.rfile)
                if message is None:
                    break
                opcode, payload = message
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    client._send(0xA, payload)
                    continue
                if opcode != 0x1:
                    continue
                try:
                    command = json.loads(payload.decode("utf-8"))
                except Exception:
                    continue
                handle_command(client, command)
        except Exception as exc:
            vlog("ws 断开:", exc)
        finally:
            drop_client(client)
            log("客户端断开:", self.client_address)


# ------------------------------------------------------------------------ main


def local_addresses():
    addresses = set()
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.settimeout(0.5)
        probe.connect(("8.8.8.8", 80))
        addresses.add(probe.getsockname()[0])
        probe.close()
    except Exception:
        pass
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            addresses.add(info[4][0])
    except Exception:
        pass
    return [address for address in addresses if not address.startswith("127.")]


def main():
    parser = argparse.ArgumentParser(description="安卓运行时桥（画面 + 触摸 + APK 安装）")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址")
    parser.add_argument("--port", type=int, default=8770, help="监听端口")
    parser.add_argument("--adb", default="adb", help="adb 可执行文件路径")
    parser.add_argument("--serial", default="", help="指定设备序列号，留空自动挑第一台")
    parser.add_argument("--fps", type=float, default=4.0, help="目标帧率，默认 4")
    parser.add_argument("--code", default="", help="访问码，填了之后客户端必须对得上")
    parser.add_argument("--mock", action="store_true", help="不出图（假画面），用来验证链路")
    parser.add_argument("--verbose", action="store_true", help="打印更多日志")
    args = parser.parse_args()

    CONFIG.update({
        "adb": args.adb,
        "serial": args.serial,
        "fps": max(0.5, args.fps),
        "mock": args.mock,
        "code": args.code,
        "verbose": args.verbose,
    })

    if CONFIG["mock"]:
        STATE["serial"] = "mock"
        with STATE["lock"]:
            STATE["width"], STATE["height"] = 270, 480
    else:
        try:
            if not CONFIG["serial"]:
                CONFIG["serial"] = detect_serial()
            STATE["serial"] = CONFIG["serial"]
            out, err, code = adb_run(["shell", "wm", "size"])
            log("设备:", CONFIG["serial"], "|", out.strip() or err.strip())
        except Exception as exc:
            log("!! 设备检查失败:", exc)
            log("!! 可以先用 --mock 验证链路，或在装好 adb/设备后重启本脚本")
            sys.exit(2)

    threading.Thread(target=capture_loop, daemon=True).start()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    log("droidbridge 已启动  监听 %s:%d  fps=%.1f  mock=%s" % (
        args.host, args.port, CONFIG["fps"], CONFIG["mock"]))
    for address in local_addresses():
        log("iPhone 里填:  ws://%s:%d/ws" % (address, args.port))
    if CONFIG["code"]:
        log("访问码:", CONFIG["code"])
    log("健康检查:   http://127.0.0.1:%d/status" % args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("退出")


if __name__ == "__main__":
    main()
