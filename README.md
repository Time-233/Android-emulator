# 安卓模拟器 for iOS 16+ · DroidBox

一个 iOS 16+ 的 `.ipa`：GitHub Actions 直接编出未签名包，你用 **Sideloadly** 自己签。
App 里从「文件」导入 APK → 真解析包信息 → 推送到你的安卓运行时（PC 上的 AVD 或一台安卓真机）安装并启动 → 画面回传到 iPhone，触摸 / 滑动 / 按键实时回写。

---

## 0. 先说清楚一件事

iOS 非越狱环境里，第三方 App **拿不到 JIT**。没有 JIT，QEMU/ART 这类动态翻译就只能纯解释执行——
在 iPhone 上虚拟一台完整安卓，开机以十分钟计，点一下卡三秒，没有使用价值。这不是代码写得好不好的问题，是系统限制。

所以本工程走的是**唯一能真正用起来**的路：

```
┌──────────────┐   ws:// 画面+触摸   ┌────────────────────┐   adb    ┌──────────────┐
│  iPhone      │ ◄─────────────────► │  PC: droidbridge.py│ ◄──────► │ 安卓设备/AVD │
│  DroidBox.ipa│   HTTP 上传 APK     │  (Python, 零依赖)   │  install │              │
└──────────────┘                     └────────────────────┘          └──────────────┘
```

安卓跑在能跑的地方（电脑上的模拟器，或者一台安卓真机），iPhone 只做「屏幕 + 遥控器 + APK 仓库」。
你导入的 APK 会真的被推到那台安卓上装好、启动，App 里看到的就是它的真实画面。

> 如果你坚持要「iPhone 本机跑虚拟机」：只有 UTM SE + Android x86 + 侧载开 JIT 一条路，能开机但慢到只能当演示，见文末附录。

---

## 1. 能做什么

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 导入 APK | ✅ | Files / 文件 App 选择，或 AirDrop 到 App |
| APK 解析 | ✅ 纯本地 | 自写 ZIP + Android 二进制 XML 解析，零第三方依赖 |
| 包名 / 版本 / SDK / 权限 | ✅ | 从二进制 AndroidManifest.xml 直读 |
| 入口 Activity | ✅ | 解析 MAIN + LAUNCHER 的 intent-filter |
| ABI / DEX 数量 / 图标 | ✅ | `lib/<abi>/`、`classes*.dex`、`res/**` 里挑最大方形图标 |
| 推送到主机安装 | ✅ | `POST /install` → `adb install -r -d` |
| 启动应用 | ✅ | `am start -n`，失败回落 `monkey -p` |
| 画面回传 | ✅ | WebSocket 二进制 PNG 帧，默认 4 fps |
| 触摸 / 滑动 / 返回键等 | ✅ | 归一化坐标，服务端换算像素 |
| 文本输入 | ✅ | `input text` |
| 会话日志 | ✅ | 每条指令都有回执 |

iOS 侧**没有任何第三方依赖**（不用 CocoaPods / SPM），Xcode 打开就能编，CI 里 `xcodebuild` 一遍过。

---

## 2. 出 IPA（不用 Mac）

仓库带了一个 GitHub Actions 工作流 `.github/workflows/build-ipa.yml`，每次 push 到 `main` 自动在 `macos-14` 上：

1. `brew install xcodegen` → `xcodegen generate` 生成 `DroidBox.xcodeproj`
2. `xcodebuild ... CODE_SIGNING_ALLOWED=NO` 编 Release（arm64）
3. 打成 `Payload/DroidBox.app` → `zip` → **`DroidBox-unsigned.ipa`**
4. 作为 artifact 上传

拿包：

- 仓库页 → **Actions** → 最新一次 `build-ipa` → 页面底部 **Artifacts** → 下载 `DroidBox-unsigned-ipa`
- 解压得到 `DroidBox-unsigned.ipa`

命令行也行：

```bash
gh run download -R <你的用户名>/Android-emulator -n DroidBox-unsigned-ipa
```

本地有 Mac 的话：

```bash
brew install xcodegen
xcodegen generate
open DroidBox.xcodeproj     # 真机跑就配好自己的 Team
```

