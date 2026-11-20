import Foundation

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int

    var isDirectory: Bool { name.hasSuffix("/") }
}

enum ZipError: Error {
    case notAZip
    case truncated
    case entryNotFound(String)
    case unsupportedMethod(UInt16)
    case corrupt(String)
}

/// 只读 ZIP 读取器，够用来读 APK（central directory + 本地头，stored / deflate）
final class ZipReader {
    private let data: Data
    private(set) var entries: [ZipEntry] = []
    private var index: [String: ZipEntry] = [:]

    init(data: Data) throws {
        self.data = data
        try loadCentralDirectory()
    }

    convenience init(url: URL) throws {
        let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: raw)
    }

    func entry(named name: String) -> ZipEntry? {
        return index[name]
    }

    func contains(_ name: String) -> Bool {
        return index[name] != nil
    }

    /// 模糊选择：所有以 suffix 结尾的条目
    func entries(withSuffix suffix: String) -> [ZipEntry] {
        let lowered = suffix.lowercased()
        return entries.filter { $0.name.lowercased().hasSuffix(lowered) }
    }

    func entries(withPrefix prefix: String) -> [ZipEntry] {
        let lowered = prefix.lowercased()
        return entries.filter { $0.name.lowercased().hasPrefix(lowered) }
    }

    func read(_ entry: ZipEntry) throws -> Data {
        let local = entry.localHeaderOffset
        guard local >= 0, local + 30 <= data.count else { throw ZipError.truncated }
        guard data.u32(local) == 0x04034b50 else { throw ZipError.corrupt("bad local header") }
        let nameLength = Int(data.u16(local + 26))
        let extraLength = Int(data.u16(local + 28))
        let start = local + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, end >= start else { throw ZipError.truncated }
        let raw = data.subdata(in: start..<end)

        switch entry.method {
        case 0:
            return raw
        case 8:
            return try Inflate.decode(raw, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    func read(named name: String) throws -> Data {
        guard let entry = index[name] else { throw ZipError.entryNotFound(name) }
        return try read(entry)
    }

    /// 解压出前 maxBytes 字节（用于只读元数据的大文件）
    func readPrefix(named name: String, maxBytes: Int) throws -> Data {
        let full = try read(named: name)
        if full.count <= maxBytes { return full }
        return full.prefix(maxBytes)
    }

    private func loadCentralDirectory() throws {
        let total = data.count
        guard total > 22 else { throw ZipError.notAZip }
        let lowest = max(0, total - (65535 + 22))
        var eocd = -1
        var scan = total - 22
        while scan >= lowest {
            if scan + 4 <= total && data.u32(scan) == 0x06054b50 {
                eocd = scan
                break
            }
            scan -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        var entryCount = Int(data.u16(eocd + 10))
        var directorySize = Int(data.u32(eocd + 12))
        var directoryOffset = Int(data.u32(eocd + 16))

        // ZIP64（APK 基本碰不到，但留个兜底）
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF {
            if let zip64 = findZip64Locator(eocdEnd: eocd) {
                entryCount = Int(zip64.count)
                directorySize = Int(zip64.size)
                directoryOffset = Int(zip64.offset)
            }
        }

        guard directoryOffset >= 0, directoryOffset <= total, directorySize >= 0 else { throw ZipError.corrupt("bad EOCD") }
        var pointer = directoryOffset
        var parsed = 0
        while parsed < entryCount && pointer + 46 <= total {
            guard data.u32(pointer) == 0x02014b50 else { break }
            let method = data.u16(pointer + 10)
            let compressed = Int(data.u32(pointer + 20))
            let uncompressed = Int(data.u32(pointer + 24))
            let nameLength = Int(data.u16(pointer + 28))
            let extraLength = Int(data.u16(pointer + 30))
            let commentLength = Int(data.u16(pointer + 32))
            let localOffset = Int(data.u32(pointer + 42))
            let name = data.text(pointer + 46, nameLength)
            let entry = ZipEntry(
                name: name,
                method: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset
            )
            entries.append(entry)
            index[name] = entry
            pointer += 46 + nameLength + extraLength + commentLength
            parsed += 1
        }

        if entries.isEmpty { throw ZipError.corrupt("empty central directory") }
    }

    private func findZip64Locator(eocdEnd: Int) -> (count: UInt64, size: UInt64, offset: UInt64)? {
        let position = eocdEnd - 20
        guard position > 0, data.u32(position) == 0x07064b50 else { return nil }
        let recordOffset = Int(data.u64(position + 8))
        guard recordOffset > 0, recordOffset + 56 <= data.count else { return nil }
        guard data.u32(recordOffset) == 0x06064b50 else { return nil }
        return (data.u64(recordOffset + 32), data.u64(recordOffset + 40), data.u64(recordOffset + 48))
    }
}
