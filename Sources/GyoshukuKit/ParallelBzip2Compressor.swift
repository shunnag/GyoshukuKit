import Foundation

final class ParallelBzip2Compressor: TarCompressor {
    typealias Encoder = @Sendable (Data, Int) throws -> Data
    // RLE1 で縮む tar 入力も、複数の内部 block を満たしてから区切る。
    static func chunkSize(level: Int) -> Int { 5 * level * 100_000 }
    private let chunkSize: Int
    private let pipeline: OrderedChunkPipeline<Data, Data, Void>
    private var input = Data()
    private var submitted = false
    private var finished = false

    init(level: Int, threads: Int, encoder: @escaping Encoder = ParallelBzip2Compressor.encode) throws {
        guard (1...9).contains(level) else { throw WriterError.invalidOption("bzip2Level") }
        guard (1...64).contains(threads) else { throw WriterError.invalidOption("compressionThreads") }
        chunkSize = Self.chunkSize(level: level)
        pipeline = OrderedChunkPipeline(threads: threads) { try encoder($0, level) }
    }

    static func encode(_ input: Data, level: Int) throws -> Data {
        var result = Data()
        try Bzip2Compressor(level: level).write(input, finish: true) { result.append($0) }
        return result
    }

    func write(_ data: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                if input.isEmpty {
                    try pipeline.waitForCapacity { _, result in try emit(result!) }
                    input.reserveCapacity(chunkSize)
                }
                let count = min(data.endIndex - offset, chunkSize - input.count, 256 * 1024)
                input.append(data[offset..<(offset + count)])
                offset += count
                if input.count == chunkSize { try submit(emit: emit) }
            }
            if finish {
                if !input.isEmpty || !submitted { try submit(emit: emit) }
                try pipeline.finish { _, result in try emit(result!) }
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
        finished = true
    }

    private func submit(emit: (Data) throws -> Void) throws {
        let block = input
        input = Data()
        submitted = true
        try pipeline.submit(block, tag: ()) { _, result in try emit(result!) }
    }
}
