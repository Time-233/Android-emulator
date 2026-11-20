import Foundation
import Compression

enum InflateError: Error {
    case badStream
    case truncated
    case tooLarge
}

/// DEFLATE 解压。
/// 优先使用系统 Compression 框架（快），如果系统接口对裸 deflate 的格式期望不一致，
/// 自动回落到纯 Swift 实现（慢一点，但结果确定）。
enum Inflate {
    static func decode(_ input: Data, expectedSize: Int) throws -> Data {
        if expectedSize <= 0 { return Data() }
        if let fast = try? systemDecode(input, expectedSize: expectedSize), fast.count == expectedSize {
            return fast
        }
        var inflator = RawInflate(input, limit: expectedSize)
        return try inflator.run()
    }

    private static func systemDecode(_ input: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: expectedSize)
        let produced = output.withUnsafeMutableBytes { (rawDst: UnsafeMutableRawBufferPointer) -> Int in
            guard let dst = rawDst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { (rawSrc: UnsafeRawBufferPointer) -> Int in
                guard let src = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                var stream = compression_stream(
                    dst_ptr: dst,
                    dst_size: expectedSize,
                    src_ptr: src,
                    src_size: input.count,
                    state: nil
                )
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                    return 0
                }
                defer { compression_stream_destroy(&stream) }
                var status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                var guardCount = 0
                while status == COMPRESSION_STATUS_OK && stream.dst_size > 0 && guardCount < 64 * 1024 {
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    guardCount += 1
                }
                if status != COMPRESSION_STATUS_END { return 0 }
                return expectedSize - stream.dst_size
            }
        }
        guard produced == expectedSize else { throw InflateError.badStream }
        return output
    }
}

/// 位读取器（低位在前，DEFLATE 的规则）
struct BitSource {
    private let bytes: [UInt8]
    private var pos: Int = 0
    private var bitBuf: UInt32 = 0
    private var bitCnt: Int = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    mutating func bits(_ n: Int) throws -> Int {
        if n == 0 { return 0 }
        while bitCnt < n {
            guard pos < bytes.count else { throw InflateError.truncated }
            bitBuf |= UInt32(bytes[pos]) << UInt32(bitCnt)
            pos += 1
            bitCnt += 8
        }
        let mask: UInt32 = ((UInt32(1) << UInt32(n)) - 1)
        let value = Int(bitBuf & mask)
        bitBuf >>= UInt32(n)
        bitCnt -= n
        return value
    }

    /// 丢弃到字节边界，并把已经预读的整字节退回
    mutating func alignToByte() {
        let partial = bitCnt % 8
        if partial != 0 {
            bitBuf >>= UInt32(partial)
            bitCnt -= partial
        }
        pos -= bitCnt / 8
        bitBuf = 0
        bitCnt = 0
    }

    mutating func rawBytes(_ n: Int) throws -> [UInt8] {
        guard bitCnt == 0 else { throw InflateError.badStream }
        guard pos + n <= bytes.count else { throw InflateError.truncated }
        let slice = Array(bytes[pos..<(pos + n)])
        pos += n
        return slice
    }
}

/// 规范 Huffman 表
struct HuffmanTable {
    private var count = [Int](repeating: 0, count: 16)
    private var symbol: [Int] = []

    init?(lengths: [Int]) {
        for length in lengths {
            guard length >= 0 && length <= 15 else { return nil }
            if length != 0 { count[length] += 1 }
        }
        var offsets = [Int](repeating: 0, count: 16)
        var i = 1
        while i < 16 {
            offsets[i] = offsets[i - 1] + count[i - 1]
            i += 1
        }
        symbol = [Int](repeating: 0, count: max(lengths.count, 1))
        for index in 0..<lengths.count {
            let length = lengths[index]
            if length != 0 {
                symbol[offsets[length]] = index
                offsets[length] += 1
            }
        }
    }

    func decode(_ source: inout BitSource) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        var length = 1
        while length <= 15 {
            code |= try source.bits(1)
            let current = count[length]
            if code - first < current {
                let target = index + code - first
                guard target >= 0 && target < symbol.count else { throw InflateError.badStream }
                return symbol[target]
            }
            index += current
            first = (first + current) << 1
            code <<= 1
            length += 1
        }
        throw InflateError.badStream
    }

    static let fixedLiteral: HuffmanTable = {
        var lengths = [Int](repeating: 8, count: 288)
        var i = 144
        while i < 256 { lengths[i] = 9; i += 1 }
        i = 256
        while i < 280 { lengths[i] = 7; i += 1 }
        return HuffmanTable(lengths: lengths)!
    }()

    static let fixedDistance: HuffmanTable = {
        let lengths = [Int](repeating: 5, count: 30)
        return HuffmanTable(lengths: lengths)!
    }()
}

