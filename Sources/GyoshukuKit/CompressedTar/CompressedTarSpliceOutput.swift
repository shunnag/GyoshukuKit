import Foundation
private import Darwin
@_spi(TarEditLayout) internal import KaitoKit

// 圧縮 tar の区切り単位の更新。経路は
// TarEditPlan → TarImageSource（+TarSpliceStorage）→ CompressedTarSplicePlan → CompressedTarSpliceOutput.commit → CompressedTarSelfCheck.verify。
// この経路は SplicedArchiveOutput（segment 計画を実行する共通の commit）を使わない。出力 inode の所有は OwnedOutputFile を共有する。
// このファイルは出力。inode を所有し、橋の事前符号化、運ぶ chunk の copy、framing、故障注入、自己照合の呼出しを行う。
final class CompressedTarSpliceOutput {
    struct Encoded: Sendable {
        let bytes: Data
        let crc: UInt32
        let headerSize: UInt64
        let payloadSize: UInt64
        let unpaddedSize: UInt64
        let seconds: Double
    }
    struct Metadata: Sendable {
        let length: UInt64, crc: UInt32, headerSize: UInt64, payloadSize: UInt64, unpaddedSize: UInt64
        init(_ encoded: Encoded) {
            length = UInt64(encoded.bytes.count); crc = encoded.crc
            headerSize = encoded.headerSize; payloadSize = encoded.payloadSize; unpaddedSize = encoded.unpaddedSize
        }
    }
    struct WrittenPart: Sendable {
        var image: Range<UInt64>
        let output: Range<UInt64>
        let baseIndex: Int?
        let meta: Metadata
    }
    struct Input: Sendable {
        let bytes: Data, dictionary: Data
        let final: Bool
    }

    let output: URL
    let snapshot: TarEditingSnapshot
    let format: ArchiveFormat
    let options: WriterOptions
    /// 並列数は init で一度だけ決め、事前符号化・書出し・自己照合の pipeline が共有する。
    let threads: Int
    private let file: OwnedOutputFile
    private var retained = false
    private var encodingSeconds = 0.0, copyingSeconds = 0.0, checkingSeconds = 0.0
    private var carriedCount = 0, encodedCount = 0
    private(set) var parts: [WrittenPart] = []
    private(set) var segments: [CompressedTarOutputSegment] = []
    private(set) var payloadEnd: UInt64 = 0
    private(set) var expectedTail = Data()
    private(set) var finalLength: UInt64 = 0
    private(set) var crc: UInt32 = 0

    init(output: URL, snapshot: TarEditingSnapshot, format: ArchiveFormat, options: WriterOptions) {
        self.output = output; self.snapshot = snapshot; self.format = format; self.options = options
        threads = options.resolvedCompressionThreads
        file = OwnedOutputFile(url: output)
    }
    deinit { if !retained { discard() } }
    func keep() { retained = true }
    func discard() { file.discard() }
    private func create() throws {
        try Task.checkCancellation()
        guard snapshot.archiveIsUnchanged() else { throw UpdaterError.sourceChanged }
        try file.open(flags: O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, operation: "create compressed tar")
    }
    static func encode(_ input: Input, format: ArchiveFormat, options: WriterOptions) throws -> Encoded {
        let start = ProcessInfo.processInfo.systemUptime
        let crc = updateCRC(0, input.bytes)
        let bytes: Data
        var header: UInt64 = 0, payload: UInt64 = 0, unpadded: UInt64 = 0
        switch format {
        case .tarGzip:
            bytes = try DeflateBlock.encode(.init(input: input.bytes, dictionary: input.dictionary, final: input.final), level: options.deflateLevel)
        case .tarBzip2: bytes = try Bzip2StreamEncoder.encode(input.bytes, level: options.bzip2Level)
        case .tarXZ:
            let compressed = try LZMA2Compressor.encode(input.bytes)
            var result = Data()
            _ = try XZFraming.emitBlock(compressed, crc: crc) { result.append($0) }
            bytes = result
            payload = UInt64(compressed.payload.count)
            header = UInt64(bytes.count) - payload - (4 - payload % 4) % 4 - 4
            unpadded = header + payload + 4
        default: throw WriterError.unsupportedOption("format")
        }
        return Encoded(bytes: bytes, crc: crc, headerSize: header, payloadSize: payload, unpaddedSize: unpadded,
                       seconds: ProcessInfo.processInfo.systemUptime - start)
    }
    private func input(_ part: CompressedTarSplicePlan.Part, image: TarImageSource) throws -> Input {
        let bytes = try TarLayout.bytes(image, at: part.image.lowerBound, count: Int(part.image.byteLength))
        let start = part.image.lowerBound
        let window = min(start, UInt64(DeflateBlock.windowSize))
        let dictionary = format == .tarGzip ? try TarLayout.bytes(image, at: start - window, count: Int(window)) : Data()
        return Input(bytes: bytes, dictionary: dictionary, final: part.image.upperBound == image.length)
    }

