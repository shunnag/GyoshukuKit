import Foundation
internal import Darwin

struct SegmentSink {
    fileprivate let writer: SegmentWriter
    func write(_ bytes: Data) throws { try writer.write(bytes) }
    func copy(_ range: Range<UInt64>, from source: ArchiveFileSource) throws { try writer.copy(range, from: source) }
}

fileprivate final class SegmentWriter {
    var engine: ZipCopyEngine
    var position: UInt64
    var limit: UInt64 = UInt64.max

    init(descriptor: Int32, position: UInt64 = 0, meter: CommitProgressMeter?) {
        engine = ZipCopyEngine(descriptor: descriptor, meter: meter)
        self.position = position
    }
    func write(_ bytes: Data) throws {
        let end = try checkedAdd(position, UInt64(bytes.count))
        guard end <= limit else { throw UpdaterRouteError.outputVerificationFailed(reason: "segment length") }
        try engine.append(bytes, at: position, progress: nil)
        position = end
    }
    func copy(_ range: Range<UInt64>, from source: ArchiveFileSource) throws {
        let end = try checkedAdd(position, range.byteLength)
        guard end <= limit else { throw UpdaterRouteError.outputVerificationFailed(reason: "segment length") }
        try engine.copy(range, from: source, to: position, progress: nil)
        position = end
    }
    func flush() throws { try engine.flush(progress: nil) }
}

// 形式側は座標と終端を渡し、inode の所有とコピー・照合はここに集める。
final class SegmentedArchiveOutput {
    @TaskLocal static var verificationReadObserver: (@Sendable (UInt64, Int) -> Void)?
    @TaskLocal static var testingBeforeSynchronize: (@Sendable (Int32) throws -> Void)?
    @TaskLocal static var testingDidCloneOutput: (@Sendable (URL) throws -> Void)?
    @TaskLocal static var testingDidSynchronize: (@Sendable () -> Void)?
    @TaskLocal static var testingVerificationElapsed: (@Sendable (Double) -> Void)?
    private let snapshot: ArchiveSourceSnapshot
    private let output: URL
    private let pathExtension: String
    let isCloneMode: Bool
    private let file: OwnedOutputFile
    private var scratch: [ScratchFile] = []
    private var initialPrefix: [OutputSegment]?
    private var committed = false

    init(snapshot: ArchiveSourceSnapshot, output: URL, pathExtension: String, sequential: Bool) {
        self.snapshot = snapshot
        self.output = output
        self.pathExtension = pathExtension
        file = OwnedOutputFile(url: output)
        isCloneMode = !sequential && snapshot.snapshot != nil
    }
    deinit { if !committed { discard() } }

    // clone 出力は clone した inode を先に所有し、開いた fd がその inode であることを OwnedOutputFile.open が確かめる。
    private func create() throws {
        guard file.handle == nil else { return }
        try snapshot.checkUnchanged()
        if isCloneMode {
            guard fclonefileat(snapshot.source.descriptor, AT_FDCWD, output.path,
                              UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
                throw WriterError.io(operation: "clone output", code: errno)
            }
            file.expectClone(try ArchiveOwnedFile(url: output))
            try Self.testingDidCloneOutput?(output)
        }
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (isCloneMode ? 0 : O_CREAT | O_EXCL)
        try file.open(flags: flags, operation: "open output")
        guard fchflags(file.descriptor, 0) == 0, fchmod(file.descriptor, 0o600) == 0 else {
            throw WriterError.io(operation: "output attributes", code: errno)
        }
        try snapshot.checkUnchanged()
    }

    func beginAppend(at offset: UInt64, prefix: [OutputSegment]) throws -> FileHandle {
        do {
            try validateScratch(prefix)
            try create()
            guard prefix.reduce(UInt64(0), { $0 + $1.length }) == offset else { throw WriterError.invalidState }
            if !isCloneMode { try execute(prefix, meter: nil) }
            initialPrefix = prefix
            let fd = dup(file.descriptor)
            guard fd >= 0 else { throw WriterError.io(operation: "dup output", code: errno) }
            let result = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try result.seek(toOffset: offset)
            return result
        } catch { discard(); throw error }
    }

