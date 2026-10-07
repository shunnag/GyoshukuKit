import Foundation

// ZIP の record を直列化する。名前の検証・衝突検査・ディスク探索は ArchiveWriter と共有し、ここでは ZIP だけを扱う。
// position は論理 offset。出力 buffer は seek、外部への引渡し、公開操作の完了前に書き出す。
final class ZipWriter {
    typealias AppendedRecords = (entries: [ZipRecords.Entry], end: UInt64)

    // pipeline の tag。entry の最初の block は entry を、最後の block は crc を運ぶ。一括追加の項目は帰属先を運ぶ。
    struct Tag {
        let entry: ZipRecords.Entry?
        let crc: UInt32?
        var attribution: AdditionAttribution? = nil
    }

    private let output: FileHandle
    private let url: URL
    private let options: WriterOptions
    private let deflateBlockSize: Int
    private let pipeline: OrderedChunkPipeline<ZipWork, Prefetched, Tag>
    private let salt: () throws -> Data
    private let entryCompressor: ZipEntryCompressor
    private let entryPipeline: OrderedChunkPipeline<EntryJob, EncodedEntry, Tag>?
    private let entryCancellation = CompressionCancellation()
    private struct EntryJob: Sendable {
        let data: Data?
        let file: FileJob?
        let name: String
        let method: CompressionMethod
        let spool: OrderedEntrySpool
    }
    private struct EncodedEntry: Sendable {
        let spool: OrderedEntrySpool
        let crc: UInt32
    }
    private var emittingEntry: ZipRecords.Entry?
    private var emittingHeaderSize = 0
    private var emittingStart: UInt64 = 0
    private var emittingAES: ZipAESEncryptor?
    private(set) var position: UInt64 = 0
    private var outputBuffer = Data()
    private var bufferedAttribution: AdditionAttribution?
    private var appendStart: UInt64 = 0
    private var recordBase: UInt64 = 0
    private(set) var entries: [ZipRecords.Entry] = []
    private static let compressedExtensions: Set<String> = [
        "zip", "gz", "bz2", "xz", "7z", "rar", "jpg", "jpeg", "png", "gif", "webp", "heic", "mp3", "mp4", "mov", "pdf"
    ]

    init(output: FileHandle, url: URL, options: WriterOptions, deflateBlockSize: Int,
         deflateEncoder: @escaping DeflateBlock.Encoder, salt: @escaping () throws -> Data) {
        self.output = output
        self.url = url
        self.options = options
        self.deflateBlockSize = deflateBlockSize
        self.salt = salt
        entryCompressor = ZipEntryCompressor(options: options)
        let entryThreads = EntryCompressionConfiguration(options: options).threads
        let cancellation = entryCancellation
        var workerOptions = options
        workerOptions.compressionThreads = 1
        let resolvedWorkerOptions = workerOptions
        entryPipeline = entryThreads > 1 && options.compressionMethod != .deflate && options.compressionMethod != .stored
            ? OrderedChunkPipeline(threads: entryThreads) { job in
                do {
                    let compressor = ZipEntryCompressor(options: resolvedWorkerOptions)
                    let data = try job.file.map { try $0.run { _ in throw WriterError.invalidState }.data } ?? job.data!
                    var offset = 0
                    let crc = try compressor.compress(name: job.name, size: UInt64(data.count), method: job.method,
                        read: { count in
                            try cancellation.check()
                            let end = min(data.count, offset + count)
                            defer { offset = end }
                            return data.subdata(in: offset..<end)
                        }, emit: { bytes in
                            try cancellation.check()
                            try job.spool.scratch.append(bytes)
                        })
                    return EncodedEntry(spool: job.spool, crc: crc)
                } catch {
                    if let file = job.file { throw additionFailure(error, index: file.index, addition: file.addition) }
                    throw error
                }
            } : nil
        pipeline = OrderedChunkPipeline(threads: options.resolvedCompressionThreads) {
            switch $0 {
            case let .block(block): return Prefetched(data: try deflateEncoder(block, options.deflateLevel), crc: 0)
            case let .file(job): return try job.run { try deflateEncoder($0, options.deflateLevel) }
            }
        }
    }

    deinit { abort() }