    /// 事前符号化の結果。metas は全 part の圧縮長と CRC（運ぶ chunk は地図から、橋は符号化結果から）。
    private struct Preflight {
        var metas: [Metadata] = []
        var cache: [Int: Encoded] = [:]
        var reencoded: UInt64 = 0, old: UInt64 = 0, carried: UInt64 = 0
    }

    /// 橋の事前符号化 → tail の確定 → total を固定した meter → 出力の作成 → framing header と parts の書出し → tail →
    /// 故障注入 → fsync → 自己照合 → 公開、の順に進む。
    func commit(image: TarImageSource?, plan: CompressedTarSplicePlan?,
                progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws -> CompressedTarCommitResult {
        guard let image, let plan else { return try unchanged(progress: progress) }
        var preflight = try preflightEncode(plan: plan, image: image)
        try prepareTail(metas: preflight.metas, plan: plan, image: image)
        let verification = CompressedTarSelfCheck.units(format: format, metas: preflight.metas, encoded: plan.parts.map { $0.reused == nil }, tail: expectedTail.count)
        let meter = CommitProgressMeter(total: try checkedAdd(try checkedAdd(preflight.reencoded, preflight.carried), verification), progress: progress)
        try meter.start()
        try create()
        var engine = try writeParts(plan: plan, image: image, metas: preflight.metas, cache: &preflight.cache, meter: meter)
        try writeTail(image: image, engine: &engine)
        try injectFault()
        try file.synchronize()
        guard snapshot.archiveIsUnchanged() else { throw UpdaterError.sourceChanged }
        let checkStart = ProcessInfo.processInfo.systemUptime
        if !CompressedTarUpdater.testingSkipsSelfCheck {
            try CompressedTarSelfCheck.verify(writer: self, image: image, plan: plan, descriptor: file.descriptor, meter: meter)
        }
        checkingSeconds = ProcessInfo.processInfo.systemUptime - checkStart
        let strategy: CompressedTarStrategy = plan.reason.map { .fullEncode($0) } ?? .splice(carriedChunks: carriedCount, reencodedChunks: encodedCount)
        return try finish(strategy: strategy, reencoded: preflight.reencoded, old: preflight.old, carried: preflight.carried, meter: meter)
    }

    /// 事前符号化と書出しで同じ並列数と軽い block の枠を使う。
    private func makePipeline() -> OrderedChunkPipeline<Input, Encoded, Int> {
        let format = self.format, options = self.options, threads = self.threads
        let lightWeightLimit = format == .tarXZ && threads > 1 ? UInt64(ParallelXZCompressor.lightChunkLimit) : 0
        return OrderedChunkPipeline(threads: threads, lightWeightLimit: lightWeightLimit) {
            try Self.encode($0, format: format, options: options)
        }
    }

    /// 圧縮長を先に確定して total を固定する。cache は並列数 × 上限サイズの定数倍で、大きい fullEncode も平らに保存しない。
    private func preflightEncode(plan: CompressedTarSplicePlan, image: TarImageSource) throws -> Preflight {
        var result = Preflight()
        var metadata: [Int: Metadata] = [:]
        var cachedBytes = 0
        let cacheLimit = threads * CompressedTarSplicePlan.limits(format, options: options).piece * 2
        let pipeline = makePipeline()
        let collect: (Int, Encoded?) throws -> Void = { index, encoded in
            guard let encoded else { return }
            metadata[index] = Metadata(encoded)
            self.encodingSeconds += encoded.seconds
            if encoded.bytes.count <= cacheLimit - cachedBytes { result.cache[index] = encoded; cachedBytes += encoded.bytes.count }
        }
        for (index, part) in plan.parts.enumerated() where part.reused == nil {
            try CompressedTarUpdater.testingStage?(.encoding)
            try pipeline.waitForCapacity(emit: collect)
            try pipeline.submit(input(part, image: image), tag: index, weight: part.image.byteLength, emit: collect)
        }
        try pipeline.finish(emit: collect)
        for (index, part) in plan.parts.enumerated() {
            if let base = part.reused {
                let chunk = plan.chunks[base]
                result.carried += chunk.compressedRange.byteLength
                var chunkCRC: UInt32 = 0, header: UInt64 = 0, payload: UInt64 = 0, unpadded: UInt64 = 0
                if case .gzip(let gzip) = snapshot.chunkMap {
                    let first = gzip.points[base].crc32
                    let last = base + 1 < gzip.points.count ? gzip.points[base + 1].crc32 : gzip.trailerCRC32
                    chunkCRC = last ^ GzipFraming.combineCRC(first, 0, length: chunk.imageRange.byteLength)
                }
                if case .xz(let xz) = snapshot.chunkMap {
                    header = xz.blocks[base].headerSize; payload = xz.blocks[base].compressedPayloadSize
                    unpadded = xz.blocks[base].unpaddedSize
                }
                result.metas.append(Metadata(Encoded(bytes: Data(), crc: chunkCRC, headerSize: header,
                    payloadSize: payload, unpaddedSize: unpadded, seconds: 0), length: chunk.compressedRange.byteLength))
            } else {
                result.reencoded += part.image.byteLength; result.old += image.oldBytes(in: part.image)
                result.metas.append(metadata[index]!)
            }
        }
        return result
    }

    /// 全 part の CRC を結合して stream の CRC を確定し、gzip の trailer / xz の Index + footer を expectedTail に置く。
    private func prepareTail(metas: [Metadata], plan: CompressedTarSplicePlan, image: TarImageSource) throws {
        var records = Data()
        for (index, part) in plan.parts.enumerated() {
            crc = GzipFraming.combineCRC(crc, metas[index].crc, length: part.image.byteLength)
            if format == .tarXZ {
                records.append(XZFraming.vli(metas[index].unpaddedSize)); records.append(XZFraming.vli(part.image.byteLength))
            }
        }
        if format == .tarGzip { expectedTail = GzipFraming.trailer(crc: crc, imageLength: image.length) }
        if format == .tarXZ {
            try XZFraming.emitIndexAndFooter(records: records, blockCount: UInt64(plan.parts.count)) { expectedTail.append($0) }
        }
    }

    /// framing header に続けて part を順に書く。運ぶ chunk は原本から copy し、橋は cache か再符号化の結果を置く。
    /// cache の橋は書いた時点で取り除いて解放する。parts / segments / payloadEnd を記録し、まだ flush していない engine を返す。
    private func writeParts(plan: CompressedTarSplicePlan, image: TarImageSource, metas: [Metadata],
                            cache: inout [Int: Encoded], meter: CommitProgressMeter) throws -> ZipCopyEngine {
        var engine = ZipCopyEngine(descriptor: file.descriptor, totalBytes: 0)
        var cursor: UInt64 = 0
        let header = format == .tarGzip ? GzipFraming.header(level: options.deflateLevel) : format == .tarXZ ? XZFraming.streamHeader : Data()
        try engine.append(header, at: cursor, progress: nil); cursor += UInt64(header.count)
        let pipeline = makePipeline()
        var dropped = false
        func emit(_ index: Int, _ value: Encoded?) throws {
            let part = plan.parts[index], meta = metas[index]
            if self.shouldDrop(part: part, index: index, of: plan.parts.count, alreadyDropped: dropped) { dropped = true; return }
            let start = cursor
            if let base = part.reused {
                try CompressedTarUpdater.testingStage?(.copying)
                let chunk = plan.chunks[base], time = ProcessInfo.processInfo.systemUptime
                try engine.copy(chunk.compressedRange, from: self.snapshot.archive, to: cursor, compressedCRC32: chunk.compressedCRC32)
                self.copyingSeconds += ProcessInfo.processInfo.systemUptime - time
                cursor += chunk.compressedRange.byteLength
                try meter.advance(chunk.compressedRange.byteLength)
                self.appendSegment(.reused(output: start..<cursor, base: chunk.compressedRange))
                self.carriedCount += 1
            } else {
                let encoded = value ?? cache.removeValue(forKey: index)!
                if value != nil { self.encodingSeconds += encoded.seconds }
                guard UInt64(encoded.bytes.count) == meta.length, encoded.crc == meta.crc else {
                    throw TarUpdaterError.outputVerificationFailed(reason: "encoding changed after planning")
                }
                try engine.append(encoded.bytes, at: cursor, progress: nil)
                cursor += UInt64(encoded.bytes.count)
                try meter.advance(part.image.byteLength)
                self.appendSegment(.encoded(output: start..<cursor))
                self.encodedCount += 1
            }
            self.parts.append(WrittenPart(image: part.image, output: start..<cursor, baseIndex: part.reused, meta: meta))
        }
        for (index, part) in plan.parts.enumerated() {
            try Task.checkCancellation()
            try pipeline.waitForCapacity(emit: emit)
            let block = part.reused != nil || cache[index] != nil ? nil : try input(part, image: image)
            try pipeline.submit(block, tag: index, weight: block == nil ? 0 : part.image.byteLength, emit: emit)
        }
        try pipeline.finish(emit: emit)
        payloadEnd = cursor
        return engine
    }

    /// 試験用の故障を反映した tail を書いて flush し、finalLength を確定する。
    private func writeTail(image: TarImageSource, engine: inout ZipCopyEngine) throws {
        var tail = expectedTail
        try applyTestingFaults(to: &tail, image: image)
        try engine.append(tail, at: payloadEnd, progress: nil)
        try engine.flush(progress: nil)
        finalLength = payloadEnd + UInt64(tail.count)
    }

    private func appendSegment(_ segment: CompressedTarOutputSegment) {
        if let last = segments.last {
            switch (last, segment) {
            case let (.encoded(a), .encoded(b)) where a.upperBound == b.lowerBound:
                segments[segments.count - 1] = .encoded(output: a.lowerBound..<b.upperBound); return
            case let (.reused(a, x), .reused(b, y)) where a.upperBound == b.lowerBound && x.upperBound == y.lowerBound:
                segments[segments.count - 1] = .reused(output: a.lowerBound..<b.upperBound, base: x.lowerBound..<y.upperBound); return
            default: break
            }
        }
        segments.append(segment)
    }

    private func finish(strategy: CompressedTarStrategy, reencoded: UInt64, old: UInt64, carried: UInt64,
                        meter: CommitProgressMeter) throws -> CompressedTarCommitResult {
        try Task.checkCancellation()
        try meter.finish()
        try Task.checkCancellation()
        try file.checkOutput()
        guard snapshot.archiveIsUnchanged() else { throw UpdaterError.sourceChanged }
        var info = stat()
        guard fstat(file.descriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) == finalLength else {
            throw TarUpdaterError.outputVerificationFailed(reason: "V3 size")
        }
        let identity = CompressedTarCommitResult.OutputIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino,
            size: UInt64(info.st_size), modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
        try file.adopt()
        return CompressedTarCommitResult(strategy: strategy, output: identity, segments: segments,
            reencodedImageBytes: reencoded, reencodedOldImageBytes: old, carriedCompressedBytes: carried)
    }

    private func unchanged(progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws -> CompressedTarCommitResult {
        let meter = CommitProgressMeter(total: snapshot.archive.length, progress: progress)
        try meter.start(); try create()
        var engine = ZipCopyEngine(descriptor: file.descriptor, meter: meter)
        let start = ProcessInfo.processInfo.systemUptime
        var cursor: UInt64 = 0
        let chunks = snapshot.chunkMap?.chunks ?? []
        // 地図が無くても copy は走る。framing byte より前に一度だけ stage を通知する。
        try CompressedTarUpdater.testingStage?(.copying)
        for chunk in chunks {
            if cursor < chunk.compressedRange.lowerBound { try engine.copy(cursor..<chunk.compressedRange.lowerBound, from: snapshot.archive, to: cursor) }
            try engine.copy(chunk.compressedRange, from: snapshot.archive, to: chunk.compressedRange.lowerBound,
                            compressedCRC32: chunk.compressedCRC32)
            cursor = chunk.compressedRange.upperBound
        }
        if cursor < snapshot.archive.length { try engine.copy(cursor..<snapshot.archive.length, from: snapshot.archive, to: cursor) }
        try engine.flush(progress: nil)
        copyingSeconds = ProcessInfo.processInfo.systemUptime - start
        finalLength = snapshot.archive.length
        let range = try unchangedPayload(chunks)
        segments = [.reused(output: range, base: range)]
        carriedCount = chunks.count
        try file.synchronize()
        return try finish(strategy: .unchanged, reencoded: 0, old: 0, carried: range.byteLength, meter: meter)
    }

    private func unchangedPayload(_ chunks: [CompressedTarChunk]) throws -> Range<UInt64> {
        if let first = chunks.first, let last = chunks.last { return first.compressedRange.lowerBound..<last.compressedRange.upperBound }
        if format == .tarBzip2 { return 0..<snapshot.archive.length }
        if format == .tarGzip {
            let header = try TarLayout.bytes(snapshot.archive, at: 0, count: 10)
            var offset: UInt64 = 10
            if header[3] & 4 != 0 {
                let extra = try TarLayout.bytes(snapshot.archive, at: offset, count: 2)
                offset += 2 + UInt64(extra[0]) + UInt64(extra[1]) * 256
            }
            for flag: UInt8 in [8, 16] where header[3] & flag != 0 {
                while try TarLayout.bytes(snapshot.archive, at: offset, count: 1)[0] != 0 { offset += 1 }
                offset += 1
            }
            if header[3] & 2 != 0 { offset += 2 }
            return offset..<(snapshot.archive.length - 8)
        }
        var end = snapshot.archive.length
        while try TarLayout.bytes(snapshot.archive, at: end - 4, count: 4) == Data(count: 4) { end -= 4 }
        let footer = try TarLayout.bytes(snapshot.archive, at: end - 12, count: 12)
        return 12..<(end - 12 - (UInt64(footer.zip32(4)) + 1) * 4)
    }

    /// 試験用。bzip2 は最初に運ぶ stream を一つ、xz は最後の block を書かずに飛ばし、自己照合と K5 が拒否することを確かめる。
    private func shouldDrop(part: CompressedTarSplicePlan.Part, index: Int, of count: Int, alreadyDropped: Bool) -> Bool {
        switch CompressedTarUpdater.testingFault {
        case .dropBzip2Stream: return format == .tarBzip2 && !alreadyDropped && part.reused != nil
        case .dropXZBlock: return format == .tarXZ && index == count - 1
        default: return false
        }
    }

    /// 試験用。xz は書いた parts から Index を作り直し（xzIndexLength は先頭 record の長さを 512 ずらす）、gzip は trailer の CRC を壊す。
    private func applyTestingFaults(to tail: inout Data, image: TarImageSource) throws {
        let fault = CompressedTarUpdater.testingFault
        if format == .tarXZ, fault == .dropXZBlock || fault == .xzIndexLength {
            var changed = Data()
            for (index, part) in parts.enumerated() {
                changed.append(XZFraming.vli(part.meta.unpaddedSize))
                changed.append(XZFraming.vli(part.image.byteLength + (fault == .xzIndexLength && index == 0 ? 512 : 0)))
            }
            tail = Data()
            try XZFraming.emitIndexAndFooter(records: changed, blockCount: UInt64(parts.count)) { tail.append($0) }
        }
        if format == .tarGzip, fault == .trailerCRC {
            tail = GzipFraming.trailer(crc: crc &+ 1, imageLength: image.length)
        }
    }

    private func injectFault() throws {
        if CompressedTarUpdater.testingFault == .shiftLedger, !parts.isEmpty {
            parts[0].image = (parts[0].image.lowerBound + 1)..<parts[0].image.upperBound
        }
        let reused: Bool
        switch CompressedTarUpdater.testingFault {
        case .flipEncodedByte: reused = false
        case .flipReusedByte: reused = true
        default: return
        }
        guard let part = parts.first(where: { ($0.baseIndex != nil) == reused }) else { return }
        // gzip の途中の bit は未使用の符号や padding に当たり、復号結果を変えないことがある。
        // encoded の注入は先頭 block の予約済み BTYPE=3 にし、V1 の拒否を確実に検証する。
        let invalidDeflate = format == .tarGzip && !reused
        let offset = part.output.lowerBound + (invalidDeflate ? 0 : part.output.byteLength / 2)
        var byte = try SplicedArchiveOutput.read(file.descriptor, at: offset, count: 1)
        if invalidDeflate { byte[0] = (byte[0] & ~UInt8(6)) | 6 }
        else { byte[0] ^= 1 }
        try byte.withUnsafeBytes { try ZipCopyEngine.pwrite(file.descriptor, bytes: $0, at: offset) }
    }

    func statistics(planning: Double, scratch: UInt64, result: CompressedTarCommitResult) -> CompressedTarCommitStatistics {
        CompressedTarCommitStatistics(planningSeconds: planning, encodingSeconds: encodingSeconds,
            copyingSeconds: copyingSeconds, selfCheckSeconds: checkingSeconds,
            reencodedImageBytes: result.reencodedImageBytes, reencodedOldImageBytes: result.reencodedOldImageBytes,
            carriedCompressedBytes: result.carriedCompressedBytes, carriedChunks: carriedCount,
            reencodedChunks: encodedCount, scratchBytes: scratch, strategy: result.strategy)
    }
}

private extension CompressedTarSpliceOutput.Metadata {
    init(_ encoded: CompressedTarSpliceOutput.Encoded, length: UInt64) {
        self.init(length: length, crc: encoded.crc, headerSize: encoded.headerSize,
                  payloadSize: encoded.payloadSize, unpaddedSize: encoded.unpaddedSize)
    }
    init(length: UInt64, crc: UInt32, headerSize: UInt64, payloadSize: UInt64, unpaddedSize: UInt64) {
        self.length = length; self.crc = crc; self.headerSize = headerSize
        self.payloadSize = payloadSize; self.unpaddedSize = unpaddedSize
    }
}
