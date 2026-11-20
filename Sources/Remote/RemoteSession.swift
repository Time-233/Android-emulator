import Foundation
import UIKit
import Combine

/// 连接 Android 运行主机（PC 上的 droidbridge）：拉画面、下发触摸、推 APK 安装
final class RemoteSession: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "连接中…"
            case .connected: return "已连接"
            case .failed(let message): return "连接失败：\(message)"
            }
        }

        var isConnected: Bool { self == .connected }
    }

    @Published var status: Status = .idle
    @Published var frame: UIImage?
    @Published var screenSize: CGSize = .zero
    @Published var logs: [String] = []
    @Published var fps: Double = 0
    @Published var busy: String?

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var httpBase: URL?
    private var heartbeat: Timer?
    private var frameCount = 0
    private var fpsAnchor = Date()
    private var closedByUser = false

    // MARK: - 连接

    func connect(url: URL, accessCode: String) {
        stop(notify: false)
        closedByUser = false
        status = .connecting
        screenSize = .zero
        frame = nil

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !accessCode.isEmpty {
            components?.queryItems = [URLQueryItem(name: "code", value: accessCode)]
        }
        guard let target = components?.url else {
            status = .failed("地址不合法")
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        self.session = session
        httpBase = Self.httpBase(from: url)

        let task = session.webSocketTask(with: target)
        task.maximumMessageSize = 8 * 1024 * 1024
        socket = task
        task.resume()

        send(["t": "hello", "code": accessCode, "client": "droidbox-ios", "v": 1])
        listen()
        startHeartbeat()
        append("→ 连接 \(target.absoluteString)")
    }

    func disconnect() {
        closedByUser = true
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        heartbeat?.invalidate()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if notify {
            status = .idle
            frame = nil
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.send(["t": "ping"])
        }
        heartbeat = timer
    }

    private static func httpBase(from url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = (url.scheme == "wss") ? "https" : "http"
        components?.path = "/"
        components?.query = nil
        return components?.url
    }

    // MARK: - 收包

    private func listen() {
        guard let task = socket else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.handleFailure(error)
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleFrame(data)
                case .string(let text):
                    self.handleText(text)
                @unknown default:
                    break
                }
                self.listen()
            }
        }
    }

    private func handleFrame(_ data: Data) {
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(fpsAnchor) >= 1 {
            let value = Double(frameCount) / now.timeIntervalSince(fpsAnchor)
            frameCount = 0
            fpsAnchor = now
            DispatchQueue.main.async { self.fps = value }
        }
        guard let image = UIImage(data: data) else { return }
        DispatchQueue.main.async {
            self.frame = image
            if self.screenSize == .zero {
                self.screenSize = image.size
                self.status = .connected
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else {
            return
        }
        switch type {
        case "meta":
            let width = (object["w"] as? NSNumber)?.doubleValue ?? 0
            let height = (object["h"] as? NSNumber)?.doubleValue ?? 0
            let serial = object["serial"] as? String ?? "android"
            DispatchQueue.main.async {
                if width > 0 && height > 0 {
                    self.screenSize = CGSize(width: width, height: height)
                }
                self.status = .connected
                self.busy = nil
            }
            append("← 主机 \(serial) \(Int(width))×\(Int(height))")
        case "log":
            append("← " + (object["v"] as? String ?? ""))
        case "ok":
            append("✔ " + (object["v"] as? String ?? "ok"))
            DispatchQueue.main.async { self.busy = nil }
        case "error":
            let message = object["v"] as? String ?? "未知错误"
            append("✘ " + message)
            DispatchQueue.main.async {
                self.busy = nil
                self.status = .failed(message)
            }
        default:
            append("← " + text)
        }
    }

    private func handleFailure(_ error: Error) {
        guard !closedByUser else { return }
        append("✘ \(error.localizedDescription)")
        DispatchQueue.main.async {
            if case .failed = self.status { return }
            self.status = .failed(error.localizedDescription)
        }
    }

    // MARK: - 发包

    private func send(_ object: [String: Any]) {
        guard let socket = socket else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    func tap(nx: Double, ny: Double) {
        send(["t": "tap", "x": nx, "y": ny])
    }

    func swipe(nx1: Double, ny1: Double, nx2: Double, ny2: Double, duration: Int) {
        send(["t": "swipe", "x1": nx1, "y1": ny1, "x2": nx2, "y2": ny2, "ms": duration])
    }

    func key(_ name: String) {
        send(["t": "key", "v": name])
    }

    func typeText(_ text: String) {
        send(["t": "text", "v": text])
    }

    func launch(package: String, activity: String) {
        busy = "正在启动 \(package)"
        send(["t": "launch", "package": package, "activity": activity])
    }

    func refreshFrame() {
        send(["t": "frame"])
    }

    // MARK: - 上传 APK 安装

    func installAndLaunch(apkURL: URL, package: String, activity: String, completion: @escaping (Bool) -> Void) {
        guard let base = httpBase else {
            completion(false)
            return
        }
        guard let apkData = try? Data(contentsOf: apkURL, options: [.mappedIfSafe]) else {
            append("✘ 读取本地 APK 失败")
            completion(false)
            return
        }
        busy = "推送 APK（\(ByteCountFormatter.string(fromByteCount: Int64(apkData.count), countStyle: .file))）"
        append("→ 上传 APK \(package)")

        var request = URLRequest(url: base.appendingPathComponent("install"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(package, forHTTPHeaderField: "X-Package")
        request.setValue(activity.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "", forHTTPHeaderField: "X-Activity")

        let session = self.session ?? URLSession(configuration: .default)
        let task = session.uploadTask(with: request, from: apkData) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.busy = nil
                    self.append("✘ 上传失败：\(error.localizedDescription)")
                }
                completion(false)
                return
            }
            if let data = data, let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self.append("← " + text) }
            }
            DispatchQueue.main.async {
                self.busy = nil
                self.launch(package: package, activity: activity)
            }
            completion(true)
        }
        task.resume()
    }

    func append(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        DispatchQueue.main.async {
            self.logs.append("[\(stamp)] \(line)")
            if self.logs.count > 400 {
                self.logs.removeFirst(self.logs.count - 400)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension RemoteSession.Status {
    var color: UIColor {
        switch self {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .failed: return .systemRed
        case .idle: return .systemGray
        }
    }
}
