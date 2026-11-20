# Husk 装机清单（iOS 27）

> 目标：在你的 iOS 27 设备上装好 Husk，让它能打开 APK，并且 JIT 真的生效。
> 结论先说：iOS 27 上 **TrollStore 不可用**（CoreTrust 漏洞只到 17.x），JIT 只有两条路——**Husk 内置 StikJIT（iOS 26+，可在手机上自己配对）** 或 **StikDebug**；翻译层类游戏还可以干脆开 **Play without JIT**。

---

## 0. 你需要准备

| 项 | 说明 |
| --- | --- |
| IPA | `Husk-3.4.ipa`（135.7 MB，上游 release）或本仓库 CI 产出的自建版 |
| 签名工具 | **Sideloadly**（Windows 直连签名）或 **SideStore/AltStore**（能导出 `.p12`，见 §5） |
| 证书 | 免费 Apple ID = 7 天；付费开发者账号 = 1 年 |
| 系统 | iOS 15.5+，你这台是 27，OK；需要 arm64 |
| 网络 | iPhone 与签名电脑同一 Wi-Fi；Windows 需装 Apple 设备驱动（iTunes / Apple Devices） |

---

## 1. 装 IPA（Sideloadly 流程）

1. 打开 Sideloadly，iPhone 有线连电脑，等它认出设备
2. 把 `Husk-3.4.ipa` 拖进窗口
3. **Apple ID** 填你的账号，密码 / 二次验证走完
4. **Bundle ID 改成你自己的**：`com.husk.app` → `com.你的名字.husk`
   - 改这一处就够。Husk 运行时会从 `PlugIns/HuskJITHelper.appex/Info.plist` 读 helper 的 identifier，所以改名后"内置 StikJIT"仍然可用（官方文档明确支持改名安装）
5. 点 **Start**，等进度条走完
6. iPhone：设置 → 通用 → VPN与设备管理 → 开发者App → **信任**
7. 首次进 Husk 会弹 **本地网络** 权限 → **允许**（不给的话配对和下载都会被系统静默拦掉）

> 关于 Sideloadly 的 "Enable JIT" 勾选：它只对"Sideloadly 自己拉起进程"的场景有效。iOS 27 上不要指望它，按第 3 节配好 Husk 自己的 JIT 通道。

---

## 2. 第一次打开要过的引导

Husk 首次启动会走一遍 setup（含可选的 Walkthrough），里面有一页 **Turn on JIT**。
如果先跳过，之后在 **Settings › JIT & sideload › Set up JIT** 重新进入同一流程。

---

## 3. 三条 JIT 路线（iOS 27 选一条）

### 3.1 内置 StikJIT —— 推荐，iOS 26+ 可用

不需要第二个 App，配对在手机上完成：

1. Settings → **JIT & sideload** → Method 选 **自动**（或直接选 Built-in StikJIT）
2. 点 **Set up JIT** → **Pair on this iPhone**
3. 允许「本地网络」→ 打开 **设置 › 隐私与安全性 › 开发者模式** → 往下找到 **Pair with Husk** → 输入 Husk 显示的 6 位码
   - 配对码同时会出现在系统后台任务横幅和通知里
4. 回到 Husk，点 **Connect LocalDevVPN**（连上后会自动跳回 Husk）
5. 点 **Check setup**：它会拉取并挂载匹配的 Developer Disk Image，然后 **Enable JIT**

细节与坑：

- 每次配对都会生成新的主机密钥，iPhone 只认最新一份，旧 pairing file 立刻作废
- 如果改过 Bundle ID，系统可能不给"持续后台任务"，此时配对窗口只有 ~30 秒——先在设置页把开发者模式打开、LocalDevVPN 连好，再点 Start 会稳很多
- **系统更新后**必须 Settings → **Reset Developer Disk Image**，否则 DDI 版本对不上

### 3.2 StikDebug —— 外部调试器 attach

1. 电脑上按 [StikDebug 配对文件指南](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md) 生成 `pairingFile.plist`
2. 传到手机，Husk → Settings → JIT → **Use a pairing file** 导入
3. Method 选 **StikDebug**，装好 StikDebug App
4. 启动游戏时 Husk 把 PID 交给 StikDebug attach，由它分配 RX 内存

