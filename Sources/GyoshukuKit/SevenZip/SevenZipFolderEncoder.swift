import Foundation
internal import KaitoKit

// writer・solid の作り直しで圧縮方式と AES の framing を共有する。header の既定は LZMA2。
final class SevenZipFolderEncoder {
    let aes: SevenZipAESEncryptor?
    private let method: SevenZipCompressionMethod
    private let deflateLevel: Int
    private let bzip2Level: Int
    private var bzip2: Bzip2StreamEncoder?
    private var rawLZMA: LZMAEncoder?
    private let lzma: LZMAWriterConfiguration?
    private let size: UInt64
    var lzmaProperties: Data { lzma?.properties?.bytes ?? LZMAEncoderProperties.preset(6).bytes }
    private(set) var properties: UInt8 = 0
    private(set) var compressedSize: UInt64 = 0
    private(set) var packedSize: UInt64 = 0

    init(aes: SevenZipAESEncryptor?, method: SevenZipCompressionMethod = .lzma2, deflateLevel: Int = 6, bzip2Level: Int = 9,
         lzma: LZMAWriterConfiguration? = nil, size: UInt64 = 0) {
        self.aes = aes; self.method = method; self.deflateLevel = deflateLevel; self.bzip2Level = bzip2Level
        self.lzma = lzma; self.size = size
        // 空の solid folder でも選択した辞書を宣言する。Apple 経路の既定値は変えない。
        if method == .lzma2, let properties = lzma?.properties {
            self.properties = LZMA2Encoder.dictionaryProperty(for: properties.dictSize)
        }
    }

    func consume(_ result: SevenZipChunkOutput, write: (Data) throws -> Void) throws {
        switch result {
        case .lzma2(let compressed):
            guard let control = compressed.payload.first, control == 1 || control >= 0xE0,
                  compressed.payload.last == 0 else { throw WriterError.compression(-1) }
            properties = max(properties, compressed.properties)
            try emit(compressed.payload.dropLast(), write: write)
        case .packed(let bytes): try emit(bytes, write: write)
        case .input(let bytes):
            if method == .lzma {
                try beginRawLZMA()
                try emit(lzmaWriterOperation { try rawLZMA!.push(bytes) }, write: write)
            } else if method == .bzip2 {
                if bzip2 == nil { bzip2 = try Bzip2StreamEncoder(level: bzip2Level) }
                try bzip2!.write(bytes, finish: false) { try emit($0, write: write) }
            } else { try emit(bytes, write: write) }
        }
    }
    func finish(write: (Data) throws -> Void) throws {
        switch method {
        case .lzma2: try emit(Data([0]), write: write)
        case .lzma:
            try beginRawLZMA()
            try emit(lzmaWriterOperation { try rawLZMA!.finish() }, write: write)
            rawLZMA = nil
        case .bzip2:
            if bzip2 == nil { bzip2 = try Bzip2StreamEncoder(level: bzip2Level) }
            try bzip2!.write(Data(), finish: true) { try emit($0, write: write) }
            bzip2 = nil
        case .deflate:
            // 生存する substream が全て空でも、Deflate の終端を持つ一つの stream にする。
            if compressedSize == 0 {
                try emit(DeflateBlock.encode(.init(input: Data(), dictionary: Data(), final: true), level: deflateLevel), write: write)
            }
        case .copy: break
        }
        if let aes { try output(aes.finish(), write: write) }
    }
    private func beginRawLZMA() throws {
        if rawLZMA == nil {
            guard let lzma else { throw WriterError.invalidState }
            rawLZMA = try lzma.rawEncoder(size: size, endMarker: false)
        }
    }
    private func emit(_ data: Data, write: (Data) throws -> Void) throws {
        compressedSize = try checkedAdd(compressedSize, UInt64(data.count))
        for offset in stride(from: 0, to: data.count, by: IOChunk.size) {
            try Task.checkCancellation()
            let start = data.startIndex + offset
            let chunk = data[start..<min(start + IOChunk.size, data.endIndex)]
            try output(aes.map { try $0.encrypt(chunk) } ?? chunk, write: write)
        }
    }
    private func output(_ bytes: Data, write: (Data) throws -> Void) throws {
        try write(bytes)
        packedSize = try checkedAdd(packedSize, UInt64(bytes.count))
    }

    func folder(size: UInt64, crc: UInt32? = nil, substreamCount: Int = 1) -> SevenZipEditModel.Folder {
        let methodCoder = SevenZipEditModel.Coder.compression(method, properties: properties, lzmaProperties: lzmaProperties)
        let coders: [SevenZipEditModel.Coder]
        if let aes { coders = [.aes(properties: Array(aes.properties)), methodCoder] }
        else { coders = [methodCoder] }
        return .init(coders: coders, bindPairs: aes == nil ? [] : [.init(input: 1, output: 0)], packedInputs: [0],
                     unpackSizes: aes == nil ? [size] : [compressedSize, size], finalOutput: aes == nil ? 0 : 1,
                     crc32: crc, packIndices: 0..<1, substreamIndices: 0..<substreamCount)
    }

    static func encode(size: UInt64, options: WriterOptions, chunkSize: Int? = nil,
                       aes: SevenZipAESEncryptor?, read: (Int) throws -> Data,
                       write: (Data) throws -> Void) throws -> SevenZipFolderEncoder {
        let encoder = SevenZipFolderEncoder(aes: aes, method: options.sevenZipMethod,
            deflateLevel: options.deflateLevel, bzip2Level: options.bzip2Level,
            lzma: options.sevenZipMethod == .lzma || options.sevenZipMethod == .lzma2
                ? try LZMAWriterConfiguration(options: options, raw: options.sevenZipMethod == .lzma) : nil, size: size)
        let pipeline = try SevenZipChunkPipeline<Void>(options: options, chunkSize: chunkSize)
        defer { pipeline.abandon() }
        func emit(_: Void, _ result: SevenZipChunkOutput?) throws {
            if let result { try encoder.consume(result, write: write) }
        }
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(pipeline.chunkSize), remaining))
            var data = Data()
            data.reserveCapacity(count)
            while data.count < count {
                let chunk = try read(min(IOChunk.size, count - data.count))
                guard !chunk.isEmpty, chunk.count <= count - data.count else { throw WriterError.sourceChanged("7z folder") }
                data.append(chunk)
            }
            remaining -= UInt64(data.count)
            try pipeline.submit(data, tag: (), isLast: remaining == 0, emit: emit)
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged("7z folder") }
        try pipeline.finish(emit: emit)
        try encoder.finish(write: write)
        return encoder
    }
}

/// 作り直した solid folder の scratch と、その folder が持つ file・置換後の定義。
struct SevenZipReencodedFolder {
    let files: [Int]
    let scratch: ScratchFile
    let replacement: SevenZipEditPlan.Replacement
}
