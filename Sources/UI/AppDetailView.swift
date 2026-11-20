import SwiftUI

struct AppDetailView: View {
    let app: AndroidApp
    @ObservedObject var session: RemoteSession
    var onRemote: (AndroidApp) -> Void

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showRemote = false
    @State private var message: String?
    @State private var confirmDelete = false

    private var icon: UIImage? {
        guard let url = library.iconURL(for: app) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                infoCard
                permissionCard
                if !session.logs.isEmpty { logCard }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .background(Theme.surface.ignoresSafeArea())
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRemote) {
            RemoteScreenView(session: session, app: app)
        }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("删除本地 APK？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                library.delete(app)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删掉 iPhone 上的副本，安卓主机上已安装的应用不受影响。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(image: icon, size: 76)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.displayName).font(.title3.bold()).lineLimit(2)
                Text(app.packageName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text("v" + (app.versionName.isEmpty ? "?" : app.versionName))
                    Text("·")
                    Text(app.abis.joined(separator: "/"))
                    Text("·")
                    Text(app.sizeText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                runPrimary()
            } label: {
                HStack {
                    Image(systemName: session.status.isConnected ? "play.fill" : "bolt.horizontal.circle")
                    Text(session.status.isConnected ? "推送到主机并启动" : "连接主机并启动")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: 10) {
                Button {
                    onRemote(app)
                } label: {
                    Label("全屏控制", systemImage: "rectangle.expand.vertical")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    if settings.webSocketURL != nil {
                        session.launch(package: app.packageName, activity: app.launcherActivity)
                        onRemote(app)
                    } else {
                        message = "先去「设置」填主机地址。"
                    }
                } label: {
                    Label("仅启动", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if let busy = session.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let last = session.logs.last {
                Text(last).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("包信息").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            infoRow("版本名", app.versionName.isEmpty ? "—" : app.versionName)
            infoRow("版本号", String(app.versionCode))
            infoRow("SDK", app.sdkText)
            infoRow("入口 Activity", app.launcherActivity.isEmpty ? "未声明 LAUNCHER" : app.launcherActivity)
            infoRow("DEX 数量", String(app.dexCount))
            infoRow("ABI", app.abis.joined(separator: ", "))
            infoRow("ZIP 条目", String(app.entryCount))
            infoRow("本地大小", app.sizeText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.caption.monospaced()).foregroundStyle(.primary).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("权限（\(app.permissions.count)）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            if app.permissions.isEmpty {
                Text("未声明权限").font(.caption).foregroundStyle(.secondary)
            } else {
                FlexibleTags(items: app.permissions.map { $0.replacingOccurrences(of: "android.permission.", with: "") })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("会话日志").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            ForEach(Array(session.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runPrimary() {
        guard let url = settings.webSocketURL else {
            message = "先去「设置」填主机地址，例如 ws://192.168.1.10:8770/ws"
            return
        }
        if !session.status.isConnected {
            session.connect(url: url, accessCode: settings.accessCode)
        }
        showRemote = true
        session.installAndLaunch(
            apkURL: library.apkURL(for: app),
            package: app.packageName,
            activity: app.launcherActivity
        ) { ok in
            if !ok { message = "APK 推送失败，检查主机是否在线、adb 是否可用。" }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.vertical, 14)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.vertical, 12)
            .background(Theme.card.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// 简单的流式标签布局
struct FlexibleTags: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunked(), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.07), in: Capsule())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chunked() -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var width = 0
        for item in items {
            let cost = min(item.count, 26) + 4
            if width + cost > 38 && !current.isEmpty {
                rows.append(current)
                current = []
                width = 0
            }
            current.append(item)
            width += cost
        }
        if !current.isEmpty { rows.append(current) }
        return rows.isEmpty ? [[]] : rows
    }
}
