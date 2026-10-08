import Foundation

/// lzip version 1 の framing を公開仕様から実装する。lzip / lzlib の source は使わない。
/// https://www.nongnu.org/lzip/manual/lzip_manual.html#File-format
/// LZMA1 は lc=3 / lp=0 / pb=2 と EOS。DS は 2^n - (2^n / 16) × fraction。
enum LzipFraming {
    static func dictionaryCode(_ size: Int) throws -> UInt8 {
        guard (4096...(1 << 29)).contains(size) else { throw WriterError.invalidOption("lzipDictionarySize") }
        for exponent in 12...29 {
            let base = 1 << exponent
            for fraction in 0...7 where base - (base / 16) * fraction == size {
                return UInt8(exponent | (fraction << 5))
            }
        }
        throw WriterError.invalidOption("lzipDictionarySize")
    }

    static func encode(_ input: Data, configuration: LZMAWriterConfiguration) throws -> Data {
        let properties = configuration.properties!
        var output = Data("LZIP".utf8)
        output.append(1)
        output.append(try dictionaryCode(properties.dictSize))
        let encoder = try configuration.rawEncoder(size: UInt64(input.count), endMarker: true)
        // push 一回の戻り値を member 全体の大きさにしない。range buffer を逐次 drain する。
        for offset in stride(from: input.startIndex, to: input.endIndex, by: IOChunk.size) {
            try Task.checkCancellation()
            output.append(try lzmaWriterOperation { try encoder.push(input[offset..<min(input.endIndex, offset + IOChunk.size)]) })
        }
        output.append(try lzmaWriterOperation { try encoder.finish() })
        let memberSize = try checkedAdd(UInt64(output.count), 20)
        output.le(updateCRC(0, input))
        output.le(UInt64(input.count))
        output.le(memberSize)
        return output
    }
}

/// tar は member 境界を優先する。単独 file は同じ上限で独立 member に分割する。
/// 入力・出力の最大二片と raw encoder の作業量を LZMAWriterConfiguration が数え、並列数を制限する。
final class ParallelLzipCompressor: TarCompressor {
    private let chunkSize: Int
    private var layout: TarChunkCutter
    private let pipeline: OrderedChunkPipeline<Data, Data, Void>
    private var input = Data()
    private var submitted = false
    private var finished = false
    var pendingInputBytes: UInt64 { UInt64(input.count) + pipeline.pendingInputBytes }

    init(options: WriterOptions) throws {
        let configuration = try LZMAWriterConfiguration.singleStream(options: options, lzip: true)
        chunkSize = configuration.pieceSize
        layout = TarChunkCutter(limit: chunkSize)
        pipeline = OrderedChunkPipeline(threads: configuration.threads) {
            try LzipFraming.encode($0, configuration: configuration)
        }
    }

    deinit { abandon() }

    func beginMember(headerLength: UInt64, bodyLength: UInt64) {
        layout.beginMember(headerLength: headerLength, bodyLength: bodyLength, bufferedCount: input.count)
    }

    func beginEndOfArchive() { layout.beginEndOfArchive(bufferedCount: input.count) }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?, emit: (Data) throws -> Void) throws {
        if !input.isEmpty { try submit(didEmit: didEmit, emit: emit) }
        try pipeline.drain(didEmit: didEmit) { _, result in try emit(result!) }
    }

    func write(_ data: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if layout.takePendingCut() { try submit(emit: emit) }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                if input.isEmpty {
                    try pipeline.waitForCapacity { _, result in try emit(result!) }
                    input.reserveCapacity(chunkSize)
                }
                let count = layout.nextCount(available: data.endIndex - offset, bufferedCount: input.count)
                input.append(data[offset..<(offset + count)])
                offset += count
                if layout.appended(count, bufferedCount: input.count) || (!layout.hasHints && input.count == chunkSize) {
                    try submit(emit: emit)
                }
            }
            if finish {
                if !input.isEmpty || !submitted { try submit(emit: emit) }
                try pipeline.finish { _, result in try emit(result!) }
                finished = true
            }
        } catch { abandon(); throw error }
    }

    func abandon() {
        pipeline.abandon()
        input = Data()
        finished = true
    }

    private func submit(didEmit: ((UInt64) throws -> Void)? = nil, emit: (Data) throws -> Void) throws {
        let block = input
        input = Data()
        submitted = true
        try pipeline.submit(block, tag: (), weight: UInt64(block.count), didEmit: didEmit) { _, result in try emit(result!) }
    }
}
