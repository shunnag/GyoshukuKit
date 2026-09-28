import Foundation
@_spi(LHARawLayout) internal import KaitoKit

enum LHAAppendedMemberCheck {
    static func verify(descriptor: Int32, at outputStart: UInt64, originalStart: UInt64,
                       length: UInt64, records: [LHAWriter.MemberRecord], advance: (UInt64) throws -> Void) throws {
        let source = try ZipUpdateSource(duplicating: descriptor)
        let end = try checkedAdd(outputStart, length)
        var originalSizes: [UInt64] = []
        let walked = try LHALayout.walk(source: source, range: outputStart..<end) { index, header in
            guard records.indices.contains(index) else { throw failure("record count") }
            let expected = records[index]
            let offset = try checkedAdd(outputStart, expected.headerOffset - originalStart)
            guard header.member.headerRange == offset..<(offset + expected.headerLength),
                  header.member.dataRange == (offset + expected.headerLength)..<(offset + expected.headerLength + expected.dataLength),
                  header.member.method == expected.method, header.rawName == expected.rawName else { throw failure("walk") }
            originalSizes.append(header.originalSize)
        }
        guard walked.count == records.count, walked.end == end, !walked.terminated else { throw failure("walk end") }
        let view = AppendedView(source: source, range: outputStart..<end)
        let reader = try ArchiveReader.open(source: view, options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose))
        guard reader.format == .lha, reader.entries.count == records.count,
              let raw = try reader.lhaRawLayout(), raw.memberCount == records.count,
              raw.unpublishedMemberCount == 0 else { throw failure("reader count") }
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let entry = reader.entries[index], member = try raw.member(at: index)
            let offset = record.headerOffset - originalStart
            guard member.headerRange == offset..<(offset + record.headerLength),
                  member.dataRange == (offset + record.headerLength)..<(offset + record.headerLength + record.dataLength),
                  member.method == record.method, entry.compressedSize == record.dataLength,
                  entry.uncompressedSize == originalSizes[index],
                  record.rawName.elementsEqual(entry.rawName.bytes) else { throw failure("reader record") }
            let stream = try reader.stream(entry)
            var produced: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                produced = try checkedAdd(produced, UInt64(count))
            }
            guard entry.uncompressedSize == produced else { throw failure("decoded size") }
            try advance(record.headerLength + record.dataLength)
        }
    }

    private static func failure(_ reason: String) -> UpdaterRouteError { .outputVerificationFailed(reason: "V3 \(reason)") }

    private struct AppendedView: ByteSource {
        let source: ZipUpdateSource
        let range: Range<UInt64>
        var length: UInt64 { range.upperBound - range.lowerBound + 1 }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length, !buffer.isEmpty else { return 0 }
            if offset == length - 1 { buffer[0] = 0; return 1 }
            let count = Int(min(UInt64(buffer.count), length - offset - 1))
            return try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]), at: range.lowerBound + offset)
        }
    }
}
