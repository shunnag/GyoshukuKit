import Foundation
@_spi(LHARawLayout) internal import KaitoKit

struct LHALayout {
    @TaskLocal static var testingKaitoKitMismatch = false

    struct Member: Equatable {
        let headerRange: Range<UInt64>
        let dataRange: Range<UInt64>
        let headerLevel: UInt8
        let method: String
        let osID: UInt8?
        let crc16: UInt16
    }
    struct Header {
        let member: Member
        let rawName: Data
        let originalSize: UInt64
    }
    struct Walk {
        let count: Int
        let end: UInt64
        let terminated: Bool
    }
    private let raw: LHAArchiveLayout
    var count: Int { raw.memberCount }
    var membersEnd: UInt64 { raw.endOfMembersOffset }
    var length: UInt64 { raw.archiveLength }

    func member(_ index: Int) throws -> Member {
        let value = try raw.member(at: index)
        return Member(headerRange: value.headerRange, dataRange: value.dataRange, headerLevel: value.headerLevel,
                      method: value.method, osID: value.osID, crc16: value.crc16)
    }

    static func rewriteReason(reader: ArchiveReader) -> String? {
        guard reader.format == .lha else { return "LHA ではありません" }
        do {
            guard let raw = try reader.lhaRawLayout() else { return "LHA layout unavailable" }
            return try reason(reader: reader, raw: raw)
        } catch { return "LHA layout unavailable: \(error)" }
    }

    /// 書き直しに回す理由。符号は design.md §4「LHA の更新」の表と同じ:
    /// R10 名前の encoding（宣言が shiftJIS 以外、または宣言なしで非 ASCII）、L1 SFX、L2 0 byte 以外の終端、
    /// L3 終端の後ろの非 0 byte、L4 非公開 member、L5 level 3、L6 incomplete entry、L7 data を持つ directory、
    /// L8 LHArk の lh7、L9 UInt32 を越える packed size。R8（walk 不可・SPI との不一致）は scan / walk が出す。
    private static func reason(reader: ArchiveReader, raw: LHAArchiveLayout) throws -> String? {
        if let encoding = reader.nameEncoding, encoding != .shiftJIS { return "R10: name encoding" }
        if reader.nameEncoding == nil, reader.entries.contains(where: { $0.rawName.bytes.contains { $0 >= 0x80 } }) {
            return "R10: non-ASCII names without archive CP932 encoding"
        }
        if raw.firstHeaderOffset != 0 { return "L1: SFX prefix" }
        guard case .zeroByte = raw.terminator else { return "L2: non-zero-byte terminator" }
        switch raw.trailingBytes {
        case .nonZero, .unchecked: return "L3: trailing bytes"
        default: break
        }
        if raw.unpublishedMemberCount > 0 { return "L4: unpublished members" }
        for index in 0..<raw.memberCount {
            let member = try raw.member(at: index)
            if member.headerLevel == 3 { return "L5: level 3" }
            guard let entryIndex = member.entryIndex, reader.entries.indices.contains(entryIndex) else {
                return "L4: unpublished members"
            }
            let entry = reader.entries[entryIndex]
            if entry.isIncomplete { return "L6: incomplete entry" }
            if entry.kind == .directory,
               member.method != LHARecords.Method.lhd || !member.dataRange.isEmpty || entry.uncompressedSize != 0 {
                return "L7: directory with data"
            }
            if member.method == "-lh7-", member.osID == 0x20 { return "L8: LHArk" }
            if member.dataRange.byteLength > UInt32.max { return "L9: packed size" }
        }
        return nil
    }

    static func scan(source: any ByteSource, reader: ArchiveReader) throws -> LHALayout {
        guard let raw = try reader.lhaRawLayout() else { throw refuse("layout unavailable") }
        if let reason = try reason(reader: reader, raw: raw) { throw UpdaterRouteError.requiresRewrite(reason: reason) }
        let layout = LHALayout(raw: raw)
        guard raw.archiveLength == source.length, raw.memberCount == reader.entries.count else { throw refuse("member count") }
        let result = try walk(source: source, range: 0..<source.length) { index, header in
            guard index < layout.count, !testingKaitoKitMismatch else { throw refuse("member count") }
            let expected = try raw.member(at: index)
            guard header.member == (try layout.member(index)), expected.entryIndex == index,
                  header.rawName.elementsEqual(reader.entries[index].rawName.bytes) else { throw refuse("reader mismatch") }
        }
        guard result.count == layout.count, result.terminated, result.end == raw.endOfMembersOffset,
              case .zeroByte(let end) = raw.terminator, end == result.end else { throw refuse("terminator") }
        return layout
    }

    static func walk(source: any ByteSource, range: Range<UInt64>,
                     visit: (Int, Header) throws -> Void) throws -> Walk {
        guard range.upperBound <= source.length else { throw refuse("walk bounds") }
        var cache = HeaderCache(source: source, length: range.upperBound)
        var offset = range.lowerBound, count = 0
        while offset < range.upperBound {
            if count & 1023 == 0 { try Task.checkCancellation() }
            if try cache.bytes(at: offset, count: 1)[0] == 0 { return Walk(count: count, end: offset, terminated: true) }
            let header = try parseHeader(at: offset, cache: &cache)
            guard header.member.dataRange.upperBound <= range.upperBound else { throw refuse("payload bounds") }
            try visit(count, header)
            offset = header.member.dataRange.upperBound
            count += 1
        }
        return Walk(count: count, end: offset, terminated: false)
    }

