import Foundation

struct AXMLAttribute {
    let namespace: String?
    let name: String
    let rawValue: String?
    let valueType: UInt8
    let data: UInt32
    let stringValue: String?

    var intValue: Int? {
        switch valueType {
        case 0x10, 0x11:
            return Int(Int32(bitPattern: data))
        case 0x12:
            return data != 0 ? 1 : 0
        default:
            if let stringValue = stringValue, let parsed = Int(stringValue) { return parsed }
            if let rawValue = rawValue, let parsed = Int(rawValue) { return parsed }
            return nil
        }
    }

    var boolValue: Bool? {
        if valueType == 0x12 { return data != 0 }
        if let stringValue = stringValue {
            if stringValue == "true" { return true }
            if stringValue == "false" { return false }
        }
        return nil
    }

    var isResourceReference: Bool { valueType == 0x01 }
}

final class AXMLNode {
    let name: String
    let namespace: String?
    var attributes: [AXMLAttribute] = []
    var children: [AXMLNode] = []
    var text: String = ""
    weak var parent: AXMLNode?

    init(name: String, namespace: String?) {
        self.name = name
        self.namespace = namespace
    }

    func attr(_ name: String) -> AXMLAttribute? {
        return attributes.first { $0.name == name }
    }

    func attrString(_ name: String) -> String? {
        guard let attribute = attr(name) else { return nil }
        if let raw = attribute.rawValue, !raw.isEmpty { return raw }
        if let value = attribute.stringValue, !value.isEmpty { return value }
        return nil
    }

    func attrInt(_ name: String) -> Int? {
        return attr(name)?.intValue
    }

    func kids(_ name: String) -> [AXMLNode] {
        return children.filter { $0.name == name }
    }

    func deep(_ name: String, into result: inout [AXMLNode]) {
        for child in children {
            if child.name == name { result.append(child) }
            child.deep(name, into: &result)
        }
    }

    func all(_ name: String) -> [AXMLNode] {
        var result: [AXMLNode] = []
        deep(name, into: &result)
        return result
    }

    func dump(_ depth: Int = 0) -> String {
        var line = String(repeating: "  ", count: depth) + "<\(name)"
        for attribute in attributes {
            let value = attribute.rawValue ?? attribute.stringValue ?? String(attribute.data)
            line += " \(attribute.name)=\"\(value)\""
        }
        line += ">\n"
        for child in children { line += child.dump(depth + 1) }
        return line
    }
}

enum AXMLParserError: Error {
    case notBinaryXML
    case truncated
    case badStringPool
}

/// Android 二进制 XML（AndroidManifest.xml / 资源 XML）解析器
final class BinaryXMLParser {
    private let data: Data
    private var strings: [String] = []
    private var resourceMap: [UInt32] = []

    init(data: Data) {
        self.data = data
    }

    convenience init(url: URL) throws {
        let raw = try Data(contentsOf: url)
        self.init(data: raw)
    }

    func parse() throws -> AXMLNode {
        guard data.count >= 8 else { throw AXMLParserError.truncated }
        let fileType = data.u16(0)
        guard fileType == 0x0003 else { throw AXMLParserError.notBinaryXML }
        var headerSize = Int(data.u16(2))
        if headerSize < 8 { headerSize = 8 }
        let fileSize = min(Int(data.u32(4)), data.count)

        var pointer = headerSize
        var stack: [AXMLNode] = []
        var root: AXMLNode?

        while pointer + 8 <= fileSize {
            let chunkType = data.u16(pointer)
            let chunkHeaderSize = Int(data.u16(pointer + 2))
            let chunkSize = Int(data.u32(pointer + 4))
            guard chunkSize >= 8, pointer + chunkSize <= fileSize else { break }

            switch chunkType {
            case 0x0001:
                try parseStringPool(at: pointer, headerSize: chunkHeaderSize, size: chunkSize)
            case 0x0180:
                parseResourceMap(at: pointer, headerSize: chunkHeaderSize, size: chunkSize)
            case 0x0102:
                if let node = parseStartElement(at: pointer, headerSize: chunkHeaderSize) {
                    if let parent = stack.last {
                        node.parent = parent
                        parent.children.append(node)
                    } else if root == nil {
                        root = node
                    }
                    stack.append(node)
                }
            case 0x0103:
                if !stack.isEmpty { stack.removeLast() }
            default:
                break
            }
            pointer += chunkSize
        }

        guard let rootNode = root else { throw AXMLParserError.truncated }
        return rootNode
    }

