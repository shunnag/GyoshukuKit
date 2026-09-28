import Foundation
@_spi(SevenZipEditLayout) internal import KaitoKit

struct SevenZipEditModel: Sendable, Equatable {
    struct Coder: Sendable, Equatable {
        /// 7z の method ID。AES-256 + SHA-256 の鍵導出は 06 F1 07 01、LZMA2 は 21。
        static let aesMethodID: [UInt8] = [0x06, 0xF1, 0x07, 0x01]
        static let lzma2MethodID: [UInt8] = [0x21]
        var methodID: [UInt8]
        var inputCount = 1
        var outputCount = 1
        var isComplex = false
        var properties: [UInt8]?
        var isAES: Bool { methodID == Self.aesMethodID }
        /// 単入力・単出力の AES coder。properties は SevenZipAESEncryptor.properties の byte。
        static func aes(properties: [UInt8]) -> Coder { Coder(methodID: aesMethodID, properties: properties) }
        /// LZMA2 coder。properties は dictionary size を表す 1 byte。
        static func lzma2(properties: UInt8) -> Coder { Coder(methodID: lzma2MethodID, properties: [properties]) }
    }
    struct Bind: Sendable, Equatable { var input: Int; var output: Int }
    struct Folder: Sendable, Equatable {
        var coders: [Coder]
        var bindPairs: [Bind]
        var packedInputs: [Int]
        var unpackSizes: [UInt64]
        var finalOutput: Int
        var crc32: UInt32?
        var packIndices: Range<Int>
        var substreamIndices: Range<Int>
        var isEncrypted: Bool { coders.contains(where: \.isAES) }
        var size: UInt64 { unpackSizes[finalOutput] }
        var canReencrypt: Bool {
            guard packedInputs.count == 1 else { return false }
            let aes = coders.indices.filter { coders[$0].isAES }
            guard !aes.isEmpty else { return true }
            guard aes.count == 1, let index = aes.first,
                  coders[index].inputCount == 1, coders[index].outputCount == 1 else { return false }
            return coders[..<index].reduce(0) { $0 + $1.inputCount } == packedInputs[0]
        }
    }
    struct Pack: Sendable, Equatable {
        var range: Range<UInt64>
        var crc32: UInt32?
        var length: UInt64 { range.byteLength }
    }
    struct Substream: Sendable, Equatable {
        var folderIndex: Int
        var offset: UInt64
        var size: UInt64
        var crc32: UInt32?
    }
    struct File: Sendable, Equatable {
        var rawName: [UInt8]
        var substreamIndex: Int?
        var isEmptyFile: Bool
        var isAnti = false
        var creationTime: UInt64?
        var accessTime: UInt64?
        var modificationTime: UInt64?
        var attributes: UInt32?
        var startPosition: UInt64?
        var hasStream: Bool { substreamIndex != nil }
    }
    struct Header: Sendable, Equatable {
        var encoded = false
        var encrypted = false
        var compressed = false
    }
    var baseOffset: UInt64 = 0
    var versionMajor: UInt8 = 0
    var versionMinor: UInt8 = 4
    var nextHeaderRange: Range<UInt64> = 32..<32
    var header = Header()
    var plainHeaderLength: UInt64 = 0
    var packPosition: UInt64 = 0
    var packs: [Pack] = []
    var folders: [Folder] = []
    var substreams: [Substream] = []
    var files: [File] = []
    var mainPackEnd: UInt64 = 32
    var filePropertyOrder: [UInt8] = []
    var unrepresentedReason: String?

    // 7-Zip の更新は、属性 vector の無い元には新規・置換 item にも属性を置かない。
    // 空の書庫は writer の既定に従い、一部だけ定義された元はその形のまま保つ。
    var storesAttributesForAdditions: Bool { files.isEmpty || files.contains { $0.attributes != nil } }

