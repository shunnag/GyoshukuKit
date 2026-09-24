import Foundation

final class GzipCompressor: TarCompressor {
    private let level: Int
    private let blockSize: Int
    private let pipeline: OrderedChunkPipeline<DeflateBlock, Data, Void>
    private var input = Data()
    private var dictionary = Data()
    private var crc: UInt32 = 0
    private var size: UInt32 = 0
    private var started = false
    private var finished = false

    init(level: Int, threads: Int = WriterOptions().resolvedCompressionThreads,
         blockSize: Int = DeflateBlock.size, encoder: @escaping DeflateBlock.Encoder = DeflateBlock.encode) throws {
        guard (0...9).contains(level) else { throw WriterError.invalidOption("deflateLevel") }
        guard (1...64).contains(threads) else { throw WriterError.invalidOption("compressionThreads") }
        precondition((1...DeflateBlock.size).contains(blockSize))
        self.level = level
        self.blockSize = blockSize
        pipeline = OrderedChunkPipeline(threads: threads) { try encoder($0, level) }
    }

    func write(_ data: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if data.isEmpty && !finish { return }
            if !started {
                try emit(Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, level == 9 ? 2 : (level <= 1 ? 4 : 0), 3]))
                started = true
            }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                // 満杯でも次の入力まで保持し、最後の block だけ FINISH にする。
                if input.count == blockSize { try submit(final: false, emit: emit) }
                if input.isEmpty {
                    try pipeline.waitForCapacity { _, result in try emit(result!) }
                    input.reserveCapacity(blockSize)
                }
                let count = min(data.endIndex - offset, blockSize - input.count, 256 * 1024)
                let chunk = data[offset..<(offset + count)]
                input.append(chunk)
                crc = updateCRC(crc, chunk)
                size &+= UInt32(count)
                offset += count
            }
            if finish {
                if input.isEmpty { try pipeline.waitForCapacity { _, result in try emit(result!) } }
                try submit(final: true, emit: emit)
                try pipeline.finish { _, result in try emit(result!) }
                var trailer = Data()
                trailer.le(crc)
                trailer.le(size)
                try emit(trailer)
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

    private func submit(final: Bool, emit: (Data) throws -> Void) throws {
        let block = DeflateBlock(input: input, dictionary: dictionary, final: final)
        dictionary = final ? Data() : DeflateBlock.dictionary(from: input)
        input = Data()
        try pipeline.submit(block, tag: ()) { _, result in try emit(result!) }
    }
}
