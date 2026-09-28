import Foundation
private import CommonCrypto

/// WinZip AES-256: 圧縮 chunk ごとに CTR 暗号化し、暗号文だけを HMAC へ加える。
final class ZipAESEncryptor {
    let prefix: Data
    private let key: Data
    private var hmac = CCHmacContext()
    private var counter = [UInt8](repeating: 0, count: 16)
    private var pending = Data()
    private var finished = false

    convenience init(password: String, salt: Data? = nil) throws {
        let salt = try salt ?? EncryptionPrimitives.random(count: 16)
        precondition(salt.count == 16)
        let material = try EncryptionPrimitives.zipKeyMaterial(password: password, salt: salt)
        try self.init(material: material, salt: salt)
    }

    init(material: Data, salt: Data) throws {
        guard material.count == 66, salt.count == 16 else { throw WriterError.invalidOption("ZIP AES material") }
        key = Data(material.prefix(32))
        prefix = salt + material.suffix(2)
        material.subdata(in: 32..<64).withUnsafeBytes {
            CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), $0.baseAddress, Int($0.count))
        }
    }

    func encrypt(_ input: Data) throws -> Data {
        guard !finished else { throw WriterError.invalidState }
        guard !input.isEmpty else { return Data() }
        var result = input
        var offset = 0
        if !pending.isEmpty {
            let count = min(input.count, pending.count)
            result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for index in 0..<count { output[index] ^= pending[pending.startIndex + index] }
            }
            pending = Data(pending.dropFirst(count))
            offset = count
        }
        while offset < input.count {
            try Task.checkCancellation()
            let count = min(IOChunk.size, input.count - offset)
            let blocks = (count + 15) / 16
            var counters = Data()
            counters.reserveCapacity(blocks * 16)
            for _ in 0..<blocks {
                // WinZip は 128 bit little-endian、最初の counter は 1。
                for index in counter.indices {
                    counter[index] &+= 1
                    if counter[index] != 0 { break }
                    if index == 15 { throw WriterError.sizeOverflow }
                }
                counters.append(contentsOf: counter)
            }
            let stream = try EncryptionPrimitives.ecb(counters, key: key)
            result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                stream.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    for index in 0..<count { output[offset + index] ^= bytes[index] }
                }
            }
            pending = Data(stream.dropFirst(count))
            offset += count
        }
        result.withUnsafeBytes { CCHmacUpdate(&hmac, $0.baseAddress, Int($0.count)) }
        return result
    }

    func finish() throws -> Data {
        guard !finished else { throw WriterError.invalidState }
        finished = true
        var digest = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { CCHmacFinal(&hmac, $0.baseAddress) }
        return Data(digest.prefix(10))
    }
}