    static func readerOptions(password: String?) -> ReaderOptions {
        var options = ReaderOptions(limits: ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max),
                                    password: password, appleDoublePolicy: .expose)
        options.recordsSevenZipEditLayout = true
        return options
    }

    static func read(_ reader: ArchiveReader) -> Self? {
        guard let snapshot = reader.sevenZipEditingSnapshot() else { return nil }
        var model = Self()
        model.baseOffset = snapshot.baseOffset
        model.versionMajor = snapshot.versionMajor; model.versionMinor = snapshot.versionMinor
        model.nextHeaderRange = snapshot.nextHeaderRange
        if case .encoded = snapshot.header { model.header.encoded = true }
        model.header.encrypted = snapshot.header.isEncrypted
        model.header.compressed = snapshot.header.isCompressed
        model.plainHeaderLength = snapshot.plainHeaderLength
        model.packPosition = snapshot.packPosition
        model.packs = snapshot.packs.map { Pack(range: $0.range, crc32: $0.crc32) }
        model.folders = snapshot.folders.map { folder in
            Folder(coders: folder.coders.map { Coder(methodID: $0.methodID, inputCount: $0.inputCount,
                outputCount: $0.outputCount, isComplex: $0.isComplex, properties: $0.properties) },
                bindPairs: folder.bindPairs.map { Bind(input: $0.input, output: $0.output) },
                packedInputs: folder.packedInputs, unpackSizes: folder.unpackSizes, finalOutput: folder.finalOutput,
                crc32: folder.crc32, packIndices: folder.packIndices, substreamIndices: folder.substreamIndices)
        }
        model.substreams = snapshot.substreams.map { Substream(folderIndex: $0.folderIndex, offset: $0.offset,
                                                               size: $0.size, crc32: $0.crc32) }
        model.files = snapshot.files.map { File(rawName: $0.rawName, substreamIndex: $0.substreamIndex,
            isEmptyFile: $0.isEmptyFile, isAnti: $0.isAnti, creationTime: $0.creationTime, accessTime: $0.accessTime,
            modificationTime: $0.modificationTime, attributes: $0.attributes, startPosition: $0.startPosition) }
        model.mainPackEnd = snapshot.mainPackEnd
        model.filePropertyOrder = snapshot.filePropertyOrder
        switch snapshot.unrepresentedReason {
        case .archiveProperties: model.unrepresentedReason = "header: archiveProperties"
        case .additionalStreams: model.unrepresentedReason = "header: additionalStreams"
        case .externalData: model.unrepresentedReason = "header: externalData"
        case .unknownFileProperty(let id): model.unrepresentedReason = String(format: "header: unknownFileProperty(0x%02X)", id)
        case nil: break
        }
        return model
    }

    func rewriteReason(entries: [ArchiveEntry]) -> String? {
        if baseOffset != 0 { return "sfx prefix" }
        if let unrepresentedReason { return unrepresentedReason }
        if packPosition != 0 { return "pack position gap" }
        guard validLayout(), files.count == entries.count else { return "layout mismatch" }
        for (file, entry) in zip(files, entries) {
            guard file.rawName == entry.rawName.bytes else { return "layout mismatch" }
            if let stream = file.substreamIndex, substreams[stream].size != entry.uncompressedSize { return "layout mismatch" }
        }
        return nil
    }

    func validLayout() -> Bool {
        let start = UInt64(32).addingReportingOverflow(packPosition)
        guard !start.overflow else { return false }
        var position = start.partialValue
        for pack in packs {
            guard pack.range.lowerBound == position else { return false }
            position = pack.range.upperBound
        }
        guard position == mainPackEnd else { return false }
        var packIndex = 0, substreamIndex = 0
        for (index, folder) in folders.enumerated() {
            guard folder.packIndices.lowerBound == packIndex, folder.packIndices.upperBound <= packs.count,
                  folder.packIndices.count == folder.packedInputs.count,
                  folder.substreamIndices.lowerBound == substreamIndex, folder.substreamIndices.upperBound <= substreams.count,
                  folder.finalOutput >= 0, folder.finalOutput < folder.unpackSizes.count,
                  folder.unpackSizes.count == folder.coders.reduce(0, { $0 + $1.outputCount }) else { return false }
            var offset: UInt64 = 0
            for stream in substreams[folder.substreamIndices] {
                guard stream.folderIndex == index, stream.offset == offset else { return false }
                let sum = offset.addingReportingOverflow(stream.size)
                guard !sum.overflow else { return false }
                offset = sum.partialValue
            }
            guard folder.substreamIndices.isEmpty || offset == folder.size else { return false }
            packIndex = folder.packIndices.upperBound; substreamIndex = folder.substreamIndices.upperBound
        }
        guard packIndex == packs.count, substreamIndex == substreams.count else { return false }
        var next = 0
        for file in files {
            if let index = file.substreamIndex {
                guard index == next, index < substreams.count else { return false }
                next += 1
            }
        }
        return next == substreams.count
    }

    var filesByFolder: [[Int]] {
        var result = Array(repeating: [Int](), count: folders.count)
        for (index, file) in files.enumerated() {
            if let stream = file.substreamIndex { result[substreams[stream].folderIndex].append(index) }
        }
        return result
    }

    static func nameBytes(_ name: String) -> [UInt8] {
        name.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
    }
}
