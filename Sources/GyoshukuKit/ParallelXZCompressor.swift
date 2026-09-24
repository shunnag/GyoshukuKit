import Foundation

// 参照仕様: https://tukaani.org/xz/xz-file-format.txt (1.2.1)。
final class ParallelXZCompressor: TarCompressor {
    private let chunkSize: Int
    private let pipeline: LZMA2ChunkPipeline<Void>
    private var input = Data()
    private var records = Data()
    private var blockCount: UInt64 = 0
    private var started = false
    private var finished = false
    private static let outputSize = 256 * 1024
    private static let flags = Data([0, 1])

    init(threads: Int = WriterOptions().resolvedCompressionThreads,
         chunkSize: Int = LZMA2ChunkPipeline<Void>.chunkSize,
         encoder: @escaping LZMA2ChunkPipeline<Void>.Encoder = LZMA2Compressor.encode) throws {
        guard (1...64).contains(threads) else { throw WriterError.invalidOption("compressionThreads") }
        precondition((1...LZMA2ChunkPipeline<Void>.chunkSize).contains(chunkSize))
        self.chunkSize = chunkSize
        pipeline = LZMA2ChunkPipeline(threads: threads, checksum: true, encoder: encoder)
    }

    deinit { abandon() }

    func write(_ data: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if data.isEmpty && !finish { return }
            if !started {
                var header = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0])
                header.append(Self.flags)
                header.le(updateCRC(0, Self.flags))
                try emit(header)
                started = true
            }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                if input.isEmpty { input.reserveCapacity(chunkSize) }
                let count = min(data.endIndex - offset, chunkSize - input.count, Self.outputSize)
                input.append(data[offset..<(offset + count)])
                offset += count
                if input.count == chunkSize { try submit(emit: emit) }
            }
            if finish {
                if !input.isEmpty { try submit(emit: emit) }
                try pipeline.finish { _, result in try self.emitBlock(result!, emit: emit) }
                try emitIndexAndFooter(emit: emit)
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

    private func submit(emit: (Data) throws -> Void) throws {
        let block = input
        input = Data()
        try pipeline.submit(block, tag: ()) { _, result in try self.emitBlock(result!, emit: emit) }
    }

    private func emitBlock(_ result: LZMA2ChunkPipeline<Void>.Output, emit: (Data) throws -> Void) throws {
        try Task.checkCancellation()
        let compressed = result.compressed
        var header = Data([0, 0xC0])
        header.append(Self.vli(UInt64(compressed.payload.count)))
        header.append(Self.vli(compressed.uncompressedSize))
        header.append(contentsOf: [0x21, 1, compressed.properties])
        while header.count % 4 != 0 { header.append(0) }
        header[0] = UInt8(header.count / 4)
        header.le(updateCRC(0, header))
        try emit(header)
        try slices(compressed.payload, emit: emit)
        var check = Data(count: (4 - compressed.payload.count % 4) % 4)
        check.le(result.crc)
        try emit(check)
        records.append(Self.vli(UInt64(header.count + compressed.payload.count + 4)))
        records.append(Self.vli(compressed.uncompressedSize))
        blockCount = try checkedAdd(blockCount, 1)
    }

    private func emitIndexAndFooter(emit: (Data) throws -> Void) throws {
        var prefix = Data([0])
        prefix.append(Self.vli(blockCount))
        let size = try checkedAdd(UInt64(prefix.count), UInt64(records.count))
        let padding = (4 - size % 4) % 4
        let indexSize = try checkedAdd(size, padding + 4)
        guard indexSize / 4 - 1 <= UInt64(UInt32.max) else { throw WriterError.sizeOverflow }
        var crc = updateCRC(0, prefix)
        try emit(prefix)
        try slices(records) {
            crc = updateCRC(crc, $0)
            try emit($0)
        }
        var tail = Data(count: Int(padding))
        crc = updateCRC(crc, tail)
        tail.le(crc)
        try emit(tail)
        var footer = Data()
        footer.le(UInt32(indexSize / 4 - 1))
        footer.append(Self.flags)
        var result = Data()
        result.le(updateCRC(0, footer))
        result.append(footer)
        result.append(contentsOf: [0x59, 0x5A])
        try emit(result)
        records = Data()
    }

    private func slices(_ data: Data, emit: (Data) throws -> Void) throws {
        for offset in stride(from: data.startIndex, to: data.endIndex, by: Self.outputSize) {
            try Task.checkCancellation()
            try emit(data[offset..<min(offset + Self.outputSize, data.endIndex)])
        }
    }

    private static func vli(_ value: UInt64) -> Data {
        precondition(value < 1 << 63)
        var remaining = value
        var result = Data()
        repeat {
            result.append(UInt8(remaining & 0x7F) | (remaining >= 128 ? 0x80 : 0))
            remaining >>= 7
        } while remaining > 0
        return result
    }
}

typealias XZCompressor = ParallelXZCompressor