### 3.3 Play without JIT —— 翻译层游戏专用，完全不要 JIT

Husk 3.2 起支持：翻译层跑的游戏不启 JIT 也能跑，代价是要**导入签名证书**给它重新签名转换后的 `.so`。

1. Settings → 打开 **Play without JIT**
2. 导入 `.p12` + 密码（见 §5）
3. 首次打开某个游戏会花几十秒"转换 + 重签"它的库，之后秒开

限制：只对**翻译层能跑的** App 有效（Unity / cocos2d-x / 纯 Java 的那批最常见）。走 QEMU 完整 LineageOS 的那条线仍然需要 JIT。

---

## 4. 自检（30 秒判定 JIT 到底通没通）

| 检查 | 期望 |
| --- | --- |
| Settings → Check setup | DDI 挂载成功 + Enable JIT 成功 |
| 打开 `GTA: San Andreas` 或 `Minecraft Dungeons` | 能进画面、有声音 = JIT + GPU 都通了 |
| 只有黑屏/秒退 | JIT 没生效，或该游戏走 QEMU 而你只开了翻译层 |
| 日志页 | Husk 的报错一般直接写"缺哪一步"（配对失效 / DDI 过期 / 证书不对） |

---

## 5. `.p12` 从哪来

- **SideStore / AltStore**：装完后在它自己的设置里能**导出证书**（`.p12` + 密码），这是最省事的一条
- **纯 Sideloadly**：证书材料在电脑上（Sideloadly 的工作目录里）。可以先用 Sideloadly 签 Husk 装上，再装一个 SideStore 导出一份 p12 给 Husk 用
- 一句话：**Play without JIT 想要 p12，就装一次 SideStore**

---

## 6. 故障对照表

| 现象 | 大概率原因 | 处理 |
| --- | --- | --- |
| 安装报 `invalid signature` | Bundle ID 撞车 / 描述文件过期 | 换个 Bundle ID 重签 |
| 装完点开就闪退 | entitlement 被裁（缺 `get-task-allow`） | 用 Sideloadly 重签，别手改 IPA |
| JIT 一直失败 / `brk` 报错 | 没挂 DDI、配对失效、VPN 没连 | 重跑 Set up JIT；iOS 升级后 Reset DDI |
| 游戏黑屏但有声音 | 渲染路径问题（Vulkan/Games） | 换 MoltenVK/Vulkan 开关，或用翻译层模式 |
| 完全连不上配对 | 本地网络权限没给 | 设置 → 隐私与安全性 → 本地网络 → Husk 打开 |
| 7 天后打不开 | 免费证书到期 | 重签；SideStore 可自动续签 |
| 提示 "unsupported entitlement" | 自建版带了 `dynamic-codesigning` | 用 `.tipa`/让签名器剥掉该 entitlement 再装 |

---

## 7. 兼容性预期（3.4 官方数据）

- F-Droid 测试集 472 个 App：**约 97%** 能跑（3.3 时是 85%）
- Play Store 测试集 169 个：**约 90%**，不含反篡改 / 风控类（Husk 明确不做绕过）

---

## 8. 自建版注意事项

本仓库的 `build-husk` workflow 产出的 IPA：

- 应用层（Swift/ObjC/C 翻译层）**从 tag 源码编译**；QEMU / ANGLE / MoltenVK / PS4 这些原生核在 `mode=app` 下取自**同 tag 的上游成品**，保证 ABI 一致
- Bundle ID 固定为 `com.husk.app`，签名时在 Sideloadly 里改成你自己的
- 产物是 ad-hoc 签名 + 完整 entitlements（`get-task-allow`、`dynamic-codesigning`、两条 kernel 权限），Sideloadly 重签后 `dynamic-codesigning` 通常会被裁掉——不影响 StikDebug 那条路（它靠调试器给 RX），但 TrollStore 包必须用 `.tipa`
- 许可证：GPL-2.0-or-later（链了 QEMU）。自己用随便；对外分发改过的包要公开源码
