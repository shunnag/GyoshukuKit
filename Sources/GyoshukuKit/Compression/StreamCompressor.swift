import Foundation

/// tar と単独 file の sink を共有する。既存 tar の区切り・framing は変えない。
enum StreamCompressor {
    static func make(format: ArchiveFormat, options: WriterOptions, size: UInt64? = nil) throws -> any TarCompressor {
        switch format {
        case .tarGzip:
            return try GzipCompressor(level: options.deflateLevel, threads: options.resolvedCompressionThreads)
        case .tarBzip2:
            return try ParallelBzip2Compressor(level: options.bzip2Level, threads: options.resolvedCompressionThreads)
        case .tarXZ:
            let configuration = try LZMAWriterConfiguration(options: options, size: size)
            return try ParallelXZCompressor(threads: configuration.threads, chunkSize: configuration.pieceSize,
                allowsLightChunks: configuration.properties == nil, encoder: configuration.encoder)
        case .tarLZMA: return try LZMAAloneCompressor(options: options)
        case .tarZstd: return try ParallelZstdCompressor(options: options)
        case .tarLzip: return try ParallelLzipCompressor(options: options, size: size)
        case .tarLZ4: return try LZ4TarCompressor(threads: options.resolvedCompressionThreads)
        case .tarBrotli: return try SequentialStreamCompressor(brotli: BrotliStreamEncoder())
        case .tarCompress: return try SequentialStreamCompressor(compress: LZWStreamEncoder(maxbits: 16))
        default: throw WriterError.unsupportedOption("format")
        }
    }
}

private final class LZMAAloneCompressor: TarCompressor {
    private var encoder: LZMAEncoder?
    private let properties: LZMAEncoderProperties
    private var started = false
    var pendingInputBytes: UInt64 { 0 }

    init(options: WriterOptions) throws {
        let configuration = try LZMAWriterConfiguration.singleStream(options: options)
        properties = configuration.properties!
        encoder = try lzmaWriterOperation {
            try LZMAEncoder(properties: properties, endMarker: true, memoryLimit: configuration.encoderMemory, finderThreads: configuration.finderThreads)
        }
    }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws {}

    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard let encoder else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if !started {
                var header = properties.bytes
                header.le(UInt64.max)
                try emit(header)
                started = true
            }
            try emit(try lzmaWriterOperation { try encoder.push(input) })
            if finish {
                try emit(try lzmaWriterOperation { try encoder.finish() })
                self.encoder = nil
            }
        } catch { abandon(); throw error }
    }

    func abandon() { encoder = nil }
}

private final class LZ4TarCompressor: TarCompressor {
    private let encoder: LZ4FrameEncoder
    var pendingInputBytes: UInt64 { encoder.pendingInputBytes }
    init(threads: Int) throws { encoder = try LZ4FrameEncoder(threads: threads) }
    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws {
        try encoder.finishAdditions(didEmit: didEmit, emit: emit)
    }
    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        try encoder.write(input, finish: finish, emit: emit)
    }
    func abandon() { encoder.abandon() }
}

/// 逐次 codec の内部辞書・buffer は pendingInputBytes の対象外。
private final class SequentialStreamCompressor: TarCompressor {
    private var brotli: BrotliStreamEncoder?
    private var compress: LZWStreamEncoder?
    var pendingInputBytes: UInt64 { 0 }
    init(brotli: BrotliStreamEncoder) { self.brotli = brotli }
    init(compress: LZWStreamEncoder) { self.compress = compress }
    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws {}
    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard brotli != nil || compress != nil else { throw WriterError.invalidState }
        do {
            if let brotli { try brotli.write(input, finish: finish, emit: emit) }
            if let compress { try compress.write(input, finish: finish, emit: emit) }
            if finish { abandon() }
        } catch { abandon(); throw error }
    }
    func abandon() { brotli = nil; compress = nil }
}
