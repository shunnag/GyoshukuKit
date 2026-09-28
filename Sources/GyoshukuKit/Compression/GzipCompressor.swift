import Foundation

/// gzip の TarCompressor。DeflateBlock ごとに OrderedChunkPipeline で並列に deflate し、一つの gzip member に連結する。
/// ParallelBzip2Compressor / ParallelXZCompressor と同じ並列 sink で、名前にだけ接頭辞を付けない。
final class GzipCompressor: TarCompressor {
    private let level: Int
    private let blockSize: Int
    private var layout: TarChunkLayout
    private let pipeline: OrderedChunkPipeline<DeflateBlock, Data, Void>
    private var input = Data()
    private var dictionary = Data()
    private var crc: UInt32 = 0
    private var size: UInt32 = 0
    private var started = false
    private var finished = false
    var pendingInputBytes: UInt64 { UInt64(input.count) + pipeline.pendingInputBytes }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws {
        if !input.isEmpty { try submit(final: false, didEmit: didEmit, emit: emit) }
        try pipeline.drain(didEmit: didEmit) { _, result in try emit(result!) }
    }

    init(level: Int, threads: Int = WriterOptions().resolvedCompressionThreads,
         blockSize: Int = DeflateBlock.size, encoder: @escaping DeflateBlock.Encoder = DeflateBlock.encode) throws {
        guard (0...9).contains(level) else { throw WriterError.invalidOption("deflateLevel") }
        guard (1...64).contains(threads) else { throw WriterError.invalidOption("compressionThreads") }
        precondition((1...DeflateBlock.size).contains(blockSize))
        self.level = level
        self.blockSize = blockSize
        layout = TarChunkLayout(limit: blockSize)
        pipeline = OrderedChunkPipeline(threads: threads) { try encoder($0, level) }
    }

    func beginMember(headerLength: UInt64, bodyLength: UInt64) {
        layout.beginMember(headerLength: headerLength, bodyLength: bodyLength, bufferedCount: input.count)
    }

    func beginEndOfArchive() { layout.beginEndOfArchive(bufferedCount: input.count) }

    func write(_ data: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if data.isEmpty && !finish { return }
            if !started {
                try emit(GzipFraming.header(level: level))
                started = true
            }
            if layout.takePendingCut() { try submit(final: false, emit: emit) }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                // hint がなければ満杯でも次の入力まで保持し、最後だけ FINISH にする。
                if !layout.hasHints && input.count == blockSize { try submit(final: false, emit: emit) }
                if input.isEmpty {
                    try pipeline.waitForCapacity { _, result in try emit(result!) }
                    input.reserveCapacity(blockSize)
                }
                let count = layout.nextCount(available: data.endIndex - offset, bufferedCount: input.count)
                let chunk = data[offset..<(offset + count)]
                input.append(chunk)
                crc = updateCRC(crc, chunk)
                size &+= UInt32(count)
                offset += count
                if layout.appended(count, bufferedCount: input.count) { try submit(final: false, emit: emit) }
            }
            if finish {
                if input.isEmpty { try pipeline.waitForCapacity { _, result in try emit(result!) } }
                try submit(final: true, emit: emit)
                try pipeline.finish { _, result in try emit(result!) }
                try emit(GzipFraming.trailer(crc: crc, imageLength: UInt64(size)))
                finished = true
            }
        } catch {
            abandon()
            throw error
        }
    }

    func abandon() {
        pipeline.abandon()
        input = Data()
        dictionary = Data()
        finished = true
    }

    private func submit(final: Bool, didEmit: ((UInt64) throws -> Void)? = nil, emit: (Data) throws -> Void) throws {
        let block = DeflateBlock(input: input, dictionary: dictionary, final: final)
        if final {
            dictionary = Data()
        } else if layout.hasHints && input.count < DeflateBlock.windowSize {
            // 短い header 群をまたいでも、直前の全入力から 32 KiB を残す。
            dictionary = Data(dictionary.suffix(DeflateBlock.windowSize - input.count))
            dictionary.append(input)
        } else {
            dictionary = DeflateBlock.dictionary(from: input)
        }
        input = Data()
        try pipeline.submit(block, tag: (), weight: UInt64(block.input.count), didEmit: didEmit) { _, result in try emit(result!) }
    }
}
