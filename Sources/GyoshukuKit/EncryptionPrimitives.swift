import Foundation
private import CommonCrypto
private import Security
private import CryptoKit

// 暗号 primitive と OS の乱数境界。外部依存や独自 AES 実装を持たない。
enum EncryptionPrimitives {
    static func random(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status: OSStatus = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, Int(count), $0.baseAddress!)
        }
        guard status == OSStatus(errSecSuccess) else { throw WriterError.io(operation: "random", code: Int32(status)) }
        return bytes
    }

    static func zipKeyMaterial(password: String, salt: Data) throws -> Data {
        let password = Data(password.utf8)
        var result = Data(count: 66)
        let status: Int32 = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int(password.count),
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), Int(salt.count),
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(1_000),
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), Int(66))
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw WriterError.io(operation: "derive ZIP key", code: status) }
        return result
    }

    static func sevenZipKey(password: String) throws -> Data {
        var passwordBytes = Data()
        for unit in password.utf16 { passwordBytes.le(unit) }
        let recordSize = passwordBytes.count + 8
        // SHA256 呼出し回数を抑えつつ、パスワード長以外は固定量のメモリに収める。
        let recordsPerChunk = max(1, min(4_096, (512 * 1024) / recordSize))
        var chunk = Data(count: recordSize * recordsPerChunk)
        for record in 0..<recordsPerChunk {
            chunk.replaceSubrange((record * recordSize)..<(record * recordSize + passwordBytes.count),
                                  with: passwordBytes)
        }
        var sha = SHA256()
        for start in stride(from: 0, to: 1 << 19, by: recordsPerChunk) {
            try Task.checkCancellation()
            let count = min(recordsPerChunk, (1 << 19) - start)
            chunk.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for record in 0..<count {
                    let base = record * recordSize + passwordBytes.count
                    let counter = UInt64(start + record)
                    for index in 0..<8 { bytes[base + index] = UInt8(truncatingIfNeeded: counter >> (8 * index)) }
                }
            }
            sha.update(data: chunk.prefix(count * recordSize))
        }
        return Data(sha.finalize())
    }

    // ECB は WinZip の little-endian CTR counter block の暗号化にだけ使う。
    static func ecb(_ blocks: Data, key: Data) throws -> Data {
        var result = Data(count: blocks.count)
        var moved: Int = 0 // SDK の size_t * は Swift では UnsafeMutablePointer<Int>。
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            blocks.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { output in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, Int(key.count), nil, input.baseAddress, Int(blocks.count),
                            output.baseAddress, Int(output.count), &moved)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved == Int(blocks.count) else {
            throw WriterError.io(operation: "AES ECB",
                                 code: status == CCCryptorStatus(kCCSuccess) ? Int32(kCCParamError) : status)
        }
        return result
    }
}

/// WinZip AES-256: 圧縮 chunk ごとに CTR 暗号化し、暗号文だけを HMAC へ加える。
final class ZipAESEncryptor {
    let prefix: Data
    private let key: Data
    private var hmac = CCHmacContext()
    private var counter = [UInt8](repeating: 0, count: 16)
    private var pending = Data()
    private var finished = false

    init(password: String) throws {
        let salt = try EncryptionPrimitives.random(count: 16)
        let material = try EncryptionPrimitives.zipKeyMaterial(password: password, salt: salt)
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
            let count = min(256 * 1024, input.count - offset)
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

/// 7z AES-256-CBC。CommonCrypto が block の端数を保持し、最後だけ明示的に zero pad する。
final class SevenZipAESEncryptor {
    let properties: Data
    private var cryptor: CCCryptorRef?
    private var remainder = 0
    private var finished = false

    init(key: Data) throws {
        let iv = try EncryptionPrimitives.random(count: 16)
        // cycles=19、salt なし、IV=16 byte。saltSize=0 の上位 nibble は 0。
        properties = Data([0x53, 0x0F]) + iv
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                                keyBytes.baseAddress, Int(key.count), ivBytes.baseAddress, &cryptor)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw WriterError.io(operation: "create AES CBC", code: status) }
    }

    deinit { if let cryptor { _ = CCCryptorRelease(cryptor) } }

    func encrypt(_ input: Data) throws -> Data {
        guard !finished, let cryptor else { throw WriterError.invalidState }
        guard !input.isEmpty else { return Data() }
        var result = Data(count: input.count + 16)
        var moved: Int = 0
        let status: CCCryptorStatus = input.withUnsafeBytes { bytes in
            result.withUnsafeMutableBytes { output in
                CCCryptorUpdate(cryptor, bytes.baseAddress, Int(bytes.count), output.baseAddress, Int(output.count), &moved)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw WriterError.io(operation: "AES CBC update", code: status) }
        remainder = (remainder + input.count % 16) % 16
        result.removeSubrange(moved..<result.count)
        return result
    }

    func finish() throws -> Data {
        guard !finished, let cryptor else { throw WriterError.invalidState }
        let padding = remainder == 0 ? Data() : Data(count: 16 - remainder)
        var result = try encrypt(padding)
        finished = true
        var tail = Data(count: 16)
        var moved: Int = 0
        let status: CCCryptorStatus = tail.withUnsafeMutableBytes {
            CCCryptorFinal(cryptor, $0.baseAddress, Int($0.count), &moved)
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw WriterError.io(operation: "AES CBC finish", code: status) }
        result.append(tail.prefix(moved))
        return result
    }
}
