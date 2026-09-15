import Foundation

// 参照仕様: https://www.7-zip.org/7z.html と LZMA SDK DOC/7zFormat.txt (18.06)。
// folder は非空ファイルと一対一。header は平文か AES の EncodedHeader を選べる。
enum SevenZipRecords {
    struct Entry {
        let name: String
        let mode: UInt16
        let size: UInt64
        let mtime: UInt64
        var packedSize: UInt64 = 0
        var compressedSize: UInt64 = 0
        var properties: UInt8 = 0
        var crc: UInt32 = 0
        var aesProperties: Data?

        var isDirectory: Bool { mode & 0xF000 == 0x4000 }
    }

    static func timestamp(_ date: Date) throws -> UInt64 {
        let seconds = floor(date.timeIntervalSince1970)
        let since1601 = seconds + 11_644_473_600
        guard since1601.isFinite, since1601 >= 0,
              since1601 <= Double(UInt64.max / 10_000_000) else { throw WriterError.invalidDate }
        // Double で tick まで掛けると下位 bit を丸める。公開 API の秒切り捨て後は整数で換算する。
        return UInt64(since1601) * 10_000_000
    }

    static func signature(packedSize: UInt64, header: Data) -> Data {
        var start = Data()
        start.le(packedSize)
        start.le(UInt64(header.count))
        start.le(checksum(header))
        var result = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])
        result.le(checksum(start))
        result.append(start)
        return result
    }

    static func header(_ entries: [Entry]) throws -> Data {
        var result = Data([0x01])
        let streams = entries.filter { $0.size > 0 }
        if !streams.isEmpty {
            result.append(contentsOf: [0x04, 0x06]) // MainStreamsInfo, PackInfo
            result.append(number(0))
            result.append(number(UInt64(streams.count)))
            result.append(0x09)
            for entry in streams {
                try Task.checkCancellation()
                result.append(number(entry.packedSize))
            }
            result.append(contentsOf: [0x00, 0x07, 0x0B])
            result.append(number(UInt64(streams.count)))
            result.append(0) // inline folders
            for entry in streams {
                try Task.checkCancellation()
                if let properties = entry.aesProperties {
                    // 7zz と同じ decoder 順: packed → AES (0) → LZMA2 (1) → file。
                    result.append(2)
                    result.append(aesCoder(properties))
                    result.append(contentsOf: [0x21, 0x21, 1, entry.properties, 1, 0])
                    // bind pair は input 1 ← output 0。唯一の packed input 0 は暗黙。
                } else {
                    result.append(contentsOf: [1, 0x21, 0x21, 1, entry.properties])
                }
            }
            result.append(0x0C)
            for entry in streams {
                if entry.aesProperties != nil { result.append(number(entry.compressedSize)) }
                result.append(number(entry.size))
            }
            result.append(contentsOf: [0x00, 0x08, 0x0A, 1])
            // folder CRC を省略し、全 substream の CRC をここで定義する。
            // folder ごとの stream 数の既定値は 1、最後の stream の size は unpack size から決まる。
            for entry in streams { result.le(entry.crc) }
            result.append(contentsOf: [0x00, 0x00])
        }
        if !entries.isEmpty {
            result.append(0x05)
            result.append(number(UInt64(entries.count)))
            let empty = entries.filter { $0.size == 0 }
            if !empty.isEmpty {
                property(0x0E, bits(entries.map { $0.size == 0 }), to: &result)
                // EmptyFile の添字は全 entry ではなく EmptyStream が立った entry だけを数える。
                property(0x0F, bits(empty.map { !$0.isDirectory }), to: &result)
            }
            var names = Data([0])
            var times = Data([1, 0])
            var attributes = Data([1, 0])
            for entry in entries {
                try Task.checkCancellation()
                for unit in entry.name.utf16 { names.le(unit) }
                names.le(UInt16(0))
                times.le(entry.mtime)
                // 0x8000 は Unix mode がある印。type も含め、Unix の実行 bit / symlink を復元させる。
                attributes.le(UInt32(entry.mode) << 16 | 0x8000 | (entry.isDirectory ? 0x10 : 0x20))
            }
            property(0x11, names, to: &result)
            property(0x14, times, to: &result)
            property(0x15, attributes, to: &result)
            result.append(0)
        }
        result.append(0)
        return result
    }

    static func encodedHeader(packOffset: UInt64, packedSize: UInt64, unpackedSize: UInt64,
                              crc: UInt32, properties: Data) -> Data {
        var result = Data([0x17, 0x06]) // EncodedHeader, PackInfo
        result.append(number(packOffset))
        result.append(contentsOf: [1, 0x09])
        result.append(number(packedSize))
        result.append(contentsOf: [0, 0x07, 0x0B, 1, 0, 1]) // UnpackInfo: inline folder, one coder
        result.append(aesCoder(properties))
        result.append(0x0C)
        result.append(number(unpackedSize))
        result.append(contentsOf: [0x0A, 1]) // folder CRC verifies decrypted header, including wrong passwords
        result.le(crc)
        result.append(contentsOf: [0, 0])
        return result
    }

    private static func aesCoder(_ properties: Data) -> Data {
        var result = Data([0x24, 0x06, 0xF1, 0x07, 0x01])
        result.append(number(UInt64(properties.count)))
        result.append(properties)
        return result
    }

    static func number(_ value: UInt64) -> Data {
        var first: UInt8 = 0
        var mask: UInt8 = 0x80
        for extra in 0..<8 {
            if value < UInt64(1) << (7 * (extra + 1)) {
                var result = Data([first | UInt8(value >> (8 * extra))])
                for index in 0..<extra { result.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
                return result
            }
            first |= mask
            mask >>= 1
        }
        var result = Data([0xFF])
        result.le(value)
        return result
    }

    static func checksum(_ data: Data) -> UInt32 {
        // zlib の一回の入力長は uInt。大きな header でも長さを切り詰めない。
        var crc: UInt32 = 0
        for offset in stride(from: 0, to: data.count, by: 256 * 1024) {
            let start = data.startIndex + offset
            crc = updateCRC(crc, data.subdata(in: start..<min(start + 256 * 1024, data.endIndex)))
        }
        return crc
    }

    private static func bits(_ values: [Bool]) -> Data {
        var result = Data(count: (values.count + 7) / 8)
        for (index, value) in values.enumerated() where value { result[index / 8] |= 0x80 >> (index % 8) }
        return result
    }

    private static func property(_ id: UInt8, _ value: Data, to result: inout Data) {
        result.append(id)
        result.append(number(UInt64(value.count)))
        result.append(value)
    }
}
