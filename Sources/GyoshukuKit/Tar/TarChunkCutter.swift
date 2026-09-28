import Foundation

// 圧縮器用の chunk 境界機械。member の header / 本文の境目と packing / piece の上限だけで区切りを決める。
// TarCompressor（GzipCompressor / ParallelBzip2Compressor / ParallelXZCompressor）と
// CompressedTarSplicePlan.cuts が同じ規則を使い、計画と writer の境界を一致させる。
struct TarChunkLimits: Sendable, Equatable {
    let packing: Int
    let piece: Int

    init(packing: Int, piece: Int) {
        precondition(1 <= packing && packing <= piece)
        self.packing = packing
        self.piece = piece
    }

    init(uniform: Int) { self.init(packing: uniform, piece: uniform) }
}

struct TarChunkCutter {
    let limits: TarChunkLimits
    private(set) var hasHints = false
    private var position: UInt64 = 0
    private var pendingEnds: [UInt64] = []
    // hint は emit を持たないため、次の write で直前の区切りを送る。
    private var cutBeforeInput = false
    private var ending = false

    init(limits: TarChunkLimits) { self.limits = limits }
    init(limit: Int) { self.init(limits: .init(uniform: limit)) }

    private var currentLimit: Int {
        !hasHints || !pendingEnds.isEmpty ? limits.piece : limits.packing
    }

    mutating func beginMember(headerLength: UInt64, bodyLength: UInt64, bufferedCount: Int) {
        precondition(pendingEnds.isEmpty && !ending)
        hasHints = true
        let length = headerLength + bodyLength
        cutBeforeInput = bufferedCount > 0 && length > UInt64(limits.packing - bufferedCount)
        if length > UInt64(limits.packing) {
            // 片ごとの位置は入力時に求め、巨大な member でも境界表を増やさない。
            if headerLength > 0 { pendingEnds.append(position + headerLength) }
            if bodyLength > 0 { pendingEnds.append(position + length) }
        }
    }

    mutating func beginEndOfArchive(bufferedCount: Int) {
        precondition(pendingEnds.isEmpty && !ending)
        hasHints = true
        cutBeforeInput = bufferedCount > 0
        ending = true
    }

    mutating func takePendingCut() -> Bool {
        defer { cutBeforeInput = false }
        return cutBeforeInput
    }

    func nextCount(available: Int, bufferedCount: Int) -> Int {
        // 終端と record の詰め物は、小さい試験用 S でも一つに保つ。
        var count = min(available, IOChunk.size)
        if !ending { count = min(count, currentLimit - bufferedCount) }
        if let end = pendingEnds.first { count = Int(min(UInt64(count), end - position)) }
        return count
    }

    mutating func appended(_ count: Int, bufferedCount: Int) -> Bool {
        let limit = currentLimit
        position += UInt64(count)
        var reachedEnd = false
        if pendingEnds.first == position {
            pendingEnds.removeFirst()
            reachedEnd = true
        }
        return hasHints && !ending && (reachedEnd || bufferedCount == limit)
    }
}
