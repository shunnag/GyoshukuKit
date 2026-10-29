import Foundation

final class LZMA2ChunkPipeline<Tag> {
    static var chunkSize: Int { 16 * 1024 * 1024 }
    typealias Encoder = @Sendable (Data) throws -> XZLZMA2

    struct Output: Sendable {
        let compressed: XZLZMA2
        let crc: UInt32
    }

    private struct Input: Sendable { let bytes: Data; let stored: Bool }
    private let pipeline: OrderedChunkPipeline<Input, Output, Tag>
    private let pieceSize: Int
    var pendingInputBytes: UInt64 { pipeline.pendingInputBytes }

    init(threads: Int, checksum: Bool = false, lightWeightLimit: UInt64 = 0, pieceSize: Int = LZMA2ChunkPipeline.chunkSize,
         inlineSingleThread: Bool = false, encoder: @escaping Encoder = LZMA2Compressor.encode) {
        precondition(pieceSize > 0)
        self.pieceSize = pieceSize
        pipeline = OrderedChunkPipeline(threads: threads, lightWeightLimit: lightWeightLimit, inlineSingleThread: inlineSingleThread) { input in
            Output(compressed: try input.stored ? XZLZMA2.storing(input.bytes) : encoder(input.bytes),
                   crc: checksum ? updateCRC(0, input.bytes) : 0)
        }
    }

    func submit(_ input: Data?, tag: Tag, weight: UInt64 = 0, stored: Bool = false,
                didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        if let input { precondition(!input.isEmpty && input.count <= pieceSize) }
        try pipeline.submit(input.map { Input(bytes: $0, stored: stored) }, tag: tag, weight: weight, didEmit: didEmit, emit: emit)
    }

    func drain(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        try pipeline.drain(didEmit: didEmit, emit: emit)
    }
    func finish(emit: (Tag, Output?) throws -> Void) throws { try pipeline.finish(emit: emit) }
    func abandon() { pipeline.abandon() }
}
