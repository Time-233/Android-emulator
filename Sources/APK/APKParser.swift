import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct ParsedAPK {
    var packageName: String
    var versionName: String
    var versionCode: Int
    var displayName: String
    var labelIsLiteral: Bool
    var launcherActivity: String
    var minSDK: Int
    var targetSDK: Int
    var permissions: [String]
    var abis: [String]
    var dexCount: Int
    var entryCount: Int
    var fileSize: Int64
    var iconData: Data?
    var iconEntry: String?
}

enum APKParseError: Error {
    case missingManifest
    case unreadableManifest
}

final class APKParser {
    private let zip: ZipReader
    private let fileSize: Int64

    init(url: URL) throws {
        self.zip = try ZipReader(url: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        self.fileSize = Int64(values.fileSize ?? 0)
    }

    func parse(fallbackName: String) throws -> ParsedAPK {
        guard let manifestEntry = zip.entry(named: "AndroidManifest.xml") else {
            throw APKParseError.missingManifest
        }
        let manifestData = try zip.read(manifestEntry)
        let root: AXMLNode
        do {
            root = try BinaryXMLParser(data: manifestData).parse()
        } catch {
            throw APKParseError.unreadableManifest
        }

        guard root.name == "manifest" else { throw APKParseError.unreadableManifest }

        let packageName = root.attrString("package") ?? ""
        let versionName = root.attrString("versionName") ?? ""
        let versionCode = root.attrInt("versionCode") ?? 0

        var minSDK = 0
        var targetSDK = 0
        for uses in root.kids("uses-sdk") {
            if let value = uses.attrInt("minSdkVersion") { minSDK = value }
            if let value = uses.attrInt("targetSdkVersion") { targetSDK = value }
        }

        var permissions: [String] = []
        for permission in root.kids("uses-permission") + root.kids("uses-permission-sdk-23") {
            if let name = permission.attrString("name"), !name.isEmpty {
                permissions.append(name)
            }
        }

        var label = ""
        var labelIsLiteral = false
        var launcherActivity = ""

        for application in root.kids("application") {
            if let literal = application.attrString("label"), !literal.isEmpty {
                label = literal
                labelIsLiteral = true
            }
            for activity in application.kids("activity") + application.kids("activity-alias") {
                let activityName = activity.attrString("name") ?? ""
                var isLauncher = false
                for filter in activity.kids("intent-filter") {
                    let actions = filter.kids("action").compactMap { $0.attrString("name") }
                    let categories = filter.kids("category").compactMap { $0.attrString("name") }
                    if actions.contains("android.intent.action.MAIN") && categories.contains("android.intent.category.LAUNCHER") {
                        isLauncher = true
                    }
                }
                if isLauncher && !activityName.isEmpty {
                    launcherActivity = activityName
                    if label.isEmpty {
                        if let activityLabel = activity.attrString("label"), !activityLabel.isEmpty {
                            label = activityLabel
                            labelIsLiteral = true
                        }
                    }
                }
            }
        }

        let abis = Set(zip.entries(withPrefix: "lib/").compactMap { entry -> String? in
            let parts = entry.name.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return String(parts[1])
        }).sorted()

        let dexCount = zip.entries.filter {
            let lower = $0.name.lowercased()
            return lower.hasSuffix(".dex") && !lower.contains("/")
        }.count

        let icon = APKIconFinder.pickBest(from: zip)

        let name = labelIsLiteral && !label.isEmpty ? label : fallbackName

        return ParsedAPK(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            displayName: name,
            labelIsLiteral: labelIsLiteral,
            launcherActivity: launcherActivity,
            minSDK: minSDK,
            targetSDK: targetSDK,
            permissions: permissions,
            abis: abis.isEmpty ? ["universal"] : abis,
            dexCount: dexCount,
            entryCount: zip.entries.count,
            fileSize: fileSize,
            iconData: icon?.data,
            iconEntry: icon?.name
        )
    }
}

/// 不看 resources.arsc，直接在 res/ 里按“名字像图标 + 像素面积最大”挑一个。
/// 好处是零依赖、几乎不会崩；坏处是极少数应用会挑到非图标资源。
enum APKIconFinder {
    struct Candidate {
        let name: String
        let data: Data
        let area: Int
        let isMipmap: Bool
    }

    static func pickBest(from zip: ZipReader) -> Candidate? {
        var candidates: [(ZipEntry, Int, Bool)] = []
        for entry in zip.entries {
            let lower = entry.name.lowercased()
            guard lower.hasPrefix("res/") else { continue }
            guard lower.hasSuffix(".png") || lower.hasSuffix(".webp") else { continue }
            guard entry.uncompressedSize > 256, entry.uncompressedSize < 4 * 1024 * 1024 else { continue }
            let nameHit = lower.contains("icon") || lower.contains("launcher") || lower.contains("logo")
            let isMipmap = lower.hasPrefix("res/mipmap")
            if !nameHit && !isMipmap { continue }
            candidates.append((entry, entry.uncompressedSize, isMipmap))
        }
        guard !candidates.isEmpty else { return nil }

        var best: Candidate?
        var bestScore = -1
        for (entry, _, isMipmap) in candidates {
            guard let data = try? zip.read(entry) else { continue }
            let dimensions = imageSize(data)
            let area: Int
            if dimensions.width > 0 && dimensions.height > 0 {
                let ratio = Double(dimensions.width) / Double(dimensions.height)
                guard ratio > 0.8 && ratio < 1.25 else { continue }
                area = dimensions.width * dimensions.height
            } else {
                area = data.count * 4
            }
            var score = area
            if isMipmap { score += 4096 }
            if score > bestScore {
                bestScore = score
                best = Candidate(name: entry.name, data: data, area: area, isMipmap: isMipmap)
            }
        }
        return best
    }

    static func imageSize(_ data: Data) -> (width: Int, height: Int) {
        guard data.count > 32 else { return (0, 0) }
        // PNG
        if data.u8(0) == 0x89, data.u8(1) == 0x50 {
            let width = Int(data.u32(16).bigEndian)
            let height = Int(data.u32(20).bigEndian)
            return (width, height)
        }
        // WebP
        if data.text(0, 4) == "RIFF", data.text(8, 4) == "WEBP" {
            let chunk = data.text(12, 4)
            if chunk == "VP8X", data.count >= 30 {
                let width = 1 + Int(data.u8(24)) + (Int(data.u8(25)) << 8) + (Int(data.u8(26)) << 16)
                let height = 1 + Int(data.u8(27)) + (Int(data.u8(28)) << 8) + (Int(data.u8(29)) << 16)
                return (width, height)
            }
            if chunk == "VP8 ", data.count >= 30 {
                let width = Int(data.u16(26) & 0x3FFF)
                let height = Int(data.u16(28) & 0x3FFF)
                return (width, height)
            }
            return (0, 0)
        }
        return (0, 0)
    }
}
