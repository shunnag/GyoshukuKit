import Foundation

/// container 間で辞書・片・並列数の解決を共有する。未知サイズは従来の境界を保つ。
struct LZMAWriterConfiguration: Sendable {
    // XZの実際の片境界を縮め、巨大項目の構造試験を小入力で行う。
    @TaskLocal static var testingPieceSize: Int?
    let properties: LZMAEncoderProperties?
    let pieceSize: Int
    let threads: Int
    let finderThreads: Int
    let encoderMemory: Int
    let memoryPerThread: UInt64
    let memoryBudget: UInt64
    let legacyRawWindowSlack: Bool

    init(options: WriterOptions, raw: Bool = false, lzip: Bool = false, parallelFinder: Bool = false, size: UInt64? = nil,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        if let level = options.lzmaLevel, !(0...9).contains(level) { throw WriterError.invalidOption("lzmaLevel") }
        memoryBudget = min(options.memoryLimit ?? physicalMemory / 2, physicalMemory / 2)
        guard raw || options.lzmaLevel != nil else {
            properties = nil
            pieceSize = Self.testingPieceSize ?? CompressionPieceSize.resolve(standard: ParallelXZCompressor.defaultBlockSize,
                size: size, prefersSpeed: options.prefersSpeed)
            threads = options.resolvedCompressionThreads
            finderThreads = 1
            legacyRawWindowSlack = false
            encoderMemory = 0; memoryPerThread = 0
            return
        }
        let p = LZMAEncoderProperties.preset(options.lzmaLevel ?? 6,
            extreme: options.lzmaLevel != nil && options.lzmaExtreme)
        properties = p
        let standard = lzip ? max(16 << 20, 3 * p.dictSize) : p.dictSize > ParallelXZCompressor.defaultBlockSize
            ? 3 * p.dictSize : ParallelXZCompressor.defaultBlockSize
        pieceSize = raw && !lzip ? IOChunk.size : Self.testingPieceSize ?? CompressionPieceSize.resolve(standard: standard,
            floor: lzip ? max(2 << 20, p.dictSize) : 2 << 20, size: size, prefersSpeed: options.prefersSpeed)
        // memorySize は raw の辞書に応じた slack と LZMA2 の2 MiBを含む。
        // LZMA2 の range buffer は64 KiBの pack limit 内。raw は最大16 MiBの伸長分も予約する。
        let preferredMemory = LZMAEncodingEngine.memorySize(properties: p, dictionary: p.dictSize, chunked: !raw)
            + (raw ? (16 << 20) - 131072 : 0)
        // 大きいslackは任意。従来の64 KiBなら収まる予算も受理する。
        legacyRawWindowSlack = raw && UInt64(preferredMemory) + 2 * UInt64(pieceSize) > memoryBudget
        let sequentialMemory = LZMAEncodingEngine.memorySize(properties: p, dictionary: p.dictSize, chunked: !raw,
            legacyRawWindowSlack: legacyRawWindowSlack) + (raw ? (16 << 20) - 131072 : 0)
        // 任意の高速化のために従来受理した予算を拒否しない。追加bufferが収まる場合だけ使う。
        finderThreads = raw && !lzip && parallelFinder && options.resolvedCompressionThreads >= 2
            && UInt64(sequentialMemory + LZMAMatchFinderPipeline.memorySize + 2 * pieceSize) <= memoryBudget ? 2 : 1
        encoderMemory = sequentialMemory + (finderThreads == 2 ? LZMAMatchFinderPipeline.memorySize : 0)
        memoryPerThread = UInt64(encoderMemory) + 2 * UInt64(pieceSize)
        guard memoryPerThread <= memoryBudget else { throw WriterError.invalidOption("memoryLimit") }
        threads = raw && !lzip ? 1 : min(options.resolvedCompressionThreads, Int(min(UInt64(WriterOptions.compressionThreadsRange.upperBound), memoryBudget / memoryPerThread)))
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
            try LZMAEncoder(properties: properties, expectedSize: size, endMarker: endMarker, memoryLimit: encoderMemory,
                finderThreads: finderThreads, legacyRawWindowSlack: legacyRawWindowSlack)
        }
    }

    /// 単独 LZMA / lzip は nil も自前 level 6。既存 ZIP / 7z の nil の解決は変えない。
    static func singleStream(options: WriterOptions, lzip: Bool = false, size: UInt64? = nil) throws -> Self {
        var resolved = options
        resolved.lzmaLevel = options.lzmaLevel ?? 6
        return try Self(options: resolved, raw: true, lzip: lzip, parallelFinder: !lzip, size: size)
    }
}

/// ZIP の通常窓とは別に予約した一coreを、同時に一つの大項目だけへ貸す。
final class LZMAFinderThreadReservation: @unchecked Sendable {
    private let lock = NSLock()
    private let enabled: Bool
    private var busy = false
    init(enabled: Bool) { self.enabled = enabled }
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled && !busy else { return false }
        busy = true; return true
    }
    func release() { lock.lock(); busy = false; lock.unlock() }
}

/// 内部 encoder の失敗を公開 writer の error に揃え、取消しはそのまま伝える。
func lzmaWriterOperation<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch LZMAEncodingError.memoryLimit { throw WriterError.invalidOption("memoryLimit") }
    catch is LZMAEncodingError { throw WriterError.compression(-1) }
}
