import Foundation
import CommonCrypto
import XCTest
@testable import GyoshukuKit

final class ZipAESEncryptorTests: XCTestCase {
    func testCiphertextAndAuthenticationMatchOriginalAtBlockAndCallBoundaries() throws {
        let salt = Data(0..<16)
        let material = try EncryptionPrimitives.zipKeyMaterial(password: EncryptionTestSupport.password, salt: salt)
        for size in [0, 1, 15, 16, 17, 4095, 65537, IOChunk.size + 17] {
            // prefix を落とした Data で、入力の開始 index と alignment に依存しないことも検査する。
            let bytes = Data((0..<(size + 1)).map { UInt8(truncatingIfNeeded: $0 * 29) }).dropFirst()
            for widths in [[Int.max], [0, 1, 7, 8, 15, 16, 17, 4095, 65537]] {
                let reference = OriginalCTR(material: material)
                let encryptor = try ZipAESEncryptor(material: material, salt: salt)
                XCTAssertEqual(encryptor.prefix, salt + material.suffix(2))
                var offset = bytes.startIndex
                var call = 0
                while offset < bytes.endIndex {
                    let count = min(widths[call % widths.count], bytes.endIndex - offset)
                    let chunk = bytes[offset..<(offset + count)]
                    XCTAssertEqual(try encryptor.encrypt(chunk), try reference.encrypt(chunk), "size=\(size), call=\(call)")
                    offset += count
                    call += 1
                }
                XCTAssertEqual(try encryptor.encrypt(Data()), Data())
                XCTAssertEqual(try encryptor.finish(), reference.finish())
                XCTAssertThrowsError(try encryptor.encrypt(Data([1])))
                XCTAssertThrowsError(try encryptor.finish())
            }
        }
    }

    // 最適化前の byte ごとの counter / XOR を固定した独立の参照。製品の CTR 実装に合わせて変更しない。
    private final class OriginalCTR {
        private let key: Data
        private var hmac = CCHmacContext()
        private var counter = [UInt8](repeating: 0, count: 16)
        private var pending = Data()

        init(material: Data) {
            key = Data(material.prefix(32))
            material.subdata(in: 32..<64).withUnsafeBytes {
                CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), $0.baseAddress, $0.count)
            }
        }

        func encrypt(_ input: Data) throws -> Data {
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
                let count = min(IOChunk.size, input.count - offset)
                var counters = Data()
                for _ in 0..<((count + 15) / 16) {
                    for index in counter.indices {
                        counter[index] &+= 1
                        if counter[index] != 0 { break }
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
            result.withUnsafeBytes { CCHmacUpdate(&hmac, $0.baseAddress, $0.count) }
            return result
        }

        func finish() -> Data {
            var digest = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
            digest.withUnsafeMutableBytes { CCHmacFinal(&hmac, $0.baseAddress) }
            return Data(digest.prefix(10))
        }
    }
}
