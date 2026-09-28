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
        try zipKeyMaterial(passwordBytes: Data(password.utf8), salt: salt)
    }

    static func zipKeyMaterial(passwordBytes password: Data, salt: Data) throws -> Data {
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