    var pendingInputBytes: UInt64 { pipeline.pendingInputBytes + (entryPipeline?.pendingInputBytes ?? 0) }

    // ZipCrypto は CRC が要るので spool を通り、一括追加の通常ファイルは項目別の経路へ戻す。
    var encryptsWithZipCrypto: Bool { options.password != nil && options.zipEncryption == .zipCrypto }

    // updater は既存書庫の CD の位置から書き始める。recordBase は entry.offset の基準で、原本の CD offset。
    func prepareAppend(at offset: UInt64, recordBase: UInt64?) {
        position = offset
        appendStart = offset
        self.recordBase = recordBase ?? offset
    }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?) throws {
        try entryPipeline?.drain(didEmit: didEmit, emit: emitEntry)
        try pipeline.drain(didEmit: didEmit, emit: emitDeflate)
    }

    func drainAppendedRecords() throws -> AppendedRecords {
        try entryPipeline?.drain(emit: emitEntry)
        try pipeline.drain(emit: emitDeflate)
        return (entries, position)
    }

    // 旧 CD は copyCentral が一定量ずつ運び、追加分の central と EOCD をこの writer が続けて書く。
    func finish(existingCount: UInt64, comment: Data,
                progress: ((UInt64, Int) throws -> Void)?,
                copyCentral: (_ emit: (Data) throws -> Void) throws -> Void) throws {
        try entryPipeline?.finish(emit: emitEntry)
        try pipeline.finish(emit: emitDeflate)
        let start = position
        func emit(_ bytes: Data) throws {
            let offset = position
            try write(bytes)
            if let progress {
                try flushOutput()
                ZipCopyEngine.writeObserver?(offset, bytes.count)
                try progress(offset, bytes.count)
            }
        }
        var central = ZipCentralDirectory.CopyValidator(expectedCount: existingCount)
        try copyCentral { bytes in
            try central.consume(bytes)
            try emit(bytes)
        }
        try central.finish()
        for entry in entries {
            try autoreleasepool { try emit(entry.central()) }
        }
        try emit(ZipRecords.end(count: checkedAdd(existingCount, UInt64(entries.count)),
                                centralSize: position - start, centralOffset: start, comment: comment))
        try flushOutput()
        try output.truncate(atOffset: position)
        try output.synchronize()
        try output.close()
    }

    // 失敗した writer の pipeline を止め、未出力の buffer と進行中の entry を捨てる。
    func abort() {
        entryCancellation.cancel()
        entryPipeline?.abandonAndWait()
        pipeline.abandon()
        emittingEntry = nil
        emittingAES = nil
        outputBuffer.removeAll()
        bufferedAttribution = nil
    }

    // MARK: 項目別の追加

    func add(name: String, mode: UInt16, size: UInt64, date: Date, atime: Date?, owners: (UInt32, UInt32)?,
             read: (Int) throws -> Data) throws {
        try Task.checkCancellation()
        let method = compression(name: name, mode: mode, size: size)
        if let entryPipeline, size <= EntryCompressionConfiguration.inputLimit {
            try entryPipeline.waitForCapacity(emit: emitEntry)
            let entry = try makeEntry(name: name, mode: mode, size: size, date: date, atime: atime, owners: owners, method: method)
            var input = Data()
            input.reserveCapacity(Int(size))
            while input.count < Int(size) {
                try Task.checkCancellation()
                let requested = min(IOChunk.size, Int(size) - input.count)
                let bytes = try read(requested)
                guard !bytes.isEmpty, bytes.count <= requested else { throw WriterError.sourceChanged(name) }
                input.append(bytes)
            }
            guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            let spool = try OrderedEntrySpool(directory: url.deletingLastPathComponent(), tag: "zip-entry")
            try entryPipeline.submit(EntryJob(data: input, file: nil, name: name, method: method, spool: spool), tag: Tag(entry: entry, crc: nil),
                                     weight: size, emit: emitEntry)
            return
        }
        if method != .deflate || encryptsWithZipCrypto {
            try entryPipeline?.drain(emit: emitEntry)
            try pipeline.drain(emit: emitDeflate)
        }
        var entry = try makeEntry(name: name, mode: mode, size: size, date: date, atime: atime, owners: owners, method: method)
        let password = mode.isRegularFileMode ? options.password : nil
        if let password, entry.encryption == .zipCrypto {
            try writeZipCryptoEntry(&entry, name: name, password: password, read: read)
            entries.append(entry)
            return
        }
        if method == .deflate {
            try submitDeflate(entry, name: name, read: read)
            return
        }
        let header = entry.local()
        try write(header)
        let start = position
        let aes = try password.map { try ZipAESEncryptor(password: $0, salt: salt()) }
        if let aes { try write(aes.prefix) }
        entry.crc = try compressEntry(name: name, size: size, method: method, read: read) { chunk in
            try write(aes.map { try $0.encrypt(chunk) } ?? chunk)
        }
        if let aes { try write(aes.finish()) }
        entry.compressedSize = position - start
        try patchLocalHeader(entry, expectedSize: header.count)
        entries.append(entry)
    }

    // 圧縮だけを worker で行い、暗号化・header・本文・CRC は投入順に確定する。
    private func emitEntry(_ tag: Tag, _ result: EncodedEntry?) throws {
        guard let entry = tag.entry, let result else { throw WriterError.invalidState }
        try emitComplete(entry, spool: result.spool, crc: result.crc)
    }

    private func emitEntry(_ tag: Tag, _ result: EncodedEntry?, batchEmit: (Tag, Prefetched?) throws -> Void) throws {
        if tag.attribution != nil {
            try batchEmit(tag, result.map { Prefetched(data: Data(), crc: $0.crc, spool: $0.spool) })
        } else { try emitEntry(tag, result) }
    }

    func emitComplete(_ source: ZipRecords.Entry, spool: OrderedEntrySpool, crc: UInt32,
                      attribution: AdditionAttribution? = nil) throws {
        try Task.checkCancellation()
        let scratch = spool.scratch
        defer { scratch.close() }
        var entry = source
        entry.offset = try checkedAdd(recordBase, position - appendStart)
        entry.crc = crc
        func emit(_ bytes: Data) throws { try write(bytes, attribution: attribution) }
        if entry.encryption == .zipCrypto {
            entry.compressedSize = try checkedAdd(scratch.length, 12)
            var encryptor = ZipCryptoEncryptor(password: options.password!)
            var header = try EncryptionPrimitives.testingRandomBytes?(11) ?? EncryptionPrimitives.random(count: 11)
            header.append(UInt8(truncatingIfNeeded: entry.crc >> 24))
            try emit(entry.local())
            try emit(encryptor.encrypt(header))
            try scratch.forEachChunk { try emit(encryptor.encrypt($0)) }
        } else {
            let aes = entry.encryption == .aes256 ? try ZipAESEncryptor(password: options.password!, salt: salt()) : nil
            entry.compressedSize = try checkedAdd(scratch.length, aes == nil ? 0 : 28)
            try emit(entry.local())
            if let aes { try emit(aes.prefix) }
            try scratch.forEachChunk { chunk in try emit(aes.map { try $0.encrypt(chunk) } ?? chunk) }
            if let aes { try emit(aes.finish()) }
        }
        entries.append(entry)
    }

    private func submitDeflate(_ entry: ZipRecords.Entry, name: String, read: (Int) throws -> Data) throws {
        var remaining = entry.size
        var first = true
        var crc: UInt32 = 0
        var dictionary = Data()
        while remaining > 0 {
            try pipeline.waitForCapacity(emit: emitDeflate)
            let count = Int(min(remaining, UInt64(deflateBlockSize)))
            var input = Data()
            input.reserveCapacity(count)
            while input.count < count {
                try Task.checkCancellation()
                let requested = min(IOChunk.size, count - input.count)
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                input.append(chunk)
                crc = updateCRC(crc, chunk)
            }
            remaining -= UInt64(count)
            if remaining == 0, try !read(1).isEmpty { throw WriterError.sourceChanged(name) }
            let block = DeflateBlock(input: input, dictionary: dictionary, final: remaining == 0)
            dictionary = remaining == 0 ? Data() : DeflateBlock.dictionary(from: input)
            try pipeline.submit(.block(block), tag: Tag(entry: first ? entry : nil, crc: remaining == 0 ? crc : nil),
                                weight: UInt64(input.count), emit: emitDeflate)
            first = false
        }
    }

    // pipeline の結果を順に書く。単一 block の entry は一度に、複数 block の entry は header を先に書いて最後に patch する。
    func emitDeflate(_ tag: Tag, _ result: Prefetched?) throws {
        try Task.checkCancellation()
        if let entry = tag.entry, let crc = tag.crc {
            try emitComplete(entry, data: result!.data, crc: crc)
            return
        }
        if var entry = tag.entry {
            entry.offset = try checkedAdd(recordBase, position - appendStart)
            emittingEntry = entry
            let header = entry.local()
            emittingHeaderSize = header.count
            try write(header)
            emittingStart = position
            emittingAES = try options.password.map { try ZipAESEncryptor(password: $0, salt: salt()) }
            if let emittingAES { try write(emittingAES.prefix) }
        }
        let compressed = result!.data
        for offset in stride(from: compressed.startIndex, to: compressed.endIndex, by: IOChunk.size) {
            let chunk = compressed[offset..<min(offset + IOChunk.size, compressed.endIndex)]
            try write(emittingAES.map { try $0.encrypt(chunk) } ?? chunk)
        }
        if let crc = tag.crc {
            if let emittingAES { try write(emittingAES.finish()) }
            var entry = emittingEntry!
            entry.crc = crc
            entry.compressedSize = position - emittingStart
            try patchLocalHeader(entry, expectedSize: emittingHeaderSize)
            entries.append(entry)
            emittingEntry = nil
            emittingAES = nil
        }
    }

    // 一括追加は方式を決めてから entry を作る。offset はここでの値を emit 時に置き直す。
    func makeEntry(name: String, mode: UInt16, size: UInt64, date: Date, atime: Date?,
                   owners: (UInt32, UInt32)?) throws -> ZipRecords.Entry {
        try makeEntry(name: name, mode: mode, size: size, date: date, atime: atime, owners: owners,
                      method: compression(name: name, mode: mode, size: size))
    }

    private func makeEntry(name: String, mode: UInt16, size: UInt64, date: Date, atime: Date?,
                           owners: (UInt32, UInt32)?, method: CompressionMethod) throws -> ZipRecords.Entry {
        let dos = ZipRecords.dosDate(date)
        var entry = ZipRecords.Entry(name: Data(name.utf8), method: method,
            mtime: try ZipRecords.timestamp(date), atime: try ZipRecords.timestamp(atime ?? date),
            dosTime: dos.time, dosDate: dos.date, mode: mode, owners: owners,
            offset: try checkedAdd(recordBase, position - appendStart), size: size)
        entry.encryption = mode.isRegularFileMode && options.password != nil ? options.zipEncryption : nil
        // ZipCrypto は spool の後に確定したサイズで header を書くので予約しない。他は圧縮後の最大長
        // （各 codec の上限、AES は salt・verifier・認証 tag の 28 byte を足す）が 4 GiB に届けば ZIP64 を予約する。
        if entry.encryption != .zipCrypto {
            var bound = try compressedSizeBound(size: size, method: method)
            if entry.encryption == .aes256 { bound = try checkedAdd(bound, 28) }
            entry.reservedZIP64 = bound >= ZipRecords.limit
        }
        return entry
    }

    // local header の長さを patch 後も保つため、圧縮が膨らむ場合も先に ZIP64 の余白を予約する。
    private func compressedSizeBound(size: UInt64, method: CompressionMethod) throws -> UInt64 {
        switch method {
        case .stored: return size
        case .deflate: return try DeflateBlock.bound(size: size, blockSize: deflateBlockSize)
        case .bzip2:
            // libbz2 の入力長 + 1% + 600 byte の出力上界を使う。
            // https://sourceware.org/bzip2/manual/manual.html §3.5.1
            return try checkedAdd(checkedAdd(size, size / 100), 600)
        case .lzma:
            // range coding の最悪 literal 膨張を覆い、properties header と EOS の余白も予約する。
            let (bound, overflow) = size.multipliedReportingOverflow(by: 16)
            guard !overflow else { throw WriterError.sizeOverflow }
            return try checkedAdd(bound, 1024)
        case .zstd:
            // raw fallback 以下の block と3 byte header、frame header・checksum の上界。
            let blocks = size / UInt64(ZstdFrameEncoder.blockSize) + 1
            return try checkedAdd(checkedAdd(size, blocks * 3), 18)
        case .ppmd:
            // 最大 order の全 suffix で escape しても、各 range 操作の正規化は最大4 byte。
            // literal と EOF、parameter word・flush を含む保守的な上界で ZIP64 の余白を予約する。
            let bytesPerSymbol = UInt64((try options.ppmd8Properties().order + 1) * 4)
            let (bound, overflow) = size.multipliedReportingOverflow(by: bytesPerSymbol)
            guard !overflow else { throw WriterError.sizeOverflow }
            return try checkedAdd(bound, bytesPerSymbol + 6)
        case .xz:
            // encodeXZ は block ごとに入力長の2倍 + 65,536 byte まで。
            // 組み直す block header・check・index record は各1,024 byte、stream 終端も1,024 byteで覆う。
            let blockSize = UInt64(try LZMAWriterConfiguration(options: options).pieceSize)
            let blocks = size / blockSize + (size % blockSize == 0 ? 0 : 1)
            let (overhead, overflow) = blocks.multipliedReportingOverflow(by: 65_536 + 1_024)
            guard !overflow else { throw WriterError.sizeOverflow }
            return try checkedAdd(checkedAdd(checkedAdd(size, size), overhead), 1_024)
        }
    }

    // 完成済みの単一 block は、既存と同じ header/data を一度の write で出力する。
    func emitComplete(_ source: ZipRecords.Entry, data: Data, crc: UInt32, attribution: AdditionAttribution? = nil) throws {
        var entry = source
        entry.offset = try checkedAdd(recordBase, position - appendStart)
        entry.crc = crc
        var payload = data
        if entry.encryption == .aes256 {
            let aes = try ZipAESEncryptor(password: options.password!, salt: salt())
            payload = aes.prefix
            payload.append(try aes.encrypt(data))
            payload.append(try aes.finish())
        }
        entry.compressedSize = UInt64(payload.count)
        var record = entry.local()
        record.append(payload)
        try write(record, attribution: attribution)
        entries.append(entry)
    }

    private func writeZipCryptoEntry(_ entry: inout ZipRecords.Entry, name: String, password: String,
                                     read: (Int) throws -> Data) throws {
        let spool = try ZipCryptoSpool(nextTo: url)
        // spool は作成直後に unlink 済み。どの失敗でも deinit で descriptor を閉じる。
        entry.crc = try compressEntry(name: name, size: entry.size, method: entry.method, read: read, emit: spool.write)
        entry.compressedSize = try checkedAdd(spool.size, 12)
        var encryptor = ZipCryptoEncryptor(password: password)
        var header = try EncryptionPrimitives.testingRandomBytes?(11) ?? EncryptionPrimitives.random(count: 11)
        header.append(UInt8(truncatingIfNeeded: entry.crc >> 24))
        try write(entry.local())
        try write(encryptor.encrypt(header))
        try spool.copy(encryptor: &encryptor, emit: write)
        try spool.close()
    }

    private func compressEntry(name: String, size: UInt64, method: CompressionMethod,
                               read: (Int) throws -> Data, emit: (Data) throws -> Void) throws -> UInt32 {
        try entryCompressor.compress(name: name, size: size, method: method, read: read, emit: emit)
    }

    // 圧縮後に確定した CRC とサイズで local header を書き直す。長さは予約時と同じでなければならない。
    private func patchLocalHeader(_ entry: ZipRecords.Entry, expectedSize: Int) throws {
        let patched = entry.local()
        guard patched.count == expectedSize else { throw WriterError.sizeOverflow }
        try flushOutput()
        try output.seek(toOffset: checkedAdd(appendStart, entry.offset - recordBase))
        try output.write(contentsOf: patched)
        try output.seek(toOffset: position)
    }

    private func compression(name: String, mode: UInt16, size: UInt64) -> CompressionMethod {
        guard size > 0, mode.isRegularFileMode else { return .stored }
        if options.useCompressionHeuristic {
            if Self.compressedExtensions.contains((name as NSString).pathExtension.lowercased()) { return .stored }
        }
        return options.compressionMethod
    }

    // MARK: 出力 buffer

    private func write(_ data: Data) throws {
        try write(data, attribution: nil)
    }

    private func write(_ data: Data, attribution: AdditionAttribution?) throws {
        try Task.checkCancellation()
        let next = try checkedAdd(position, UInt64(data.count))
        if data.count >= IOChunk.size {
            try flushOutput()
            try output.write(contentsOf: data)
        } else {
            if outputBuffer.count + data.count > IOChunk.size { try flushOutput() }
            if outputBuffer.isEmpty { bufferedAttribution = attribution }
            outputBuffer.append(data)
        }
        position = next
    }

    func flushOutput() throws {
        guard !outputBuffer.isEmpty else { return }
        try Task.checkCancellation()
        do { try output.write(contentsOf: outputBuffer) }
        catch {
            // 一括 write の失敗は、まだ書き終えていない最初の項目へ帰属させる。
            if let entry = bufferedAttribution { throw additionFailure(error, index: entry.index, addition: entry.addition) }
            throw error
        }
        outputBuffer.removeAll(keepingCapacity: true)
        bufferedAttribution = nil
    }

    // MARK: 一括追加

    // bzip2 / LZMA / XZ / Zstandard / PPMd の一括追加も有界の項目窓を共有する。
    // deflate は指定の block 幅、stored は既定の block 幅まで先読みする。
    func singleBlockLimit(name: String, mode: UInt16, size: UInt64) -> Int {
        switch options.compressionMethod {
        case .bzip2, .lzma, .xz, .zstd, .ppmd:
            return entryPipeline == nil ? 0 : EntryCompressionConfiguration.inputLimit
        case .stored, .deflate: break
        }
        return compression(name: name, mode: mode, size: size) == .deflate ? deflateBlockSize : DeflateBlock.size
    }

    func waitForCapacity(emit: (Tag, Prefetched?) throws -> Void) throws {
        try entryPipeline?.waitForCapacity { tag, result in try self.emitEntry(tag, result, batchEmit: emit) }
        try pipeline.waitForCapacity(emit: emit)
    }

    // job が nil の項目（directory・symlink）は worker を通さず、tag だけが順に emit される。
    func submit(_ job: FileJob?, attribution: AdditionAttribution, weight: UInt64,
                emit: (Tag, Prefetched?) throws -> Void) throws {
        if let entryPipeline {
            let work = try job.map { file in
                EntryJob(data: nil, file: file, name: attribution.addition.path, method: compression(name: attribution.addition.path, mode: FileMode.regular | 0o644, size: UInt64(file.size)),
                         spool: try OrderedEntrySpool(directory: url.deletingLastPathComponent(), tag: "zip-entry"))
            }
            try entryPipeline.submit(work, tag: Tag(entry: nil, crc: nil, attribution: attribution), weight: weight) {
                tag, result in try self.emitEntry(tag, result, batchEmit: emit)
            }
        } else {
            try pipeline.submit(job.map { .file($0) }, tag: Tag(entry: nil, crc: nil, attribution: attribution), weight: weight, emit: emit)
        }
    }

    func drain(emit: (Tag, Prefetched?) throws -> Void) throws {
        try entryPipeline?.drain { tag, result in try self.emitEntry(tag, result, batchEmit: emit) }
        try pipeline.drain(emit: emit)
    }

    func abandonAndWait() {
        entryCancellation.cancel()
        entryPipeline?.abandonAndWait()
        pipeline.abandonAndWait()
    }

    // 検証済みの前方の項目の write 失敗を、後方の項目の source 失敗より先に報告する。
    func flushOutput(ifBufferedBefore index: Int) throws {
        guard let buffered = bufferedAttribution, buffered.index < index else { return }
        try flushOutput()
    }
}

// deflate の pipeline に入る仕事。項目別 API の block と、一括追加が worker で読む file。
enum ZipWork: Sendable {
    case block(DeflateBlock)
    case file(FileJob)
}

// 一括追加の項目への失敗の帰属。writer は index の比較と ArchiveAdditionError の生成にだけ使う。
struct AdditionAttribution {
    let index: Int
    let addition: ArchiveAddition
}
