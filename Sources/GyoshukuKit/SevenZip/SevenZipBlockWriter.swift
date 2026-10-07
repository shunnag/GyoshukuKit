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
    private let cancellation = CompressionCancellation()
    private var assignedThreads = 0
    // scratch と AES は worker に所有権を渡し、完了後は出力 spool だけを呼出側へ渡す。
    private struct Job: @unchecked Sendable {
        let input: ScratchFile
        let output: OrderedEntrySpool
        let aes: SevenZipAESEncryptor?
        let filter: SevenZipWriteFilter
        let files: Int
        let threads: Int
    }
    private struct EncodedBlock: Sendable {
        let output: OrderedEntrySpool
        let folder: SevenZipEditModel.Folder
    }
    private struct BlockTag {
        let files: [Int]
        let streams: [SevenZipEditModel.Substream]
        let threads: Int
    }

    init(options: WriterOptions, directory: URL, chunkSize: Int?) {
        self.options = options; self.directory = directory; self.chunkSize = chunkSize
        encryptors = .init(password: options.password)
        let threads = EntryCompressionConfiguration(options: options, method: options.sevenZipMethod, innerParallelism: true).threads
        let cancellation = self.cancellation

        pipeline = threads > 1 && options.resolvedSevenZipBlockSize <= 256 << 20
            && !(options.sevenZipMethod == .copy && options.sevenZipFilter == .none) ? OrderedChunkPipeline(threads: threads) { job in
            defer { job.input.close() }
            try job.input.handle.seek(toOffset: 0)
            let size = job.input.length
            var workerOptions = options
            workerOptions.compressionThreads = job.threads
            let encoder = try SevenZipFolderEncoder.encode(size: size, options: workerOptions, chunkSize: chunkSize, inlineSingleThread: true,
                aes: job.aes, filter: job.filter, read: { count in
                    try cancellation.check()
                    return try FileRead.readChunk(job.input.handle.fileDescriptor, upTo: count)
                }, write: { bytes in
                    try cancellation.check()
                    try job.output.append(bytes)
                })
            return EncodedBlock(output: job.output, folder: encoder.folder(size: size, substreamCount: job.files))
        } : nil
    }

    deinit { abandon() }

    var pendingInputBytes: UInt64 { (scratch?.length ?? 0) + (pipeline?.pendingInputBytes ?? 0) }

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
            try pipeline?.waitForCapacity { tag, result in try self.emit(tag, result, position: position, write: write) }
            scratch = try ScratchFile(directory: directory, tag: "7z-solid", pathExtension: "spool")
            currentFilter = filter
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
        if options.sevenZipSolid == .off || scratch!.length >= limit || indices.count >= filesLimit {
            try submitBlock(position: position, write: write)
        }
    }

    func flush(position: () -> UInt64, write: (Data) throws -> Void, didEmit: ((UInt64) throws -> Void)? = nil) throws {
        try submitBlock(position: position, write: write, didEmit: didEmit, final: true)
        try pipeline?.drain(didEmit: didEmit) { tag, result in try self.emit(tag, result, position: position, write: write) }
    }

    private func submitBlock(position: () -> UInt64, write: (Data) throws -> Void,
                             didEmit: ((UInt64) throws -> Void)? = nil, final: Bool = false) throws {
        guard let scratch else { return }
        try Task.checkCancellation()
        let size = scratch.length
        var streamOffset: UInt64 = 0
        let streams: [SevenZipEditModel.Substream] = indices.map { index in
            let record = records[index]
            defer { streamOffset += record.size }
            return .init(folderIndex: 0, offset: streamOffset, size: record.size, crc32: record.crc)
        }
        let parallelLimit = options.sevenZipSolid == .off ? UInt64(EntryCompressionConfiguration.inputLimit)
            : options.resolvedSevenZipBlockSize
        if let pipeline, size <= parallelLimit, !(final && pipeline.pendingCount == 0) {
            try pipeline.waitForCapacity(didEmit: didEmit) { tag, result in try self.emit(tag, result, position: position, write: write) }
            while assignedThreads >= options.resolvedCompressionThreads {
                try pipeline.emitNext({ tag, result in try self.emit(tag, result, position: position, write: write) }, didEmit: didEmit)
            }
            // 単一 stream の codec は一枠、片並列は実際の片数まで予約する。
            let pieces: Int
            switch options.sevenZipMethod {
            case .lzma2:
                let width = try chunkSize ?? LZMAWriterConfiguration(options: options).pieceSize
                pieces = Int((size - 1) / UInt64(width) + 1)
            case .deflate:
                let width = try min(chunkSize ?? LZMAWriterConfiguration(options: WriterOptions(compressionThreads: options.compressionThreads)).pieceSize, DeflateBlock.size)
                pieces = Int((size - 1) / UInt64(width) + 1)
            case .lzma, .bzip2, .ppmd, .copy: pieces = 1
            }
            let innerThreads = min(pieces, options.resolvedCompressionThreads - assignedThreads,
                max(1, options.resolvedCompressionThreads / (pipeline.pendingCount + 1)))
            let output = try OrderedEntrySpool(directory: directory, tag: "7z-folder")
            let job = Job(input: scratch, output: output, aes: try makeEncryptor(), filter: currentFilter, files: indices.count,
                threads: innerThreads)
            assignedThreads += innerThreads
            try pipeline.submit(job, tag: BlockTag(files: indices, streams: streams, threads: innerThreads), weight: size,
                didEmit: didEmit) { tag, result in try self.emit(tag, result, position: position, write: write) }
            self.scratch = nil
            indices.removeAll(keepingCapacity: true)
            return
        }
        // 上限を超える単一ファイルは入力全体を保持せず、既存の stream encoder で処理する。
        try pipeline?.drain(didEmit: didEmit) { tag, result in try self.emit(tag, result, position: position, write: write) }
        let start = position()
        try scratch.handle.seek(toOffset: 0)
        let encoder = try SevenZipFolderEncoder.encode(size: size, options: options, chunkSize: chunkSize,
            aes: makeEncryptor(), filter: currentFilter,
            read: { count in
                let bytes = try FileRead.readChunk(scratch.handle.fileDescriptor, upTo: count)
                try didEmit?(UInt64(bytes.count))
                return bytes
            }, write: write)
        let range = start..<position()
        blocks.append(.init(files: indices, replacement: .init(folder: encoder.folder(size: size, substreamCount: indices.count),
            packs: [.init(range: 0..<range.byteLength)], streams: streams), range: range))
        scratch.close(); self.scratch = nil; indices.removeAll(keepingCapacity: true)
    }

    private func emit(_ tag: BlockTag, _ result: EncodedBlock?, position: () -> UInt64,
                      write: (Data) throws -> Void) throws {
        defer { assignedThreads -= tag.threads }
        try Task.checkCancellation()
        guard let result else { throw WriterError.invalidState }
        let scratch = result.output
        defer { scratch.close() }
        let start = position()
        try scratch.forEachChunk(write)
        let range = start..<position()
        blocks.append(.init(files: tag.files, replacement: .init(folder: result.folder,
            packs: [.init(range: 0..<range.byteLength)], streams: tag.streams), range: range))
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
}
