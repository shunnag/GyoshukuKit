import Foundation
private import CommonCrypto

/// 7z AES-256-CBC。CommonCrypto が block の端数を保持し、最後だけ明示的に zero pad する。
final class SevenZipAESEncryptor {
    @TaskLocal static var testingIV: (@Sendable () -> Data)?
    /// properties は設定 2 byte + IV 16 byte。header 長の見積りで実物の代わりに使う。
    static let propertiesLength = 18
    let properties: Data
    private var cryptor: CCCryptorRef?
    private var remainder = 0
    private var finished = false

    init(key: Data) throws {
        let iv = try Self.testingIV?() ?? EncryptionPrimitives.random(count: 16)
        guard iv.count == 16 else { throw WriterError.invalidOption("IV") }
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

extension SevenZipAESEncryptor {
    /// salt なしの KDF は書庫内で共通。鍵は最初の make で一度だけ導出し、folder / header ごとに IV の独立した
    /// encryptor を作る。password が無ければ nil。SevenZipWriter と SevenZipUpdater が共有する。
    struct Factory {
        private let password: String?
        private var key: Data?

        init(password: String?) { self.password = password }

        mutating func make() throws -> SevenZipAESEncryptor? {
            guard let password else { return nil }
            if key == nil { key = try EncryptionPrimitives.sevenZipKey(password: password) }
            return try SevenZipAESEncryptor(key: key!)
        }
    }
}
