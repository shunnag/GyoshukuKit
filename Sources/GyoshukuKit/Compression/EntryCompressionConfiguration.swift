import Foundation

/// 小〜中項目の窓と、長いstreamの専用codecまたは片並列の共有枠を予約する。
struct EntryCompressionConfiguration {
    @TaskLocal static var testingInputLimit: Int?
    @TaskLocal static var testingMemoryBudget: UInt64?
    static var inputLimit: Int { testingInputLimit ?? (16 << 20) }
    @TaskLocal static var testingEntryThreadLimit: Int?
    static var maximumEntryThreads: Int { testingEntryThreadLimit ?? CompressionWorkerPool.maximumEntryThreads }
    let threads: Int
    let codecThreads: Int
    // 7zでは専用jobのcodec core数（LZMAのparser+finderは2）、ZIPでは追加finder core数。
    let longPoleThreads: Int
    let earlyLongPoleSlots: Int

    init(lhaThreads: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        codecThreads = 1
        longPoleThreads = 0
        earlyLongPoleSlots = 0
        // 各memberの片並列にも最大の内部codec数を予約する。
        let state = UInt64(8 << 20) * UInt64(max(1, min(WriterOptions.compressionThreadsRange.upperBound, lhaThreads)))
        threads = Self.resolve(requested: lhaThreads, state: state,
                               budget: physicalMemory / 2)
    }

    init(options: WriterOptions, method: SevenZipCompressionMethod, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory, innerParallelism: Bool = false, chunkSize: Int? = nil) {
        let state: UInt64
        let budget: UInt64
        var pieceSize = 1
        switch method {
        case .lzma, .lzma2:
            let configuration = try? LZMAWriterConfiguration(options: options, raw: method == .lzma, physicalMemory: physicalMemory)
            state = configuration?.properties == nil ? 130 << 20 : configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
            pieceSize = chunkSize ?? (options.prefersSpeed && method == .lzma2
                ? LZMAWriterConfiguration.testingPieceSize ?? (2 << 20) : configuration?.pieceSize ?? ParallelXZCompressor.defaultBlockSize)
        case .bzip2:
            state = ParallelBzip2StreamEncoder.memoryReservation(level: options.bzip2Level,
                threads: innerParallelism ? ParallelBzip2StreamEncoder.resolvedThreads(options: options, physicalMemory: physicalMemory) : 1)
            budget = min(physicalMemory / 2, options.memoryLimit ?? UInt64.max)
        case .ppmd:
            // モデルを縮小せず、同時モデル数だけを物理メモリの半分に収める。
            state = UInt64((try? options.ppmd7Properties().memorySize) ?? (16 << 20)) + (2 << 20)
            budget = physicalMemory / 2
        case .deflate, .copy:
            state = 4 << 20
            budget = physicalMemory / 2
            pieceSize = min(chunkSize ?? ParallelXZCompressor.defaultBlockSize, DeflateBlock.size)
        }
        let requested = max(1, min(WriterOptions.compressionThreadsRange.upperBound, options.resolvedCompressionThreads))
        let available = min(budget, Self.testingMemoryBudget ?? budget)
        let singleStream = method == .lzma || method == .ppmd || method == .copy
        let io = UInt64(Self.inputLimit + OrderedEntrySpool.memoryLimit + 4 * IOChunk.size)
        let (reservation, reserveOverflow) = state.addingReportingOverflow(io)
        let finderMemory = method == .lzma && requested >= 3 ? UInt64(LZMAMatchFinderPipeline.memorySize) : 0
        // LZMAの二coreは要求数の内側で確保する。要求2では通常窓をdrainして二枠を貸す。
        longPoleThreads = singleStream && requested > 1 && !reserveOverflow
            && reservation + finderMemory <= available / 2 ? (method == .lzma ? (requested >= 3 ? 2 : 0) : 1) : 0
        let normalBudget = available - (longPoleThreads > 0 ? reservation + finderMemory : 0)
        // 単一 stream は一つ、片並列はfolder上限に入る片数だけcodec状態を予約する。
        let size = options.sevenZipSolid == .off ? UInt64(Self.inputLimit) : options.resolvedSevenZipBlockSize
        let pieces = innerParallelism && (method == .lzma2 || method == .deflate)
            ? min(UInt64(requested), (max(1, size) - 1) / UInt64(pieceSize) + 1) : 1
        let (folderState, overflow) = state.multipliedReportingOverflow(by: pieces)
        let normalRequested = method == .lzma ? max(1, requested - longPoleThreads) : requested
        threads = Self.resolve(requested: normalRequested, state: overflow ? UInt64.max : folderState, budget: normalBudget)
        // 通常窓のI/Oを先に差し引く。片並列の専用枠にもI/Oを一枠予約する。
        // 単一streamの専用状態とI/Oは既に差し引き、通常codecへ貸さない。
        let ioSlots = threads + (!singleStream && threads > 1 ? 1 : 0)
        let overhead = min(normalBudget, UInt64(ioSlots) * io)
        let codecState = method == .bzip2 ? ParallelBzip2StreamEncoder.memoryReservation(level: options.bzip2Level, threads: 1) : state
        let normalCodecs = max(1, Int(min(UInt64(normalRequested), (normalBudget - overhead) / max(1, codecState))))
        codecThreads = normalCodecs + longPoleThreads
        earlyLongPoleSlots = requested >= 4 && options.password == nil && options.sevenZipFilter == .none
            && ((method == .lzma || method == .ppmd) && longPoleThreads > 0
                || (method == .bzip2 && options.sevenZipSolid == .off && codecThreads >= 3 && threads > 1)) ? 1 : 0
    }

