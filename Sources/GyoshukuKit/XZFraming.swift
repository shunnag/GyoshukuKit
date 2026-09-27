import Foundation

// 参照仕様: https://tukaani.org/xz/xz-file-format.txt (1.2.1)。
enum XZFraming {
    private static let outputSize = 256 * 1024
    private static let flags = Data([0, 1])

    static var streamHeader: Data {
        var header = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0])
        header.append(flags)
        header.le(updateCRC(0, flags))
        return header
    }

    static func emitBlock(_ compressed: XZLZMA2, crc: UInt32, emit: (Data) throws -> Void) throws -> Data {
        try Task.checkCancellation()
        var header = Data([0, 0xC0])
        header.append(Self.vli(UInt64(compressed.payload.count)))
        header.append(Self.vli(compressed.uncompressedSize))
        header.append(contentsOf: [0x21, 1, compressed.properties])
        while header.count % 4 != 0 { header.append(0) }
        header[0] = UInt8(header.count / 4)
        header.le(updateCRC(0, header))
        try emit(header)
        try slices(compressed.payload, emit: emit)
        var check = Data(count: (4 - compressed.payload.count % 4) % 4)
        check.le(crc)
        try emit(check)
        var record = Self.vli(UInt64(header.count + compressed.payload.count + 4))
        record.append(Self.vli(compressed.uncompressedSize))
        return record
    }

    static func emitIndexAndFooter(records: Data, blockCount: UInt64, emit: (Data) throws -> Void) throws {
        var prefix = Data([0])
        prefix.append(Self.vli(blockCount))
        let size = try checkedAdd(UInt64(prefix.count), UInt64(records.count))
        let padding = (4 - size % 4) % 4
        let indexSize = try checkedAdd(size, padding + 4)
        guard indexSize / 4 - 1 <= UInt64(UInt32.max) else { throw WriterError.sizeOverflow }
        var crc = updateCRC(0, prefix)
        try emit(prefix)
        try slices(records) {
            crc = updateCRC(crc, $0)
            try emit($0)
        }
        var tail = Data(count: Int(padding))
        crc = updateCRC(crc, tail)
        tail.le(crc)
        try emit(tail)
        var footer = Data()
        footer.le(UInt32(indexSize / 4 - 1))
        footer.append(Self.flags)
        var result = Data()
        result.le(updateCRC(0, footer))
        result.append(footer)
        result.append(contentsOf: [0x59, 0x5A])
        try emit(result)
    }

    private static func slices(_ data: Data, emit: (Data) throws -> Void) throws {
        for offset in stride(from: data.startIndex, to: data.endIndex, by: Self.outputSize) {
            try Task.checkCancellation()
            try emit(data[offset..<min(offset + Self.outputSize, data.endIndex)])
        }
    }

    static func vli(_ value: UInt64) -> Data {
        precondition(value < 1 << 63)
        var remaining = value
        var result = Data()
        repeat {
            result.append(UInt8(remaining & 0x7F) | (remaining >= 128 ? 0x80 : 0))
            remaining >>= 7
        } while remaining > 0
        return result
    }
}
