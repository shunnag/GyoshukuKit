import Foundation
private import Darwin
internal import KaitoKit

// 圧縮 tar の区切り単位の更新。経路は
// TarEditPlan → TarImageSource（+ScratchFile）→ CompressedTarSplicePlan → CompressedTarSpliceOutput.commit → CompressedTarSelfCheck.verify。
// この経路は SplicedArchiveOutput（segment 計画を実行する共通の commit）を使わない。出力 inode の所有は OwnedOutputFile を共有する。
// このファイルは編集後の tar image。原本の区間と作業ファイルの区間を繋いだ ByteSource で、member の座標表も持つ。
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
                     storage: ScratchFile, additionLength: UInt64,
                     additions: [(groupStart: UInt64, dataStart: UInt64, end: UInt64)]) throws -> TarImageSource {
        var pieces: [(old: Bool, offset: UInt64, length: UInt64)] = []
        for segment in plan.prefix {
            try Task.checkCancellation()
            switch segment {
            case .source(let range): pieces.append((true, range.lowerBound, segment.length))
            case .literal(let length, let bytes):
                let data = try bytes()
                guard UInt64(data.count) == length else { throw UpdaterRouteError.outputVerificationFailed(reason: "literal length") }
                let range = try storage.append(data)
                pieces.append((false, range.lowerBound, length))
            case .generated, .scratch: throw WriterError.invalidState
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
