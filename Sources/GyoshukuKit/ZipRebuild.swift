import Foundation
internal import KaitoKit

// entry の解釈と descriptor の終端は KaitoKit だけが決める。
// ここで読む CD の byte 表は、未知の extra / comment / 属性を保存して再出力するためのもの。
enum ZipRebuild {
    static func write(source: ZipUpdateSource, layout: ZipUpdateLayout, reader: ArchiveReader,
                      output: FileHandle, removed: Set<Int>, renamed: [Int: String],
                      rawRecord: (ArchiveReader, ArchiveEntry) throws -> RawEntryRecord?) throws {
        var position: UInt64 = 0
        var offsets = [UInt64?](repeating: nil, count: reader.entries.count)
        var descriptorMarkers: Set<Int> = []
        try output.seek(toOffset: 0)
        func emit(_ bytes: Data) throws {
            try Task.checkCancellation()
            let next = try checkedAdd(position, UInt64(bytes.count))
            try output.write(contentsOf: bytes)
            position = next
        }
        func copy(_ range: Range<UInt64>) throws {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                let count = Int(min(range.upperBound - cursor, 256 * 1024))
                try emit(source.bytes(at: cursor, count: count))
                cursor += UInt64(count)
            }
        }
        for entry in reader.entries where !removed.contains(entry.index) {
            try Task.checkCancellation()
            guard let raw = try rawRecord(reader, entry) else {
                throw UpdaterError.nonRelocatableEntry(index: entry.index, name: entry.name,
                    reason: "rawRecord が nil のため独立して移動できません。削除・改名による再構築を拒否します")
            }
            let start = position
            // KaitoKit 0.4.0 は central の offset 専用 ZIP64 extra も descriptor の幅判定に使う。
            // 元が ZIP32 descriptor のときは、その追加で読取側の解釈が変わるため安全に断る。
            // descriptor を独自に再符号化して帳尻を合わせてはいけない。
            if start >= ZipRecords.limit, raw.formatSpecific["hasDataDescriptor"] == "true",
               raw.formatSpecific["isZIP64"] == "false" {
                throw UpdaterError.nonRelocatableEntry(index: entry.index, name: entry.name,
                    reason: "ZIP32 descriptor の移動先に ZIP64 offset が必要です。KaitoKit 0.4.0 の幅の解釈が変わるため再構築を拒否します")
            }
            offsets[entry.index] = start
            let wideDescriptor = raw.formatSpecific["hasDataDescriptor"] == "true"
                && raw.formatSpecific["isZIP64"] == "true"
            if let name = renamed[entry.index] {
                let header = try LocalHeader(source: source, raw: raw)
                if wideDescriptor && !header.hasZIP64 { descriptorMarkers.insert(entry.index) }
                let bytes = Data(name.utf8)
                let replacement = try header.renamed(bytes)
                if bytes.count == header.name.count {
                    // 同長なら record 全体を運び、local の名前・flag・名前用 extra だけを同じ位置で更新。
                    try copy(raw.recordRange)
                    try output.seek(toOffset: start)
                    try output.write(contentsOf: replacement)
                    try output.seek(toOffset: position)
                } else {
                    try emit(replacement)
                    // payload から descriptor 終端まで。幅の算術は一切持たない。
                    try copy(raw.payloadRange.lowerBound..<raw.recordRange.upperBound)
                }
            } else {
                if wideDescriptor {
                    let header = try LocalHeader(source: source, raw: raw)
                    if !header.hasZIP64 { descriptorMarkers.insert(entry.index) }
                }
                try copy(raw.recordRange)
            }
        }
        let centralOffset = position
        var cursor = layout.centralOffset
        let end = try checkedAdd(cursor, layout.centralSize)
        for entry in reader.entries {
            try Task.checkCancellation()
            let central = try CentralHeader(source: source, at: cursor, end: end)
            cursor += UInt64(central.byteCount)
            if let offset = offsets[entry.index] {
                guard let size = entry.uncompressedSize, let compressedSize = entry.compressedSize else {
                    throw UpdaterError.invalidArchive("ZIP entry のサイズがありません")
                }
                try emit(central.rebuilt(offset: offset, size: size, compressedSize: compressedSize,
                    name: renamed[entry.index].map { Data($0.utf8) },
                    preserveDescriptorMarker: descriptorMarkers.contains(entry.index)))
            }
        }
        guard cursor == end else { throw UpdaterError.invalidArchive("CD の終端と entry 数が一致しません") }
        let count = UInt64(reader.entries.count - removed.count)
        try emit(ZipRecords.end(count: count, centralSize: position - centralOffset,
                                centralOffset: centralOffset, comment: layout.comment))
        try output.truncate(atOffset: position)
        try output.synchronize()
    }

    private struct LocalHeader {
        var fixed: Data
        let name: Data
        let extra: Data
        var hasZIP64: Bool { extraFields(extra).contains { $0.id == 1 } }

        init(source: ZipUpdateSource, raw: RawEntryRecord) throws {
            fixed = try source.bytes(at: raw.recordRange.lowerBound, count: 30)
            let nameLength = Int(fixed.zip16(26))
            let extraLength = Int(fixed.zip16(28))
            let variableOffset = try checkedAdd(raw.recordRange.lowerBound, 30)
            guard fixed.zip32(0) == 0x04034B50,
                  try checkedAdd(variableOffset, UInt64(nameLength + extraLength)) == raw.payloadRange.lowerBound else {
                throw UpdaterError.invalidArchive("local header と rawRecord の payload 位置が一致しません")
            }
            name = try source.bytes(at: variableOffset, count: nameLength)
            extra = try source.bytes(at: variableOffset + UInt64(nameLength), count: extraLength)
        }

        func renamed(_ name: Data) throws -> Data {
            guard name.count <= Int(UInt16.max) else { throw WriterError.sizeOverflow }
            var result = fixed
            result.zipSet(fixed.zip16(6) | ZipRecords.flags, at: 6)
            result.zipSet(UInt16(name.count), at: 26)
            result.append(name)
            result.append(renamedExtra(extra))
            return result
        }
    }

    struct CentralHeader {
        let fixed: Data
        let name: Data
        let extra: Data
        let comment: Data
        var byteCount: Int { 46 + name.count + extra.count + comment.count }

        init(source: ZipUpdateSource, at offset: UInt64, end: UInt64) throws {
            guard offset <= end, end - offset >= 46 else { throw UpdaterError.invalidArchive("CD が途中で終わっています") }
            fixed = try source.bytes(at: offset, count: 46)
            guard fixed.zip32(0) == 0x02014B50 else { throw UpdaterError.invalidArchive("CD signature がありません") }
            let n = Int(fixed.zip16(28)), e = Int(fixed.zip16(30)), c = Int(fixed.zip16(32))
            guard UInt64(n + e + c) <= end - offset - 46 else { throw UpdaterError.invalidArchive("CD metadata が範囲外です") }
            name = try source.bytes(at: offset + 46, count: n)
            extra = try source.bytes(at: offset + 46 + UInt64(n), count: e)
            comment = try source.bytes(at: offset + 46 + UInt64(n + e), count: c)
        }

        func rebuilt(offset: UInt64, size: UInt64, compressedSize: UInt64, name newName: Data?,
                     preserveDescriptorMarker: Bool = false) throws -> Data {
            var zip64 = Data()
            if size >= ZipRecords.limit { zip64.le(size) }
            if compressedSize >= ZipRecords.limit { zip64.le(compressedSize) }
            if offset >= ZipRecords.limit { zip64.le(offset) }
            var extras = Data()
            if !zip64.isEmpty || preserveDescriptorMarker { extras.append(ZipRecords.field(1, zip64)) }
            // central だけの ZIP64 extra で幅が決まる descriptor もある。サイズの sentinel を
            // 不要に残す代わりに空の marker を保ち、KaitoKit が解決した幅を変えない。
            let fields = extraFields(extra)
            var consumed = 0
            for field in fields {
                if field.id != 1 { extras.append(extra.subdata(in: field.range)) }
                consumed = field.range.upperBound
            }
            // KaitoKit が許した末尾 padding も残す。新しい ZIP64 field は必ずその前に置く。
            extras.append(extra.dropFirst(consumed))
            if newName != nil { extras = renamedExtra(extras) }
            let name = newName ?? name
            guard name.count <= Int(UInt16.max), extras.count <= Int(UInt16.max) else { throw WriterError.sizeOverflow }
            var result = fixed
            if !zip64.isEmpty || preserveDescriptorMarker { result.zipSet(max(fixed.zip16(6), 45), at: 6) }
            if newName != nil { result.zipSet(fixed.zip16(8) | ZipRecords.flags, at: 8) }
            result.zipSet(UInt32(min(compressedSize, ZipRecords.limit)), at: 20)
            result.zipSet(UInt32(min(size, ZipRecords.limit)), at: 24)
            result.zipSet(UInt16(name.count), at: 28)
            result.zipSet(UInt16(extras.count), at: 30)
            result.zipSet(UInt16(0), at: 34)
            result.zipSet(UInt32(min(offset, ZipRecords.limit)), at: 42)
            result.append(name)
            result.append(extras)
            result.append(comment)
            return result
        }
    }

    private static func extraFields(_ data: Data) -> [(id: UInt16, range: Range<Int>)] {
        var fields: [(UInt16, Range<Int>)] = []
        var cursor = 0
        while data.count - cursor >= 4 {
            let length = Int(data.zip16(cursor + 2))
            guard length <= data.count - cursor - 4 else { break }
            let end = cursor + 4 + length
            fields.append((data.zip16(cursor), cursor..<end))
            cursor = end
        }
        return fields
    }

    private static func renamedExtra(_ extra: Data) -> Data {
        var result = extra
        // Unicode Path は旧名とその CRC を含む。padding ID へ置換し、同長改名でも
        // payload の位置を動かさず旧名の override を無効にする。他の extra は触らない。
        for field in extraFields(extra) where field.id == 0x7075 {
            result.zipSet(UInt16(0xFFFF), at: field.range.lowerBound)
        }
        return result
    }
}
