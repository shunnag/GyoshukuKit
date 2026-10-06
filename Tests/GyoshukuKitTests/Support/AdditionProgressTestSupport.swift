import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

enum AdditionProgressTestSupport {
    static let mib = 1024 * 1024
    static let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]
    static let options = WriterOptions(bzip2Level: 1, useCompressionHeuristic: false, compressionThreads: 8)

    static func file(_ root: URL, _ name: String, size: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x61, count: size).write(to: url)
        try timestamp(url)
        return url
    }

    static func timestamp(_ url: URL) throws {
        var times = [timeval(tv_sec: 1_700_000_001, tv_usec: 0), timeval(tv_sec: 1_700_000_001, tv_usec: 0)]
        guard lutimes(url.path, &times) == 0 else { throw WriterError.io(operation: "lutimes", code: errno) }
    }

    static func source(_ root: URL, format: GyoshukuKit.ArchiveFormat, size: Int = 1) throws -> URL {
        let url = root.appendingPathComponent("source." + format.testFileExtension)
        let writer = try ArchiveWriter.create(url: url, format: format, options: options)
        try writer.add(data: Data(repeating: 0x62, count: size), as: "base", modificationDate: TestSupport.date)
        try writer.finish()
        return url
    }

    static func editor(_ source: URL, output: URL, format: GyoshukuKit.ArchiveFormat,
                       options: WriterOptions = options, rewrite: Bool = false) throws -> any ArchiveEditing {
        if rewrite { return try ArchiveRewriter.open(url: source, output: output, format: format, options: options) }
        switch format {
        case .zip: return try ArchiveUpdater.open(url: source, output: output, options: options)
        case .tar: return try TarUpdater.open(url: source, output: output, options: options)
        case .tarGzip, .tarBzip2, .tarXZ:
            return try CompressedTarUpdater.open(reader: CompressedTarTestSupport.open(source), output: output, format: format, options: options)
        case .tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress:
            return try ArchiveRewriter.open(url: source, output: output, format: format, options: options)
        case .sevenZip: return try SevenZipUpdater.open(url: source, output: output, options: options)
        case .lha: return try LHAUpdater.open(url: source, output: output, options: options)
        }
    }

    static func strategy(_ editor: any ArchiveEditing) -> String {
        switch editor {
        case let value as ArchiveUpdater: return String(describing: value.lastCommitStrategy)
        case let value as TarUpdater: return String(describing: value.lastCommitStrategy)
        case let value as LHAUpdater: return String(describing: value.lastCommitStrategy)
        case let value as SevenZipUpdater: return String(describing: value.lastCommitStrategy)
        case let value as CompressedTarUpdater: return String(describing: value.lastCommitStatistics?.strategy)
        default: return "rewriter"
        }
    }

    final class Session {
        var updates: [ArchiveUpdater.CommitProgress] = []
        private let thread = pthread_self()
        var active = true
        func record(_ update: ArchiveUpdater.CommitProgress) {
            XCTAssertTrue(active, "callback escaped the operation")
            XCTAssertNotEqual(pthread_equal(thread, pthread_self()), 0)
            updates.append(update)
        }
        func check(total: UInt64, file: StaticString = #filePath, line: UInt = #line) {
            active = false
            XCTAssertEqual(updates.first?.completedBytes, 0, file: file, line: line)
            XCTAssertEqual(updates.last?.completedBytes, total, file: file, line: line)
            XCTAssertTrue(updates.allSatisfy { $0.totalBytes == total && $0.completedBytes <= total }, file: file, line: line)
            XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes }, file: file, line: line)
            XCTAssertLessThanOrEqual(updates.count, Int((total + 4 * UInt64(mib) - 1) / (4 * UInt64(mib))) + 2, file: file, line: line)
            XCTAssertEqual(updates.filter { $0.completedBytes == total }.count, total == 0 ? 2 : 1, file: file, line: line)
        }
    }

    enum Failure: Error, Equatable { case callback }
}
