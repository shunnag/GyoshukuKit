import Foundation

/// 新規 solid / filter の入力を folder ごとの unlink 済み spool に集める。
/// folder のサイズ確定後に既存の有界 encoder を使い、巨大ファイルも全体をメモリに載せない。
final class SevenZipBlockWriter {
    private let options: WriterOptions
    private let directory: URL
    private let chunkSize: Int?
    private var encryptors: SevenZipAESEncryptor.Factory
    private var scratch: ScratchFile?
    private var indices: [Int] = []
    private var currentFilter: SevenZipWriteFilter = .none
    private var records: [SevenZipRecords.Entry] = []
    private struct Block {
        let files: [Int]
        let replacement: SevenZipEditPlan.Replacement
        let range: Range<UInt64>
    }
    private var blocks: [Block] = []
    private let pipeline: OrderedChunkPipeline<Job, EncodedBlock, BlockTag>?
    private let folderThreads: Int
    private let codecThreads: Int
    private let longPoleThreads: Int
    private let cancellation = CompressionCancellation()
    private(set) var assignedThreads = 0
    // scratch と AES は worker に所有権を渡し、完了後は出力 spool だけを呼出側へ渡す。
    private struct Job: @unchecked Sendable {
        let input: ScratchFile
        let output: OrderedEntrySpool
        let aes: SevenZipAESEncryptor?
        let filter: SevenZipWriteFilter
        let files: Int
        let threads: Int
        let attribution: AdditionAttribution?
        let name: String
    }
    private struct EncodedBlock: Sendable {
        let output: OrderedEntrySpool
        let folder: SevenZipEditModel.Folder
    }
    private struct BlockTag {
        let files: [Int]
        let streams: [SevenZipEditModel.Substream]
        let threads: Int
        let attribution: AdditionAttribution?
    }

    // 試験では実際に動く内側codecの開始・終了を観測する。
    init(options: WriterOptions, directory: URL, chunkSize: Int?, workerActivity: (@Sendable (Bool) -> Void)? = nil) {
        self.options = options; self.directory = directory; self.chunkSize = chunkSize
        encryptors = .init(password: options.password)
        let configuration = EntryCompressionConfiguration(options: options, method: options.sevenZipMethod, innerParallelism: true, chunkSize: chunkSize)
        let threads = configuration.threads
        folderThreads = threads
        codecThreads = configuration.codecThreads
        longPoleThreads = configuration.longPoleThreads
        let cancellation = self.cancellation
        let bzip2Encoder = ParallelBzip2StreamEncoder.testingEncoder
        let workerRead = SevenZipWriter.testingWorkerRead

        pipeline = threads > 1 || configuration.longPoleThreads > 0 ? OrderedChunkPipeline(threads: threads) { job in
            do {
                defer { job.input.close() }
                try job.input.handle.seek(toOffset: 0)
                let size = job.input.length
                var workerOptions = options
                workerOptions.compressionThreads = job.threads
                let encoder = try ParallelBzip2StreamEncoder.$testingEncoder.withValue(bzip2Encoder) {
                    try SevenZipFolderEncoder.encode(size: size, options: workerOptions, chunkSize: chunkSize, inlineSingleThread: true,
                        aes: job.aes, filter: job.filter, workerActivity: workerActivity, cancellation: cancellation, read: { count in
                            try cancellation.check()
                            try workerRead?(job.name, size)
                            return try FileRead.readChunk(job.input.handle.fileDescriptor, upTo: count)
                        }, write: { bytes in
                            try cancellation.check()
                            try job.output.append(bytes)
                        })
                }
                return EncodedBlock(output: job.output, folder: encoder.folder(size: size, substreamCount: job.files))
            } catch {
                job.output.close()
                if let attribution = job.attribution {
                    throw additionFailure(error, index: attribution.index, addition: attribution.addition)
                }
                throw error
            }
        } : nil
    }

    deinit { abandon() }

