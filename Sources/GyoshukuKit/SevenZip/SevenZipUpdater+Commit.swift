import Foundation
import Synchronization
internal import KaitoKit

struct SevenZipReencodedFolder {
    let files: [Int]
    let scratch: SplicedScratchFile
    let replacement: SevenZipEditPlan.Replacement
}

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

extension SevenZipUpdater {
    func prepareConversions(_ plan: SevenZipEditPlan, toScratch: Bool = false) throws {
        for case let .convert(index, kind) in plan.works {
            try Task.checkCancellation()
            if kind != .attach, !passwordChecked.contains(index) {
                try SevenZipFolderConversion.verifyPassword(reader: reader, files: filesByFolder[index])
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
                try conversion.write(reader: reader, source: snapshot.source, model: model, write: scratch.append)
                conversion.scratch = scratch
            }
        }
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
            let encoder = try SevenZipFolderEncoder.encode(size: size, threads: options.resolvedCompressionThreads,
                aes: aes, read: input.read, write: scratch.append)
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

    func preliminaryPrefix(_ plan: SevenZipEditPlan) throws -> [SplicedSegment] {
        var prefix: [SplicedSegment] = [.literal(length: 32, bytes: { Data(count: 32) })]
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

    func makePrefix(_ plan: SevenZipEditPlan) throws -> [SplicedSegment] {
        var prefix: [SplicedSegment] = [.literal(length: 32, bytes: { Data(count: 32) })]
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

    private func upperBound(_ plan: SevenZipEditPlan, additions: [SevenZipWriter.AppendedEntry], appended: Range<UInt64>?) throws -> UInt64 {
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
                    replacement.coders = (encrypted ? [.init(methodID: [6, 0xF1, 7, 1], properties: Array(repeating: 0, count: 18))] : [])
                        + [.init(methodID: [0x21], properties: [0])]
                    replacement.bindPairs = encrypted ? [.init(input: 1, output: 0)] : []
                    replacement.packedInputs = [0]; replacement.unpackSizes = encrypted ? [bound, size] : [size]
                    replacement.finalOutput = encrypted ? 1 : 0; replacement.crc32 = nil
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

    func executeCommit(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws -> SevenZipCommitStatistics {
        try snapshot.checkUnchanged()
        let additions = try writer?.endSevenZipEntries() ?? []
        writer = nil
        if model.header.encrypted && !options.encryptsSevenZipHeaders && !reencrypt {
            throw WriterError.invalidOption("encryptsSevenZipHeaders")
        }
        var stats = SevenZipCommitStatistics()
        let started = ProcessInfo.processInfo.systemUptime
        let plan = makePlan(additions: additions.count)
        if plan.unchanged { return try unchangedCommit(progress: callbackForUnchanged(progress)) }
        let end = additions.last?.packRange.upperBound ?? appendStart
        let appended = appendStart.flatMap { start in end.map { start..<$0 } }
        stats.appendedPackBytes = appended?.byteLength ?? 0
        stats.planSeconds = ProcessInfo.processInfo.systemUptime - started
        let verificationStarted = ProcessInfo.processInfo.systemUptime
        try prepareConversions(plan)
        stats.passwordVerificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStarted
        try Task.checkCancellation()
        var progressError: Error?
        let callback: ((ArchiveUpdater.CommitProgress) throws -> Void) = { update in
            do { try progress?(update) } catch { progressError = error; throw error }
            guard self.state == .committing else { throw UpdaterError.invalidState }
        }
        let needsReencode = plan.works.contains { work in
            if case let .reencode(index, files) = work { return reencoded[index]?.files != files }; return false
        }
        var meter: CommitProgressMeter?
        if needsReencode {
            let estimateStart = ProcessInfo.processInfo.systemUptime
            meter = try CommitProgressMeter(total: upperBound(plan, additions: additions, appended: appended), progress: callback)
            stats.planSeconds += ProcessInfo.processInfo.systemUptime - estimateStart
            try meter!.start()
        }
        let scratchStart = ProcessInfo.processInfo.systemUptime
        try prepareReencodings(plan, advance: { try meter?.advance($0) })
        stats.reencodeScratchSeconds = ProcessInfo.processInfo.systemUptime - scratchStart
        let assemblyStart = ProcessInfo.processInfo.systemUptime
        var assembly = try plan.assemble(original: model, filesByFolder: filesByFolder, replacements: replacements(plan), additions: additions)
        if Self.testingFault == .dropLastPackFromModel { assembly.model.packs = Array(assembly.model.packs.dropLast()) }
        guard assembly.model.validLayout() else { throw failure("V0 pack layout") }
        stats.planSeconds += ProcessInfo.processInfo.systemUptime - assemblyStart
        let headerStart = ProcessInfo.processInfo.systemUptime
        var serialized = assembly.model
        if Self.testingFault == .corruptSerializedName, !serialized.files.isEmpty, !serialized.files[0].rawName.isEmpty {
            serialized.files[0].rawName[0] ^= 1
        }
        let plain = try SevenZipHeaderSerializer.header(serialized)
        stats.plainHeaderBytes = UInt64(plain.count)
        let terminal = try encodeHeader(plain, policy: plan.header, mainEnd: assembly.model.mainPackEnd)
        stats.storedHeaderBytes = UInt64(terminal.bytes.count)
        assembly.model.plainHeaderLength = UInt64(plain.count)
        assembly.model.nextHeaderRange = terminal.nextRange
        stats.headerSeconds = ProcessInfo.processInfo.systemUptime - headerStart
        let prefix = plan.unchanged ? [.source(0..<snapshot.source.length)] : try makePrefix(plan)
        let checkUnits = plan.unchanged ? 0 : Self.verificationUnits(assembly: assembly, plan: plan, conversions: conversions)
        let outputPlan = SplicedCommitPlan(prefix: prefix, appended: plan.unchanged ? nil : appended,
            terminal: plan.unchanged ? Data() : terminal.bytes,
            finalLength: plan.unchanged ? snapshot.source.length : terminal.nextRange.upperBound,
            finalPatch: plan.unchanged ? nil : (0, terminal.signature), formatVerificationUnits: checkUnits)
        if meter == nil { meter = CommitProgressMeter(total: destination.units(for: outputPlan), progress: callback); try meter!.start() }
        let totalVerification = Mutex<Double>(0)
        let fault = Self.faultAction(plan: plan, assembly: assembly)
        let scratchBefore = reencoded.mapValues { $0.scratch.copySeconds }
        let packsStart = ProcessInfo.processInfo.systemUptime
        let strategy: SplicedCommitStrategy
        do {
            strategy = try SplicedArchiveOutput.$testingBeforeSynchronize.withValue(fault ?? SplicedArchiveOutput.testingBeforeSynchronize) {
                try SplicedArchiveOutput.$testingVerificationElapsed.withValue({ seconds in totalVerification.withLock { $0 = seconds } }) {
                    try destination.commit(outputPlan, meter: meter!) { fd, advance in
                        if !plan.unchanged { try self.selfCheck(fd: fd, plan: plan, assembly: assembly, advance: advance, statistics: &stats) }
                    }
                }
            }
        } catch { if let progressError { throw progressError }; throw error }
        stats.v2Seconds = max(0, totalVerification.withLock { $0 } - stats.selfCheckSeconds)
        stats.packsSeconds = max(0, ProcessInfo.processInfo.systemUptime - packsStart - totalVerification.withLock { $0 })
        var shifted = false, converted = false, reencodedAny = false
        for work in plan.works {
            let index = work.index, target = assembly.model.folders[assembly.outputFolderIndices[index]!]
            switch work {
            case .carry:
                for (old, new) in zip(model.packs[model.folders[index].packIndices], assembly.model.packs[target.packIndices]) {
                    let moved = old.range.lowerBound != new.range.lowerBound
                    shifted = shifted || moved
                    if (!destination.isCloneMode && (appended == nil || strategy == .relocatedAppend)) || (destination.isCloneMode && moved) {
                        stats.writtenCarriedPackBytes += old.length
                    }
                    if !destination.isCloneMode || moved { stats.verificationReadBytes += old.length * 2 }
                }
            case .convert:
                converted = true; stats.convertedPackBytes += conversions[index]!.replacement.packs[0].length
            case .reencode:
                reencodedAny = true; stats.reencodedFolderCount += 1
                stats.scratchCopySeconds += reencoded[index]!.scratch.copySeconds - (scratchBefore[index] ?? 0)
                stats.reencodedInputBytes += model.folders[index].size
                stats.reencodedPackBytes += reencoded[index]!.scratch.length
                stats.reencodeScratchWrittenBytes += reencoded[index]!.scratch.length
            }
        }
        stats.strategy = plan.unchanged ? .unchanged : converted ? .reencrypted : reencodedAny ? .reencoded
            : shifted ? .compacted : additions.isEmpty ? .headerOnly : .appendOnly
        if strategy == .relocatedAppend { stats.strategy = .relocatedAppend }
        else if strategy == .sequential { stats.strategy = .sequential }
        try meter!.finish()
        try Task.checkCancellation()
        try snapshot.original.checkUnchanged(at: snapshot.originalURL)
        snapshot.cleanup()
        return stats
    }

    private func callbackForUnchanged(_ progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?)
        -> (ArchiveUpdater.CommitProgress) throws -> Void {
        { update in
            try progress?(update)
            guard self.state == .committing else { throw UpdaterError.invalidState }
        }
    }

    private func unchangedCommit(progress: @escaping (ArchiveUpdater.CommitProgress) throws -> Void) throws -> SevenZipCommitStatistics {
        let plan = SplicedCommitPlan(prefix: [.source(0..<snapshot.source.length)], appended: nil, terminal: Data(),
                                    finalLength: snapshot.source.length, formatVerificationUnits: 0)
        let meter = CommitProgressMeter(total: destination.units(for: plan), progress: progress)
        try meter.start()
        _ = try destination.commit(plan, meter: meter) { _, _ in }
        try meter.finish()
        try Task.checkCancellation()
        try snapshot.original.checkUnchanged(at: snapshot.originalURL)
        var result = SevenZipCommitStatistics()
        if !destination.isCloneMode { result.verificationReadBytes = snapshot.source.length * 2 }
        return result
    }

    private func encodeHeader(_ plain: Data, policy: SevenZipEditModel.Header, mainEnd: UInt64)
        throws -> (bytes: Data, signature: Data, nextRange: Range<UInt64>) {
        var pack = Data(), next = plain
        if policy.encoded {
            let aes = try makeEncryptor(enabled: policy.encrypted)
            let folder: SevenZipEditModel.Folder
            if policy.compressed {
                var position = 0
                let encoder = try SevenZipFolderEncoder.encode(size: UInt64(plain.count), threads: options.resolvedCompressionThreads,
                    chunkSize: 1024 * 1024, aes: aes, read: { count in
                        let end = min(position + count, plain.count)
                        defer { position = end }
                        return plain.subdata(in: position..<end)
                    }, write: { pack.append($0) })
                folder = encoder.folder(size: UInt64(plain.count), crc: SevenZipRecords.checksum(plain))
            } else {
                guard let aes else { throw WriterError.invalidState }
                pack = try aes.encrypt(plain); pack.append(try aes.finish())
                folder = .init(coders: [.init(methodID: [6, 0xF1, 7, 1], properties: Array(aes.properties))],
                    bindPairs: [], packedInputs: [0], unpackSizes: [UInt64(plain.count)], finalOutput: 0,
                    crc32: SevenZipRecords.checksum(plain), packIndices: 0..<1, substreamIndices: 0..<1)
            }
            next = SevenZipHeaderSerializer.encodedHeader(folder: folder, packOffset: mainEnd - 32, length: UInt64(pack.count))
        }
        let start = try checkedAdd(mainEnd, UInt64(pack.count))
        return (pack + next, SevenZipRecords.signature(packedSize: start - 32, header: next), start..<(try checkedAdd(start, UInt64(next.count))))
    }

    func failure(_ reason: String) -> UpdaterRouteError { .outputVerificationFailed(reason: reason) }
}
