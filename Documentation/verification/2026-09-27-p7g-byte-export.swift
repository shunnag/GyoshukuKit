import Foundation
import XCTest
@testable import GyoshukuKit
final class P7BaselineExportTests: XCTestCase {
    func testExport() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GYOSHUKU_P7_EXPORT"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ArchiveUpdater.$testingRandomBytes.withValue({ Data(repeating: 17, count: $0) }) {
        try SevenZipAESEncryptor.$testingIV.withValue({ Data(repeating: 23, count: 16) }) {
            for format in AdditionProgressTestSupport.formats {
                for encryption in 0..<(format == .zip ? 3 : format == .sevenZip ? 2 : 1) {
                    let options = WriterOptions(password: encryption == 0 ? nil : "password",
                        zipEncryption: encryption == 2 ? .zipCrypto : .aes256,
                        encryptsSevenZipHeaders: format == .sevenZip && encryption == 1, compressionThreads: 8)
                    let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(format)-\(encryption)"),
                        format: format, options: options, deflateBlockSize: 65536,
                        zipSalt: { Data(repeating: 19, count: 16) }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
                    try ParallelDeflateBzip2WriterTests.addProgressFixture(to: writer)
                    try writer.finish()
                }
            }
        } }
    }
}
