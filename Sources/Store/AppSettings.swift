import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var accessCode: String {
        didSet { UserDefaults.standard.set(accessCode, forKey: "accessCode") }
    }
    @Published var autoLaunchPackage: Bool {
        didSet { UserDefaults.standard.set(autoLaunchPackage, forKey: "autoLaunchPackage") }
    }

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: "serverURL") ?? "ws://192.168.1.10:8770/ws"
        accessCode = defaults.string(forKey: "accessCode") ?? ""
        autoLaunchPackage = defaults.object(forKey: "autoLaunchPackage") as? Bool ?? true
    }

    var webSocketURL: URL? {
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.lowercased().hasPrefix("ws://") && !text.lowercased().hasPrefix("wss://") {
            text = "ws://" + text
        }
        if !text.lowercased().hasSuffix("/ws") {
            if text.hasSuffix("/") { text += "ws" } else { text += "/ws" }
        }
        return URL(string: text)
    }
}