    private var parallelLimit: UInt64 {
        options.sevenZipSolid == .off ? UInt64(EntryCompressionConfiguration.inputLimit) : options.resolvedSevenZipBlockSize
    }
    var pendingInputBytes: UInt64 { min(scratch?.length ?? 0, parallelLimit) + (pipeline?.pendingInputBytes ?? 0) }
    private var attribution: AdditionAttribution?

    /// 本文と header の鍵導出を共有し、IV は folder ごとに作る。
    func makeEncryptor() throws -> SevenZipAESEncryptor? { try encryptors.make() }

    func add(name: String, mode: UInt16, size: UInt64, date: Date, read: (Int) throws -> Data,
             position: () -> UInt64, write: (Data) throws -> Void) throws {
        var record = SevenZipRecords.Entry(name: name, mode: mode, size: size, mtime: try SevenZipRecords.timestamp(date))
        guard size > 0 else {
            guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            records.append(record)
            return
        }
        // auto は magic header のみで判定する。PE の探索にも上限を置く。
        var prefix = Data()
        if options.sevenZipFilter == .auto {
            let count = Int(min(size, 64 << 10))
            while prefix.count < count {
                try Task.checkCancellation()
                let bytes = try read(count - prefix.count)
                guard !bytes.isEmpty, bytes.count <= count - prefix.count else { throw WriterError.sourceChanged(name) }
                prefix.append(bytes)
            }
        }
        let filter = SevenZipWriteFilter.select(options.sevenZipFilter, prefix: prefix)
        let limit = options.resolvedSevenZipBlockSize
        let filesLimit: Int
        if case let .on(_, count) = options.sevenZipSolid { filesLimit = count ?? 1_000_000 }
        else { filesLimit = 1 }
        if let scratch, currentFilter != filter || indices.count >= filesLimit || size > limit - min(limit, scratch.length) {
            try submitBlock(position: position, write: write)
        }
        if scratch == nil {
            try pipeline?.waitForCapacity(reserved: size > parallelLimit && !SevenZipWriter.testingOldDrain) {
                tag, result in try self.emit(tag, result, position: position, write: write)
            }
            scratch = try ScratchFile(directory: directory, tag: "7z-solid", pathExtension: "spool")
            currentFilter = filter
            attribution = SevenZipWriter.additionAttribution
        }
        func append(_ bytes: Data) throws {
            record.crc = updateCRC(record.crc, bytes)
            try scratch!.append(bytes)
        }
        try append(prefix)
        var remaining = size - UInt64(prefix.count)
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(IOChunk.size), remaining))
            let bytes = try read(count)
            guard !bytes.isEmpty, bytes.count <= count else { throw WriterError.sourceChanged(name) }
            try append(bytes); remaining -= UInt64(bytes.count)
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        indices.append(records.count); records.append(record)
        // BZip2 solidは次の入力まで確定folderを保持する。単一folderならflushで全coreを使う。
        if options.sevenZipSolid == .off || (options.sevenZipMethod != .bzip2 && (scratch!.length >= limit || indices.count >= filesLimit)) {
            try submitBlock(position: position, write: write)
        }
    }

    func flush(position: () -> UInt64, write: (Data) throws -> Void, didEmit: ((UInt64) throws -> Void)? = nil) throws {
        try submitBlock(position: position, write: write, didEmit: didEmit, final: true)
        try pipeline?.drain(didEmit: didEmit) { tag, result in try self.emit(tag, result, position: position, write: write) }
    }

    private func submitBlock(position: () -> UInt64, write: (Data) throws -> Void,
                             didEmit: ((UInt64) throws -> Void)? = nil, final: Bool = false) throws {
        do {
            try submitBlockWork(position: position, write: write, didEmit: didEmit, final: final)
        } catch {
            if let attribution {
                throw additionFailure(error, index: attribution.index, addition: attribution.addition)
            }
            throw error
        }
    }

    private func submitBlockWork(position: () -> UInt64, write: (Data) throws -> Void,
                                 didEmit: ((UInt64) throws -> Void)?, final: Bool) throws {
        guard let scratch else { return }
        try Task.checkCancellation()
        let size = scratch.length
        var streamOffset: UInt64 = 0
        let streams: [SevenZipEditModel.Substream] = indices.map { index in
            let record = records[index]
            defer { streamOffset += record.size }
            return .init(folderIndex: 0, offset: streamOffset, size: record.size, crc32: record.crc)
        }
        let oversized = size > parallelLimit
        if let pipeline, !(oversized && SevenZipWriter.testingOldDrain), !(final && pipeline.pendingCount == 0) {
            let reservedCodec = oversized && longPoleThreads > 0
            try pipeline.waitForCapacity(reserved: oversized, didEmit: didEmit) {
                tag, result in try self.emit(tag, result, position: position, write: write)
            }
            let normalCodecs = codecThreads - longPoleThreads
            let finderThreads = oversized && options.sevenZipMethod == .lzma ? min(2, normalCodecs) : 1
            // 単一 stream の codec は一枠、片並列は実際の片数まで予約する。
            let pieces: Int
            switch options.sevenZipMethod {
            case .lzma2:
                let width = try chunkSize ?? LZMAWriterConfiguration(options: options).pieceSize
                pieces = Int(min(UInt64(options.resolvedCompressionThreads), (size - 1) / UInt64(width) + 1))
            case .deflate:
                let width = try min(chunkSize ?? LZMAWriterConfiguration(options: WriterOptions(compressionThreads: options.resolvedCompressionThreads)).pieceSize, DeflateBlock.size)
                pieces = Int(min(UInt64(options.resolvedCompressionThreads), (size - 1) / UInt64(width) + 1))
            case .bzip2:
                pieces = ParallelBzip2StreamEncoder.estimatedChunkCount(size: size, level: options.bzip2Level)
            case .lzma: pieces = finderThreads
            case .ppmd, .copy: pieces = 1
            }
            // 大きいfolderにも最低限の片並列を確保し、満杯窓から一枠だけで始めない。
            // 専用枠がないLZMAも、同じcodec予算からparserとfinderの二枠を確保する。
            let minimum = oversized ? max(finderThreads, min(pieces, max(1, (normalCodecs + 1) / 2))) : 1
            while !reservedCodec && normalCodecs - assignedThreads < minimum {
                try pipeline.emitNext({ tag, result in try self.emit(tag, result, position: position, write: write) }, didEmit: didEmit)
            }
            // 長いfolderは空いているcodec枠まで使い、通常folder向けの等分で逐次化しない。
            let share = oversized ? normalCodecs : max(1, options.resolvedCompressionThreads / (pipeline.pendingCount + 1))
            var innerThreads = reservedCodec ? longPoleThreads : min(pieces, normalCodecs - assignedThreads, share)
            if options.sevenZipMethod == .bzip2, options.sevenZipSolid != .off, currentFilter != .none, !final, !oversized {
                // filterはfolder内で逐次。次folderがあるときは予約を分け、複数filterを同時に進める。
                innerThreads = min(innerThreads, max(1, codecThreads / min(4, folderThreads)))
            }
            let output = try OrderedEntrySpool(directory: directory, tag: "7z-folder", diskBacked: oversized,
                maximumLength: OrderedEntrySpool.sevenZipMaximumLength(size: size))
            let job = Job(input: scratch, output: output, aes: try makeEncryptor(), filter: currentFilter, files: indices.count,
                threads: innerThreads, attribution: attribution, name: records[indices[0]].name)
            SevenZipWriter.testingWillSubmit?(job.name, pipeline.pendingCount, oversized, innerThreads)
            // 専用codecは通常窓の予約に混ぜず、専用pipeline枠の返却で再利用する。
            let normalThreads = reservedCodec ? 0 : innerThreads
            assignedThreads += normalThreads
            try pipeline.submit(job, tag: BlockTag(files: indices, streams: streams, threads: normalThreads, attribution: attribution), weight: min(size, parallelLimit), reserved: oversized,
                didEmit: didEmit) { tag, result in try self.emit(tag, result, position: position, write: write) }
            self.scratch = nil
            indices.removeAll(keepingCapacity: true)
            return
        }
        // 一folderだけなら出力spoolを省き、従来のstream encoderで直接出力する。
        try pipeline?.drain(didEmit: didEmit) { tag, result in try self.emit(tag, result, position: position, write: write) }
        let start = position()
        try scratch.handle.seek(toOffset: 0)
        var reported: UInt64 = 0
        let encoder = try SevenZipFolderEncoder.encode(size: size, options: options, chunkSize: chunkSize,
            aes: makeEncryptor(), filter: currentFilter,
            read: { count in
                let bytes = try FileRead.readChunk(scratch.handle.fileDescriptor, upTo: count)
                // 巨大folderの待ち入力は一窓分の予約として報告する。
                let count = min(UInt64(bytes.count), parallelLimit - reported)
                reported += count
                if count > 0 { try didEmit?(count) }
                return bytes
            }, write: write)
        let range = start..<position()
        blocks.append(.init(files: indices, replacement: .init(folder: encoder.folder(size: size, substreamCount: indices.count),
            packs: [.init(range: 0..<range.byteLength)], streams: streams), range: range))
        scratch.close(); self.scratch = nil; indices.removeAll(keepingCapacity: true)
    }

    private func emit(_ tag: BlockTag, _ result: EncodedBlock?, position: () -> UInt64,
                      write: (Data) throws -> Void) throws {
        // 出力が失敗しても同じ予約を返さない。外部writeを呼ぶ前に返却する。
        assignedThreads -= tag.threads
        do {
            try Task.checkCancellation()
            guard let result else { throw WriterError.invalidState }
            let scratch = result.output
            defer { scratch.close() }
            let start = position()
            try scratch.forEachChunk(write)
            let range = start..<position()
            blocks.append(.init(files: tag.files, replacement: .init(folder: result.folder,
                packs: [.init(range: 0..<range.byteLength)], streams: tag.streams), range: range))
        } catch {
            if let attribution = tag.attribution {
                throw additionFailure(error, index: attribution.index, addition: attribution.addition)
            }
            throw error
        }
    }

    func appendedEntries(start: UInt64) -> [SevenZipWriter.AppendedEntry] {
        var definitions: [Int: (Int, Int)] = [:]
        for (index, block) in blocks.enumerated() {
            for (stream, file) in block.files.enumerated() { definitions[file] = (index, stream) }
        }
        var end = start
        return records.enumerated().map { index, record in
            if let (blockIndex, stream) = definitions[index] {
                let block = blocks[blockIndex]
                end = block.range.upperBound
                return .init(record: record, packRange: block.range, folder: stream == 0 ? block.replacement : nil,
                             folderSubstreamIndex: stream)
            }
            return .init(record: record, packRange: end..<end)
        }
    }

    func header(start: UInt64) throws -> Data {
        let plan = SevenZipEditPlan.make(model: .init(), filesByFolder: [], names: [], removed: [], renamed: [:],
            additions: records.count, reencrypt: false, currentPassword: nil, headerPassword: nil, options: options)
        let model = try plan.assemble(original: .init(), filesByFolder: [], replacements: [:], additions: appendedEntries(start: start)).model
        // writer の空書庫は従来と同じ二byte header。
        return records.isEmpty ? Data([1, 0]) : try SevenZipHeaderSerializer.header(model)
    }

    func abandon() {
        cancellation.cancel()
        pipeline?.abandonAndWait()
        assignedThreads = 0
        scratch?.close(); scratch = nil
    }

    func drainPending(position: () -> UInt64, write: (Data) throws -> Void) throws {
        if let pipeline, pipeline.pendingCount > 0 {
            try pipeline.drain { tag, result in try self.emit(tag, result, position: position, write: write) }
        }
    }
}
