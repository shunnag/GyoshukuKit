import Foundation
private import Compression

// 出典: LZ4 Frame Format v1.6.4 / LZ4 Block Format（framing は仕様からの独立実装）。
// https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md
// https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
// Apple SDK compression.h: COMPRESSION_LZ4_RAW は buffer API 専用の標準 block。
// https://developer.apple.com/documentation/compression/compression_lz4_raw
// COMPRESSION_LZ4 の Apple 独自 wrapper は標準 LZ4 frame の中に入れない。
final class LZ4FrameEncoder {
    static let blockSize = 4 * 1024 * 1024
    private let contentSize: UInt64?
    private let pipeline: OrderedChunkPipeline<Data, Data, Void>
    private var input = Data()
    private var checksum = XXH32()
    private var size: UInt64 = 0
    private var started = false
    private var finished = false
    private let blockChecksums: Bool

    var pendingInputBytes: UInt64 { UInt64(input.count) + pipeline.pendingInputBytes }

    /// 一つの frame 内の独立 block を並列化する。入力と結果の枠は threads 個まで。
    /// contentSize が既知なら header に記録し、finish 時にも一致を検査する。
    init(contentSize: UInt64? = nil, blockChecksums: Bool = false,
         threads: Int = WriterOptions().resolvedCompressionThreads) throws {
        guard (1...64).contains(threads) else { throw WriterError.invalidOption("compressionThreads") }
        self.contentSize = contentSize
        self.blockChecksums = blockChecksums
        pipeline = OrderedChunkPipeline(threads: threads) { input in
            try Self.encodeBlock(input, checksum: blockChecksums)
        }
    }

    deinit { abandon() }

    func write(_ data: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            let nextSize = try checkedAdd(size, UInt64(data.count))
            if let contentSize, nextSize > contentSize || (finish && nextSize != contentSize) {
                throw WriterError.invalidOption("lz4ContentSize")
            }
            if data.isEmpty && !finish { return }
            if !started {
                var descriptor = Data([0x64 | (blockChecksums ? 0x10 : 0) | (contentSize == nil ? 0 : 0x08), 0x70])
                if let contentSize { descriptor.le(contentSize) }
                var header = Data()
                header.le(UInt32(0x184D2204))
                header.append(descriptor)
                header.append(UInt8(truncatingIfNeeded: XXH32.digest(descriptor) >> 8))
                try emit(header)
                started = true
            }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                if input.isEmpty {
                    // 組立中の block も枠に含め、大入力を渡されても先読みは増やさない。
                    try pipeline.waitForCapacity { _, result in try emit(result!) }
                    input.reserveCapacity(Self.blockSize)
                }
                let count = min(Self.blockSize - input.count, data.endIndex - offset)
                let piece = data[offset..<(offset + count)]
                input.append(piece)
                checksum.update(piece)
                offset += count
                if input.count == Self.blockSize { try submit(emit: emit) }
            }
            size = nextSize
            if finish {
                if !input.isEmpty { try submit(emit: emit) }
                try pipeline.finish { _, result in try emit(result!) }
                var footer = Data()
                footer.le(UInt32(0))
                footer.le(checksum.value)
                try emit(footer)
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
        try pipeline.submit(block, tag: (), weight: UInt64(block.count)) { _, result in try emit(result!) }
    }

    private static func encodeBlock(_ input: Data, checksum: Bool) throws -> Data {
        try Task.checkCancellation()
        // 縮む場合だけ採用するので、出力は元の長さ - 1 まで。0 は容量不足か native error。
        // どちらでも stored block に退避すれば内容を失わず、再試行や容量増加も不要。
        var compressed = Data(count: max(0, input.count - 1))
        let count: Int = compressed.isEmpty ? 0 : input.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                compression_encode_buffer(destination.baseAddress!.assumingMemoryBound(to: UInt8.self), destination.count,
                                          source.baseAddress!.assumingMemoryBound(to: UInt8.self), source.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        try Task.checkCancellation()
        let payload: Data
        let word: UInt32
        if count > 0 {
            compressed.removeSubrange(count..<compressed.count)
            payload = compressed
            word = UInt32(count)
        } else {
            payload = input
            word = UInt32(input.count) | 0x8000_0000
        }
        var result = Data()
        result.reserveCapacity(payload.count + 8)
        result.le(word)
        result.append(payload)
        if checksum { result.le(XXH32.digest(payload)) }
        return result
    }
}