    private func parseStringPool(at base: Int, headerSize: Int, size: Int) throws {
        guard base + 28 <= data.count else { throw AXMLParserError.truncated }
        let stringCount = Int(data.u32(base + 8))
        let flags = data.u32(base + 16)
        let stringsStart = Int(data.u32(base + 20))
        let isUTF8 = (flags & 0x100) != 0

        guard stringCount >= 0, headerSize >= 8 else { throw AXMLParserError.badStringPool }
        var offsets: [Int] = []
        offsets.reserveCapacity(stringCount)
        var i = 0
        while i < stringCount {
            let offsetPosition = base + headerSize + i * 4
            guard offsetPosition + 4 <= data.count else { break }
            offsets.append(Int(data.u32(offsetPosition)))
            i += 1
        }

        strings = []
        strings.reserveCapacity(offsets.count)
        for offset in offsets {
            let start = base + stringsStart + offset
            guard start < data.count else { strings.append(""); continue }
            if isUTF8 {
                strings.append(readUTF8(at: start))
            } else {
                strings.append(readUTF16(at: start))
            }
        }
    }

    private func readUTF8(at start: Int) -> String {
        var pointer = start
        guard pointer < data.count else { return "" }
        var length = Int(data.u8(pointer))
        pointer += 1
        if (length & 0x80) != 0 {
            guard pointer < data.count else { return "" }
            length = ((length & 0x7F) << 8) | Int(data.u8(pointer))
            pointer += 1
        }
        guard pointer < data.count else { return "" }
        var byteLength = Int(data.u8(pointer))
        pointer += 1
        if (byteLength & 0x80) != 0 {
            guard pointer < data.count else { return "" }
            byteLength = ((byteLength & 0x7F) << 8) | Int(data.u8(pointer))
            pointer += 1
        }
        if byteLength > length { byteLength = length }
        return data.text(pointer, byteLength)
    }

    private func readUTF16(at start: Int) -> String {
        var pointer = start
        guard pointer + 2 <= data.count else { return "" }
        var length = Int(data.u16(pointer))
        pointer += 2
        if (length & 0x8000) != 0 {
            guard pointer + 2 <= data.count else { return "" }
            length = ((length & 0x7FFF) << 16) | Int(data.u16(pointer))
            pointer += 2
        }
        guard pointer + length * 2 <= data.count else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(length)
        var i = 0
        while i < length {
            units.append(data.u16(pointer + i * 2))
            i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func parseResourceMap(at base: Int, headerSize: Int, size: Int) {
        let count = max(0, (size - headerSize) / 4)
        resourceMap = []
        var i = 0
        while i < count {
            let position = base + headerSize + i * 4
            guard position + 4 <= data.count else { break }
            resourceMap.append(data.u32(position))
            i += 1
        }
    }

    private func resolveString(_ index: Int32) -> String? {
        guard index >= 0, Int(index) < strings.count else { return nil }
        return strings[Int(index)]
    }

    private func parseStartElement(at base: Int, headerSize: Int) -> AXMLNode? {
        guard base + 36 <= data.count else { return nil }
        let nsIndex = Int(data.i32(base + 16))
        let nameIndex = Int(data.i32(base + 20))
        let attributeStart = Int(data.u16(base + 24))
        let attributeSize = Int(data.u16(base + 26))
        let attributeCount = Int(data.u16(base + 28))

        let name = resolveString(Int32(nameIndex)) ?? "unknown"
        let namespace = nsIndex >= 0 ? resolveString(Int32(nsIndex)) : nil
        let node = AXMLNode(name: name, namespace: namespace)

        let attributesBase = base + 16 + attributeStart
        var i = 0
        while i < attributeCount {
            let position = attributesBase + i * max(attributeSize, 20)
            guard position >= 0, position + 20 <= data.count else { break }
            let attrNS = Int(data.i32(position))
            let attrName = Int(data.i32(position + 4))
            let rawValue = Int(data.i32(position + 8))
            let valueSize = Int(data.u16(position + 12))
            let valueRes0 = data.u8(position + 14)
            let valueType = data.u8(position + 15)
            let valueData = data.u32(position + 16)
            _ = valueSize
            _ = valueRes0

            let attributeName = resolveString(Int32(attrName)) ?? ""
            let attributeNS = attrNS >= 0 ? resolveString(Int32(attrNS)) : nil
            var rawString: String?
            if rawValue >= 0 { rawString = resolveString(Int32(rawValue)) }
            var typedString: String?
            if valueType == 0x03 { typedString = resolveString(Int32(bitPattern: valueData)) }

            let attribute = AXMLAttribute(
                namespace: attributeNS,
                name: attributeName,
                rawValue: rawString,
                valueType: valueType,
                data: valueData,
                stringValue: typedString
            )
            node.attributes.append(attribute)
            i += 1
        }
        return node
    }
}
