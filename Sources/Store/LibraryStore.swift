import Foundation
import Combine

/// 把导入的 APK 收进 App 沙盒：Documents/DroidBoxApps/<uuid>/{app.apk, icon.png, meta.json}
final class LibraryStore: ObservableObject {
    @Published var apps: [AndroidApp] = []
    @Published var isImporting: Bool = false
    @Published var lastError: String?

    private let fileManager = FileManager.default

    var rootURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("DroidBoxApps", isDirectory: true)
    }

    init() {
        ensureRoot()
        reload()
    }

    private func ensureRoot() {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    func reload() {
        ensureRoot()
        guard let folders = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            apps = []
            return
        }
        var loaded: [AndroidApp] = []
        for folder in folders {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let app = try? decoder.decode(AndroidApp.self, from: data) {
                loaded.append(app)
            }
        }
        apps = loaded.sorted { $0.importedAt > $1.importedAt }
    }

    func importAPK(from url: URL, completion: @escaping (Result<AndroidApp, Error>) -> Void) {
        isImporting = true
        let target = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let scoped = target.startAccessingSecurityScopedResource()
            defer { if scoped { target.stopAccessingSecurityScopedResource() } }

            let result: Result<AndroidApp, Error>
            do {
                result = .success(try self.store(url: target))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.isImporting = false
                switch result {
                case .success(let app):
                    self.apps.insert(app, at: 0)
                    completion(.success(app))
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    private func store(url: URL) throws -> AndroidApp {
        let identifier = UUID()
        let folder = rootURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let fallbackName = url.deletingPathExtension().lastPathComponent
        let apkURL = folder.appendingPathComponent("app.apk")
        if fileManager.fileExists(atPath: apkURL.path) {
            try fileManager.removeItem(at: apkURL)
        }
        try fileManager.copyItem(at: url, to: apkURL)

        let parsed: ParsedAPK
        do {
            parsed = try APKParser(url: apkURL).parse(fallbackName: fallbackName)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw LibraryError.badManifest
        }

        var iconName: String?
        if let iconData = parsed.iconData {
            let extensionName = (parsed.iconEntry?.lowercased().hasSuffix(".webp") ?? false) ? "webp" : "png"
            let iconURL = folder.appendingPathComponent("icon.\(extensionName)")
            if (try? iconData.write(to: iconURL)) != nil {
                iconName = iconURL.lastPathComponent
            }
        }

        let app = AndroidApp(
            id: identifier,
            displayName: parsed.displayName,
            packageName: parsed.packageName,
            versionName: parsed.versionName,
            versionCode: parsed.versionCode,
            minSDK: parsed.minSDK,
            targetSDK: parsed.targetSDK,
            launcherActivity: parsed.launcherActivity,
            permissions: parsed.permissions,
            abis: parsed.abis,
            dexCount: parsed.dexCount,
            entryCount: parsed.entryCount,
            fileSize: parsed.fileSize,
            importedAt: Date(),
            folderName: identifier.uuidString,
            apkFileName: "app.apk",
            iconFileName: iconName
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let meta = try encoder.encode(app)
        try meta.write(to: folder.appendingPathComponent("meta.json"))
        return app
    }

    func delete(_ app: AndroidApp) {
        let folder = rootURL.appendingPathComponent(app.folderName, isDirectory: true)
        try? fileManager.removeItem(at: folder)
        apps.removeAll { $0.id == app.id }
    }

    func iconURL(for app: AndroidApp) -> URL? {
        guard let name = app.iconFileName else { return nil }
        let url = rootURL.appendingPathComponent(app.folderName, isDirectory: true).appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func apkURL(for app: AndroidApp) -> URL {
        return rootURL
            .appendingPathComponent(app.folderName, isDirectory: true)
            .appendingPathComponent(app.apkFileName)
    }
}
