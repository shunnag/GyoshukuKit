import Foundation
private import Darwin
@_spi(LHARawLayout) internal import KaitoKit

/// LHAUpdater の commit 後の自己照合。失敗理由の先頭の符号（design.md §4「LHA の更新」）:
/// V1 改名 header の byte・CRC・解釈、V2 source segment 境界の header の一致、V3 追加 block の独立 walk・
/// writer の記録・KaitoKit による全復号、V4 長さと終端の 0、V5 書いた source 範囲の memcmp（SegmentedArchiveOutput が行う）。
enum LHASelfCheck {
    typealias Timings = (v2: Double, v3: Double, total: Double)

    /// 成功時に V2 / V3 と全体の所要秒を返す。advance には V2 の照合読取と V3 の追加 block 長を渡す。
    /// source は原本の snapshot、descriptor は書き終えた出力。
    static func verify(plan: LHAEditPlan, records: [LHAWriter.MemberRecord], additionLength: UInt64, finalLength: UInt64,
                       descriptor: Int32, source: ArchiveFileSource, layout: LHALayout, appendStart: UInt64?,
                       advance: (UInt64) throws -> Void) throws -> Timings {
        let started = ProcessInfo.processInfo.systemUptime
        var timings: Timings = (v2: 0, v3: 0, total: 0)
        var progressError: Error?
        func advancing(_ count: UInt64) throws {
            do { try advance(count) } catch { progressError = error; throw error }
        }
        func check() throws {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) == finalLength else { throw failure("V4 length") }
            guard plan.isChanged else { return }
            let output = try ArchiveFileSource(duplicating: descriptor)
            for change in plan.changed {
                try Task.checkCancellation()
                let actual = try SegmentedArchiveOutput.read(descriptor, at: change.outputOffset, count: change.header.count)
                guard actual == change.header, actual.first != 0 else { throw failure("V1 header") }
                let original = try layout.member(change.index)
                let payloadLength = original.dataRange.byteLength
                let end = change.outputOffset + UInt64(change.header.count) + payloadLength
                let walked = try LHALayout.walk(source: output, range: change.outputOffset..<end) { index, header in
                    guard index == 0, header.member.headerLevel == 2, header.member.method == original.method,
                          header.member.crc16 == (original.method == LHARecords.Method.lhd ? 0 : original.crc16),
                          header.member.dataRange.byteLength == payloadLength else {
                        throw failure("V1 parsed header")
                    }
                }
                guard walked.count == 1, walked.end == end, !walked.terminated else { throw failure("V1 bounds") }
            }
            let v2Start = ProcessInfo.processInfo.systemUptime
            for boundary in plan.boundaries {
                try Task.checkCancellation()
                let original = try SegmentedArchiveOutput.read(source.descriptor, at: boundary.source, count: Int(boundary.length), counted: true)
                let written = try SegmentedArchiveOutput.read(descriptor, at: boundary.output, count: Int(boundary.length), counted: true)
                try advancing(boundary.length * 2)
                guard original == written else { throw failure("V2 boundary header") }
            }
            timings.v2 = ProcessInfo.processInfo.systemUptime - v2Start
            if additionLength > 0 {
                let v3Start = ProcessInfo.processInfo.systemUptime
                do {
                    try verifyAppended(descriptor: descriptor, at: plan.membersEnd, originalStart: appendStart!,
                                       length: additionLength, records: records, advance: advancing)
                } catch {
                    if error is CancellationError { throw error }
                    throw failure("V3: \(error)")
                }
                timings.v3 = ProcessInfo.processInfo.systemUptime - v3Start
            }
            guard try SegmentedArchiveOutput.read(descriptor, at: finalLength - 1, count: 1) == Data([0]) else { throw failure("V4 terminator") }
        }
        do { try check() } catch {
            if let progressError { throw progressError }
            if error is CancellationError { throw error }
            if let failure = error as? UpdaterRouteError, case .outputVerificationFailed = failure { throw failure }
            throw failure("LHA verification: \(error)")
        }
        timings.total = ProcessInfo.processInfo.systemUptime - started
        return timings
    }

    /// V3。追加 block を独立に walk して writer の MemberRecord と照合し、その範囲だけを見せた KaitoKit で
    /// 全 member を復号して元サイズを確かめる。理由は "V3 …" で返す。
    static func verifyAppended(descriptor: Int32, at outputStart: UInt64, originalStart: UInt64,
                               length: UInt64, records: [LHAWriter.MemberRecord], advance: (UInt64) throws -> Void) throws {
        let source = try ArchiveFileSource(duplicating: descriptor)
        let end = try checkedAdd(outputStart, length)
        var originalSizes: [UInt64] = []
        let walked = try LHALayout.walk(source: source, range: outputStart..<end) { index, header in
            guard records.indices.contains(index) else { throw appendedFailure("record count") }
            let expected = records[index]
            let offset = try checkedAdd(outputStart, expected.headerOffset - originalStart)
            guard header.member.headerRange == offset..<(offset + expected.headerLength),
                  header.member.dataRange == (offset + expected.headerLength)..<(offset + expected.headerLength + expected.dataLength),
                  header.member.method == expected.method, header.rawName == expected.rawName else { throw appendedFailure("walk") }
            originalSizes.append(header.originalSize)
        }
        guard walked.count == records.count, walked.end == end, !walked.terminated else { throw appendedFailure("walk end") }
        let view = AppendedView(source: source, range: outputStart..<end)
        let reader = try ArchiveReader.open(source: view, options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose))
        guard reader.format == .lha, reader.entries.count == records.count,
              let raw = try reader.lhaRawLayout(), raw.memberCount == records.count,
              raw.unpublishedMemberCount == 0 else { throw appendedFailure("reader count") }
        var buffer = [UInt8](repeating: 0, count: IOChunk.size)
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let entry = reader.entries[index], member = try raw.member(at: index)
            let offset = record.headerOffset - originalStart
            guard member.headerRange == offset..<(offset + record.headerLength),
                  member.dataRange == (offset + record.headerLength)..<(offset + record.headerLength + record.dataLength),
                  member.method == record.method, entry.compressedSize == record.dataLength,
                  entry.uncompressedSize == originalSizes[index],
                  record.rawName.elementsEqual(entry.rawName.bytes) else { throw appendedFailure("reader record") }
            let stream = try reader.stream(entry)
            var produced: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                produced = try checkedAdd(produced, UInt64(count))
            }
            guard entry.uncompressedSize == produced else { throw appendedFailure("decoded size") }
            try advance(record.headerLength + record.dataLength)
        }
    }

    /// 試験の fault 注入。同期の直前に出力へ 1 byte の反転・source 区間のずれ・終端の欠落を入れ、
    /// 各 V がそれを検出することを LHAUpdaterOutputModeTests が確かめる。
    static func faultAction(_ fault: LHAUpdater.Fault, plan: LHAEditPlan, finalLength: UInt64,
                            records: [LHAWriter.MemberRecord], appendStart: UInt64?) -> @Sendable (Int32) throws -> Void {
        let header = plan.changed.first?.outputOffset ?? plan.membersEnd
        let boundary = plan.boundaries.first?.output ?? 0
        let membersEnd = plan.membersEnd
        let payload = records.first.map { plan.membersEnd + $0.headerOffset - (appendStart ?? 0) + $0.headerLength }
        return { fd in
            let offset: UInt64
            switch fault {
            case .flipWrittenByte(let value): offset = value
            case .shiftSourceSegment:
                let bytes = try SegmentedArchiveOutput.read(fd, at: boundary + 1, count: 21)
                try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: boundary) }
                return
            case .corruptWrittenHeader: offset = header
            case .corruptAppendedPayload: offset = payload ?? membersEnd
            case .dropTerminator:
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).truncate(atOffset: finalLength - 1)
                return
            }
            var byte = try SegmentedArchiveOutput.read(fd, at: offset, count: 1)
            byte[0] ^= 1
            try byte.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: offset) }
        }
    }

    private static func failure(_ reason: String) -> UpdaterRouteError { .outputVerificationFailed(reason: reason) }
    private static func appendedFailure(_ reason: String) -> UpdaterRouteError { .outputVerificationFailed(reason: "V3 \(reason)") }

    /// 追加 block だけを、終端の 0 を 1 byte 足した独立の LHA 書庫として KaitoKit に見せる。
    private struct AppendedView: ByteSource {
        let source: ArchiveFileSource
        let range: Range<UInt64>
        var length: UInt64 { range.byteLength + 1 }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length, !buffer.isEmpty else { return 0 }
            if offset == length - 1 { buffer[0] = 0; return 1 }
            let count = Int(min(UInt64(buffer.count), length - offset - 1))
            return try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]), at: range.lowerBound + offset)
        }
    }
}