    func makeScratch(tag: String) throws -> ScratchFile {
        let file = try ScratchFile(directory: output.deletingLastPathComponent(), tag: tag, pathExtension: pathExtension)
        scratch.append(file)
        return file
    }

    private func samePrefix(_ prefix: [OutputSegment]) -> Bool {
        guard let initialPrefix, initialPrefix.count == prefix.count else { return false }
        for (left, right) in zip(initialPrefix, prefix) {
            switch (left, right) {
            case let (.source(a), .source(b)): if a != b { return false }
            case let (.literal(a, x), .literal(b, y)):
                guard a == b, let first = try? x(), let second = try? y(), first == second else { return false }
            case let (.scratch(a, x), .scratch(b, y)):
                if a !== b || x != y { return false }
            default: return false
            }
        }
        return true
    }

    private func validateScratch(_ segments: [OutputSegment]) throws {
        let owned = Set(scratch.map(ObjectIdentifier.init))
        for case let .scratch(file, range) in segments {
            guard owned.contains(ObjectIdentifier(file)), range.upperBound <= file.length else {
                throw UpdaterRouteError.outputVerificationFailed(reason: "scratch range")
            }
        }
    }

    private func relocated(_ plan: SegmentCommitPlan) -> Bool {
        guard let appended = plan.appended else { return false }
        let end = plan.prefix.reduce(UInt64(0)) { $0 + $1.length }
        return end != appended.lowerBound || (!isCloneMode && !samePrefix(plan.prefix))
    }

    func units(for plan: SegmentCommitPlan) -> UInt64 {
        let relocate = relocated(plan)
        let alreadyWritten = !isCloneMode && plan.appended != nil && !relocate
        var total = UInt64(plan.terminal.count) + UInt64(plan.finalPatch?.bytes.count ?? 0) + plan.formatVerificationUnits
        var offset: UInt64 = 0
        for segment in plan.prefix {
            switch segment {
            case .source(let range):
                if !isCloneMode || range.lowerBound != offset {
                    total += segment.length * (alreadyWritten ? 2 : 3)
                }
            default: if !alreadyWritten { total += segment.length }
            }
            offset += segment.length
        }
        if relocate, let appended = plan.appended { total += appended.byteLength * 2 }
        return total
    }

    private func execute(_ segments: [OutputSegment], meter: CommitProgressMeter?) throws {
        let writer = SegmentWriter(descriptor: file.descriptor, meter: meter)
        for segment in segments {
            try Task.checkCancellation()
            let end = try checkedAdd(writer.position, segment.length)
            writer.limit = end
            switch segment {
            case .source(let range):
                if isCloneMode, writer.position == range.lowerBound {
                    try writer.flush()
                    writer.position = end
                } else { try writer.copy(range, from: snapshot.source) }
            case .literal(_, let bytes): try writer.write(bytes())
            case .generated(_, let generate): try generate(SegmentSink(writer: writer))
            case .scratch(let file, let range):
                let start = ProcessInfo.processInfo.systemUptime
                try writer.copy(range, from: file.source())
                file.copySeconds += ProcessInfo.processInfo.systemUptime - start
            }
            guard writer.position == end else { throw UpdaterRouteError.outputVerificationFailed(reason: "segment length") }
        }
        try writer.flush()
    }

