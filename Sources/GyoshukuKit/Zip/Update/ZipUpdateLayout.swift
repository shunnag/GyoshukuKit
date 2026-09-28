import Foundation

// entry の parser は KaitoKit に任せる。ここでは更新に必要な終端の範囲と編集用門番だけを検査する。
struct ZipUpdateLayout {
    let centralOffset: UInt64
    let centralSize: UInt64
    let count: UInt64
    let comment: Data
    let endBytes: Data?

    init(source: ArchiveFileSource) throws {
        func refuse(_ gate: UpdateGatekeeper) throws -> Never {
            throw UpdaterError.editingRefused(gatekeeper: gate, reason: gate.reason)
        }
        // KaitoKit が読む trailing data の上限と同じ。攻撃者のサイズで確保しない。
        let trailingLimit = 1_048_576
        let endLength = ZipRecords.FixedLength.end
        let locatorLength = ZipRecords.FixedLength.locator64
        let tailSize = Int(min(source.length, UInt64(endLength + 65_535 + trailingLimit)))
        guard tailSize >= endLength else { throw UpdaterError.invalidArchive("EOCD がありません") }
        let tail = try source.bytes(at: source.length - UInt64(tailSize), count: tailSize)
        var found: Int?
        var endsAtEOF = 0
        var enclosed = false
        for index in stride(from: tail.count - endLength, through: 0, by: -1) {
            guard tail[index] == 0x50, tail.zip32(index) == ZipRecords.Signature.end else { continue }
            let commentEnd = index + endLength + Int(tail.zip16(index + 20))
            guard commentEnd <= tail.count, tail.count - commentEnd <= trailingLimit else { continue }
            if commentEnd == tail.count { endsAtEOF += 1 }
            if let chosen = found {
                // 選んだ header 自体が以前の comment 内なら、reader の fallback と解釈が分岐し得る。
                if index + endLength <= chosen, chosen + endLength <= commentEnd { enclosed = true }
            } else { found = index }
        }
        guard let end = found else { throw UpdaterError.invalidArchive("EOCD がありません") }
        guard endsAtEOF <= 1, !enclosed else { try refuse(.ambiguousEndRecord) }
        // 分割 ZIP の最終巻には先頭 local header がない場合があるため、SFX より先に判定する。
        guard tail.zip16(end + 4) == 0, tail.zip16(end + 6) == 0,
              tail.zip16(end + 8) == tail.zip16(end + 10) else {
            throw UpdaterError.invalidArchive("分割 ZIP は編集できません")
        }
        let first = try source.bytes(at: 0, count: 4).zip32(0)
        guard first == ZipRecords.Signature.local || first == ZipRecords.Signature.end || first == ZipRecords.Signature.end64 else {
            try refuse(.sfxPrefix)
        }
        let commentEnd = end + endLength + Int(tail.zip16(end + 20))
        guard commentEnd == tail.count else { try refuse(.trailingData) }
        let endOffset = source.length - UInt64(tailSize) + UInt64(end)
        var count = UInt64(tail.zip16(end + 10))
        var size = UInt64(tail.zip32(end + 12))
        var offset = UInt64(tail.zip32(end + 16))
        var directoryEnd = endOffset
        let locator = endOffset >= UInt64(locatorLength)
            ? try source.bytes(at: endOffset - UInt64(locatorLength), count: locatorLength) : Data()
        if locator.count == locatorLength, locator.zip32(0) == ZipRecords.Signature.locator64 {
            guard locator.zip32(4) == 0, locator.zip32(16) == 1 else {
                throw UpdaterError.invalidArchive("ZIP64 locator が単一 volume ではありません")
            }
            let position = locator.zip64(8)
            let record = try source.bytes(at: position, count: ZipRecords.FixedLength.end64)
            guard record.zip32(0) == ZipRecords.Signature.end64, record.zip64(4) >= 44,
                  try checkedAdd(position, checkedAdd(12, record.zip64(4))) == endOffset - UInt64(locatorLength),
                  record.zip32(16) == 0, record.zip32(20) == 0,
                  record.zip64(24) == record.zip64(32),
                  count == 65_535 || count == record.zip64(32),
                  size == ZipRecords.limit || size == record.zip64(40),
                  offset == ZipRecords.limit || offset == record.zip64(48) else {
                throw UpdaterError.invalidArchive("ZIP64 終端が矛盾しています")
            }
            count = record.zip64(32)
            size = record.zip64(40)
            offset = record.zip64(48)
            directoryEnd = position
        } else if count == 65_535 || size == ZipRecords.limit || offset == ZipRecords.limit {
            throw UpdaterError.invalidArchive("ZIP64 終端が必要です")
        }
        // 空書庫には CD signature が存在しない。offset/size/count が全て 0 の正規形だけ許す。
        if count == 0 {
            guard offset == 0, size == 0, directoryEnd == 0 else {
                throw UpdaterError.invalidArchive("空 ZIP の終端が矛盾しています")
            }
        } else {
            guard offset <= source.length, source.length - offset >= 4,
                  try source.bytes(at: offset, count: 4).zip32(0) == ZipRecords.Signature.central else {
                try refuse(.centralDirectoryOffset)
            }
        }
        guard offset <= directoryEnd, size == directoryEnd - offset,
              count <= size / UInt64(ZipRecords.FixedLength.central) else {
            throw UpdaterError.invalidArchive("CD の範囲または entry 数が矛盾しています")
        }
        centralOffset = offset
        centralSize = size
        self.count = count
        comment = tail.subdata(in: (end + endLength)..<commentEnd)
        endBytes = directoryEnd == endOffset ? tail.subdata(in: end..<commentEnd) : nil
    }
}
