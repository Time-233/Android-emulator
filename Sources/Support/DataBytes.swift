import Foundation

/// 直接按字节偏移读取的小工具（APK / ZIP / AXML 共用）
extension Data {
    func u8(_ i: Int) -> UInt8 {
        return self[self.startIndex + i]
    }

    func u16(_ i: Int) -> UInt16 {
        return UInt16(self.u8(i)) | (UInt16(self.u8(i + 1)) << 8)
    }

    func u32(_ i: Int) -> UInt32 {
        return UInt32(self.u8(i))
            | (UInt32(self.u8(i + 1)) << 8)
            | (UInt32(self.u8(i + 2)) << 16)
            | (UInt32(self.u8(i + 3)) << 24)
    }

    func i32(_ i: Int) -> Int32 {
        return Int32(bitPattern: self.u32(i))
    }

    func u64(_ i: Int) -> UInt64 {
        return UInt64(self.u32(i)) | (UInt64(self.u32(i + 4)) << 32)
    }

    /// 读取 UTF-8 字符串，失败退回 Latin1
    func text(_ offset: Int, _ length: Int) -> String {
        guard length > 0, offset >= 0, offset + length <= count else { return "" }
        let start = self.startIndex + offset
        let slice = self[start..<(start + length)]
        let raw = Data(slice)
        if let value = String(data: raw, encoding: .utf8) { return value }
        if let value = String(data: raw, encoding: .isoLatin1) { return value }
        return ""
    }
}
