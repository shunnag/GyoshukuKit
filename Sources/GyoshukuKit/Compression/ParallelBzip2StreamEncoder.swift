import Foundation

/// ZIP / 7z 用。libbz2 の完全な block を並列圧縮し、header と EOS が一組の stream に繋ぐ。
/// tar.bz2 の連結 stream は ParallelBzip2Compressor が従来どおり担当する。
final class ParallelBzip2StreamEncoder {
    typealias Encoder = ParallelBzip2Compressor.Encoder
    @TaskLocal static var testingEncoder: Encoder?
    static let inputCap = 8 << 20

    static func chunkSize(level: Int) -> Int {
        let block = 100_000 * level - 19
        // 5 block相当の固定目標幅を使い、完全なblock境界まで走査する。並列数には依存しない。
        return 5 * block
    }

    static func estimatedChunkCount(size: UInt64, level: Int) -> Int {
        guard size > 0 else { return 1 }
        let width = UInt64(chunkSize(level: level))
        return Int(min(UInt64(WriterOptions.compressionThreadsRange.upperBound), (size - 1) / width + 1))
    }

    static func memoryReservation(level: Int, threads: Int) -> UInt64 {
        // 入力(t+1)cap、完了結果の最悪膨張とcodec状態t個、切断時の一時copyを予約する。
        let cap = UInt64(inputCap)
        return UInt64(threads + 2) * cap + UInt64(threads) * (cap + cap / 100 + 601 + UInt64(400_000 + 800_000 * level + IOChunk.size))
    }

    static func resolvedThreads(options: WriterOptions, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let budget = min(physicalMemory / 2, options.memoryLimit ?? UInt64.max)
        var threads = max(1, min(WriterOptions.compressionThreadsRange.upperBound, options.resolvedCompressionThreads))
        while threads > 1, memoryReservation(level: options.bzip2Level, threads: threads) > budget { threads -= 1 }
        return threads
    }

    private static func encodeChunk(_ input: Data, level: Int) throws -> Data {
        var output = Data()
        // libbz2 manual §3.5.1の上界を先に確保し、Dataの成長時の余剰容量を抑える。
        output.reserveCapacity(input.count + input.count / 100 + 601)
        try Bzip2StreamEncoder(level: level).write(input, finish: true) { output.append($0) }
        return output
    }

    private let level: Int
    private let target: Int
    private let cap: Int
    private let cancellation: CompressionCancellation?
    private let sequential: Bzip2StreamEncoder?
    private let inline: Bool
    private let pipeline: OrderedChunkPipeline<Data, Data, Int>
    private var scanner: Bzip2BlockScanner
    private var input = Data()
    private var bits = Bzip2SpliceBits()
    private var crc: UInt32 = 0
    private var started = false
    private var submitted = false
    private var finished = false
    private(set) var forcedCuts = 0
    var pendingInputBytes: UInt64 { UInt64(input.count) + pipeline.pendingInputBytes }

    init(level: Int, threads: Int, size: UInt64 = 0, chunkSize: Int? = nil, inputCap: Int = ParallelBzip2StreamEncoder.inputCap,
         encoder: Encoder? = nil, cancellation: CompressionCancellation? = nil, workerActivity: (@Sendable (Bool) -> Void)? = nil) throws {
        guard (1...9).contains(level) else { throw WriterError.invalidOption("bzip2Level") }
        guard WriterOptions.compressionThreadsRange.contains(threads) else { throw WriterError.invalidOption("compressionThreads") }
        precondition(inputCap > 0 && (chunkSize ?? 1) > 0)
        self.level = level; cap = inputCap
        self.cancellation = cancellation
        target = min(inputCap, chunkSize ?? Self.chunkSize(level: level))
        scanner = Bzip2BlockScanner(level: level)
        // cap 以下の既知入力は強制切断されない。大入力は1 threadでも同じ境界でspliceする。
        sequential = threads == 1 && size > 0 && size <= inputCap && chunkSize == nil
            ? try Bzip2StreamEncoder(level: level) : nil
        inline = threads == 1
        let encode = encoder ?? Self.testingEncoder ?? Self.encodeChunk
        pipeline = OrderedChunkPipeline(threads: threads, inlineSingleThread: true, cancellation: cancellation) { bytes in
            workerActivity?(true)
            defer { workerActivity?(false) }
            return try encode(bytes, level)
        }
    }

    deinit { abandon() }

    func write(_ data: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try cancellation?.check()
            try Task.checkCancellation()
            if let sequential {
                try sequential.write(data, finish: finish, emit: emit)
                finished = finish
                return
            }
            var offset = data.startIndex
            while offset < data.endIndex {
                try cancellation?.check()
                try Task.checkCancellation()
                if input.isEmpty {
                    try pipeline.waitForCapacity { try self.splice($1!, blocks: $0, emit: emit) }
                    input.reserveCapacity(cap)
                }
                let count = min(cap - input.count, IOChunk.size, data.endIndex - offset)
                input.append(data[offset..<(offset + count)])
                offset += count
                while let cut = scanner.scan(input, target: target) {
                    let blocks = scanner.blocks
                    let chunk = Data(input.prefix(cut))
                    input = Data(input.dropFirst(cut))
                    input.reserveCapacity(cap)
                    scanner = Bzip2BlockScanner(level: level)
                    try submit(chunk, blocks: blocks, emit: emit)
                }
                // 最後の入力までcapちょうどなら、finishで通常の最終blockとして扱う。
                if input.count == cap, offset < data.endIndex || !finish {
                    forcedCuts += 1
                    try submit(input, blocks: scanner.finalBlockCount, emit: emit)
                    input = Data(); scanner = Bzip2BlockScanner(level: level)
                }
            }
            if finish {
                if !submitted, scanner.blocks == 0 {
                    // 一block以下は既存の同期経路へ戻し、header/EOSも直接出力する。
                    try Bzip2StreamEncoder(level: level).write(input, finish: true, emit: emit)
                    input = Data(); finished = true
                    return
                }
                if !input.isEmpty || !submitted {
                    try submit(input, blocks: scanner.finalBlockCount, emit: emit)
                    input = Data()
                }
                try pipeline.finish { try self.splice($1!, blocks: $0, emit: emit) }
                bits.append(Bzip2SpliceBits.eosMagic, count: 48)
                bits.append(UInt64(crc), count: 32)
                try bits.finish(emit: emit)
                finished = true
            }
        } catch {
            abandon()
            throw error
        }
    }

    func abandon() {
        pipeline.abandon()
        input = Data(); bits = Bzip2SpliceBits(); finished = true
    }

    private func submit(_ chunk: Data, blocks: Int, emit: (Data) throws -> Void) throws {
        submitted = true
        try pipeline.submit(chunk, tag: blocks, weight: UInt64(chunk.count)) { try self.splice($1!, blocks: $0, emit: emit) }
        if inline { try pipeline.drain { try self.splice($1!, blocks: $0, emit: emit) } }
    }

    private func splice(_ stream: Data, blocks: Int, emit: (Data) throws -> Void) throws {
        let trailer = try Bzip2SpliceBits.trailer(stream, level: level)
        guard (blocks == 0) == (trailer.position == 32) else { throw WriterError.compression(-1) }
        if !started {
            try emit(Data([0x42, 0x5a, 0x68, UInt8(0x30 + level)]))
            started = true
        }
        try bits.appendPayload(stream, end: trailer.position, emit: emit)
        let rotation = blocks & 31
        if rotation != 0 { crc = (crc << rotation) | (crc >> (32 - rotation)) }
        crc ^= trailer.crc
    }
}
