import Foundation
private import Darwin

enum FileRead {
    /// file: の URL で NUL を含まないことを検証する。writer / updater は path を開く前に同じ規則で断る。
    static func validateFileURL(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw WriterError.invalidPath(url.absoluteString) }
    }

    // FileHandle の autorelease 済み Data を長い同期ループに溜めない。
    static func readChunk(_ fd: Int32, upTo count: Int) throws -> Data {
        var data = Data(count: count)
        let actual = try data.withUnsafeMutableBytes { bytes in
            while true {
                let actual = Darwin.read(fd, bytes.baseAddress, bytes.count)
                if actual >= 0 { return actual }
                let code = errno
                guard code == EINTR else { throw WriterError.io(operation: "read", code: code) }
            }
        }
        data.count = actual
        return data
    }

    /// pread を EINTR で再試行し、読めた byte 数を返す。0 は EOF。失敗は operation を付けた WriterError.io。
    static func pread(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64,
                      operation: String) throws -> Int {
        while true {
            let actual = Darwin.pread(fd, buffer.baseAddress!, buffer.count, off_t(offset))
            if actual >= 0 { return actual }
            let code = errno
            guard code == EINTR else { throw WriterError.io(operation: operation, code: code) }
        }
    }

    /// buffer を満たすまで pread を繰り返す。途中で EOF になれば shortRead の error を投げる。
    static func preadExactly(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64,
                             operation: String, shortRead: () -> any Error) throws {
        var filled = 0
        while filled < buffer.count {
            let actual = try pread(fd, into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]),
                                   at: offset + UInt64(filled), operation: operation)
            guard actual > 0 else { throw shortRead() }
            filled += actual
        }
    }
}
