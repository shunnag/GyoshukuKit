import Foundation

final class ParallelXZCompressor: TarCompressor {
    static let defaultBlockSize = 16 * 1024 * 1024
    static let memberPackingSize = 4 * 1024 * 1024
    static let lightChunkLimit = 64 * 1024
    private let chunkSize: Int
    private var layout: TarChunkCutter
    private let pipeline: LZMA2ChunkPipeline<Void>
    private var input = Data()
    private var records = Data()
    private var blockCount: UInt64 = 0
    private var started = false
    private var finished = false
    var pendingInputBytes: UInt64 { UInt64(input.count) + pipeline.pendingInputBytes }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws {
        if !input.isEmpty { try submit(didEmit: didEmit, emit: emit) }
        try pipeline.drain(didEmit: didEmit) { _, result in try self.emitBlock(result!, emit: emit) }
    }

    init(threads: Int = WriterOptions().resolvedCompressionThreads,
         chunkSize: Int = ParallelXZCompressor.defaultBlockSize,
         packingSize: Int? = nil,
         encoder: @escaping LZMA2ChunkPipeline<Void>.Encoder = LZMA2Compressor.encode) throws {
        guard (1...64).contains(threads) else { throw WriterError.invalidOption("compressionThreads") }
        precondition((1...LZMA2ChunkPipeline<Void>.chunkSize).contains(chunkSize))
        let packing = min(packingSize ?? Self.memberPackingSize, chunkSize)
        precondition((1...chunkSize).contains(packing))
        self.chunkSize = chunkSize
        layout = TarChunkCutter(limits: .init(packing: packing, piece: chunkSize))
        pipeline = LZMA2ChunkPipeline(threads: threads, checksum: true,
                                     lightWeightLimit: threads > 1 ? UInt64(Self.lightChunkLimit) : 0, encoder: encoder)
    }

    deinit { abandon() }

    func beginMember(headerLength: UInt64, bodyLength: UInt64) {
        layout.beginMember(headerLength: headerLength, bodyLength: bodyLength, bufferedCount: input.count)
    }

    func beginEndOfArchive() { layout.beginEndOfArchive(bufferedCount: input.count) }

    func write(_ data: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if data.isEmpty && !finish { return }
            if !started {
                try emit(XZFraming.streamHeader)
                started = true
            }
            if layout.takePendingCut() { try submit(emit: emit) }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                if input.isEmpty { input.reserveCapacity(chunkSize) }
                let count = layout.nextCount(available: data.endIndex - offset, bufferedCount: input.count)
                input.append(data[offset..<(offset + count)])
                offset += count
                let cut = layout.appended(count, bufferedCount: input.count)
                if cut || (!layout.hasHints && input.count == chunkSize) { try submit(emit: emit) }
            }
            if finish {
                if !input.isEmpty { try submit(emit: emit) }
                try pipeline.finish { _, result in try self.emitBlock(result!, emit: emit) }
                try XZFraming.emitIndexAndFooter(records: records, blockCount: blockCount, emit: emit)
                records = Data()
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
        records = Data()
        finished = true
    }

    private func submit(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Data) throws -> Void) throws {
        let block = input
        input = Data()
        try pipeline.submit(block, tag: (), weight: UInt64(block.count), didEmit: didEmit) { _, result in try self.emitBlock(result!, emit: emit) }
    }

    private func emitBlock(_ result: LZMA2ChunkPipeline<Void>.Output, emit: (Data) throws -> Void) throws {
        records.append(try XZFraming.emitBlock(result.compressed, crc: result.crc, emit: emit))
        blockCount = try checkedAdd(blockCount, 1)
    }
}
