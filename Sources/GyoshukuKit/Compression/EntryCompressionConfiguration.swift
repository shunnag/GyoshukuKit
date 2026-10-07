import Foundation

/// 片に分けられない codec は小〜中項目を並列化する。大項目は従来の有界 stream 経路へ戻す。
struct EntryCompressionConfiguration {
    static let inputLimit = 16 << 20
    // GCD の constrained thread 上限より十分小さくする。
    static let maximumEntryThreads = 16
    let threads: Int

    init(lhaThreads: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        // 各memberの片並列にも最大の内部codec数を予約する。
        let state = UInt64(8 << 20) * UInt64(max(1, min(64, lhaThreads)))
        threads = Self.resolve(requested: lhaThreads, state: state,
                               budget: physicalMemory / 2)
    }

    init(options: WriterOptions, method: SevenZipCompressionMethod, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory, innerParallelism: Bool = false) {
        let state: UInt64
        let budget: UInt64
        switch method {
        case .lzma, .lzma2:
            let configuration = try? LZMAWriterConfiguration(options: options, raw: method == .lzma, physicalMemory: physicalMemory)
            state = configuration?.properties == nil ? 130 << 20 : configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .bzip2:
            state = UInt64(400_000 + 8 * 100_000 * options.bzip2Level)
            budget = physicalMemory / 2
        case .ppmd:
            // モデルを縮小せず、同時モデル数だけを物理メモリの半分に収める。
            state = UInt64((try? options.ppmd7Properties().memorySize) ?? (16 << 20)) + (2 << 20)
            budget = physicalMemory / 2
        case .deflate, .copy:
            state = 4 << 20
            budget = physicalMemory / 2
        }
        // folder 内の並列化を使う窓は、各枠に最大の内部 codec 数を予約する。
        let (folderState, overflow) = state.multipliedReportingOverflow(by: UInt64(innerParallelism ? max(1, min(64, options.resolvedCompressionThreads)) : 1))
        threads = Self.resolve(options: options, state: overflow ? UInt64.max : folderState, budget: budget)
    }

    init(options: WriterOptions, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let state: UInt64
        let budget: UInt64
        switch options.compressionMethod {
        case .lzma, .xz:
            let configuration = try? LZMAWriterConfiguration(options: options, raw: options.compressionMethod == .lzma, physicalMemory: physicalMemory)
            state = configuration?.properties == nil ? 130 << 20 : configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .zstd:
            let configuration = try? ZstdWriterConfiguration(options: options, streaming: true, physicalMemory: physicalMemory)
            state = configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .ppmd:
            state = UInt64((try? options.ppmd8Properties().memorySize) ?? (16 << 20)) + (2 << 20)
            budget = physicalMemory / 2
        case .bzip2:
            state = UInt64(400_000 + 8 * 100_000 * options.bzip2Level)
            budget = physicalMemory / 2
        case .deflate, .stored:
            state = 4 << 20
            budget = physicalMemory / 2
        }
        threads = Self.resolve(options: options, state: state, budget: budget)
    }

    private static func resolve(options: WriterOptions, state: UInt64, budget: UInt64) -> Int {
        resolve(requested: options.resolvedCompressionThreads, state: state, budget: budget)
    }

    private static func resolve(requested: Int, state: UInt64, budget: UInt64) -> Int {
        // 完全な項目入力と圧縮・spool コピーの I/O buffer を追加予約する。
        // 一枠も入らない場合は既存の逐次経路を使い、従来受理した memoryLimit を拒否しない。
        let (reservation, overflow) = state.addingReportingOverflow(UInt64(inputLimit + OrderedEntrySpool.memoryLimit + 4 * IOChunk.size))
        guard !overflow, reservation > 0 else { return 1 }
        return max(1, min(requested, Int(min(UInt64(maximumEntryThreads), budget / reservation))))
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

/// 小さい結果はメモリに保持し、上限を超えたら unlink 済み file へ移す。
/// worker が所有する間だけ変更し、完了後は emit 側へ所有権を渡す。
final class OrderedEntrySpool: @unchecked Sendable {
    static let memoryLimit = 1 << 20
    private let directory: URL
    private let tag: String
    private let reserve = ScratchFile.testingFreeSpaceReserve
    private let created = ScratchFile.testingCreated
    private var buffer = Data()
    private(set) var scratch: ScratchFile?
    private(set) var length: UInt64 = 0

    init(directory: URL, tag: String, diskBacked: Bool = false) throws {
        self.directory = directory
        self.tag = tag
        if diskBacked { scratch = try ScratchFile(directory: directory, tag: tag, pathExtension: "spool") }
    }

    func append(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        if scratch == nil, bytes.count > Self.memoryLimit - buffer.count {
            scratch = try ScratchFile.$testingFreeSpaceReserve.withValue(reserve) {
                try ScratchFile.$testingCreated.withValue(created) {
                    try ScratchFile(directory: directory, tag: tag, pathExtension: "spool")
                }
            }
            try scratch!.append(buffer)
            buffer = Data()
        }
        if let scratch { try scratch.append(bytes) }
        else { buffer.append(bytes) }
        length = try checkedAdd(length, UInt64(bytes.count))
    }

    func forEachChunk(_ emit: (Data) throws -> Void) throws {
        if let scratch { try scratch.forEachChunk(emit) }
        else if !buffer.isEmpty { try emit(buffer) }
    }

    func close() { scratch?.close(); buffer = Data() }
}
