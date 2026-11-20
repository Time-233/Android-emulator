import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var probeResult: String?
    @State private var probing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ws://192.168.1.10:8770/ws", text: $settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                    TextField("访问码（可留空）", text: $settings.accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("主机")
                } footer: {
                    Text("填电脑上 droidbridge.py 的地址。端口默认 8770，路径 /ws。")
                }

                Section {
                    Button {
                        probe()
                    } label: {
                        HStack {
                            Text("测试连通性")
                            Spacer()
                            if probing { ProgressView().controlSize(.small) }
                        }
                    }
                    if let result = probeResult {
                        Text(result)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("会用 HTTP 请求一次 /status 接口，确认主机和端口通不通。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        step("1", "电脑装好 adb 与一个安卓设备（真机开无线调试，或用 AVD 模拟器）")
                        step("2", "python bridge/droidbridge.py --adb adb --serial 设备号")
                        step("3", "确认电脑与 iPhone 在同一 Wi-Fi，填上面的地址")
                        step("4", "回「应用」导入 APK → 推送安装 → 全屏控制")
                    }
                } header: {
                    Text("怎么把安卓跑起来")
                } footer: {
                    Text("iOS 不允许非越狱 App 使用 JIT，本地跑完整安卓虚拟机没有实用速度。把安卓放在电脑/安卓真机上，iPhone 只做画面与控制端，是唯一可用的路线。")
                }

                Section {
                    infoRow("App 版本", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    infoRow("构建号", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    infoRow("最低系统", "iOS 16.0")
                    infoRow("包名", Bundle.main.bundleIdentifier ?? "—")
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value).foregroundStyle(.secondary).font(.system(.footnote, design: .monospaced))
        }
    }

    private func step(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption2.weight(.bold))
                .frame(width: 16, height: 16)
                .background(Theme.accent.opacity(0.2), in: Circle())
                .foregroundStyle(Theme.accent)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func probe() {
        guard let ws = settings.webSocketURL else {
            probeResult = "地址不合法"
            return
        }
        var components = URLComponents(url: ws, resolvingAgainstBaseURL: false)
        components?.scheme = (ws.scheme == "wss") ? "https" : "http"
        components?.path = "/status"
        components?.query = nil
        guard let url = components?.url else {
            probeResult = "地址不合法"
            return
        }
        probing = true
        probeResult = nil
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                probing = false
                if let error = error {
                    probeResult = "不可达：\(error.localizedDescription)"
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                probeResult = "HTTP \(code)  \(body.prefix(200))"
            }
        }.resume()
    }
}
