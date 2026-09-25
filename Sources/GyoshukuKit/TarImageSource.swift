import Foundation
private import Darwin
internal import KaitoKit

// 追加と literal だけを保存する。名前は空 inode の間に安全に外し、以後は fd だけを持つ。
final class TarSpliceStorage {
    @TaskLocal static var testingFreeSpaceReserve: UInt64?
    @TaskLocal static var testingCreated: (@Sendable (Int32) -> Void)?
    let handle: FileHandle
    let url: URL
    private(set) var written: UInt64 = 0

    init(directory: URL) throws {
        url = directory.appendingPathComponent(".gyoshuku-splice-\(UUID().uuidString).tar")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriterError.io(operation: "create splice storage", code: errno) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard ArchiveOwnedFile.matches(url: url, descriptor: fd), unlink(url.path) == 0 else {
            ArchiveOwnedFile.remove(url: url, descriptor: fd)
            throw WriterError.io(operation: "unlink splice storage", code: errno)
        }
        Self.testingCreated?(fd)
        try willWrite(0)
    }

    func willWrite(_ count: Int) throws {
        let end = try checkedAdd(written, UInt64(count))
        // 出力 volume の追加/literal に固定の予備容量は要求しない。容量検査は故障注入時だけ。
        if let reserve = Self.testingFreeSpaceReserve {
            var space = statfs()
            guard fstatfs(handle.fileDescriptor, &space) == 0 else { throw WriterError.io(operation: "free space", code: errno) }
            let available = UInt64(space.f_bavail) * UInt64(space.f_bsize)
            guard available >= reserve else {
                throw WriterError.io(operation: "free space", code: ENOSPC)
            }
        }
        written = end
    }

    func append(_ bytes: Data) throws -> Range<UInt64> {
        let start = written
        try willWrite(bytes.count)
        try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(handle.fileDescriptor, bytes: $0, at: start) }
        return start..<written
    }
    func source() throws -> ZipUpdateSource { try ZipUpdateSource(duplicating: handle.fileDescriptor) }
}

struct TarImageSource: ByteSource {
    struct Span: Sendable {
        let source: any ByteSource
        let offset: UInt64
        let range: Range<UInt64>
        let isOld: Bool
    }
    struct Member: Sendable {
        let start: UInt64
        let data: UInt64
        let end: UInt64
    }
    let spans: [Span]
    let length: UInt64
    let members: [Member]
    let terminalStart: UInt64

    init(spans: [Span], length: UInt64, members: [Member] = [], terminalStart: UInt64) {
        self.spans = spans; self.length = length; self.members = members; self.terminalStart = terminalStart
    }

    static func make(plan: TarEditPlan, layout: TarLayout, original: any ByteSource,
                     storage: TarSpliceStorage, additionLength: UInt64,
                     additions: [(groupStart: UInt64, dataStart: UInt64, end: UInt64)]) throws -> TarImageSource {
        var pieces: [(old: Bool, offset: UInt64, length: UInt64)] = []
        for segment in plan.prefix {
            try Task.checkCancellation()
            switch segment {
            case .source(let range): pieces.append((true, range.lowerBound, segment.length))
            case .literal(let length, let bytes):
                let data = try bytes()
                guard UInt64(data.count) == length else { throw TarUpdaterError.outputVerificationFailed(reason: "literal length") }
                let range = try storage.append(data)
                pieces.append((false, range.lowerBound, length))
            case .generated: throw WriterError.invalidState
            }
        }
        if additionLength > 0 { pieces.append((false, 0, additionLength)) }
        let terminal = try storage.append(plan.terminal)
        pieces.append((false, terminal.lowerBound, UInt64(plan.terminal.count)))
        let scratch = try storage.source()
        var spans: [Span] = [], position: UInt64 = 0
        for piece in pieces where piece.length > 0 {
            let end = try checkedAdd(position, piece.length)
            spans.append(Span(source: piece.old ? original : scratch, offset: piece.offset,
                              range: position..<end, isOld: piece.old))
            position = end
        }
        let changes = Dictionary(uniqueKeysWithValues: plan.changed.map { ($0.index, $0) })
        var members: [Member] = [], memberIndex = 0
        for (index, unit) in layout.units.enumerated() {
            defer { if !unit.isGlobal { memberIndex += 1 } }
            guard let start = plan.unitOffsets[index] else { continue }
            let change = unit.isGlobal ? nil : changes[memberIndex]
            let headerLength = change?.headerLength ?? (unit.dataStart - unit.groupStart)
            let bodyLength: UInt64
            if let target = change?.materializedTarget {
                let size = layout.member(target).storedSize
                bodyLength = try checkedAdd(size, UInt64(TarRecords.padding(size)))
            } else { bodyLength = unit.paddedEnd - unit.dataStart }
            members.append(Member(start: start, data: start + headerLength, end: start + headerLength + bodyLength))
        }
        members += additions.map { Member(start: plan.membersEnd + $0.groupStart, data: plan.membersEnd + $0.dataStart,
                                           end: plan.membersEnd + $0.end) }
        return TarImageSource(spans: spans, length: position, members: members,
                              terminalStart: plan.membersEnd + additionLength)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length, !buffer.isEmpty else { return 0 }
        let low = spanIndex(at: offset)
        guard low < spans.count, spans[low].range.contains(offset) else { throw WriterError.invalidState }
        let span = spans[low]
        let count = Int(min(UInt64(buffer.count), span.range.upperBound - offset))
        let actual = try span.source.read(into: .init(rebasing: buffer[..<count]),
                                         at: span.offset + offset - span.range.lowerBound)
        guard actual > 0, actual <= count else { throw UpdaterError.sourceChanged }
        return actual
    }

    func spanIndex(at offset: UInt64) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].range.upperBound <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func oldBytes(in range: Range<UInt64>) -> UInt64 {
        var result: UInt64 = 0
        for span in spans[spanIndex(at: range.lowerBound)...] {
            if span.range.lowerBound >= range.upperBound { break }
            if !span.isOld { continue }
            let a = max(range.lowerBound, span.range.lowerBound), b = min(range.upperBound, span.range.upperBound)
            result += b > a ? b - a : 0
        }
        return result
    }
}
