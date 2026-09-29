import Foundation
@_spi(ZipRawLayout) internal import KaitoKit

struct ZipRecordLayout: Sendable, Equatable {
    let recordRange: Range<UInt64>
    let payloadRange: Range<UInt64>
    let hasDataDescriptor: Bool
    let centralHasZIP64Extra: Bool
    let localHasZIP64Extra: Bool
    let encryption: ZipRawEncryption
    let storedCRC32: UInt32
    let compressionMethod: UInt16
    var isZIP64: Bool { centralHasZIP64Extra || localHasZIP64Extra }
}

extension ZipRecordLayout {
    init(_ spi: ZipRawRecordLayout) {
        recordRange = spi.recordRange
        payloadRange = spi.payloadRange
        hasDataDescriptor = spi.hasDataDescriptor
        centralHasZIP64Extra = spi.centralHasZIP64Extra
        localHasZIP64Extra = spi.localHasZIP64Extra
        encryption = spi.encryption
        storedCRC32 = spi.storedCRC32
        compressionMethod = spi.compressionMethod
    }
}

struct ZipValidatedDirectory {
    let bytes: Data
    let records: [ZipValidatedRecord]
}

struct ZipValidatedRecord {
    let centralRange: Range<Int>
    let layout: ZipRecordLayout
    let canonical: Bool

    func usesFastPath(offset: UInt64, renamed: Bool, marker: Bool) -> Bool {
        canonical && !renamed && !marker && offset < ZipRecords.limit
    }
}

enum ZipCentralDirectory {
    private struct Header {
        let nameLength: Int
        let extraLength: Int
        let variableLength: Int
        let localOffset32: UInt32
        let zip64OffsetPosition: Int

        init(_ bytes: Data) throws {
            guard bytes.count == ZipRecords.FixedLength.central else {
                throw UpdaterError.invalidArchive("CD record の signature がありません")
            }
            try self.init(bytes, at: 0)
        }

        init(_ bytes: Data, at cursor: Int) throws {
            guard bytes.count - cursor >= ZipRecords.FixedLength.central,
                  bytes.le32(cursor) == ZipRecords.Signature.central else {
                throw UpdaterError.invalidArchive("CD record の signature がありません")
            }
            nameLength = Int(bytes.le16(cursor + 28))
            extraLength = Int(bytes.le16(cursor + 30))
            variableLength = nameLength + extraLength + Int(bytes.le16(cursor + 32))
            localOffset32 = bytes.le32(cursor + 42)
            zip64OffsetPosition = (bytes.le32(cursor + 24) == UInt32.max ? 8 : 0)
                + (bytes.le32(cursor + 20) == UInt32.max ? 8 : 0)
        }

        func localOffset(bytes: Data, at cursor: Int) throws -> UInt64 {
            guard localOffset32 == UInt32.max else { return UInt64(localOffset32) }
            var index = cursor + ZipRecords.FixedLength.central + nameLength
            let end = index + extraLength
            while end - index >= 4 {
                let length = Int(bytes.le16(index + 2))
                guard length <= end - index - 4 else { break }
                if bytes.le16(index) == ZipRecords.ExtraID.zip64 {
                    guard length >= zip64OffsetPosition + 8 else { break }
                    return bytes.le64(index + 4 + zip64OffsetPosition)
                }
                index += 4 + length
            }
            throw UpdaterError.invalidArchive("CD の ZIP64 local-header offset がありません")
        }
    }

