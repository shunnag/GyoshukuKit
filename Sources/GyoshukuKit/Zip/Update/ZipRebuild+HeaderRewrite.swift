import Foundation

// 既存 record の local / central header を byte 表から組み直す。改名と ZIP64 extra の再配置を扱い、
// 名前以外の欄・未知の extra・comment はそのまま保つ。tar の TarHeaderRewrite に対応する。
extension ZipRebuild {
    struct LocalHeader {
        var fixed: Data
        let name: Data
        let extra: Data
        var hasZIP64: Bool { extraFields(extra).contains { $0.id == ZipRecords.ExtraID.zip64 } }

        init(source: ArchiveFileSource, layout raw: ZipRecordLayout) throws {
            let fixedLength = ZipRecords.FixedLength.local
            let length = raw.payloadRange.lowerBound - raw.recordRange.lowerBound
            guard length >= UInt64(fixedLength), length <= UInt64(Int.max) else {
                throw UpdaterError.invalidArchive("local header と rawRecord の payload 位置が一致しません")
            }
            let bytes = try source.bytes(at: raw.recordRange.lowerBound, count: Int(length))
            fixed = bytes.subdata(in: 0..<fixedLength)
            let nameLength = Int(fixed.zip16(26))
            let extraLength = Int(fixed.zip16(28))
            let variableOffset = try checkedAdd(raw.recordRange.lowerBound, UInt64(fixedLength))
            guard fixed.zip32(0) == ZipRecords.Signature.local,
                  try checkedAdd(variableOffset, UInt64(nameLength + extraLength)) == raw.payloadRange.lowerBound else {
                throw UpdaterError.invalidArchive("local header と rawRecord の payload 位置が一致しません")
            }
            name = bytes.subdata(in: fixedLength..<(fixedLength + nameLength))
            extra = bytes.subdata(in: (fixedLength + nameLength)..<bytes.count)
        }

        func renamed(_ name: Data) throws -> Data {
            guard name.count <= Int(UInt16.max) else { throw WriterError.sizeOverflow }
            var result = fixed
            result.zipSet(fixed.zip16(6) | ZipRecords.flags, at: 6)
            result.zipSet(UInt16(name.count), at: 26)
            result.append(name)
            result.append(try renamedExtra(extra))
            return result
        }
    }

    struct CentralHeader {
        let fixed: Data
        let name: Data
        let extra: Data
        let comment: Data
        var byteCount: Int { ZipRecords.FixedLength.central + name.count + extra.count + comment.count }

        init(source: ArchiveFileSource, at offset: UInt64, end: UInt64) throws {
            let fixedLength = UInt64(ZipRecords.FixedLength.central)
            guard offset <= end, end - offset >= fixedLength else { throw UpdaterError.invalidArchive("CD が途中で終わっています") }
            fixed = try source.bytes(at: offset, count: Int(fixedLength))
            guard fixed.zip32(0) == ZipRecords.Signature.central else { throw UpdaterError.invalidArchive("CD signature がありません") }
            let n = Int(fixed.zip16(28)), e = Int(fixed.zip16(30)), c = Int(fixed.zip16(32))
            guard UInt64(n + e + c) <= end - offset - fixedLength else { throw UpdaterError.invalidArchive("CD metadata が範囲外です") }
            name = try source.bytes(at: offset + fixedLength, count: n)
            extra = try source.bytes(at: offset + fixedLength + UInt64(n), count: e)
            comment = try source.bytes(at: offset + fixedLength + UInt64(n + e), count: c)
        }

        init(bytes: Data, range: Range<Int>? = nil) throws {
            let fixedLength = ZipRecords.FixedLength.central
            let range = range ?? bytes.startIndex..<bytes.endIndex
            let start = range.lowerBound
            guard range.count >= fixedLength else { throw UpdaterError.invalidArchive("CD が途中で終わっています") }
            guard bytes.zip32(start) == ZipRecords.Signature.central else { throw UpdaterError.invalidArchive("CD signature がありません") }
            let n = Int(bytes.zip16(start + 28)), e = Int(bytes.zip16(start + 30)), c = Int(bytes.zip16(start + 32))
            guard n + e + c <= range.count - fixedLength else { throw UpdaterError.invalidArchive("CD metadata が範囲外です") }
            fixed = bytes.subdata(in: start..<(start + fixedLength))
            name = bytes.subdata(in: (start + fixedLength)..<(start + fixedLength + n))
            extra = bytes.subdata(in: (start + fixedLength + n)..<(start + fixedLength + n + e))
            comment = bytes.subdata(in: (start + fixedLength + n + e)..<(start + fixedLength + n + e + c))
        }

        func rebuilt(offset: UInt64, size: UInt64, compressedSize: UInt64, name newName: Data?,
                     preserveDescriptorMarker: Bool = false) throws -> Data {
            var zip64 = Data()
            if size >= ZipRecords.limit { zip64.le(size) }
            if compressedSize >= ZipRecords.limit { zip64.le(compressedSize) }
            if offset >= ZipRecords.limit { zip64.le(offset) }
            var extras = Data()
            if !zip64.isEmpty || preserveDescriptorMarker { extras.append(ZipRecords.field(ZipRecords.ExtraID.zip64, zip64)) }
            // central だけの ZIP64 extra で幅が決まる descriptor もある。サイズの sentinel を
            // 不要に残す代わりに空の marker を保ち、KaitoKit が解決した幅を変えない。
            let fields = extraFields(extra)
            var consumed = 0
            for field in fields {
                if field.id != ZipRecords.ExtraID.zip64 { extras.append(extra.subdata(in: field.range)) }
                consumed = field.range.upperBound
            }
            // KaitoKit が許した末尾 padding も残す。新しい ZIP64 field は必ずその前に置く。
            // 原本と記憶域を共有する位置 0 でない空の slice を残さない（macOS 26 の Foundation の trap 予防。append(_: Data) の前に複製する）。
            extras.append(Data(extra.dropFirst(consumed)))
            if newName != nil { extras = try renamedExtra(extras) }
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

    static func extraFields(_ data: Data) -> [(id: UInt16, range: Range<Int>)] {
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

    static func renamedExtra(_ extra: Data) throws -> Data {
        var result = extra
        var consumed = 0
        for field in extraFields(extra) {
            switch field.id {
            case ZipRecords.ExtraID.infoZipUnicodePath:
                // 長さを保って旧名と CRC を消し、同長改名の payload 位置を維持する。
                result.zipSet(ZipRecords.ExtraID.reservedPadding, at: field.range.lowerBound)
                result.resetBytes(in: (field.range.lowerBound + 4)..<field.range.upperBound)
            case let id where ZipRecords.ExtraID.nameBearing.contains(id):
                // 名前と他の metadata が混在し得る拡張は、黙って捨てず改名を拒否する。
                throw UpdaterError.invalidArchive(String(format:
                    "名前を含む ZIP extra field 0x%04X を安全に更新できないため改名できません", field.id))
            default: break
            }
            consumed = field.range.upperBound
        }
        // CD では未解析の末尾も許されるが、旧名を含まないとは保証できない。
        guard extra.dropFirst(consumed).allSatisfy({ $0 == 0 }) else {
            throw UpdaterError.invalidArchive("ZIP extra field の末尾を解析できないため改名できません")
        }
        return result
    }
}
