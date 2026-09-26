import Foundation

enum SevenZipConversion: Sendable, Equatable { case attach, detach, change }

struct SevenZipUpdatePlan {
    typealias Model = SevenZipEditModel
    enum Work: Equatable {
        case carry(Int)
        case convert(Int, SevenZipConversion)
        case reencode(Int, [Int])
        var index: Int {
            switch self { case .carry(let k), .convert(let k, _), .reencode(let k, _): k }
        }
    }
    struct Replacement {
        var folder: Model.Folder
        var packs: [Model.Pack]
        var streams: [Model.Substream]
    }
    struct Assembly {
        var model: Model
        var outputFolderIndices: [Int: Int]
        var firstAddedFolder: Int
    }
    let works: [Work]
    let survivingFiles: [Int]
    let renamed: [Int: String]
    let header: Model.Header
    let unchanged: Bool

    static func make(model: Model, filesByFolder: [[Int]], names: [String], removed: Set<Int>, renamed: [Int: String],
                     additions: Int, reencrypt: Bool, currentPassword: String?, headerPassword: String?,
                     options: WriterOptions) -> Self {
        let changes = renamed.filter { $0.value != names[$0.key] && !removed.contains($0.key) }
        var works: [Work] = []
        for (index, folder) in model.folders.enumerated() {
            let files = filesByFolder[index]
            let surviving = files.filter { !removed.contains($0) }
            if !files.isEmpty, surviving.isEmpty { continue }
            if surviving.count != files.count { works.append(.reencode(index, surviving)); continue }
            var conversion: SevenZipConversion?
            if reencrypt, !files.isEmpty {
                if folder.isEncrypted, options.password == nil { conversion = .detach }
                else if !folder.isEncrypted, options.password != nil { conversion = .attach }
                else if folder.isEncrypted, !samePassword(currentPassword, options.password) { conversion = .change }
            }
            works.append(conversion.map { .convert(index, $0) } ?? .carry(index))
        }
        let survivors = model.files.indices.filter { !removed.contains($0) }
        if survivors.isEmpty && additions == 0 { works.removeAll() }
        let header = Model.Header(encoded: model.header.compressed || options.encryptsSevenZipHeaders,
                                  encrypted: options.encryptsSevenZipHeaders, compressed: model.header.compressed)
        let hasConversion = works.contains { if case .convert = $0 { return true }; return false }
        let unchanged = removed.isEmpty && changes.isEmpty && additions == 0 && !hasConversion
            && model.header == header && (!header.encrypted || samePassword(headerPassword, options.password))
        return Self(works: works, survivingFiles: survivors,
                    renamed: changes, header: header, unchanged: unchanged)
    }

    static func samePassword(_ first: String?, _ second: String?) -> Bool {
        first.map { Array($0.utf16) } == second.map { Array($0.utf16) }
    }

    func assemble(original: Model, filesByFolder: [[Int]], replacements: [Int: Replacement],
                  additions: [SevenZipWriter.AppendedEntry]) throws -> Assembly {
        var model = Model()
        model.header = header
        model.filePropertyOrder = original.filePropertyOrder
        var fileStreams: [Int: Int] = [:], outputIndices: [Int: Int] = [:]
        for work in works {
            let index = work.index
            outputIndices[index] = model.folders.count
            let replacement: Replacement
            let files: [Int]
            switch work {
            case .carry:
                let folder = original.folders[index]
                replacement = Replacement(folder: folder, packs: Array(original.packs[folder.packIndices]),
                                          streams: Array(original.substreams[folder.substreamIndices]))
                files = filesByFolder[index]
            case .convert:
                guard let value = replacements[index] else { throw failure("V0 conversion missing \(index)") }
                replacement = value; files = filesByFolder[index]
            case .reencode(_, let survivors):
                guard let value = replacements[index] else { throw failure("V0 reencode missing \(index)") }
                replacement = value; files = survivors
            }
            guard files.count == replacement.streams.count else { throw failure("V0 substream count \(index)") }
            for (offset, file) in files.enumerated() { fileStreams[file] = model.substreams.count + offset }
            try Self.append(replacement, to: &model)
        }
        for index in survivingFiles {
            var file = original.files[index]
            if let name = renamed[index] { file.rawName = Model.nameBytes(name) }
            file.substreamIndex = fileStreams[index]
            model.files.append(file)
        }
        let firstAdded = model.folders.count
        let storesAttributes = original.storesAttributesForAdditions
        for appended in additions {
            let record = appended.record
            let streamIndex: Int? = record.size > 0 ? model.substreams.count : nil
            if record.size > 0 {
                let aes = record.aesProperties.map(Array.init)
                let coders: [Model.Coder] = (aes.map { [.init(methodID: [6, 0xF1, 7, 1], properties: $0)] } ?? [])
                    + [.init(methodID: [0x21], properties: [record.properties])]
                let folder = Model.Folder(coders: coders, bindPairs: aes == nil ? [] : [.init(input: 1, output: 0)],
                    packedInputs: [0], unpackSizes: aes == nil ? [record.size] : [record.compressedSize, record.size],
                    finalOutput: aes == nil ? 0 : 1, packIndices: 0..<1, substreamIndices: 0..<1)
                guard appended.packRange.upperBound - appended.packRange.lowerBound == record.packedSize else {
                    throw failure("V0 appended pack")
                }
                try Self.append(.init(folder: folder, packs: [.init(range: 0..<record.packedSize)],
                                      streams: [.init(folderIndex: 0, offset: 0, size: record.size, crc32: record.crc)]), to: &model)
            }
            model.files.append(.init(rawName: Model.nameBytes(record.name), substreamIndex: streamIndex,
                isEmptyFile: record.size == 0 && !record.isDirectory, modificationTime: record.mtime,
                attributes: storesAttributes ? UInt32(record.mode) << 16 | 0x8000 | (record.isDirectory ? 0x10 : 0x20) : nil))
        }
        guard model.validLayout() else { throw failure("V0 layout") }
        return Assembly(model: model, outputFolderIndices: outputIndices, firstAddedFolder: firstAdded)
    }

    private static func append(_ replacement: Replacement, to model: inout Model) throws {
        var folder = replacement.folder
        folder.packIndices = model.packs.count..<(model.packs.count + replacement.packs.count)
        folder.substreamIndices = model.substreams.count..<(model.substreams.count + replacement.streams.count)
        for pack in replacement.packs {
            let end = try checkedAdd(model.mainPackEnd, pack.length)
            model.packs.append(.init(range: model.mainPackEnd..<end, crc32: pack.crc32))
            model.mainPackEnd = end
        }
        for var stream in replacement.streams { stream.folderIndex = model.folders.count; model.substreams.append(stream) }
        model.folders.append(folder)
    }

    private static func failure(_ reason: String) -> UpdaterRouteError { .outputVerificationFailed(reason: reason) }
    private func failure(_ reason: String) -> UpdaterRouteError { Self.failure(reason) }
}
