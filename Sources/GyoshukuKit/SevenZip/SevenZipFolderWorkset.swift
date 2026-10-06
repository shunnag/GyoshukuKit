import Foundation
internal import KaitoKit

/// commit を通じて folder ごとの再圧縮・暗号化変換の状態と password / encryptor を持つ。
/// 更新のライフサイクルと出力の管理は SevenZipUpdater が担う。
final class SevenZipFolderWorkset {
    private let snapshot: ArchiveSourceSnapshot
    private let reader: ArchiveReader
    private let model: SevenZipEditModel
    private let filesByFolder: [[Int]]
    private let options: WriterOptions
    private let destination: SegmentedArchiveOutput
    private let headerPassword: String?
    private var currentPassword: String?
    private var encryptors: SevenZipAESEncryptor.Factory
    private(set) var reencrypt = false
    private(set) var reencoded: [Int: SevenZipReencodedFolder] = [:]
    private(set) var conversions: [Int: SevenZipFolderConversion] = [:]
    private var passwordChecked: Set<Int> = []

    init(snapshot: ArchiveSourceSnapshot, reader: ArchiveReader, model: SevenZipEditModel,
         filesByFolder: [[Int]], options: WriterOptions, destination: SegmentedArchiveOutput, password: String?) {
        self.snapshot = snapshot; self.reader = reader; self.model = model; self.filesByFolder = filesByFolder
        self.options = options; self.destination = destination; headerPassword = password
        encryptors = SevenZipAESEncryptor.Factory(password: options.password)
    }

    func reencryptExistingEntries(currentPassword: String?) throws {
        guard !reencrypt else { throw UpdaterError.invalidState }
        for (index, folder) in model.folders.enumerated() where !folder.canReencrypt {
            let file = filesByFolder[index].first ?? 0
            throw UpdaterError.reencryptionFailed(index: file, name: reader.entries.indices.contains(file) ? reader.entries[file].name : "",
                                                  reason: "7z の folder の形のため暗号化を変更できません")
        }
        reencrypt = true; self.currentPassword = currentPassword; reader.password = currentPassword
        reencoded.removeAll(); conversions.removeAll(); passwordChecked.removeAll()
    }

    func makePlan(ledger: EntryEditLedger, additions: Int) -> SevenZipEditPlan {
        SevenZipEditPlan.make(model: model, filesByFolder: filesByFolder, names: ledger.names, removed: ledger.removed,
            renamed: ledger.renamed, additions: additions, reencrypt: reencrypt, currentPassword: currentPassword,
            headerPassword: headerPassword, options: options)
    }

    /// enabled なら options.password の encryptor。password が無ければ invalidOption("password")。
    func makeEncryptor(enabled: Bool) throws -> SevenZipAESEncryptor? {
        guard enabled else { return nil }
        guard let aes = try encryptors.make() else { throw WriterError.invalidOption("password") }
        return aes
    }

    func prepareConversions(_ plan: SevenZipEditPlan, toScratch: Bool = false) throws {
        for case let .convert(index, kind) in plan.works {
            try Task.checkCancellation()
            if kind != .attach, !passwordChecked.contains(index) {
                try Self.verifyPassword(reader: reader, files: filesByFolder[index])
                passwordChecked.insert(index)
            }
        }
        for case let .convert(index, kind) in plan.works {
            if conversions[index] == nil {
                conversions[index] = try SevenZipFolderConversion(index: index, conversion: kind, model: model,
                                                             aes: makeEncryptor(enabled: kind != .detach))
            }
            if toScratch, let conversion = conversions[index], conversion.scratch == nil {
                let scratch = try destination.makeScratch(tag: "convert")
                try conversion.write(reader: reader, source: snapshot.source, model: model, write: { _ = try scratch.append($0) })
                conversion.scratch = scratch
            }
        }
    }

