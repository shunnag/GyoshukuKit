import Foundation

final class LZMA2ChunkPipeline<Tag> {
    static var chunkSize: Int { 16 * 1024 * 1024 }
    typealias Encoder = @Sendable (Data) throws -> XZLZMA2

    struct Output: Sendable {
        let compressed: XZLZMA2
        let crc: UInt32
    }

    private let pipeline: OrderedChunkPipeline<Data, Output, Tag>

    init(threads: Int, checksum: Bool = false, encoder: @escaping Encoder = LZMA2Compressor.encode) {
        pipeline = OrderedChunkPipeline(threads: threads) { input in
            Output(compressed: try encoder(input), crc: checksum ? updateCRC(0, input) : 0)
        }
    }

    func submit(_ input: Data?, tag: Tag, emit: (Tag, Output?) throws -> Void) throws {
        if let input { precondition(!input.isEmpty && input.count <= Self.chunkSize) }
        try pipeline.submit(input, tag: tag, emit: emit)
    }

    func finish(emit: (Tag, Output?) throws -> Void) throws { try pipeline.finish(emit: emit) }
    func abandon() { pipeline.abandon() }
}