/// 纯 Swift 的 DEFLATE 解压（RFC 1951）
struct RawInflate {
    private let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                              35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                               3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                            257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                             7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private var source: BitSource
    private var output: [UInt8] = []
    private let limit: Int

    init(_ data: Data, limit: Int) {
        self.source = BitSource(data)
        self.limit = limit > 0 ? limit : (1 << 26)
        self.output.reserveCapacity(min(max(self.limit, 1024), 1 << 20))
    }

    mutating func run() throws -> Data {
        var isLast = 0
        while true {
            isLast = try source.bits(1)
            let type = try source.bits(2)
            switch type {
            case 0: try readStored()
            case 1: try readBlock(literal: HuffmanTable.fixedLiteral, distance: HuffmanTable.fixedDistance)
            case 2: try readDynamic()
            default: throw InflateError.badStream
            }
            if isLast == 1 { break }
        }
        return Data(output)
    }

    private mutating func append(_ byte: UInt8) throws {
        guard output.count < limit + 1024 else { throw InflateError.tooLarge }
        output.append(byte)
    }

    private mutating func readStored() throws {
        source.alignToByte()
        let header = try source.rawBytes(4)
        let length = Int(header[0]) | (Int(header[1]) << 8)
        let nlength = Int(header[2]) | (Int(header[3]) << 8)
        guard (length ^ 0xFFFF) == nlength else { throw InflateError.badStream }
        let payload = try source.rawBytes(length)
        for byte in payload { try append(byte) }
    }

    private mutating func readBlock(literal: HuffmanTable, distance: HuffmanTable) throws {
        while true {
            let symbol = try literal.decode(&source)
            if symbol < 256 {
                try append(UInt8(symbol & 0xFF))
            } else if symbol == 256 {
                return
            } else {
                let index = symbol - 257
                guard index >= 0 && index < lengthBase.count else { throw InflateError.badStream }
                let length = lengthBase[index] + (try source.bits(lengthExtra[index]))
                let distSymbol = try distance.decode(&source)
                guard distSymbol >= 0 && distSymbol < distBase.count else { throw InflateError.badStream }
                let dist = distBase[distSymbol] + (try source.bits(distExtra[distSymbol]))
                guard dist > 0 && dist <= output.count else { throw InflateError.badStream }
                var i = 0
                while i < length {
                    let byte = output[output.count - dist]
                    try append(byte)
                    i += 1
                }
            }
        }
    }

    private mutating func readDynamic() throws {
        let hlit = try source.bits(5) + 257
        let hdist = try source.bits(5) + 1
        let hclen = try source.bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

        var codeLengths = [Int](repeating: 0, count: 19)
        var i = 0
        while i < hclen {
            codeLengths[order[i]] = try source.bits(3)
            i += 1
        }
        guard let codeTable = HuffmanTable(lengths: codeLengths) else { throw InflateError.badStream }

        var lengths: [Int] = []
        lengths.reserveCapacity(hlit + hdist)
        while lengths.count < hlit + hdist {
            let symbol = try codeTable.decode(&source)
            if symbol <= 15 {
                lengths.append(symbol)
            } else if symbol == 16 {
                guard let previous = lengths.last else { throw InflateError.badStream }
                let repeatCount = try source.bits(2) + 3
                var k = 0
                while k < repeatCount { lengths.append(previous); k += 1 }
            } else if symbol == 17 {
                let repeatCount = try source.bits(3) + 3
                var k = 0
                while k < repeatCount { lengths.append(0); k += 1 }
            } else if symbol == 18 {
                let repeatCount = try source.bits(7) + 11
                var k = 0
                while k < repeatCount { lengths.append(0); k += 1 }
            } else {
                throw InflateError.badStream
            }
            if lengths.count > hlit + hdist + 64 { throw InflateError.badStream }
        }

        let literalLengths = Array(lengths[0..<hlit])
        let distanceLengths = Array(lengths[hlit..<(hlit + hdist)])
        guard let literalTable = HuffmanTable(lengths: literalLengths) else { throw InflateError.badStream }
        guard let distanceTable = HuffmanTable(lengths: distanceLengths) else { throw InflateError.badStream }
        try readBlock(literal: literalTable, distance: distanceTable)
    }
}