    // validate 自体は取消しを検査しない。KaitoKit の解析は取消し済み Task で CancellationError を投げる。
    @discardableResult
    static func validate(source: ArchiveFileSource, reader: ArchiveReader,
                         centralOffset: UInt64, centralSize: UInt64,
                         maximumCentralSize: UInt64 = ReadLimits().maxTotalMetadataSize) throws -> ZipValidatedDirectory {
        guard centralOffset <= source.length, centralSize <= source.length - centralOffset else {
            throw UpdaterError.invalidArchive("CD の範囲がファイル範囲外です")
        }
        guard centralSize <= maximumCentralSize, centralSize <= UInt64(Int.max) else {
            throw UpdaterError.invalidArchive("CD のサイズが metadata の上限を超えています")
        }
        let bytes = try source.bytes(at: centralOffset, count: Int(centralSize))
        let end = bytes.count
        let fixedLength = ZipRecords.FixedLength.central
        var cursor = 0
        var records: [ZipValidatedRecord] = []
        records.reserveCapacity(reader.entries.count)
        for entry in reader.entries {
            guard cursor <= end, end - cursor >= fixedLength else {
                throw UpdaterError.invalidArchive("CD record が途中で終わっています")
            }
            let header = try Header(bytes, at: cursor)
            guard header.variableLength <= end - cursor - fixedLength else {
                throw UpdaterError.invalidArchive("CD record の可変長領域が範囲外です")
            }
            let offset = try header.localOffset(bytes: bytes, at: cursor)
            let record: ZipRecordLayout?
            do { record = try reader.zipRawRecordLayout(at: entry.index).map(ZipRecordLayout.init) }
            catch let error as KaitoError {
                throw UpdaterError.invalidArchive("ZIP local record を検証できません: \(entry.name): \(error)")
            }
            guard let record else {
                throw UpdaterError.invalidArchive("ZIP local record の範囲がありません: \(entry.name)")
            }
            guard offset == record.recordRange.lowerBound else {
                throw UpdaterError.invalidArchive("CD の local-header offset と KaitoKit が一致しません: \(entry.name)")
            }
            guard record.recordRange.upperBound <= centralOffset else {
                throw UpdaterError.invalidArchive("CD の開始位置が local record の終端より前です: \(entry.name)")
            }
            let extraStart = cursor + fixedLength + header.nameLength
            let extra = bytes.subdata(in: extraStart..<(extraStart + header.extraLength))
            let hasZIP64 = ZipRebuild.extraFields(extra).contains { $0.id == ZipRecords.ExtraID.zip64 }
            guard hasZIP64 == record.centralHasZIP64Extra else {
                throw UpdaterError.invalidArchive("CD の ZIP64 extra の解釈が KaitoKit と一致しません: \(entry.name)")
            }
            let canonical = !hasZIP64 && bytes.le32(cursor + 20) != UInt32.max
                && bytes.le32(cursor + 24) != UInt32.max
                && entry.compressedSize == UInt64(bytes.le32(cursor + 20))
                && entry.uncompressedSize == UInt64(bytes.le32(cursor + 24))
                && bytes.le16(cursor + 34) == 0 && header.localOffset32 != UInt32.max
            let next = cursor + fixedLength + header.variableLength
            records.append(ZipValidatedRecord(centralRange: cursor..<next, layout: record, canonical: canonical))
            cursor = next
        }
        guard cursor == end else {
            throw UpdaterError.invalidArchive("CD の walk 終端と宣言されたサイズが一致しません")
        }
        return ZipValidatedDirectory(bytes: bytes, records: records)
    }

    // copyCentral の chunk 境界に依存せず、固定 header 46 byte だけを保持する。
    // 旧 EOCD や padding を CD としてコピーして完成させることを拒否する。
    struct CopyValidator {
        let expectedCount: UInt64
        private var count: UInt64 = 0
        private var fixed = Data()
        private var variableRemaining = 0

        // Swift 6.3 は private の stored property を持つ struct の memberwise init を private にする。
        init(expectedCount: UInt64) { self.expectedCount = expectedCount }

        mutating func consume(_ bytes: Data) throws {
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                if variableRemaining > 0 {
                    let consumed = min(variableRemaining, bytes.endIndex - cursor)
                    variableRemaining -= consumed
                    cursor += consumed
                    continue
                }
                guard count < expectedCount else {
                    throw UpdaterError.invalidArchive("旧 CD の entry 数を超える byte があります")
                }
                let consumed = min(ZipRecords.FixedLength.central - fixed.count, bytes.endIndex - cursor)
                fixed.append(bytes[cursor..<(cursor + consumed)])
                cursor += consumed
                if fixed.count == ZipRecords.FixedLength.central {
                    variableRemaining = try Header(fixed).variableLength
                    count += 1
                    fixed.removeAll(keepingCapacity: true)
                }
            }
        }

        func finish() throws {
            guard count == expectedCount, fixed.isEmpty, variableRemaining == 0 else {
                throw UpdaterError.invalidArchive("旧 CD の record 数または終端が一致しません")
            }
        }
    }
}
