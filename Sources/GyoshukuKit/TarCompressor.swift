import Foundation

// tar record を順に受け取り、gzip / XZ stream または bzip2 stream の連結を出力する。
protocol TarCompressor: AnyObject {
    func beginMember(headerLength: UInt64, bodyLength: UInt64)
    func beginEndOfArchive()
    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws
    func abandon()
}

extension TarCompressor {
    func beginMember(headerLength: UInt64, bodyLength: UInt64) {}
    func beginEndOfArchive() {}
    func abandon() {}
}

struct TarChunkLayout {
    let limit: Int
    private(set) var hasHints = false
    private var position: UInt64 = 0
    private var pendingEnds: [UInt64] = []
    // hint は emit を持たないため、次の write で直前の区切りを送る。
    private var cutBeforeInput = false
    private var ending = false

    mutating func beginMember(headerLength: UInt64, bodyLength: UInt64, bufferedCount: Int) {
        precondition(pendingEnds.isEmpty && !ending)
        hasHints = true
        let length = headerLength + bodyLength
        cutBeforeInput = bufferedCount > 0 && length > UInt64(limit - bufferedCount)
        if length > UInt64(limit) {
            // S ごとの位置は入力時に求め、巨大な member でも境界表を増やさない。
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
        var count = min(available, 256 * 1024)
        if !ending { count = min(count, limit - bufferedCount) }
        if let end = pendingEnds.first { count = Int(min(UInt64(count), end - position)) }
        return count
    }

    mutating func appended(_ count: Int, bufferedCount: Int) -> Bool {
        position += UInt64(count)
        var reachedEnd = false
        if pendingEnds.first == position {
            pendingEnds.removeFirst()
            reachedEnd = true
        }
        return hasHints && !ending && (reachedEnd || bufferedCount == limit)
    }
}
