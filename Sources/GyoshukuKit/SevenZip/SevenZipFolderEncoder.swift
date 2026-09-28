import Foundation
internal import KaitoKit

// writer・solid の作り直し・header で同じ LZMA2 の連結規則を使う。
final class SevenZipFolderEncoder {
    let aes: SevenZipAESEncryptor?
    private(set) var properties: UInt8 = 0
    private(set) var compressedSize: UInt64 = 0
    private(set) var packedSize: UInt64 = 0

    init(aes: SevenZipAESEncryptor?) { self.aes = aes }

    func consume(_ compressed: XZLZMA2, write: (Data) throws -> Void) throws {
        guard let control = compressed.payload.first, control == 1 || control >= 0xE0,
              compressed.payload.last == 0 else { throw WriterError.compression(-1) }
        properties = max(properties, compressed.properties)
        try emit(compressed.payload.dropLast(), write: write)
    }
    func finish(write: (Data) throws -> Void) throws {
        try emit(Data([0]), write: write)
        if let aes { try output(aes.finish(), write: write) }
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
        let lzma = SevenZipEditModel.Coder(methodID: [0x21], properties: [properties])
        let coders: [SevenZipEditModel.Coder]
        if let aes { coders = [.init(methodID: [6, 0xF1, 7, 1], properties: Array(aes.properties)), lzma] }
        else { coders = [lzma] }
        return .init(coders: coders, bindPairs: aes == nil ? [] : [.init(input: 1, output: 0)], packedInputs: [0],
                     unpackSizes: aes == nil ? [size] : [compressedSize, size], finalOutput: aes == nil ? 0 : 1,
                     crc32: crc, packIndices: 0..<1, substreamIndices: 0..<substreamCount)
    }

    static func encode(size: UInt64, threads: Int, chunkSize: Int = LZMA2ChunkPipeline<Void>.chunkSize,
                       aes: SevenZipAESEncryptor?, read: (Int) throws -> Data,
                       write: (Data) throws -> Void) throws -> SevenZipFolderEncoder {
        let encoder = SevenZipFolderEncoder(aes: aes)
        let pipeline = LZMA2ChunkPipeline<Void>(threads: threads)
        defer { pipeline.abandon() }
        func emit(_: Void, _ result: LZMA2ChunkPipeline<Void>.Output?) throws {
            if let result { try encoder.consume(result.compressed, write: write) }
        }
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(chunkSize), remaining))
            var data = Data()
            data.reserveCapacity(count)
            while data.count < count {
                let chunk = try read(min(IOChunk.size, count - data.count))
                guard !chunk.isEmpty, chunk.count <= count - data.count else { throw WriterError.sourceChanged("7z folder") }
                data.append(chunk)
            }
            remaining -= UInt64(data.count)
            try pipeline.submit(data, tag: (), emit: emit)
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
    let scratch: SplicedScratchFile
    let replacement: SevenZipEditPlan.Replacement
}

/// solid folder を順に復号し、削除 file の byte は読み捨てて CRC だけ取る reader。
final class SevenZipSolidInput {
    let reader: ArchiveReader
    let files: [Int]
    let surviving: Set<Int>
    let advance: (UInt64) throws -> Void
    var cursor = 0
    var stream: EntryStream?
    var crc: UInt32 = 0
    var crcs: [Int: UInt32] = [:]

    init(reader: ArchiveReader, files: [Int], surviving: [Int], advance: @escaping (UInt64) throws -> Void) {
        self.reader = reader; self.files = files; self.surviving = Set(surviving); self.advance = advance
    }
    func read(_ count: Int) throws -> Data {
        while cursor < files.count {
            try Task.checkCancellation()
            let file = files[cursor]
            if stream == nil { stream = try reader.stream(reader.entries[file]); crc = 0 }
            let keep = surviving.contains(file)
            let bytes = try stream!.readSome(upTo: keep ? count : IOChunk.size)
            try advance(UInt64(bytes.count))
            crc = updateCRC(crc, bytes)
            if bytes.isEmpty { crcs[file] = crc; stream = nil; cursor += 1 }
            else if keep { return bytes }
        }
        return Data()
    }
}
