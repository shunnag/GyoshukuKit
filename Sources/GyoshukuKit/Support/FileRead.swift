import Foundation
private import Darwin

enum FileRead {
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
}