    init(options: WriterOptions, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        codecThreads = 1
        let state: UInt64
        let budget: UInt64
        switch options.compressionMethod {
        case .lzma, .xz:
            let configuration = try? LZMAWriterConfiguration(options: options, raw: options.compressionMethod == .lzma, physicalMemory: physicalMemory)
            state = configuration?.properties == nil ? 130 << 20 : configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .zstd:
            let configuration = try? ZstdWriterConfiguration(options: options, streaming: !options.prefersSpeed, physicalMemory: physicalMemory)
            state = configuration?.memoryPerThread ?? UInt64.max
            budget = configuration?.memoryBudget ?? 0
        case .ppmd:
            state = UInt64((try? options.ppmd8Properties().memorySize) ?? (16 << 20)) + (2 << 20)
            budget = physicalMemory / 2
        case .bzip2:
            state = ParallelBzip2StreamEncoder.memoryReservation(level: options.bzip2Level, threads: 1)
            budget = min(physicalMemory / 2, options.memoryLimit ?? UInt64.max)
        case .deflate, .stored:
            state = 4 << 20
            budget = physicalMemory / 2
        }
        // ZIP LZMA は一coreとbuffer一組を大項目用に確保する。通常窓の項目はfinder=1。
        let extra = UInt64(LZMAMatchFinderPipeline.memorySize)
        let available = min(budget, Self.testingMemoryBudget ?? budget)
        let parallelFinder = options.compressionMethod == .lzma && options.resolvedCompressionThreads >= 2
            && state < available && extra <= available - state
        longPoleThreads = parallelFinder ? 1 : 0
        threads = Self.resolve(requested: max(1, options.resolvedCompressionThreads - longPoleThreads),
            state: state, budget: parallelFinder ? available - extra : available)
        earlyLongPoleSlots = options.resolvedCompressionThreads >= 4 && threads > 1
            && !(options.password != nil && options.zipEncryption == .zipCrypto)
            && (options.compressionMethod == .lzma || options.compressionMethod == .ppmd
                || (options.compressionMethod == .zstd && !options.prefersSpeed)) ? 1 : 0
    }

    private static func resolve(options: WriterOptions, state: UInt64, budget: UInt64) -> Int {
        resolve(requested: options.resolvedCompressionThreads, state: state, budget: budget)
    }

    private static func resolve(requested: Int, state: UInt64, budget: UInt64) -> Int {
        // 完全な項目入力と圧縮・spool コピーの I/O buffer を追加予約する。
        // 一枠も入らない場合は既存の逐次経路を使い、従来受理した memoryLimit を拒否しない。
        let (reservation, overflow) = state.addingReportingOverflow(UInt64(inputLimit + OrderedEntrySpool.memoryLimit + 4 * IOChunk.size))
        guard !overflow, reservation > 0 else { return 1 }
        return max(1, min(requested, Int(min(UInt64(maximumEntryThreads), min(budget, testingMemoryBudget ?? budget) / reservation))))
    }

    var maximumPendingInputBytes: UInt64 { threads > 1 ? UInt64((threads + earlyLongPoleSlots) * Self.inputLimit) : 0 }
    var sevenZipWindowCount: Int { threads > 1 || longPoleThreads > 0 ? threads + 1 + earlyLongPoleSlots : 1 }
    var sevenZipMaximumPendingInputBytes: UInt64 {
        threads > 1 || longPoleThreads > 0 ? UInt64(sevenZipWindowCount) * UInt64(Self.inputLimit) : 0
    }

    // 満杯の通常窓から一枠だけ借りると、長い片並列が最後まで逐次になる。
    // 通常項目一つ分を残して空き枠を確保し、片数まで長い項目へ渡す。
    // 単一stream専用codecは通常窓へ貸さず、LZMAのparser+finderも予約数に含める。
    func minimumLongPoleCodecs(pieces: Int) -> Int {
        longPoleThreads > 0 ? longPoleThreads : min(pieces, max(1, codecThreads - 1))
    }
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
    private let maximumLength: UInt64
    private let reserve = ScratchFile.testingFreeSpaceReserve
    private let created = ScratchFile.testingCreated
    private var buffer = Data()
    private(set) var scratch: ScratchFile?
    private(set) var length: UInt64 = 0

    init(directory: URL, tag: String, diskBacked: Bool = false, maximumLength: UInt64 = .max) throws {
        self.directory = directory
        self.tag = tag
        self.maximumLength = maximumLength
        if diskBacked { scratch = try ScratchFile(directory: directory, tag: tag, pathExtension: "spool") }
    }

    func append(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        guard UInt64(bytes.count) <= maximumLength - length else { throw WriterError.sizeOverflow }
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

    // 空き容量には依存しない固定の膨張上限。PPMdの最大orderでのescapeとAES終端にも余裕を置く。
    // 上限は確定入力長に比例し、巨大入力でも全体をメモリへ載せない。
    static func sevenZipMaximumLength(size: UInt64) -> UInt64 {
        let (body, overflow) = size.multipliedReportingOverflow(by: 256)
        let (total, endOverflow) = body.addingReportingOverflow(UInt64(memoryLimit))
        return overflow || endOverflow ? .max : total
    }
}