    func commit(_ plan: SegmentCommitPlan, meter: CommitProgressMeter,
                verify: (_ output: Int32, _ advance: (UInt64) throws -> Void) throws -> Void) throws -> SegmentCommitStrategy {
        do {
            try validateScratch(plan.prefix)
            try create()
            try file.checkOutput()
            let relocate = relocated(plan)
            let prefixEnd = plan.prefix.reduce(UInt64(0)) { $0 + $1.length }
            var spool: ScratchFile?
            if relocate, let appended = plan.appended {
                let scratchFile = try makeScratch(tag: "append")
                let source = try ArchiveFileSource(duplicating: file.descriptor)
                let writer = SegmentWriter(descriptor: scratchFile.handle.fileDescriptor, meter: meter)
                try writer.copy(appended, from: source)
                try writer.flush()
                // writer が fd に直接書いた分を scratch の長さに反映する（容量検査も同じ経路）。
                try scratchFile.willWrite(Int(writer.position))
                spool = scratchFile
                if isCloneMode {
                    try file.reset()
                    try create()
                } else { try file.truncate(atOffset: 0) }
            }
            if isCloneMode || plan.appended == nil || relocate { try execute(plan.prefix, meter: meter) }
            let tail = SegmentWriter(descriptor: file.descriptor, position: prefixEnd, meter: meter)
            if let spool { try tail.copy(0..<spool.length, from: spool.source()) }
            else if let appended = plan.appended { tail.position += appended.byteLength }
            try tail.write(plan.terminal)
            try tail.flush()
            guard tail.position == plan.finalLength else { throw UpdaterRouteError.outputVerificationFailed(reason: "final length plan") }
            try file.truncate(atOffset: plan.finalLength)
            try Self.testingBeforeSynchronize?(file.descriptor)
            try file.synchronize()
            Self.testingDidSynchronize?()
            if let patch = plan.finalPatch {
                guard try checkedAdd(patch.offset, UInt64(patch.bytes.count)) <= plan.finalLength else {
                    throw UpdaterRouteError.outputVerificationFailed(reason: "final patch bounds")
                }
                var engine = ZipCopyEngine(descriptor: file.descriptor, meter: meter)
                try engine.patch(patch.bytes, at: patch.offset, progress: nil)
                try file.synchronize()
                Self.testingDidSynchronize?()
            }
            try snapshot.checkUnchanged()
            let verificationStart = ProcessInfo.processInfo.systemUptime
            try verifySources(plan.prefix, meter: meter)
            try verify(file.descriptor, meter.advance)
            Self.testingVerificationElapsed?(ProcessInfo.processInfo.systemUptime - verificationStart)
            try Task.checkCancellation()
            try snapshot.checkUnchanged()
            try file.checkOutput()
            try file.adopt()
            scratch.forEach { $0.close() }
            scratch.removeAll()
            snapshot.cleanup()
            committed = true
            if plan.appended == nil, plan.terminal.isEmpty, plan.finalPatch == nil,
               plan.prefix.count == 1, case .source(let range) = plan.prefix[0], range == 0..<snapshot.source.length {
                return .unchanged
            }
            if relocate { return .relocatedAppend }
            if !isCloneMode { return .sequential }
            if plan.appended != nil, plan.prefix.count <= 1,
               plan.prefix.isEmpty || { if case .source(let range) = plan.prefix[0] { return range.lowerBound == 0 }; return false }() {
                return .appendOnly
            }
            var cursor: UInt64 = 0
            var inPlace = plan.appended == nil
            for segment in plan.prefix {
                if case .source(let range) = segment, range.lowerBound != cursor { inPlace = false }
                cursor += segment.length
            }
            return inPlace ? .inPlacePatch : .splice
        } catch { discard(); throw error }
    }

    private func verifySources(_ segments: [OutputSegment], meter: CommitProgressMeter) throws {
        var outputOffset: UInt64 = 0
        for segment in segments {
            defer { outputOffset += segment.length }
            guard case .source(let range) = segment, !isCloneMode || range.lowerBound != outputOffset else { continue }
            var cursor: UInt64 = 0
            while cursor < segment.length {
                try Task.checkCancellation()
                let count = Int(min(4 * 1024 * 1024, segment.length - cursor))
                let original = try Self.read(snapshot.source.descriptor, at: range.lowerBound + cursor, count: count, counted: true)
                let written = try Self.read(file.descriptor, at: outputOffset + cursor, count: count, counted: true)
                try meter.advance(UInt64(count) * 2)
                guard original == written else { throw UpdaterRouteError.outputVerificationFailed(reason: "V5 source bytes") }
                cursor += UInt64(count)
            }
        }
    }

    static func read(_ fd: Int32, at offset: UInt64, count: Int, counted: Bool = false) throws -> Data {
        let data = try ZipAppendedRecordSelfCheck.read(fd, at: offset, count: count)
        if counted { verificationReadObserver?(offset, count) }
        return data
    }

    func discard() {
        file.discard()
        scratch.forEach { $0.close() }
        scratch.removeAll()
        snapshot.cleanup()
    }
}
