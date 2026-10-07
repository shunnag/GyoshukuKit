import Foundation

/// 片に分けられない codec は小〜中項目を並列化する。大項目は従来の有界 stream 経路へ戻す。
struct EntryCompressionConfiguration {
    static let inputLimit = 16 << 20
    let threads: Int

    init(lhaThreads: Int) {
        // LH7の約3.7 MiBに符号列の一時コピー・Huffman領域を足し、8 MiBで予約する。
        threads = Self.resolve(requested: lhaThreads, state: 8 << 20,
                               budget: ProcessInfo.processInfo.physicalMemory / 2)
    }

    init(options: WriterOptions, method: SevenZipCompressionMethod) {
        let state: UInt64
        let budget: UInt64
        switch method {
        case .lzma, .lzma2:
            let configuration = try? LZMAWriterConfiguration(options: options, raw: method == .lzma)
            state = configuration?.properties == nil ? 130 << 20 : configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .bzip2:
            state = UInt64(400_000 + 8 * 100_000 * options.bzip2Level)
            budget = ProcessInfo.processInfo.physicalMemory / 2
        case .ppmd:
            // モデルを縮小せず、同時モデル数だけを物理メモリの半分に収める。
            state = UInt64((try? options.ppmd7Properties().memorySize) ?? (16 << 20)) + (2 << 20)
            budget = ProcessInfo.processInfo.physicalMemory / 2
        case .deflate, .copy:
            state = 4 << 20
            budget = ProcessInfo.processInfo.physicalMemory / 2
        }
        threads = Self.resolve(options: options, state: state, budget: budget)
    }

    init(options: WriterOptions) {
        let state: UInt64
        let budget: UInt64
        switch options.compressionMethod {
        case .lzma, .xz:
            let configuration = try? LZMAWriterConfiguration(options: options, raw: options.compressionMethod == .lzma)
            state = configuration?.properties == nil ? 130 << 20 : configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .zstd:
            let configuration = try? ZstdWriterConfiguration(options: options, streaming: true)
            state = configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .ppmd:
            state = UInt64((try? options.ppmd8Properties().memorySize) ?? (16 << 20)) + (2 << 20)
            budget = ProcessInfo.processInfo.physicalMemory / 2
        case .bzip2:
            state = UInt64(400_000 + 8 * 100_000 * options.bzip2Level)
            budget = ProcessInfo.processInfo.physicalMemory / 2
        case .deflate, .stored:
            state = 4 << 20
            budget = ProcessInfo.processInfo.physicalMemory / 2
        }
        threads = Self.resolve(options: options, state: state, budget: budget)
    }

    private static func resolve(options: WriterOptions, state: UInt64, budget: UInt64) -> Int {
        resolve(requested: options.resolvedCompressionThreads, state: state, budget: budget)
    }

    private static func resolve(requested: Int, state: UInt64, budget: UInt64) -> Int {
        // 完全な項目入力と圧縮・spool コピーの I/O buffer を追加予約する。
        // 一枠も入らない場合は既存の逐次経路を使い、従来受理した memoryLimit を拒否しない。
        let (reservation, overflow) = state.addingReportingOverflow(UInt64(inputLimit + 4 * IOChunk.size))
        guard !overflow, reservation > 0 else { return 1 }
        return max(1, min(requested, Int(min(64, budget / reservation))))
    }

    var maximumPendingInputBytes: UInt64 { threads > 1 ? UInt64(threads * Self.inputLimit) : 0 }
}

/// worker の stream 読取と出力でも呼出側の取消しを観測する。
final class CompressionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        try Task.checkCancellation()
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// 可変長圧縮結果はメモリに貯めず disk に置く。worker から emit への所有権移譲後だけ読む。
final class OrderedEntrySpool: @unchecked Sendable {
    let scratch: ScratchFile
    init(directory: URL, tag: String) throws {
        scratch = try ScratchFile(directory: directory, tag: tag, pathExtension: "spool")
    }
}
