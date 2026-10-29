import Foundation
private import CommonCrypto

/// WinZip AES-256: 圧縮 chunk ごとに CTR 暗号化し、暗号文だけを HMAC へ加える。
final class ZipAESEncryptor {
    // salt は投入側で確保し、PBKDF2 だけを圧縮 worker へ渡す。
    struct KeyInput: Sendable {
        let password: Data
        let salt: Data

        func derive() throws -> KeyMaterial {
            KeyMaterial(bytes: try EncryptionPrimitives.zipKeyMaterial(passwordBytes: password, salt: salt), salt: salt)
        }
    }

    struct KeyMaterial: Sendable {
        let bytes: Data
        let salt: Data

        func encryptor() throws -> ZipAESEncryptor { try ZipAESEncryptor(material: bytes, salt: salt) }
    }

    let prefix: Data
    private let key: Data
    private var hmac = CCHmacContext()
    private var counterLow: UInt64 = 0
    private var counterHigh: UInt64 = 0
    private var pending = [UInt8](repeating: 0, count: 16)
    private var pendingOffset = 16
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
        if pendingOffset < 16 {
            let count = min(input.count, 16 - pendingOffset)
            result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                pending.withUnsafeBytes { bytes in
                    Self.xor(output, offset: 0, bytes, start: pendingOffset, count: count)
                }
            }
            pendingOffset += count
            offset = count
        }
        while offset < input.count {
            try Task.checkCancellation()
            let count = min(IOChunk.size, input.count - offset)
            let blocks = (count + 15) / 16
            var counters = Data(count: blocks * 16)
            try counters.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for block in 0..<blocks {
                    // WinZip は 128 bit little-endian、最初の counter は 1。
                    counterLow &+= 1
                    if counterLow == 0 {
                        counterHigh &+= 1
                        if counterHigh == 0 { throw WriterError.sizeOverflow }
                    }
                    bytes.storeBytes(of: counterLow.littleEndian, toByteOffset: block * 16, as: UInt64.self)
                    bytes.storeBytes(of: counterHigh.littleEndian, toByteOffset: block * 16 + 8, as: UInt64.self)
                }
            }
            let stream = try EncryptionPrimitives.ecb(counters, key: key)
            result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                stream.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    Self.xor(output, offset: offset, bytes, start: 0, count: count)
                }
            }
            pendingOffset = count % 16
            if pendingOffset == 0 { pendingOffset = 16 }
            else {
                pending.withUnsafeMutableBytes { destination in
                    stream.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[(bytes.count - 16)...]))
                    }
                }
            }
            offset += count
        }
        result.withUnsafeBytes { CCHmacUpdate(&hmac, $0.baseAddress, Int($0.count)) }
        return result
    }

    private static func xor(_ output: UnsafeMutableRawBufferPointer, offset: Int,
                            _ stream: UnsafeRawBufferPointer, start: Int, count: Int) {
        var index = 0
        while index + 8 <= count {
            let word = output.loadUnaligned(fromByteOffset: offset + index, as: UInt64.self)
                ^ stream.loadUnaligned(fromByteOffset: start + index, as: UInt64.self)
            output.storeBytes(of: word, toByteOffset: offset + index, as: UInt64.self)
            index += 8
        }
        while index < count {
            output[offset + index] ^= stream[start + index]
            index += 1
        }
    }

    func finish() throws -> Data {
        guard !finished else { throw WriterError.invalidState }
        finished = true
        var digest = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { CCHmacFinal(&hmac, $0.baseAddress) }
        return Data(digest.prefix(10))
    }
}
