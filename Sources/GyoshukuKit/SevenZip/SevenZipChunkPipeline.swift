import Foundation

enum SevenZipChunkOutput: Sendable {
    case lzma2(XZLZMA2)
    case packed(Data)
    case input(Data)
}

/// LZMA2 / Deflate の block は並列化し、LZMA / Copy / BZip2 の入力は同期で folder encoder に渡す。
/// BZip2 の状態は folder が持つので、複数の bzip2 stream を連結しない。
final class SevenZipChunkPipeline<Tag> {
    private enum Input: Sendable {
        case lzma2(Data)
        case deflate(DeflateBlock)
    }
    private let method: SevenZipCompressionMethod
    private let pipeline: OrderedChunkPipeline<Input, SevenZipChunkOutput, Tag>
    private var dictionary = Data()
    let chunkSize: Int
    var pendingInputBytes: UInt64 { pipeline.pendingInputBytes }

    init(options: WriterOptions, chunkSize: Int? = nil,
         encoder: LZMA2ChunkPipeline<Void>.Encoder? = nil) throws {
        let configuration = try LZMAWriterConfiguration(options: options.sevenZipMethod == .lzma || options.sevenZipMethod == .lzma2
            ? options : WriterOptions(compressionThreads: options.compressionThreads), raw: options.sevenZipMethod == .lzma)
        let pieceSize = chunkSize ?? configuration.pieceSize
        precondition(pieceSize > 0)
        let encode = encoder ?? configuration.encoder
        method = options.sevenZipMethod
        switch method {
        case .lzma2: self.chunkSize = pieceSize
        case .deflate: self.chunkSize = min(pieceSize, DeflateBlock.size)
        case .lzma, .bzip2, .copy: self.chunkSize = min(pieceSize, IOChunk.size)
        }
        pipeline = OrderedChunkPipeline(threads: method == .lzma2 ? configuration.threads : options.resolvedCompressionThreads) { input in
            switch input {
            case .lzma2(let bytes): return .lzma2(try encode(bytes))
            case .deflate(let block): return .packed(try DeflateBlock.encode(block, level: options.deflateLevel))
            }
        }
    }

    func submit(_ data: Data?, tag: Tag, isLast: Bool, weight: UInt64 = 0,
                emit: (Tag, SevenZipChunkOutput?) throws -> Void) throws {
        if let data { precondition(!data.isEmpty && data.count <= chunkSize) }
        switch method {
        case .lzma2:
            try pipeline.submit(data.map { .lzma2($0) }, tag: tag, weight: weight, emit: emit)
        case .deflate:
            let block = data.map { DeflateBlock(input: $0, dictionary: dictionary, final: isLast) }
            dictionary = isLast ? Data() : data.map(DeflateBlock.dictionary(from:)) ?? Data()
            try pipeline.submit(block.map { .deflate($0) }, tag: tag, weight: weight, emit: emit)
        case .lzma, .bzip2, .copy:
            try Task.checkCancellation()
            try emit(tag, data.map { .input($0) })
        }
    }

    func drain(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Tag, SevenZipChunkOutput?) throws -> Void) throws {
        try pipeline.drain(didEmit: didEmit, emit: emit)
    }
    func finish(emit: (Tag, SevenZipChunkOutput?) throws -> Void) throws { try pipeline.finish(emit: emit) }
    func abandon() { pipeline.abandon() }
}
