import Foundation
private import Darwin

// 名前の検証・衝突検査・ディスク探索は ArchiveWriter と共有し、ここでは tar だけを扱う。
final class TarWriter {
    private let output: FileHandle
    private let url: URL
    private let compressor: (any TarCompressor)?
    private var position: UInt64 = 0
    var recordsMemberLayout = false
    var observesWrites = false
    var willWrite: ((Int) throws -> Void)?
    private(set) var memberLayouts: [(groupStart: UInt64, dataStart: UInt64, end: UInt64)] = []
    private var finished = false
    private var aborted = false
    private struct FileID: Hashable { let device: Int64; let inode: UInt64 }
    private var hardLinks: [FileID: (path: String, signature: [Int64])] = [:]

    init(output: FileHandle, url: URL, compressor: (any TarCompressor)?,
         startPosition: UInt64 = 0) {
        self.output = output
        self.url = url
        self.compressor = compressor
        self.position = startPosition
    }

    deinit { abort() }

    var pendingInputBytes: UInt64 { compressor?.pendingInputBytes ?? 0 }

    func finishAdditions(didEmit: ((UInt64) throws -> Void)?) throws {
        try compressor?.finishAdditions(didEmit: didEmit, emit: emit)
    }

    func hardLinkTarget(device: Int64, inode: UInt64, signature: [Int64]) throws -> String? {
        guard let previous = hardLinks[FileID(device: device, inode: inode)] else { return nil }
        guard previous.signature == signature else { throw WriterError.sourceChanged(previous.path) }
        return previous.path
    }

    func rememberHardLink(device: Int64, inode: UInt64, signature: [Int64], path: String) {
        hardLinks[FileID(device: device, inode: inode)] = (path, signature)
    }

    func add(
        name: String, mode: UInt16, size: UInt64, date: Date, owners: (UInt32, UInt32)?,
        hardLink: String?, read: (Int) throws -> Data
    ) throws {
        try Task.checkCancellation()
        var entry = TarRecords.Entry(name: Data(name.utf8), mode: mode, size: size,
                                     mtime: try TarRecords.timestamp(date), uid: owners?.0 ?? 0, gid: owners?.1 ?? 0)
        if mode & 0xF000 == 0x4000 {
            entry.type = 0x35
            entry.size = 0
        } else if mode & 0xF000 == 0xA000 {
            // link は payload ではない。readlink 由来の byte をそのまま linkname / pax に置く。
            guard size <= UInt64(PATH_MAX) else { throw WriterError.invalidPath(name) }
            entry.link = try read(Int(size))
            guard entry.link.count == Int(size), !entry.link.contains(0), try read(1).isEmpty else {
                throw WriterError.sourceChanged(name)
            }
            entry.type = 0x32
            entry.size = 0
        } else if let hardLink {
            entry.type = 0x31
            entry.link = Data(hardLink.utf8)
            entry.size = 0
        }
        let headers = try entry.headers()
        let bodyLength = entry.type == 0x30 ? try checkedAdd(size, UInt64(TarRecords.padding(size))) : 0
        let groupStart = position
        let dataStart = try checkedAdd(position, UInt64(headers.count))
        _ = try checkedAdd(dataStart, bodyLength)
        compressor?.beginMember(headerLength: UInt64(headers.count), bodyLength: bodyLength)
        try write(headers)
        if entry.type == 0x30 {
            var remaining = size
            while remaining > 0 {
                try Task.checkCancellation()
                let requested = Int(min(UInt64(IOChunk.size), remaining))
                let chunk = try read(requested)
                guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
                try write(chunk)
                remaining -= UInt64(chunk.count)
            }
            guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
            try write(Data(count: TarRecords.padding(size)))
        }
        if recordsMemberLayout { memberLayouts.append((groupStart, dataStart, position)) }
    }

    func endMembers() throws -> UInt64 {
        guard compressor == nil, !finished, !aborted else { throw WriterError.invalidState }
        try Task.checkCancellation()
        finished = true
        return position
    }

    func finish() throws {
        try Task.checkCancellation()
        // 終端の二 block を必ず置き、その後を従来の blocking factor 20 までゼロで埋める。
        compressor?.beginEndOfArchive()
        try write(Data(count: 2 * TarRecords.blockSize))
        let padding = (UInt64(TarRecords.recordSize) - position % UInt64(TarRecords.recordSize)) % UInt64(TarRecords.recordSize)
        try write(Data(count: Int(padding)))
        if let compressor { try compressor.write(Data(), finish: true, emit: emit) }
        try Task.checkCancellation()
        try output.synchronize()
        try Task.checkCancellation()
        try output.close()
        finished = true
    }

    func abort() {
        guard !finished, !aborted else { return }
        aborted = true
        compressor?.abandon()
        // tar は途中まででも読めるため、失敗時には終端を省くだけでは不十分。
        // 別名の hard link も無効化し、出力先が置換されていれば別人のファイルは消さない。
        ArchiveOwnedFile.remove(url: url, descriptor: output.fileDescriptor)
        try? output.truncate(atOffset: 0)
    }

    private func write(_ data: Data) throws {
        try Task.checkCancellation()
        let next = try checkedAdd(position, UInt64(data.count))
        if let compressor { try compressor.write(data, finish: false, emit: emit) } else { try emit(data) }
        position = next
    }

    private func emit(_ data: Data) throws {
        try Task.checkCancellation()
        try willWrite?(data.count)
        try output.write(contentsOf: data)
        if observesWrites { ZipCopyEngine.writeObserver?(position, data.count) }
    }
}
