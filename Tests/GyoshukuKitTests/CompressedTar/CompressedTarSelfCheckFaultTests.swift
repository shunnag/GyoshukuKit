import Foundation
import Darwin
import Synchronization
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarSelfCheckFaultTests: XCTestCase {
    func testSelfCheckFaultsAndK5Separation() throws {
        for format in CompressedTarTestSupport.formats {
            let root = try TestSupport.directory("compressed-tar-fault-\(format)")
            let source = try CompressedTarTestSupport.fixture(root, format)
            let original = try Data(contentsOf: source), originalID = try ZipEditTestSupport.info(source).st_ino
            let faults: [CompressedTarUpdater.Fault] = format == .tarGzip
                ? [.trailerCRC, .missingDictionaryProtection, .flipEncodedByte, .shiftLedger]
                : format == .tarBzip2 ? [.dropBzip2Stream, .flipEncodedByte, .shiftLedger]
                : [.xzIndexLength, .dropXZBlock, .flipEncodedByte, .shiftLedger]
            for fault in faults {
                let output = root.appendingPathComponent("bad-\(fault)")
                let editor = try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: format)
                try editor.rename(entryAt: 0, to: "large-C")
                let scratchFD = Mutex<Int32>(-1)
                XCTAssertThrowsError(try ScratchFile.$testingCreated.withValue({ fd in scratchFD.withLock { $0 = fd } }) {
                    try CompressedTarUpdater.$testingFault.withValue(fault) { try editor.commit() }
                }) {
                    guard case TarUpdaterError.outputVerificationFailed = $0 else { return XCTFail("\(format) \(fault): \($0)") }
                }
                let fd = scratchFD.withLock { $0 }
                XCTAssertGreaterThanOrEqual(fd, 0)
                XCTAssertEqual(fcntl(fd, F_GETFD), -1)
                XCTAssertEqual(errno, EBADF)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertThrowsError(try editor.commit())
                XCTAssertEqual(try Data(contentsOf: source), original)
                XCTAssertEqual(try ZipEditTestSupport.info(source).st_ino, originalID)
            }
            let oracle = root.appendingPathComponent("expected")
            let plain = try TarUpdater.open(url: root.appendingPathComponent("input.tar"), output: oracle)
            try plain.rename(entryAt: 0, to: "large-C"); try plain.commit()
            for fault in faults + [.flipReusedByte] where fault != .shiftLedger {
                let reader = try CompressedTarTestSupport.open(source), base = reader.tarEditingSnapshot()!
                let output = root.appendingPathComponent("k5-\(fault)")
                let editor = try CompressedTarUpdater.open(reader: reader, output: output, format: format)
                try editor.rename(entryAt: 0, to: "large-C")
                let result = try CompressedTarUpdater.$testingSkipsSelfCheck.withValue(true) {
                    try CompressedTarUpdater.$testingFault.withValue(fault) { try editor.commit(progress: nil) }
                }
                do {
                    let verified = try CompressedTarTestSupport.spliceVerifiedReader(output, base: base, result: result)
                    XCTAssertTrue(fault == .dropBzip2Stream || fault == .dropXZBlock, "K5 accepted \(fault)")
                    let image = verified.tarEditingSnapshot()!.image
                    let wanted = try FileByteSource(url: oracle)
                    if image.length == wanted.length {
                        XCTAssertNotEqual(try TarLayout.bytes(image, at: 0, count: Int(image.length)), try Data(contentsOf: oracle))
                    } else { XCTAssertNotEqual(image.length, wanted.length) }
                } catch let error as TarSpliceVerificationError {
                    switch fault {
                    case .flipReusedByte: XCTAssertEqual(error.reason, .reusedBytesDiffer)
                    case .trailerCRC: XCTAssertEqual(error.reason, .checksumMismatch)
                    case .missingDictionaryProtection: XCTAssertEqual(error.reason, .dictionaryMismatch)
                    case .xzIndexLength: XCTAssertEqual(error.reason, .framingMismatch)
                    default: break
                    }
                } catch {
                    XCTAssertTrue(fault == .dropBzip2Stream || fault == .dropXZBlock, "\(fault): \(error)")
                    XCTAssertThrowsError(try CompressedTarTestSupport.open(output))
                }
            }
            // 出力の運ぶ部分の反転だけは通常の自己照合も通り、K5 が拒否する。
            let reader = try CompressedTarTestSupport.open(source), base = reader.tarEditingSnapshot()!
            let output = root.appendingPathComponent("reused-fault")
            let editor = try CompressedTarUpdater.open(reader: reader, output: output, format: format)
            try editor.rename(entryAt: 0, to: "large-C")
            let result = try CompressedTarUpdater.$testingFault.withValue(.flipReusedByte) { try editor.commit(progress: nil) }
            XCTAssertThrowsError(try CompressedTarTestSupport.spliceVerifiedReader(output, base: base, result: result)) {
                XCTAssertEqual(($0 as? TarSpliceVerificationError)?.reason, .reusedBytesDiffer)
            }
        }
    }
    func testV4SeesSameInodeSameSizeRestoredMtimeChanges() throws {
        for format in CompressedTarTestSupport.formats {
            let root = try TestSupport.directory("compressed-tar-v4-\(format)")
            let source = try CompressedTarTestSupport.fixture(root, format)
            try FileManager.default.setAttributes([.modificationDate: TestSupport.date], ofItemAtPath: source.path)
            let reader = try CompressedTarTestSupport.open(source), base = reader.tarEditingSnapshot()!
            let output = root.appendingPathComponent("bad")
            let editor = try CompressedTarUpdater.open(reader: reader, output: output, format: format)
            try editor.add(data: Data([1]), as: "added")
            let chunk = try XCTUnwrap(base.chunkMap?.chunks.first { $0.imageRange.upperBound - $0.imageRange.lowerBound > 100000 })
            let handle = try FileHandle(forUpdating: source)
            let offset = chunk.compressedRange.lowerBound + (chunk.compressedRange.upperBound - chunk.compressedRange.lowerBound) / 2
            var byte = try SegmentedArchiveOutput.read(handle.fileDescriptor, at: offset, count: 1); byte[0] ^= 1
            try byte.withUnsafeBytes { try ZipCopyEngine.pwrite(handle.fileDescriptor, bytes: $0, at: offset) }
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: TestSupport.date], ofItemAtPath: source.path)
            XCTAssertTrue(base.archiveIsUnchanged())
            let changed = try Data(contentsOf: source)
            XCTAssertThrowsError(try editor.commit()) { XCTAssertEqual($0 as? UpdaterError, .sourceChanged) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), changed)
        }
    }
}
