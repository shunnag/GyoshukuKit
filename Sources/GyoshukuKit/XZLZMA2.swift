import Foundation

// 参照仕様: https://tukaani.org/xz/xz-file-format.txt (1.2.1)。
// Apple の単一 block を移し替えるための framing parser。複数 block / filter は拒否する。
struct XZLZMA2 {
    let payload: Data
    let properties: UInt8
    let uncompressedSize: UInt64
    let payloadOffset: Int

    static func extract(_ container: Data) throws -> XZLZMA2 {
        let bytes = [UInt8](container)
        guard bytes.count >= 36, bytes.count % 4 == 0,
              bytes[0..<6].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0]),
              bytes[6] == 0, bytes[7] & 0xF0 == 0 else { throw WriterError.compression(-1) }
        try verifyCRC(bytes, range: 6..<8, at: 8)
        let checkSize: Int
        switch bytes[7] {
        case 0: checkSize = 0
        case 1: checkSize = 4
        case 4: checkSize = 8
        case 10: checkSize = 32
        default: throw WriterError.compression(-1)
        }

        var end = bytes.count
        while end > 12, bytes[end - 1] == 0 { end -= 1 }
        guard end >= 36, (bytes.count - end) % 4 == 0 else { throw WriterError.compression(-1) }
        let footer = end - 12
        guard bytes[(footer + 10)..<end].elementsEqual([0x59, 0x5A]),
              bytes[footer + 8] == bytes[6], bytes[footer + 9] == bytes[7] else {
            throw WriterError.compression(-1)
        }
        try verifyCRC(bytes, range: (footer + 4)..<(footer + 10), at: footer)
        let indexSize = (UInt64(uint32(bytes, at: footer + 4)) + 1) * 4
        // 単一 record の Index は最大でも 24 byte。巨大な偽 Index を CRC 用にコピーしない。
        guard indexSize >= 8, indexSize <= 24, indexSize <= UInt64(footer - 12) else { throw WriterError.compression(-1) }
        let indexStart = footer - Int(indexSize)
        try verifyCRC(bytes, range: indexStart..<(footer - 4), at: footer - 4)
        var index = Cursor(bytes: bytes, position: indexStart, end: footer - 4)
        guard try index.byte() == 0, try index.vli() == 1 else { throw WriterError.compression(-1) }
        let unpaddedSize = try index.vli()
        let unpackedSize = try index.vli()
        guard index.end - index.position < 4 else { throw WriterError.compression(-1) }
        try index.zeroPadding()

        let headerSize = (Int(bytes[12]) + 1) * 4
        let payloadStart = 12 + headerSize
        guard bytes[12] != 0, payloadStart <= indexStart else { throw WriterError.compression(-1) }
        try verifyCRC(bytes, range: 12..<(payloadStart - 4), at: payloadStart - 4)
        var header = Cursor(bytes: bytes, position: 13, end: payloadStart - 4)
        let flags = try header.byte()
        guard flags & 0x3F == 0 else { throw WriterError.compression(-1) }
        let declaredPackedSize = flags & 0x40 != 0 ? try header.vli() : nil
        let declaredUnpackedSize = flags & 0x80 != 0 ? try header.vli() : nil
        guard try header.vli() == 0x21, try header.vli() == 1 else { throw WriterError.compression(-1) }
        let properties = try header.byte()
        guard properties <= 40 else { throw WriterError.compression(-1) }
        try header.zeroPadding()

        // Index の Unpadded Size は header と check を含む。末尾の 0 を探すと LZMA2 終端まで削ってしまう。
        let overhead = UInt64(headerSize + checkSize)
        guard unpaddedSize > overhead, unpaddedSize <= UInt64(indexStart - 12) else {
            throw WriterError.compression(-1)
        }
        let padding = (4 - unpaddedSize % 4) % 4
        guard unpaddedSize + padding == UInt64(indexStart - 12) else { throw WriterError.compression(-1) }
        let packedSize = unpaddedSize - overhead
        guard declaredPackedSize == nil || declaredPackedSize == packedSize,
              declaredUnpackedSize == nil || declaredUnpackedSize == unpackedSize else {
            throw WriterError.compression(-1)
        }
        let payloadEnd = payloadStart + Int(packedSize)
        guard bytes[payloadEnd - 1] == 0,
              bytes[payloadEnd..<(payloadEnd + Int(padding))].allSatisfy({ $0 == 0 }) else {
            throw WriterError.compression(-1)
        }
        // check は 7z に持ち込まない。元データから計算した CRC を SubStreamsInfo へ別途保存する。
        return XZLZMA2(payload: Data(bytes[payloadStart..<payloadEnd]), properties: properties,
                       uncompressedSize: unpackedSize, payloadOffset: payloadStart)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    private static func verifyCRC(_ bytes: [UInt8], range: Range<Int>, at offset: Int) throws {
        guard updateCRC(0, Data(bytes[range])) == uint32(bytes, at: offset) else { throw WriterError.compression(-1) }
    }

    private struct Cursor {
        let bytes: [UInt8]
        var position: Int
        let end: Int

        mutating func byte() throws -> UInt8 {
            guard position < end else { throw WriterError.compression(-1) }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func vli() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 56, by: 7) {
                let next = try byte()
                value |= UInt64(next & 0x7F) << shift
                if next & 0x80 == 0 {
                    guard shift == 0 || next != 0 else { throw WriterError.compression(-1) }
                    return value
                }
            }
            throw WriterError.compression(-1)
        }

        mutating func zeroPadding() throws {
            while position < end {
                guard try byte() == 0 else { throw WriterError.compression(-1) }
            }
        }
    }
}
