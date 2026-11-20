import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var session: RemoteSession

    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var remoteApp: AndroidApp?

    private var apkTypes: [UTType] {
        var types: [UTType] = []
        if let apk = UTType(filenameExtension: "apk") { types.append(apk) }
        if let apks = UTType(filenameExtension: "apks") { types.append(apks) }
        if let xapk = UTType(filenameExtension: "xapk") { types.append(xapk) }
        types.append(.archive)
        types.append(.data)
        return types
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.apps.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle("安卓模拟器")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: apkTypes, allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $remoteApp) { app in
                RemoteScreenView(session: session, app: app)
            }
            .overlay {
                if library.isImporting {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().scaleEffect(1.2)
                            Text("正在解析 APK…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把 APK 装进这台 iPhone")
                        .font(.title2.bold())
                    Text("点右上角 +，从「文件」里选一个 .apk。导入后会自动解析包名、版本、权限、入口 Activity 和图标。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)

                Card(title: "运行方式", lines: [
                    "iOS 无 JIT，本地跑不了完整安卓虚拟机。",
                    "所以画面和算力放在你电脑（或安卓真机）上：",
                    "① 电脑跑 droidbridge.py + 安卓（真机/AVD）",
                    "② 本 App 连接它，把 APK 推过去装好并启动",
                    "③ 画面回传到 iPhone，触摸指令实时回写"
                ])

                Card(title: "下一步", lines: [
                    "去「设置」填主机地址，例如 ws://192.168.1.10:8770/ws",
                    "电脑端：python bridge/droidbridge.py --adb adb",
                    "连接成功后回「应用」导入 APK 即可"
                ])

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(library.apps) { app in
                    NavigationLink {
                        AppDetailView(app: app, session: session, onRemote: { remoteApp = $0 })
                    } label: {
                        AppRow(app: app, icon: iconImage(for: app))
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        library.delete(library.apps[index])
                    }
                }
            } header: {
                Text("已导入 \(library.apps.count) 个 APK")
            } footer: {
                Text("左滑删除。点进详情可推送安装并启动。")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func iconImage(for app: AndroidApp) -> UIImage? {
        guard let url = library.iconURL(for: app) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            library.importAPK(from: url) { outcome in
                if case .failure(let error) = outcome {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

struct AppRow: View {
    let app: AndroidApp
    let icon: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(image: icon, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Text(app.packageName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(app.versionName.isEmpty ? "—" : app.versionName)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct IconBadge: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "apps.iphone")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct Card: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
