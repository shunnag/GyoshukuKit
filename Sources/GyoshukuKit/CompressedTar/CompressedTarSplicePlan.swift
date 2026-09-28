import Foundation
@_spi(TarEditLayout) internal import KaitoKit

// 圧縮 tar の区切り単位の更新。経路は
// TarEditPlan → TarImageSource（+ScratchFile）→ CompressedTarSplicePlan → CompressedTarSpliceOutput.commit → CompressedTarSelfCheck.verify。
// この経路は SplicedArchiveOutput（segment 計画を実行する共通の commit）を使わない。出力 inode の所有は OwnedOutputFile を共有する。
// このファイルは計画。新 image のどの区間を運ぶ chunk（reused）にし、どこを橋として再符号化するかを決める。
struct CompressedTarSplicePlan {
    struct Part: Sendable {
        var image: Range<UInt64>
        let reused: Int?
    }
    let parts: [Part]
    let chunks: [CompressedTarChunk]
    let reason: CompressedTarFullEncodeReason?

    static func framingReason(_ snapshot: TarEditingSnapshot) -> CompressedTarFullEncodeReason? {
        guard let map = snapshot.chunkMap else {
            return .framing(String(describing: snapshot.chunkMapUnavailableReason))
        }
        if case .xz(let xz) = map, xz.streamFlags != 0x0100 { return .framing("xz check is not CRC32") }
        return nil
    }

    static func limits(_ format: ArchiveFormat, options: WriterOptions) -> TarChunkLimits {
        switch format {
        case .tarGzip: .init(uniform: DeflateBlock.size)
        case .tarBzip2: .init(uniform: ParallelBzip2Compressor.chunkSize(level: options.bzip2Level))
        default: .init(packing: ParallelXZCompressor.memberPackingSize, piece: ParallelXZCompressor.defaultBlockSize)
        }
    }

    static func make(snapshot: TarEditingSnapshot, image: TarImageSource, format: ArchiveFormat,
                     options: WriterOptions, force: Bool, ignoresWindow: Bool) throws -> CompressedTarSplicePlan {
        let chunks = snapshot.chunkMap?.chunks ?? []
        let reason = framingReason(snapshot)
        var selected: [Part] = []
        if !force, reason == nil {
            for span in image.spans where span.isOld {
                let oldEnd = span.offset + span.range.byteLength
                var low = 0, high = chunks.count
                while low < high {
                    let middle = (low + high) / 2
                    if chunks[middle].imageRange.lowerBound < span.offset { low = middle + 1 } else { high = middle }
                }
                for index in low..<chunks.count {
                    let chunk = chunks[index]
                    if chunk.imageRange.upperBound > oldEnd { break }
                    let window = format == .tarGzip && !ignoresWindow ? min(UInt64(DeflateBlock.windowSize), chunk.imageRange.lowerBound) : 0
                    guard chunk.imageRange.lowerBound - window >= span.offset, !chunk.imageRange.isEmpty else { continue }
                    // 変更後の終端は必ず literal。旧 gzip の BFINAL は運ばない。
                    if format == .tarGzip, index == chunks.count - 1 { continue }
                    let start = span.range.lowerBound + chunk.imageRange.lowerBound - span.offset
                    selected.append(Part(image: start..<(start + chunk.imageRange.byteLength), reused: index))
                }
            }
        }
        let limits = limits(format, options: options)
        var absorbed = Set<Int>(), start = 0
        while start < selected.count {
            var end = start + 1
            while end < selected.count, selected[end - 1].image.upperBound == selected[end].image.lowerBound { end += 1 }
            let left = selected[start].image.lowerBound > 0
            let right = selected[end - 1].image.upperBound < image.length
            let small: (Int) -> Bool = { selected[$0].image.byteLength < UInt64(limits.packing / 16) }
            if left && right && (start..<end).allSatisfy(small) { absorbed.formUnion(start..<end) }
            else {
                if left && small(start) { absorbed.insert(start) }
                if right && small(end - 1) { absorbed.insert(end - 1) }
            }
            start = end
        }
        selected = selected.enumerated().compactMap { absorbed.contains($0.offset) ? nil : $0.element }
        var parts: [Part] = [], cursor: UInt64 = 0
        for part in selected {
            try Task.checkCancellation()
            if cursor < part.image.lowerBound {
                parts += cuts(cursor..<part.image.lowerBound, image: image, limits: limits).map { Part(image: $0, reused: nil) }
            }
            parts.append(part)
            cursor = part.image.upperBound
        }
        if cursor < image.length { parts += cuts(cursor..<image.length, image: image, limits: limits).map { Part(image: $0, reused: nil) } }
        return CompressedTarSplicePlan(parts: parts, chunks: chunks,
                                      reason: selected.isEmpty ? reason ?? .noReusableChunk : nil)
    }

    // G1 の境界機械を byte 数だけで進める。橋の先頭が header/本文の途中でも同じ規則を使う。
    static func cuts(_ range: Range<UInt64>, image: TarImageSource, limits: TarChunkLimits) -> [Range<UInt64>] {
        var layout = TarChunkLayout(limits: limits), buffered = 0
        var cursor = range.lowerBound, start = cursor
        var result: [Range<UInt64>] = []
        func cut() {
            if cursor > start { result.append(start..<cursor); start = cursor; buffered = 0 }
        }
        func feed(to end: UInt64) {
            if layout.takePendingCut() { cut() }
            while cursor < end {
                let n = layout.nextCount(available: Int(min(UInt64(IOChunk.size), end - cursor)), bufferedCount: buffered)
                buffered += n; cursor += UInt64(n)
                if layout.appended(n, bufferedCount: buffered) { cut() }
            }
        }
        var low = 0, high = image.members.count
        while low < high {
            let middle = (low + high) / 2
            if image.members[middle].end <= cursor { low = middle + 1 } else { high = middle }
        }
        for member in image.members[low...] {
            if cursor >= range.upperBound { break }
            let header = member.data > cursor ? member.data - cursor : 0
            layout.beginMember(headerLength: header, bodyLength: member.end - max(cursor, member.data), bufferedCount: buffered)
            feed(to: min(member.end, range.upperBound))
        }
        if cursor < range.upperBound {
            layout.beginEndOfArchive(bufferedCount: buffered)
            feed(to: range.upperBound)
        }
        cut()
        return result
    }
}
