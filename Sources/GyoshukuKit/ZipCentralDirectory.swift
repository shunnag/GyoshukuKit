import Foundation
internal import KaitoKit

enum ZipCentralDirectory {
    private struct Header {
        let nameLength: Int
        let extraLength: Int
        let variableLength: Int
        let localOffset32: UInt32
        let zip64OffsetPosition: Int

        init(_ bytes: Data) throws {
            guard bytes.count == 46, bytes.zip32(0) == 0x02014B50 else {
                throw UpdaterError.invalidArchive("CD record の signature がありません")
            }
            nameLength = Int(bytes.zip16(28))
            extraLength = Int(bytes.zip16(30))
            variableLength = nameLength + extraLength + Int(bytes.zip16(32))
            localOffset32 = bytes.zip32(42)
            zip64OffsetPosition = (bytes.zip32(24) == UInt32.max ? 8 : 0)
                + (bytes.zip32(20) == UInt32.max ? 8 : 0)
        }

        func localOffset(source: ZipUpdateSource, at cursor: UInt64) throws -> UInt64 {
            guard localOffset32 == UInt32.max else { return UInt64(localOffset32) }
            let extra = try source.bytes(at: cursor + 46 + UInt64(nameLength), count: extraLength)
            var index = 0
            while extra.count - index >= 4 {
                let length = Int(extra.zip16(index + 2))
                guard length <= extra.count - index - 4 else { break }
                if extra.zip16(index) == 1 {
                    guard length >= zip64OffsetPosition + 8 else { break }
                    return extra.zip64(index + 4 + zip64OffsetPosition)
                }
                index += 4 + length
            }
            throw UpdaterError.invalidArchive("CD の ZIP64 local-header offset がありません")
        }
    }

    // open の entry 数照合後に使う。サイズや offset の解釈は KaitoKit の raw record と必ず照合する。
    // probe はこの O(entries) の walk を行わず、終端の曖昧さの検査に留める。
    static func validate(source: ZipUpdateSource, reader: ArchiveReader,
                         centralOffset: UInt64, centralSize: UInt64) throws {
        guard centralOffset <= source.length, centralSize <= source.length - centralOffset else {
            throw UpdaterError.invalidArchive("CD の範囲がファイル範囲外です")
        }
        let end = centralOffset + centralSize
        var cursor = centralOffset
        // open は KaitoKit の open と同じく取消しに依存しない。KaitoFinder は公開後の再オープンを
        // 取消し済みの Task で行うことがあり、ここで CancellationError を返すと成功した保存を隠す。
        // walk は maxTotalMetadataSize / maxEntryCount で有界。
        for entry in reader.entries {
            guard cursor <= end, end - cursor >= 46 else {
                throw UpdaterError.invalidArchive("CD record が途中で終わっています")
            }
            let header = try Header(source.bytes(at: cursor, count: 46))
            guard UInt64(header.variableLength) <= end - cursor - 46 else {
                throw UpdaterError.invalidArchive("CD record の可変長領域が範囲外です")
            }
            let offset = try header.localOffset(source: source, at: cursor)
            let record: RawEntryRecord?
            do { record = try reader.rawRecord(of: entry) }
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
            cursor += 46 + UInt64(header.variableLength)
        }
        guard cursor == end else {
            throw UpdaterError.invalidArchive("CD の walk 終端と宣言されたサイズが一致しません")
        }
    }

    // copyCentral の chunk 境界に依存せず、固定 header 46 byte だけを保持する。
    // 旧 EOCD や padding を CD としてコピーして完成させることを拒否する。
    struct CopyValidator {
        let expectedCount: UInt64
        private var count: UInt64 = 0
        private var fixed = Data()
        private var variableRemaining = 0

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
                let consumed = min(46 - fixed.count, bytes.endIndex - cursor)
                fixed.append(bytes[cursor..<(cursor + consumed)])
                cursor += consumed
                if fixed.count == 46 {
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
