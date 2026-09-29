import Foundation
import Synchronization
internal import KaitoKit

extension SevenZipUpdater {
    func executeCommit(workset: SevenZipFolderWorkset, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws -> SevenZipCommitStatistics {
        try snapshot.checkUnchanged()
        let additions = try writer?.endSevenZipEntries() ?? []
        writer = nil
        if model.header.encrypted && !options.encryptsSevenZipHeaders && !workset.reencrypt {
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
        try workset.prepareConversions(plan)
        stats.passwordVerificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStarted
        try Task.checkCancellation()
        var progressError: Error?
        let callback: ((ArchiveUpdater.CommitProgress) throws -> Void) = { update in
            do { try progress?(update) } catch { progressError = error; throw error }
            guard self.state == .committing else { throw UpdaterError.invalidState }
        }
        let needsReencode = plan.works.contains { work in
            if case let .reencode(index, files) = work { return workset.reencoded[index]?.files != files }; return false
        }
        var meter: CommitProgressMeter?
        if needsReencode {
            let estimateStart = ProcessInfo.processInfo.systemUptime
            meter = try CommitProgressMeter(total: workset.upperBound(plan, additions: additions, appended: appended), progress: callback)
            stats.planSeconds += ProcessInfo.processInfo.systemUptime - estimateStart
            try meter!.start()
        }
        let scratchStart = ProcessInfo.processInfo.systemUptime
        try workset.prepareReencodings(plan, advance: { try meter?.advance($0) })
        stats.reencodeScratchSeconds = ProcessInfo.processInfo.systemUptime - scratchStart
        let assemblyStart = ProcessInfo.processInfo.systemUptime
        var assembly = try plan.assemble(original: model, filesByFolder: filesByFolder, replacements: workset.replacements(plan), additions: additions)
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
        let terminal = try encodeHeader(plain, policy: plan.header, mainEnd: assembly.model.mainPackEnd, workset: workset)
        stats.storedHeaderBytes = UInt64(terminal.bytes.count)
        assembly.model.plainHeaderLength = UInt64(plain.count)
        assembly.model.nextHeaderRange = terminal.nextRange
        stats.headerSeconds = ProcessInfo.processInfo.systemUptime - headerStart
        let prefix = plan.unchanged ? [.source(0..<snapshot.source.length)] : try workset.makePrefix(plan)
        let checkUnits = plan.unchanged ? 0 : Self.verificationUnits(assembly: assembly, plan: plan, workset: workset)
        let outputPlan = SegmentCommitPlan(prefix: prefix, appended: plan.unchanged ? nil : appended,
            terminal: plan.unchanged ? Data() : terminal.bytes,
            finalLength: plan.unchanged ? snapshot.source.length : terminal.nextRange.upperBound,
            finalPatch: plan.unchanged ? nil : (0, terminal.signature), formatVerificationUnits: checkUnits)
        if meter == nil { meter = CommitProgressMeter(total: destination.units(for: outputPlan), progress: callback); try meter!.start() }
        let totalVerification = Mutex<Double>(0)
        let fault = Self.faultAction(plan: plan, assembly: assembly)
        let scratchBefore = workset.reencoded.mapValues { $0.scratch.copySeconds }
        let packsStart = ProcessInfo.processInfo.systemUptime
        let strategy: SegmentCommitStrategy
        do {
            strategy = try SegmentedArchiveOutput.$testingBeforeSynchronize.withValue(fault ?? SegmentedArchiveOutput.testingBeforeSynchronize) {
                try SegmentedArchiveOutput.$testingVerificationElapsed.withValue({ seconds in totalVerification.withLock { $0 = seconds } }) {
                    try destination.commit(outputPlan, meter: meter!) { fd, advance in
                        if !plan.unchanged { try self.selfCheck(fd: fd, plan: plan, assembly: assembly, workset: workset, advance: advance, statistics: &stats) }
                    }
                }
            }
        } catch { if let progressError { throw progressError }; throw error }
        stats.v2Seconds = max(0, totalVerification.withLock { $0 } - stats.selfCheckSeconds)
        stats.packsSeconds = max(0, ProcessInfo.processInfo.systemUptime - packsStart - totalVerification.withLock { $0 })
        stats.summarize(plan: plan, assembly: assembly, original: model, shared: strategy, isCloneMode: destination.isCloneMode,
                        appended: appended, hasAdditions: !additions.isEmpty, workset: workset,
                        scratchBefore: scratchBefore)
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
        let plan = SegmentCommitPlan(prefix: [.source(0..<snapshot.source.length)], appended: nil, terminal: Data(),
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

    private func encodeHeader(_ plain: Data, policy: SevenZipEditModel.Header, mainEnd: UInt64, workset: SevenZipFolderWorkset)
        throws -> (bytes: Data, signature: Data, nextRange: Range<UInt64>) {
        var pack = Data(), next = plain
        if policy.encoded {
            let aes = try workset.makeEncryptor(enabled: policy.encrypted)
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
                folder = .init(coders: [.aes(properties: Array(aes.properties))],
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
