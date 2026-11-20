import Foundation

struct AndroidApp: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var packageName: String
    var versionName: String
    var versionCode: Int
    var minSDK: Int
    var targetSDK: Int
    var launcherActivity: String
    var permissions: [String]
    var abis: [String]
    var dexCount: Int
    var entryCount: Int
    var fileSize: Int64
    var importedAt: Date
    var folderName: String
    var apkFileName: String
    var iconFileName: String?

    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var sdkText: String {
        if minSDK == 0 && targetSDK == 0 { return "未知" }
        return "min \(minSDK) / target \(targetSDK)"
    }
}

enum LibraryError: Error, LocalizedError {
    case badManifest
    case storage

    var errorDescription: String? {
        switch self {
        case .badManifest: return "这个 APK 的 AndroidManifest.xml 读不出来，可能不是标准 APK。"
        case .storage: return "写入 App 沙盒目录失败。"
        }
    }
}
