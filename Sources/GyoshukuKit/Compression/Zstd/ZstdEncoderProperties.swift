// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation

/// GyoshukuKit's own effort presets, not the reference encoder's level parameters.
struct ZstdEncoderProperties: Sendable {
    enum Strategy: Sendable { case fast, doubleHash, lazy, lazy2, optimal }
    let level: Int
    let windowLog: Int
    let hashLog: Int
    let depth: Int
    let niceLength: Int
    let strategy: Strategy
    var windowSize: Int { 1 << windowLog }

    static func preset(_ level: Int) throws -> Self {
        guard (1...19).contains(level) else { throw WriterError.invalidOption("zstd level must be 1...19") }
        let windows = [20,20,21,21,21,21,21,22,22,22,22,22,23,23,23,23,23,23,23]
        let hashes = [17,18,18,19,19,19,19,19,20,20,20,20,20,20,20,21,21,21,21]
        let depths = [1,1,2,2,2,16,24,32,48,64,96,128,64,96,128,192,256,384,512]
        let nice = [32,48,64,80,96,64,80,96,128,160,192,256,128,160,192,256,384,512,768]
        let strategy: Strategy = level <= 2 ? .fast : level <= 5 ? .doubleHash
            : level <= 8 ? .lazy : level <= 12 ? .lazy2 : .optimal
        return Self(level: level, windowLog: windows[level - 1], hashLog: hashes[level - 1],
                    depth: depths[level - 1], niceLength: nice[level - 1], strategy: strategy)
    }

    /// Includes two sliding windows, match tables and conservative block/entropy/parser scratch.
    /// Caller-owned input/output and allocator bookkeeping are excluded.
    var estimatedMemoryBytes: Int {
        let heads = (1 << hashLog) * 4 + (strategy == .fast ? 0 : (1 << 16) * 4)
        let links = strategy == .optimal ? windowSize * 8
            : (strategy == .lazy || strategy == .lazy2 ? windowSize * 4 : 0)
        return 2 * windowSize + heads + links + (strategy == .optimal ? 16 << 20 : 5 << 20)
    }
}
