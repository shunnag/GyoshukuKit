import Foundation

final class LZMA2ChunkPipeline<Tag> {
    static var chunkSize: Int { 16 * 1024 * 1024 }
    typealias Encoder = @Sendable (Data) throws -> XZLZMA2

    struct Output: Sendable {
        let compressed: XZLZMA2
        let crc: UInt32
    }

    private let pipeline: OrderedChunkPipeline<Data, Output, Tag>
    var pendingInputBytes: UInt64 { pipeline.pendingInputBytes }

    init(threads: Int, checksum: Bool = false, lightWeightLimit: UInt64 = 0,
         encoder: @escaping Encoder = LZMA2Compressor.encode) {
        pipeline = OrderedChunkPipeline(threads: threads, lightWeightLimit: lightWeightLimit) { input in
            Output(compressed: try encoder(input), crc: checksum ? updateCRC(0, input) : 0)
        }
    }

    func submit(_ input: Data?, tag: Tag, weight: UInt64 = 0,
                didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        if let input { precondition(!input.isEmpty && input.count <= Self.chunkSize) }
        try pipeline.submit(input, tag: tag, weight: weight, didEmit: didEmit, emit: emit)
    }

    func drain(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, Output?) throws -> Void) throws {
        try pipeline.drain(didEmit: didEmit, emit: emit)
    }
    func finish(emit: (Tag, Output?) throws -> Void) throws { try pipeline.finish(emit: emit) }
    func abandon() { pipeline.abandon() }
}