    /// folder の file を先頭から合計 64 KiB 復号して現在の password を確かめる。復号の malformed / truncated は
    /// wrongPassword と見る。detach / change の前にだけ要る（attach は平文を読む）。
    private static func verifyPassword(reader: ArchiveReader, files: [Int]) throws {
        guard reader.password != nil else { throw KaitoError.passwordRequired }
        do {
            var remaining = 64 * 1024
            for index in files {
                try Task.checkCancellation()
                let stream = try reader.stream(reader.entries[index])
                repeat {
                    let bytes = try stream.readSome(upTo: min(remaining, 64 * 1024))
                    remaining -= bytes.count
                    if bytes.isEmpty { break }
                } while remaining > 0
                if remaining == 0 { break }
            }
        } catch KaitoError.malformed { throw KaitoError.wrongPassword }
        catch KaitoError.truncated { throw KaitoError.wrongPassword }
    }

    func prepareReencodings(_ plan: SevenZipEditPlan, advance: @escaping (UInt64) throws -> Void) throws {
        for case let .reencode(index, files) in plan.works {
            try Task.checkCancellation()
            if reencoded[index]?.files == files { continue }
            let scratch = try destination.makeScratch(tag: "reencode")
            let encrypted = reencrypt ? options.password != nil : model.folders[index].isEncrypted
            let aes = try makeEncryptor(enabled: encrypted)
            let input = SevenZipSolidInput(reader: reader, files: filesByFolder[index], surviving: files, advance: advance)
            let sizes = files.map { model.substreams[model.files[$0].substreamIndex!].size }
            let size = try sizes.reduce(UInt64(0)) { try checkedAdd($0, $1) }
            let encoder = try SevenZipFolderEncoder.encode(size: size, options: options,
                aes: aes, filter: SevenZipWriteFilter.preserved(in: model.folders[index]),
                read: input.read, write: { _ = try scratch.append($0) })
            var offset: UInt64 = 0
            let streams: [SevenZipEditModel.Substream] = zip(files, sizes).map { file, size in
                defer { offset += size }
                return .init(folderIndex: 0, offset: offset, size: size, crc32: input.crcs[file])
            }
            reencoded[index] = SevenZipReencodedFolder(files: files, scratch: scratch,
                replacement: .init(folder: encoder.folder(size: size, substreamCount: files.count),
                                   packs: [.init(range: 0..<scratch.length)], streams: streams))
        }
    }

    func preliminaryPrefix(_ plan: SevenZipEditPlan) throws -> [OutputSegment] {
        var prefix: [OutputSegment] = [.literal(length: 32, bytes: { Data(count: 32) })]
        for work in plan.works {
            let folder = model.folders[work.index]
            switch work {
            case .convert(_, let kind):
                let length: UInt64
                if kind == .attach { length = try checkedAdd(model.packs[folder.packIndices.lowerBound].length, 15) / 16 * 16 }
                else {
                    let aes = folder.coders.firstIndex(where: \.isAES)!
                    let out = folder.coders[..<aes].reduce(0) { $0 + $1.outputCount }
                    let plain = folder.unpackSizes[out]
                    length = kind == .detach ? plain : try checkedAdd(plain, 15) / 16 * 16
                }
                prefix.append(.generated(length: length, write: { _ in throw WriterError.invalidState }))
            default:
                for pack in model.packs[folder.packIndices] { prefix.append(.source(pack.range)) }
            }
        }
        return prefix
    }

    func makePrefix(_ plan: SevenZipEditPlan) throws -> [OutputSegment] {
        var prefix: [OutputSegment] = [.literal(length: 32, bytes: { Data(count: 32) })]
        for work in plan.works {
            switch work {
            case .carry(let index):
                for pack in model.packs[model.folders[index].packIndices] { prefix.append(.source(pack.range)) }
            case .reencode(let index, _):
                guard let value = reencoded[index] else { throw failure("V0 reencoded pack \(index)") }
                prefix.append(.scratch(value.scratch, 0..<value.scratch.length))
            case .convert(let index, _):
                guard let value = conversions[index] else { throw failure("V0 converted pack \(index)") }
                if let scratch = value.scratch { prefix.append(.scratch(scratch, 0..<scratch.length)) }
                else {
                    prefix.append(.generated(length: value.replacement.packs[0].length, write: { sink in
                        try value.write(reader: self.reader, source: self.snapshot.source, model: self.model, write: sink.write)
                    }))
                }
            }
        }
        return prefix
    }

