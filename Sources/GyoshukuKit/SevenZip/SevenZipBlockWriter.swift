import Foundation

/// 新規 solid / filter の入力を一つの unlink 済み spool に集める。
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

    init(options: WriterOptions, directory: URL, chunkSize: Int?) {
        self.options = options; self.directory = directory; self.chunkSize = chunkSize
        encryptors = .init(password: options.password)
    }

    var pendingInputBytes: UInt64 { scratch?.length ?? 0 }

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
            try flush(position: position, write: write)
        }
        if scratch == nil {
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
            try flush(position: position, write: write)
        }
    }

    func flush(position: () -> UInt64, write: (Data) throws -> Void, didEmit: ((UInt64) throws -> Void)? = nil) throws {
        guard let scratch else { return }
        try Task.checkCancellation()
        let start = position(), size = scratch.length
        try scratch.handle.seek(toOffset: 0)
        let encoder = try SevenZipFolderEncoder.encode(size: size, options: options, chunkSize: chunkSize,
            aes: makeEncryptor(), filter: currentFilter,
            read: { count in
                let bytes = try FileRead.readChunk(scratch.handle.fileDescriptor, upTo: count)
                try didEmit?(UInt64(bytes.count))
                return bytes
            }, write: write)
        var offset: UInt64 = 0
        let streams: [SevenZipEditModel.Substream] = indices.map { index in
            let record = records[index]
            defer { offset += record.size }
            return .init(folderIndex: 0, offset: offset, size: record.size, crc32: record.crc)
        }
        let range = start..<position()
        blocks.append(.init(files: indices, replacement: .init(folder: encoder.folder(size: size, substreamCount: indices.count),
            packs: [.init(range: 0..<range.byteLength)], streams: streams), range: range))
        scratch.close(); self.scratch = nil; indices.removeAll(keepingCapacity: true)
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

    func abandon() { scratch?.close(); scratch = nil }
}
