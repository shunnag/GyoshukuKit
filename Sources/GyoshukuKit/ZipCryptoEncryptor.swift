import Foundation
private import Darwin

// PKWARE traditional encryption。鍵の更新には暗号化前の byte と未補数の CRC を使う。
struct ZipCryptoEncryptor {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
        return crc
    }

    init(password: String) { for byte in password.utf8 { update(byte) } }

    mutating func encrypt(_ input: Data) -> Data {
        var result = input
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in 0..<bytes.count {
                let plain = bytes[index]
                let temporary = key2 | 2
                bytes[index] ^= UInt8(truncatingIfNeeded: (temporary &* (temporary ^ 1)) >> 8)
                update(plain)
            }
        }
        return result
    }

    private mutating func update(_ byte: UInt8) {
        key0 = (key0 >> 8) ^ Self.table[Int(UInt8(truncatingIfNeeded: key0) ^ byte)]
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = (key2 >> 8) ^ Self.table[Int(UInt8(truncatingIfNeeded: key2) ^ UInt8(truncatingIfNeeded: key1 >> 24))]
    }
}

// CRC が確定するまで圧縮結果だけを出力と同じ directory に置く。mkstemp は mode 0600。
// ZIP bit 3 / descriptor を使わず、全ての終了経路で一時ファイルを削除する。
final class ZipCryptoSpool {
    private var descriptor: Int32
    private let path: String
    private var removed = false
    private(set) var size: UInt64 = 0

    init(nextTo output: URL) throws {
        var template = Array(output.deletingLastPathComponent()
            .appendingPathComponent(".gyoshuku-zipcrypto-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw WriterError.io(operation: "create ZipCrypto spool", code: errno) }
        descriptor = fd
        path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1 {
            let code = errno
            Darwin.close(descriptor)
            descriptor = -1
            unlink(path)
            throw WriterError.io(operation: "configure ZipCrypto spool", code: code)
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        if !removed { unlink(path) }
    }

    func write(_ data: Data) throws {
        let next = try checkedAdd(size, UInt64(data.count))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let actual = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if actual < 0, errno == EINTR { continue }
                guard actual > 0 else { throw WriterError.io(operation: "write ZipCrypto spool", code: actual == 0 ? EIO : errno) }
                offset += actual
            }
        }
        size = next
    }

    func copy(encryptor: inout ZipCryptoEncryptor, emit: (Data) throws -> Void) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw WriterError.io(operation: "seek ZipCrypto spool", code: errno) }
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            var chunk = Data(count: Int(min(256 * 1024, remaining)))
            let actual = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if actual < 0, errno == EINTR { continue }
            guard actual > 0 else { throw WriterError.io(operation: "read ZipCrypto spool", code: actual == 0 ? EIO : errno) }
            chunk.removeSubrange(actual..<chunk.count)
            try emit(encryptor.encrypt(chunk))
            remaining -= UInt64(actual)
        }
    }

    func remove() throws {
        guard unlink(path) == 0 else { throw WriterError.io(operation: "remove ZipCrypto spool", code: errno) }
        removed = true
        let fd = descriptor
        descriptor = -1
        guard Darwin.close(fd) == 0 else { throw WriterError.io(operation: "close ZipCrypto spool", code: errno) }
    }
}
