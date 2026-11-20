import SwiftUI

struct RemoteScreenView: View {
    @ObservedObject var session: RemoteSession
    let app: AndroidApp?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showLogs = false
    @State private var showTextInput = false
    @State private var textInput = ""
    @State private var didAutoConnect = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let rect = fittedRect(in: geo.size)
                ZStack {
                    if let frame = session.frame {
                        Image(uiImage: frame)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        placeholder
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(dragGesture(container: geo.size, rect: rect))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .statusBarHidden(false)
        .onAppear(perform: autoConnect)
        .sheet(isPresented: $showLogs) {
            LogSheet(session: session)
        }
        .alert("发送文本", isPresented: $showTextInput) {
            TextField("输入内容", text: $textInput)
            Button("发送") {
                if !textInput.isEmpty { session.typeText(textInput) }
                textInput = ""
            }
            Button("取消", role: .cancel) { textInput = "" }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(uiColor: session.status.color))
                .frame(width: 8, height: 8)
            Text(session.status.text)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            if session.fps > 0 {
                Text(String(format: "%.1f fps", session.fps))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button {
                showLogs = true
            } label: {
                Image(systemName: "text.alignleft").font(.caption)
            }
            .foregroundStyle(.white.opacity(0.8))
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            controlButton("chevron.backward") { session.key("BACK") }
            controlButton("house") { session.key("HOME") }
            controlButton("square.on.square") { session.key("APP_SWITCH") }
            controlButton("keyboard") { showTextInput = true }
            controlButton("arrow.clockwise") {
                if let url = settings.webSocketURL {
                    session.connect(url: url, accessCode: settings.accessCode)
                }
            }
            controlButton("xmark.octagon") { session.disconnect() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 10)
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 36, height: 30)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white).scaleEffect(1.1)
            Text("等待主机画面…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
            if case .failed(let message) = session.status {
                Text(message)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Text(settings.serverURL)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func autoConnect() {
        guard !didAutoConnect else { return }
        didAutoConnect = true
        guard !session.status.isConnected, let url = settings.webSocketURL else { return }
        session.connect(url: url, accessCode: settings.accessCode)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let imageSize = session.frame?.size ?? session.screenSize
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func dragGesture(container: CGSize, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onEnded { value in
                let start = value.startLocation
                let end = value.location
                let dx = end.x - start.x
                let dy = end.y - start.y
                let distance = sqrt(dx * dx + dy * dy)

                let originX = rect.minX
                let originY = rect.minY
                let width = max(rect.width, 1)
                let height = max(rect.height, 1)

                func norm(_ point: CGPoint) -> (Double, Double) {
                    let nx = Double((point.x - originX) / width)
                    let ny = Double((point.y - originY) / height)
                    return (min(max(nx, 0), 1), min(max(ny, 0), 1))
                }

                if distance < 14 {
                    let point = norm(start)
                    session.tap(nx: point.0, ny: point.1)
                } else {
                    let a = norm(start)
                    let b = norm(end)
                    let duration = max(90, min(1200, Int(distance * 1.6)))
                    session.swipe(nx1: a.0, ny1: a.1, nx2: b.0, ny2: b.1, duration: duration)
                }
            }
    }
}

struct LogSheet: View {
    @ObservedObject var session: RemoteSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(session.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle("会话日志")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

struct RemoteConsoleView: View {
    @ObservedObject var session: RemoteSession
    @EnvironmentObject private var settings: AppSettings

    @State private var showFullScreen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    previewCard
                    controlsCard
                    logCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle("远程主机")
            .sheet(isPresented: $showFullScreen) {
                RemoteScreenView(session: session, app: nil)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color(uiColor: session.status.color)).frame(width: 9, height: 9)
                Text(session.status.text).font(.subheadline.weight(.medium))
                Spacer()
                if session.fps > 0 {
                    Text(String(format: "%.1f fps", session.fps))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text(settings.serverURL)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Button {
                    if let url = settings.webSocketURL {
                        session.connect(url: url, accessCode: settings.accessCode)
                    }
                } label: {
                    Text("连接").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    session.disconnect()
                } label: {
                    Text("断开").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var previewCard: some View {
        Button {
            showFullScreen = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black)
                if let frame = session.frame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.4))
                        Text("还没有画面").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(height: 260)
            .overlay(alignment: .bottomTrailing) {
                Text("全屏控制")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(Theme.accent)
                    .padding(10)
            }
        }
        .buttonStyle(.plain)
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷操作").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            HStack(spacing: 10) {
                keyButton("返回", "BACK")
                keyButton("主屏", "HOME")
                keyButton("多任务", "APP_SWITCH")
                keyButton("电源", "POWER")
                keyButton("音量+", "VOLUME_UP")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func keyButton(_ title: String, _ code: String) -> some View {
        Button {
            session.key(code)
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.07), in: Capsule())
                .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("日志").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            if session.logs.isEmpty {
                Text("暂无日志").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(session.logs.suffix(12).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