    func replacements(_ plan: SevenZipEditPlan) throws -> [Int: SevenZipEditPlan.Replacement] {
        var result: [Int: SevenZipEditPlan.Replacement] = [:]
        for work in plan.works {
            switch work {
            case .carry: break
            case .convert(let index, _): result[index] = conversions[index]?.replacement
            case .reencode(let index, _): result[index] = reencoded[index]?.replacement
            }
        }
        return result
    }

    func upperBound(_ plan: SevenZipEditPlan, additions: [SevenZipWriter.AppendedEntry], appended: Range<UInt64>?) throws -> UInt64 {
        var predicted = try replacements(plan)
        var input: UInt64 = 0, copy: UInt64 = 0, verification: UInt64 = 0, carried: UInt64 = 0
        var position: UInt64 = 32
        var uncertainPosition = false
        for work in plan.works {
            let index = work.index, folder = model.folders[work.index]
            switch work {
            case .carry:
                for pack in model.packs[folder.packIndices] {
                    if !destination.isCloneMode || uncertainPosition || pack.range.lowerBound != position {
                        carried = try checkedAdd(carried, pack.length * 3)
                    }
                    position = try checkedAdd(position, pack.length)
                }
            case .convert:
                let conversion = conversions[index]!
                copy = try checkedAdd(copy, conversion.replacement.packs[0].length)
                verification = try checkedAdd(verification, conversion.plaintextLength)
                position = try checkedAdd(position, conversion.replacement.packs[0].length)
            case .reencode(_, let files):
                let size = files.reduce(UInt64(0)) { $0 + model.substreams[model.files[$1].substreamIndex!].size }
                verification = try checkedAdd(verification, size)
                let bound = try checkedAdd(size, size / 32 + 256)
                copy = try checkedAdd(copy, bound)
                if reencoded[index]?.files != files {
                    uncertainPosition = true
                    position = try checkedAdd(position, bound)
                    input = try checkedAdd(input, folder.size)
                    let encrypted = reencrypt ? options.password != nil : folder.isEncrypted
                    var replacement = folder
                    replacement.coders = (encrypted ? [.aes(properties: Array(repeating: 0, count: SevenZipAESEncryptor.propertiesLength))] : [])
                        + [.compression(options.sevenZipMethod)]
                    replacement.bindPairs = encrypted ? [.init(input: 1, output: 0)] : []
                    replacement.packedInputs = [0]; replacement.unpackSizes = encrypted ? [bound, size] : [size]
                    replacement.finalOutput = encrypted ? 1 : 0; replacement.crc32 = nil
                    if let filter = try SevenZipWriteFilter.preserved(in: folder).coder {
                        replacement.coders.append(filter)
                        replacement.bindPairs.append(.init(input: replacement.coders.count - 1, output: replacement.coders.count - 2))
                        replacement.unpackSizes.append(size)
                        replacement.finalOutput += 1
                    }
                    var offset: UInt64 = 0
                    let streams: [SevenZipEditModel.Substream] = files.map { file in
                        let size = model.substreams[model.files[file].substreamIndex!].size
                        defer { offset += size }
                        return .init(folderIndex: 0, offset: offset, size: size, crc32: 0)
                    }
                    predicted[index] = .init(folder: replacement, packs: [.init(range: 0..<bound)], streams: streams)
                } else { position = try checkedAdd(position, reencoded[index]!.scratch.length) }
            }
        }
        let assembly = try plan.assemble(original: model, filesByFolder: filesByFolder, replacements: predicted, additions: additions)
        let h = UInt64(try SevenZipHeaderSerializer.header(assembly.model).count) + UInt64(plan.works.count) * 18 + 17 * 9
        let headerBound = try checkedAdd(h, h / 32 + 512)
        let additionsLength = appended?.byteLength ?? 0
        let additionalVerification = additions.reduce(UInt64(0)) { $0 + $1.record.size }
        return try [input, copy, carried, verification, additionalVerification, additionsLength * 2, headerBound * 2, 64]
            .reduce(UInt64(0)) { try checkedAdd($0, $1) }
    }

    private func failure(_ reason: String) -> UpdaterRouteError { .outputVerificationFailed(reason: reason) }
}

/// solid folder を順に復号し、削除 file の byte は読み捨てて CRC だけ取る reader。
private final class SevenZipSolidInput {
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
