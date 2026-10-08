import Foundation

/// container 間で辞書・片・並列数の解決を共有する。Apple 経路は従来の境界を保つ。
struct LZMAWriterConfiguration: Sendable {
    let properties: LZMAEncoderProperties?
    let pieceSize: Int
    let threads: Int
    let encoderMemory: Int
    let memoryPerThread: UInt64
    let memoryBudget: UInt64

    init(options: WriterOptions, raw: Bool = false, lzip: Bool = false,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        if let level = options.lzmaLevel, !(0...9).contains(level) { throw WriterError.invalidOption("lzmaLevel") }
        memoryBudget = min(options.memoryLimit ?? physicalMemory / 2, physicalMemory / 2)
        guard raw || options.lzmaLevel != nil else {
            properties = nil
            pieceSize = ParallelXZCompressor.defaultBlockSize
            threads = options.resolvedCompressionThreads
            encoderMemory = 0; memoryPerThread = 0
            return
        }
        let p = LZMAEncoderProperties.preset(options.lzmaLevel ?? 6,
            extreme: options.lzmaLevel != nil && options.lzmaExtreme)
        properties = p
        pieceSize = lzip ? max(16 << 20, 3 * p.dictSize) : raw ? IOChunk.size : p.dictSize > ParallelXZCompressor.defaultBlockSize
            ? max(ParallelXZCompressor.defaultBlockSize, 3 * p.dictSize) : ParallelXZCompressor.defaultBlockSize
        // memorySize は raw の辞書に応じた slack と LZMA2 の2 MiBを含む。
        // LZMA2 の range buffer は64 KiBの pack limit 内。raw は最大16 MiBの伸長分も予約する。
        encoderMemory = LZMAEncodingEngine.memorySize(properties: p, dictionary: p.dictSize, chunked: !raw)
            + (raw ? (16 << 20) - 131072 : 0)
        memoryPerThread = UInt64(encoderMemory) + 2 * UInt64(pieceSize)
        guard memoryPerThread <= memoryBudget else { throw WriterError.invalidOption("memoryLimit") }
        threads = raw && !lzip ? 1 : min(options.resolvedCompressionThreads, Int(min(64, memoryBudget / memoryPerThread)))
    }

    var encoder: LZMA2ChunkPipeline<Void>.Encoder {
        guard let properties else { return LZMA2Compressor.encode }
        let memory = encoderMemory
        return { input in
            try lzmaWriterOperation {
                let encoder = try LZMA2Encoder(properties: properties, expectedSize: UInt64(input.count), memoryLimit: memory)
                let payload = try encoder.push(input) + encoder.finish()
                return XZLZMA2(payload: payload, properties: encoder.dictionaryProperty,
                    uncompressedSize: UInt64(input.count), payloadOffset: 0)
            }
        }
    }

    func rawEncoder(size: UInt64, endMarker: Bool) throws -> LZMAEncoder {
        guard let properties else { throw WriterError.invalidState }
        return try lzmaWriterOperation {
            try LZMAEncoder(properties: properties, expectedSize: size, endMarker: endMarker, memoryLimit: encoderMemory)
        }
    }

    /// 単独 LZMA / lzip は nil も自前 level 6。既存 ZIP / 7z の nil の解決は変えない。
    static func singleStream(options: WriterOptions, lzip: Bool = false) throws -> Self {
        var resolved = options
        resolved.lzmaLevel = options.lzmaLevel ?? 6
        return try Self(options: resolved, raw: true, lzip: lzip)
    }
}

/// 内部 encoder の失敗を公開 writer の error に揃え、取消しはそのまま伝える。
func lzmaWriterOperation<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch LZMAEncodingError.memoryLimit { throw WriterError.invalidOption("memoryLimit") }
    catch is LZMAEncodingError { throw WriterError.compression(-1) }
}
