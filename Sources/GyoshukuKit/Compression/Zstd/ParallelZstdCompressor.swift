import Foundation

/// tar は member 境界、単独 file は固定長の片を独立 frame にする。
/// 組立中も並列数の枠に含め、checksum 付き frame を入力順に出力する。
final class ParallelZstdCompressor: TarCompressor {
    private let chunkSize: Int
    private var layout: TarChunkCutter
    private let pipeline: OrderedChunkPipeline<Data, Data, Void>
    private var input = Data()
    private var submitted = false
    private var finished = false
    var pendingInputBytes: UInt64 { UInt64(input.count) + pipeline.pendingInputBytes }

    init(options: WriterOptions, inlineSingleThread: Bool = false) throws {
        let configuration = try ZstdWriterConfiguration(options: options)
        chunkSize = configuration.chunkSize
        layout = TarChunkCutter(limit: chunkSize)
        pipeline = OrderedChunkPipeline(threads: configuration.threads, inlineSingleThread: inlineSingleThread) {
            try ZstdFrameEncoder.encode($0, level: configuration.properties.level)
        }
    }

    deinit { abandon() }

    func beginMember(headerLength: UInt64, bodyLength: UInt64) {
        layout.beginMember(headerLength: headerLength, bodyLength: bodyLength, bufferedCount: input.count)
    }

    func beginEndOfArchive() { layout.beginEndOfArchive(bufferedCount: input.count) }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws {
        if !input.isEmpty { try submit(didEmit: didEmit, emit: emit) }
        try pipeline.drain(didEmit: didEmit) { _, result in try emit(result!) }
    }

    func write(_ data: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if layout.takePendingCut() { try submit(emit: emit) }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                if input.isEmpty {
                    try pipeline.waitForCapacity { _, result in try emit(result!) }
                    input.reserveCapacity(chunkSize)
                }
                let count = layout.nextCount(available: data.endIndex - offset, bufferedCount: input.count)
                input.append(data[offset..<(offset + count)])
                offset += count
                if layout.appended(count, bufferedCount: input.count) || (!layout.hasHints && input.count == chunkSize) {
                    try submit(emit: emit)
                }
            }
            if finish {
                if !input.isEmpty || !submitted { try submit(emit: emit) }
                try pipeline.finish { _, result in try emit(result!) }
                finished = true
            }
        } catch { abandon(); throw error }
    }

    func abandon() {
        pipeline.abandon()
        input = Data()
        finished = true
    }

    private func submit(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Data) throws -> Void) throws {
        let block = input
        input = Data()
        submitted = true
        try pipeline.submit(block, tag: (), weight: UInt64(block.count), didEmit: didEmit) { _, result in try emit(result!) }
    }
}