---

## 3. Sideloadly 签名

1. Windows/Mac 装 [Sideloadly](https://sideloadly.io/)，iPhone 用数据线连电脑
2. 把 `DroidBox-unsigned.ipa` 拖进 Sideloadly
3. **Apple ID** 填你的（免费账号即可，7 天有效；有开发者账号就 1 年）
4. Bundle ID 撞车就改一个：`com.你的名字.droidbox`
5. 点 **Start**，等进度条走完
6. iPhone：**设置 → 通用 → VPN与设备管理 → 开发者App → 信任**
7. 首次进 App 会弹「本地网络」权限 → **允许**（不加就搜不到电脑）

> 免费账号每 7 天要重签一次，这是苹果的规矩。想省事就买个开发者账号，或者在 Sideloadly 里勾选自动续签（需要保持电脑在线）。

---

## 4. 电脑端：把安卓跑起来

### 4.1 装 adb + 一个安卓设备

任选一种：

- **安卓真机（最推荐，性能最好）**
  设置 → 关于手机 → 连点版本号开开发者选项 → 开发者选项 → **无线调试** → 配对
  ```bash
  adb pair 192.168.1.23:37821      # 手机上显示的配对码
  adb connect 192.168.1.23:5555
  adb devices
  ```
- **Android Studio AVD**
  装 Android Studio → Device Manager → 建一个 **arm64-v8a** 的镜像（x86 镜像装不了 arm-only 的 APK）
  启动模拟器后 `adb devices` 会看到 `emulator-5554`

### 4.2 起桥

```bash
cd bridge
python droidbridge.py                 # 自动挑第一台设备，端口 8770
python droidbridge.py --mock          # 没有设备时：假画面，验证 iPhone 能不能连
```

Windows 直接双击 `bridge/run-bridge.bat`，或 `run-bridge.bat mock`。

终端会打印：

```
droidbridge 已启动  监听 0.0.0.0:8770  fps=4.0  mock=False
iPhone 里填:  ws://192.168.1.10:8770/ws
```

### 4.3 iPhone 端

1. **设置** 页填 `ws://192.168.1.10:8770/ws`（就是你电脑的局域网 IP），点「测试连通性」确认通
2. **应用** 页右上角 `+` → 选一个 `.apk`
3. 进详情页 → **推送到主机并启动**
4. 自动跳到全屏控制：能看见安卓画面，点哪儿按哪儿，底部有返回/主屏/多任务/键盘

---

## 5. 仓库结构

```
.
├── .github/workflows/build-ipa.yml   # macOS runner 编译 + 打包未签名 IPA
├── project.yml                       # XcodeGen 工程定义（iOS 16.0，arm64）
├── Info.plist                        # UTI 注册（.apk/.apks/.xapk）、本地网络权限
├── Resources/Assets.xcassets         # AppIcon（1024 单尺寸）
├── Sources/
│   ├── App/DroidBoxApp.swift         # 入口 + 主题
│   ├── Support/
│   │   ├── DataBytes.swift           # 字节读取
│   │   ├── Inflate.swift             # DEFLATE：系统 Compression + 自写 inflate 兜底
│   │   └── ZipReader.swift           # ZIP 中央目录 / 本地头 / ZIP64
│   ├── APK/
│   │   ├── AXML.swift                # 二进制 AndroidManifest.xml 解析器
│   │   └── APKParser.swift           # 包信息聚合 + 图标挑选
│   ├── Models/AndroidApp.swift
│   ├── Store/{LibraryStore,AppSettings}.swift
│   ├── Remote/RemoteSession.swift    # WS 客户端 + HTTP 上传 APK
│   └── UI/{LibraryView,AppDetailView,RemoteViews,SettingsView}.swift
├── bridge/
│   ├── droidbridge.py                # 画面抓取 + 触摸回写 + APK 安装（零依赖）
│   ├── run-bridge.bat
│   └── README.md                     # 协议文档
└── tools/
    ├── make_icon.js                  # 生成 AppIcon
    ├── inflate_ref.js                # inflate 算法的 zlib 交叉校验（140/140 通过）
    └── ws_selftest.js                # 桥的 WebSocket 协议自测
```

---

## 6. 协议备忘

App ↔ 桥之间就两层：

- **WS 二进制帧** = PNG 屏幕帧
- **WS 文本帧** = JSON 指令

```json
// App → 桥
{"t":"hello","code":"1234"}
{"t":"tap","x":0.5,"y":0.5}
{"t":"swipe","x1":0.5,"y1":0.8,"x2":0.5,"y2":0.2,"ms":180}
{"t":"key","v":"BACK"}
{"t":"text","v":"hello"}
{"t":"launch","package":"com.example.app","activity":".MainActivity"}

// 桥 → App
{"t":"meta","w":1080,"h":2400,"serial":"emulator-5554","mock":false,"fps":4.0}
{"t":"ok","v":"tap 540,1200"}
{"t":"error","v":"启动失败：..."}
```

完整表格见 [bridge/README.md](bridge/README.md)。

---

## 7. 常见问题

**Q：App 连不上电脑**
- 必须在同一个 Wi-Fi，且路由器没开「AP 隔离」
- Windows 防火墙要放行 8770（或第一次弹窗时点允许）
- 先在电脑浏览器打开 `http://127.0.0.1:8770/status`，再在 iPhone Safari 打开 `http://电脑IP:8770/status`
- iPhone 上没给「本地网络」权限的话，系统会静默拦截 → 设置 → 隐私 → 本地网络 → 打开

**Q：画面一直是黑的**
- `python droidbridge.py --mock` 能出假画面 → iPhone 侧没问题，是 adb 没拿到画面
- `adb exec-out screencap -p > test.png` 手动试，能出图才是好的
- 安卓锁屏了：连上后按一次「主屏」键，或者先在手机上解锁

**Q：APK 装不上**
- `INSTALL_FAILED_NO_MATCHING_ABIS`：模拟器是 x86、APK 只有 arm64 → 换 arm64 镜像或用真机
- `INSTALL_FAILED_UPDATE_INCOMPATIBLE`：签名冲突，先 `adb uninstall 包名`
- `INSTALL_PARSE_FAILED`：APK 本身坏了，或者下载的是 xapk/apks 拆分包（暂不支持拆分包合并）

**Q：帧率太低**
- `--fps 6` 提一点；再高徒增 CPU（adb 截图本身就要 100~400ms）
- 用真机代替 AVD，明显更快
- 30fps 要走 scrcpy 的 H.264 流，见路线图

**Q：导入 APK 后图标是默认的**
- 该 APK 用的是 adaptive icon（XML）或者图标在 `res/` 里不符合方形规则 → 解析器会退回默认图标，不影响运行

---

## 8. 路线图

- [ ] scrcpy H.264 流 + VideoToolbox 硬解 → 30fps、可变码率
- [ ] iOS 直接 ADB over TCP（去掉 Python 中间层）
- [ ] `resources.arsc` 完整解析 → 精确 label / adaptive icon
- [ ] xapk / apks 拆分包合并安装
- [ ] 多点触控 + 键盘映射 + 手柄
- [ ] 多设备切换

---

## 9. 附录：真要「iPhone 本机虚拟机」

可以，但只能当演示：

1. 侧载 [UTM](https://github.com/utmapp/UTM)（自己编或找现成 ipa），用 Sideloadly 签
2. 用 [StikDebug](https://github.com/StephenDev0/StikDebug) / Jitterbug 之类工具在 iOS 17+ 上给 UTM 打开 JIT（要连电脑调试）
3. 下载 Android x86_64 的 ISO，在 UTM 里新建虚拟机，开 TCG
4. 开机 + 装 APK：**以小时计**，触摸延迟以秒计

没有 JIT 时更慢。所以这条路只适合发截图。

---

## 10. 自测（不装 iPhone 也能跑）

```bash
# 桥的协议自测：health / WS 握手 / 收帧 / 指令回执
node tools/ws_selftest.js

# inflate 算法与 zlib 的交叉校验
node tools/inflate_ref.js
```

两个脚本都是零依赖，Windows 上直接 `node` 就能跑。

---

MIT License