    private static func parseHeader(at offset: UInt64, cache: inout HeaderCache) throws -> Header {
        let first = try cache.bytes(at: offset, count: 21)
        let level = first[20]
        guard level <= 2, first[0] != 0 else { throw refuse("header level") }
        let length = level == 2 ? Int(first.le16(0)) : Int(first[0]) + 2
        guard length >= (level == 0 ? 24 : level == 1 ? 27 : 26) else { throw refuse("short header") }
        var header = try cache.bytes(at: offset, count: length)
        let methodBytes = header[2..<7]
        guard methodBytes.first == 0x2D, methodBytes.last == 0x2D,
              methodBytes.dropFirst().dropLast().allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw refuse("method")
        }
        let method = String(decoding: methodBytes, as: UTF8.self)
        var filename = Data(), directory = Data(), packed = UInt64(header.le32(7))
        var originalSize = UInt64(header.le32(11))
        let crc: UInt16, osID: UInt8?
        var headerCRC: (offset: Int, value: UInt16)?
        var extendedSize = false
        func extended(_ type: UInt8, _ data: Data, at start: Int) throws {
            switch type {
            case 0:
                guard data.count >= 2, headerCRC == nil else { throw refuse("header CRC field") }
                headerCRC = (start, data.le16(0))
            case 1: if !data.isEmpty { filename = data }
            case 2: if !data.isEmpty { directory = data }
            case 0x42:
                guard data.count == 16, !extendedSize else { throw refuse("extended sizes") }
                packed = data.le64(0); originalSize = data.le64(8); extendedSize = true
            default: break
            }
        }
        if level < 2 {
            guard header.dropFirst(2).reduce(UInt8(0), &+) == header[1] else { throw refuse("byte checksum") }
            let endName = 22 + Int(header[21])
            guard endName <= header.count - (level == 0 ? 2 : 5) else { throw refuse("name bounds") }
            filename = header.subdata(in: 22..<endName)
            crc = header.le16(endName)
            osID = level == 1 || endName + 2 < header.count ? header[endName + 2] : nil
            if level == 1 {
                let skip = packed
                var next = Int(header.le16(length - 2)), total: UInt64 = 0
                while next != 0 {
                    guard next >= 3, try checkedAdd(total, UInt64(next)) <= skip else { throw refuse("extension bounds") }
                    let start = header.count
                    let record = try cache.bytes(at: checkedAdd(offset, UInt64(start)), count: next)
                    try extended(record[0], record.subdata(in: 1..<(next - 2)), at: start + 1)
                    total += UInt64(next)
                    header.append(record)
                    next = Int(record.le16(record.count - 2))
                }
                if !extendedSize { packed = skip - total }
            }
        } else {
            crc = header.le16(21); osID = header[23]
            var cursor = 24
            while true {
                guard cursor <= header.count - 2 else { throw refuse("extension length bounds") }
                let next = Int(header.le16(cursor))
                if next == 0 { break }
                guard next >= 3, next <= header.count - cursor - 2 else { throw refuse("extension bounds") }
                try extended(header[cursor + 2], header.subdata(in: (cursor + 3)..<(cursor + next)), at: cursor + 3)
                cursor += next
            }
        }
        if let expected = headerCRC {
            header[expected.offset] = 0; header[expected.offset + 1] = 0
            guard LHACRC16.update(0, header) == expected.value else { throw refuse("header CRC") }
        }
        guard !directory.contains(0) else { throw refuse("directory NUL") }
        var raw = Data(directory.map { $0 == 0xFF ? 0x2F : $0 })
        let name = filename.prefix { $0 != 0 }.map { $0 == 0xFF ? 0x2F : $0 }
        if !raw.isEmpty, !name.isEmpty, raw.last != 0x2F { raw.append(0x2F) }
        raw.append(contentsOf: name)
        let dataStart = try checkedAdd(offset, UInt64(header.count))
        return Header(member: Member(headerRange: offset..<dataStart, dataRange: dataStart..<(try checkedAdd(dataStart, packed)),
                                    headerLevel: level, method: method, osID: osID, crc16: crc),
                      rawName: raw, originalSize: originalSize)
    }

    /// R8: 独立した header walk が構造を読めない、または KaitoKit の SPI / 公開 entry と一致しない。
    private static func refuse(_ reason: String) -> UpdaterRouteError { .requiresRewrite(reason: "R8: \(reason)") }

    private struct HeaderCache {
        let source: any ByteSource
        let length: UInt64
        var start: UInt64 = 0
        var data = Data()
        mutating func bytes(at offset: UInt64, count: Int) throws -> Data {
            guard offset <= length, UInt64(count) <= length - offset else { throw refuse("header bounds") }
            if offset >= start, offset - start <= data.count, UInt64(count) <= UInt64(data.count) - (offset - start) {
                let index = Int(offset - start)
                return data.subdata(in: index..<(index + count))
            }
            let size = max(count, Int(min(4096, length - offset)))
            var bytes = Data(count: size)
            try bytes.withUnsafeMutableBytes { buffer in
                var filled = 0
                while filled < size {
                    let actual = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]), at: offset + UInt64(filled))
                    guard actual > 0, actual <= size - filled else { throw refuse("short header read") }
                    filled += actual
                }
            }
            start = offset; data = bytes
            return bytes.subdata(in: 0..<count)
        }
    }
}
