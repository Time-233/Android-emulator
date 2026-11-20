# droidbridge

把一台安卓设备（真机 / Android Studio 里的 AVD 模拟器）变成 iPhone 可遥控的「安卓运行时」。
零第三方依赖：只要 `python3` + `adb`。

## 跑起来

```bash
# 1) 安卓一侧准备好
adb devices                       # 应该有 device 状态的一行
# 真机：设置 → 开发者选项 → 无线调试 → 配对（adb pair）→ adb connect <ip>:<port>
# 模拟器：直接 adb devices 就能看到 emulator-5554

# 2) 起桥
python droidbridge.py                      # 自动挑第一台设备，端口 8770
python droidbridge.py --serial emulator-5554 --fps 6
python droidbridge.py --code 1234           # 加访问码
python droidbridge.py --mock                # 没设备时验证链路

# Windows 双击 run-bridge.bat 也行，run-bridge.bat mock 是 mock 模式
```

启动后终端会打印形如：

```
droidbridge 已启动  监听 0.0.0.0:8770  fps=4.0  mock=False
iPhone 里填:  ws://192.168.1.10:8770/ws
```

把这个地址填进 App 的「设置 → 主机」。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/status` | 健康检查：设备、帧数、分辨率、客户端数 |
| GET | `/screen.png` | 最近一帧，浏览器里能直接看 |
| POST | `/install` | 请求体是 APK 原始字节；`X-Package` / `X-Activity` 头可选，安装完自动拉起 |
| WS | `/ws` | 二进制 = PNG 帧；文本 = JSON 指令 |

WebSocket 指令（App → 桥）：

```json
{"t":"hello","code":"1234"}
{"t":"tap","x":0.5,"y":0.5}                       // x/y 是 0~1 归一化
{"t":"swipe","x1":0.5,"y1":0.8,"x2":0.5,"y2":0.2,"ms":180}
{"t":"key","v":"BACK"}                            // BACK/HOME/APP_SWITCH/POWER/VOLUME_UP...
{"t":"text","v":"hello world"}
{"t":"launch","package":"com.example.app","activity":".MainActivity"}
{"t":"install","path":"/abs/path/app.apk"}
{"t":"frame"}                                     // 只要一帧
{"t":"ping"}
```

桥 → App：

```json
{"t":"meta","w":1080,"h":2400,"serial":"emulator-5554","mock":false,"fps":4.0}
{"t":"ok","v":"tap 540,1200"}
{"t":"error","v":"启动失败：..."}
```

## 为什么帧率只有几帧

安卓侧用的是 `adb exec-out screencap -p`，每次截图 100~400ms，这是 adb 的物理上限。
要 30fps 得走 `scrcpy` 的 H.264 流，那是下一步（见仓库 README 的路线图）。
日常点按、翻页、装 APK 调试，4fps 完全够用。
