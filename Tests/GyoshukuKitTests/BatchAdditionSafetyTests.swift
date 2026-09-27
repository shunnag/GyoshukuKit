import Foundation
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class BatchAdditionSafetyTests: XCTestCase {
    private typealias S = AdditionProgressTestSupport
    private typealias B = BatchAdditionTestSupport

    func testWorkerReplacementAndReadMutationNeverPublish() throws {
        for format in S.formats {
            for mutation in ["symlink", "replace", "grow", "shrink"] {
                let root = try ZipTestSupport.directory("p7-safety-\(format)-\(mutation)")
                defer { try? FileManager.default.removeItem(at: root) }
                let items = try B.small(root, size: 65536)
                let source = try S.source(root, format: format)
                let original = try Data(contentsOf: source)
                let output = root.appendingPathComponent("output")
                let editor = try S.editor(source, output: output, format: format)
                let changed = Mutex(false)
                var finished: [Int] = []
                func check(_ error: Error) {
                    guard let failure = error as? ArchiveAdditionError else { return XCTFail("\(error)") }
                    XCTAssertEqual(failure.index, 2)
                    XCTAssertEqual(failure.path, items[2].path)
                    XCTAssertEqual(failure.sourceURL, items[2].sourceURL)
                    XCTAssertEqual(failure.underlying as? WriterError, mutation == "symlink"
                        ? .io(operation: "open source", code: ELOOP) : .sourceChanged(items[2].sourceURL!.path))
                }
                try FileJob.$testingBeforeWorkerOpen.withValue({ index, url in
                    guard index == 2 else { return }
                    if mutation == "symlink" {
                        try FileManager.default.removeItem(at: url)
                        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: items[0].sourceURL!.path)
                    } else if mutation == "replace" {
                        try Data(repeating: 91, count: 65536).write(to: url, options: .atomic)
                    }
                }) {
                    try FileJob.$testingDuringWorkerRead.withValue({ index, url in
                        guard index == 2, mutation == "grow" || mutation == "shrink" else { return }
                        guard changed.withLock({ value in if value { return false }; value = true; return true }) else { return }
                        let handle = try FileHandle(forWritingTo: url)
                        defer { try? handle.close() }
                        if mutation == "grow" { try handle.seekToEnd(); try handle.write(contentsOf: Data([1])) }
                        else { try handle.truncate(atOffset: 7) }
                    }) {
                        XCTAssertThrowsError(try editor.add(items, events: {
                            if case let .didFinish(index) = $0 { finished.append(index) }
                        }), "\(format) \(mutation)", check)
                    }
                }
                XCTAssertEqual(finished, [0, 1])
                XCTAssertThrowsError(try editor.commit())
                XCTAssertEqual(try Data(contentsOf: source), original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testMinimumIndexReadErrorBeatsLaterDuplicateAndDeflateErrorHasIndex() throws {
        let root = try ZipTestSupport.directory("p7-attribution")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try B.small(root)
        for duplicate in [false, true] {
            var items = original
            if duplicate { items[3].path = items[0].path }
            XCTAssertEqual(chmod(items[2].sourceURL!.path, 0), 0)
            defer { chmod(items[2].sourceURL!.path, 0o644) }
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("read-\(duplicate).zip"))
            var finished: [Int] = []
            XCTAssertThrowsError(try writer.add(items, events: { if case let .didFinish(i) = $0 { finished.append(i) } })) {
                let error = $0 as? ArchiveAdditionError
                XCTAssertEqual(error?.index, 2)
                XCTAssertEqual(error?.path, items[2].path)
                XCTAssertEqual(error?.sourceURL, items[2].sourceURL)
                XCTAssertEqual(error?.underlying as? WriterError, .io(operation: "open source", code: EACCES))
            }
            XCTAssertEqual(finished, [0, 1])
        }
        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("deflate.zip"), format: .zip,
            deflateEncoder: { block, level in
                if block.input.first == 3 { throw WriterError.compression(-77) }
                return try DeflateBlock.encode(block, level: level)
            }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
        var finished: [Int] = []
        XCTAssertThrowsError(try writer.add(original, events: { if case let .didFinish(i) = $0 { finished.append(i) } })) {
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 3)
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .compression(-77))
        }
        XCTAssertEqual(finished, [0, 1, 2])
    }

    func testOutputIdentityAndRecursiveDescendantAttribution() throws {
        let root = try ZipTestSupport.directory("p7-output-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("self.zip")
        let writer = try ArchiveWriter.create(url: output)
        XCTAssertThrowsError(try writer.add([.init(path: "self", source: .contents(of: output))], events: nil)) {
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .invalidPath("source contains output archive"))
        }
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let unreadable = try S.file(tree, "unreadable", size: 13)
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        defer { chmod(unreadable.path, 0o644) }
        let recursive = try ArchiveWriter.create(url: root.appendingPathComponent("recursive.zip"))
        XCTAssertThrowsError(try recursive.add([.init(path: "folder", source: .contents(of: tree))], events: nil)) {
            let error = $0 as? ArchiveAdditionError
            XCTAssertEqual(error?.index, 0)
            XCTAssertEqual(error?.path, "folder")
            XCTAssertEqual(error?.sourceURL, unreadable)
        }
    }

    func testPrewalkFailureReportsDescendantAndLargeDeflateFailureReportsItem() throws {
        let root = try ZipTestSupport.directory("p7-fallback-errors")
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree"), child = tree.appendingPathComponent("inaccessible")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(child.path, 0), 0)
        defer { chmod(child.path, 0o755) }
        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("prewalk.zip"))
        XCTAssertThrowsError(try writer.add([.init(path: "tree", source: .contents(of: tree))], events: { _ in })) {
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.sourceURL?.path, child.path)
        }
        let items = try B.small(root, size: 65537)
        let large = try ArchiveWriter.create(url: root.appendingPathComponent("large.zip"), format: .zip,
            deflateBlockSize: 65536, deflateEncoder: { block, level in
                if block.input.first == 3 { throw WriterError.compression(-71) }
                return try DeflateBlock.encode(block, level: level)
            }, lzmaChunkSize: LZMA2ChunkPipeline<Void>.chunkSize)
        var finished: [Int] = []
        XCTAssertThrowsError(try large.add(items, events: { if case let .didFinish(i) = $0 { finished.append(i) } })) {
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 3)
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .compression(-71))
        }
        XCTAssertEqual(finished, [0, 1, 2])
    }

    func testFallbackKeepsFirstSignatureWhileDrainingEarlierEvents() throws {
        for format in [ArchiveFormat.zip, .tarGzip] {
            let root = try ZipTestSupport.directory("p7-fallback-stamp-\(format)")
            defer { try? FileManager.default.removeItem(at: root) }
            var items = try B.small(root, count: 2)
            let large = try S.file(root, "large", size: S.mib + 1)
            items.append(.init(path: "large", source: .contents(of: large)))
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("output"), format: format,
                                                 options: .init(compressionThreads: 8))
            var largeStarted = false, finished: [Int] = []
            XCTAssertThrowsError(try writer.add(items, events: {
                if case .willStart(2) = $0 { largeStarted = true }
                if case let .didFinish(index) = $0 {
                    finished.append(index)
                    if index == 0 {
                        XCTAssertTrue(largeStarted)
                        try Data(repeating: 97, count: S.mib + 1).write(to: large, options: .atomic)
                    }
                }
            })) {
                XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 2)
                XCTAssertEqual(($0 as? ArchiveAdditionError)?.sourceURL, large)
                XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .sourceChanged(large.path))
            }
            XCTAssertEqual(finished, [0, 1])
        }
    }

    func testDeferredExpectedSignatureAndCallbackCleanupInEveryEditor() throws {
        let root = try ZipTestSupport.directory("p7-deferred-safety")
        defer { try? FileManager.default.removeItem(at: root) }
        for format in S.formats {
            let source = try S.source(root, format: format)
            let original = try Data(contentsOf: source)
            let file = try S.file(root, "input-\(format)", size: 64)
            let output = root.appendingPathComponent("deferred-\(format)")
            let rewriter = try S.editor(source, output: output, format: format, rewrite: true)
            try rewriter.add([.init(path: "added", source: .contents(of: file))], events: nil)
            try Data(repeating: 19, count: 64).write(to: file, options: .atomic)
            XCTAssertThrowsError(try rewriter.commit()) { XCTAssertEqual($0 as? WriterError, .sourceChanged(file.path)) }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            for kind in ["update", "beginning", "end"] {
                var options = S.options; options.additionPlacement = kind == "beginning" ? .beginning : .end
                let destination = root.appendingPathComponent("callback-\(format)-\(kind)")
                let editor = try S.editor(source, output: destination, format: format, options: options, rewrite: kind != "update")
                XCTAssertThrowsError(try editor.add([.init(path: "added", source: .contents(of: file))], events: { _ in throw S.Failure.callback })) {
                    XCTAssertEqual($0 as? S.Failure, .callback)
                }
                XCTAssertThrowsError(try editor.commit())
                XCTAssertEqual(try Data(contentsOf: source), original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }
}
