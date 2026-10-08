import Foundation
private import Darwin

enum SingleStreamWriter {
    /// 読取後・圧縮前。取消しと出力の競合を実際の公開 API 経由で検証する。
    @TaskLocal static var testingDidRead: (@Sendable (UInt64) throws -> Void)?

    static func compress(file source: URL, to output: URL, format: SingleStreamFormat,
                         options: WriterOptions, progress: Progress?) throws {
        try FileRead.validateFileURL(source)
        try FileRead.validateFileURL(output)
        try options.validate(for: format.archiveFormat)
        try checkCancellation(progress)
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw WriterError.io(operation: "lstat source", code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WriterError.unsupportedFileType(source.path) }
        guard info.st_size >= 0 else { throw WriterError.sourceChanged(source.path) }
        let signature = DiskSignature(info)
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WriterError.io(operation: "open source", code: errno) }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw WriterError.io(operation: "fstat source", code: errno) }
        guard signature.matches(opened) else { throw WriterError.sourceChanged(source.path) }

        var existing = stat()
        guard lstat(output.path, &existing) != 0 else { throw WriterError.io(operation: "create", code: EEXIST) }
        guard errno == ENOENT else { throw WriterError.io(operation: "lstat output", code: errno) }
        let compressor = try StreamCompressor.make(format: format.archiveFormat, options: options)
        defer { compressor.abandon() }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".gyoshuku-stream-\(UUID().uuidString).tmp")
        let destination = try createTemporary(temporary)
        let destinationFD = destination.fileDescriptor
        var ownedURL = temporary
        var closedOwner: ArchiveOwnedFile?
        var completed = false
        defer {
            if !completed {
                if let closedOwner { closedOwner.remove() }
                else { ArchiveOwnedFile.remove(url: ownedURL, descriptor: destinationFD) }
            }
            try? destination.close()
        }
        progress?.totalUnitCount = Int64(info.st_size)
        progress?.completedUnitCount = 0
        let emit: (Data) throws -> Void = { data in
            try checkCancellation(progress)
            try destination.write(contentsOf: data)
        }
        var remaining = UInt64(info.st_size)
        while remaining > 0 {
            try checkCancellation(progress)
            let input = try FileRead.readChunk(fd, upTo: Int(min(UInt64(IOChunk.size), remaining)))
            guard !input.isEmpty else { throw WriterError.sourceChanged(source.path) }
            remaining -= UInt64(input.count)
            progress?.completedUnitCount += Int64(input.count)
            try testingDidRead?(UInt64(info.st_size) - remaining)
            try checkCancellation(progress)
            try compressor.write(input, finish: false, emit: emit)
        }
        guard try FileRead.readChunk(fd, upTo: 1).isEmpty,
              fstat(fd, &opened) == 0, signature.matches(opened),
              lstat(source.path, &opened) == 0, signature.matches(opened) else {
            throw WriterError.sourceChanged(source.path)
        }
        try compressor.write(Data(), finish: true, emit: emit)
        try destination.synchronize()
        try checkCancellation(progress)
        guard ArchiveOwnedFile.matches(url: temporary, descriptor: destination.fileDescriptor) else {
            throw WriterError.sourceChanged(temporary.path)
        }
        // RENAME_EXCL は存在検査と公開を一操作にする。読取中に現れた出力も上書きしない。
        guard renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            throw WriterError.io(operation: "rename output", code: errno)
        }
        ownedURL = output
        try checkCancellation(progress)
        let ownership = try ArchiveOwnedFile(url: output, descriptor: destinationFD)
        closedOwner = ownership
        try destination.close()
        try checkCancellation(progress)
        completed = true
    }

    private static func createTemporary(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw WriterError.io(operation: "create temporary", code: errno) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func checkCancellation(_ progress: Progress?) throws {
        try Task.checkCancellation()
        if progress?.isCancelled == true { throw CancellationError() }
    }
}
