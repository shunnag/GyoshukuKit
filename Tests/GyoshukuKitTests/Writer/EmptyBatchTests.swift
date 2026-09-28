import Foundation
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class EmptyBatchTests: XCTestCase {
    private typealias S = AdditionProgressTestSupport

    private static func unexpectedEvent(_ event: ArchiveAdditionEvent) throws {
        XCTFail("empty batch sent \(event)")
        throw S.Failure.callback
    }

    // Include temporary directories and their bytes, so preparing an append writer is observable
    // even for an editor whose eventual commit strategy would happen to stay the same.
    private static func snapshot(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(path)
            result[path] = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                ? Data() : Data(contentsOf: url)
        }
        return result
    }

    private static func empty(_ editor: any ArchiveEditing, in directory: URL) throws {
        let before = try snapshot(directory), names = editor.entryNames
        try editor.add([], events: unexpectedEvent)
        try editor.add([], events: nil)
        XCTAssertEqual(editor.entryNames, names)
        XCTAssertEqual(try snapshot(directory), before)
    }

    private func renameOnly(_ format: ArchiveFormat, rewrite: Bool = false,
                            placement: AdditionPlacement = .end) throws {
        let root = try TestSupport.directory("p7-empty-\(format)-\(rewrite)-\(placement)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try S.source(root, format: format), original = try Data(contentsOf: source)
        var options = S.options
        options.additionPlacement = placement
        for finish in [false, true] {
            var expected: Data?, expectedStrategy: String?, expectedProgress: [ArchiveUpdater.CommitProgress]?
            for empty in [false, true] {
                let work = root.appendingPathComponent("\(finish)-\(empty)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
                let output = work.appendingPathComponent("output")
                let editor = try S.editor(source, output: output, format: format, options: options, rewrite: rewrite)
                if empty { try EmptyBatchTests.empty(editor, in: work) }
                try editor.rename(entryAt: 0, to: "edit")
                if empty { try EmptyBatchTests.empty(editor, in: work) }
                var progress: [ArchiveUpdater.CommitProgress] = []
                if finish {
                    for _ in 0..<2 {
                        let session = S.Session()
                        try editor.finishAdditions(progress: session.record)
                        session.check(total: 0)
                        progress += session.updates
                        if empty { try EmptyBatchTests.empty(editor, in: work) }
                    }
                }
                try editor.commit()
                switch editor {
                case let updater as ArchiveUpdater: XCTAssertEqual(updater.lastCommitStrategy, .inPlacePatch)
                case let updater as TarUpdater: XCTAssertEqual(updater.lastCommitStrategy, .inPlacePatch)
                case let updater as LHAUpdater: XCTAssertEqual(updater.lastCommitStrategy, .inPlacePatch)
                case let updater as SevenZipUpdater: XCTAssertEqual(updater.lastCommitStrategy, .headerOnly)
                case let updater as CompressedTarUpdater: XCTAssertNotNil(updater.lastCommitStatistics)
                default: break
                }
                let bytes = try Data(contentsOf: output), strategy = S.strategy(editor)
                if let expected {
                    XCTAssertEqual(bytes, expected)
                    XCTAssertEqual(strategy, expectedStrategy)
                    XCTAssertEqual(progress, expectedProgress)
                } else {
                    expected = bytes; expectedStrategy = strategy; expectedProgress = progress
                }
                if empty { try EmptyBatchTests.empty(editor, in: work) }
                try editor.commit()
                XCTAssertEqual(try Data(contentsOf: output), bytes)
                XCTAssertEqual(S.strategy(editor), strategy)
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testArchiveUpdaterRenameKeepsInPlacePatchAndBytes() throws { try renameOnly(.zip) }
    func testTarUpdaterRenameKeepsInPlacePatchAndBytes() throws { try renameOnly(.tar) }
    func testLHAUpdaterRenameKeepsInPlacePatchAndBytes() throws { try renameOnly(.lha) }
    func testSevenZipUpdaterRenameKeepsHeaderOnlyAndBytes() throws { try renameOnly(.sevenZip) }

    func testCompressedTarUpdaterKeepsStrategyAndBytes() throws {
        for format in [ArchiveFormat.tarGzip, .tarBzip2, .tarXZ] { try renameOnly(format) }
    }

    func testArchiveRewriterBothPlacementsKeepBytesWithoutPreparingOutput() throws {
        for format in S.formats {
            for placement in [AdditionPlacement.beginning, .end] {
                try renameOnly(format, rewrite: true, placement: placement)
            }
        }
    }

    func testArchiveWriterDoesNotDrainPendingInputOrChangeFinishAndBytes() throws {
        var sawPendingInput = false
        for format in S.formats {
            let root = try TestSupport.directory("p7-empty-writer-\(format)")
            defer { try? FileManager.default.removeItem(at: root) }
            for populated in [false, true] {
                for finish in [false, true] {
                    var expected: Data?, expectedProgress: [ArchiveUpdater.CommitProgress]?
                    for empty in [false, true] {
                        let output = root.appendingPathComponent("\(populated)-\(finish)-\(empty)")
                        let writer = try ArchiveWriter.create(url: output, format: format, options: S.options,
                            deflateBlockSize: 64 * 1024, lzmaChunkSize: 64 * 1024)
                        func checkEmpty() throws {
                            let before = try Data(contentsOf: output), pending = writer.pendingInputBytes
                            try writer.add([], events: EmptyBatchTests.unexpectedEvent)
                            try writer.add([], events: nil)
                            XCTAssertEqual(writer.pendingInputBytes, pending)
                            XCTAssertEqual(try Data(contentsOf: output), before)
                        }
                        if empty { try checkEmpty() }
                        if populated {
                            try writer.add(data: Data(repeating: 0x61, count: 128 * 1024 + 1), as: "pending",
                                           modificationDate: TestSupport.date)
                        }
                        sawPendingInput = sawPendingInput || writer.pendingInputBytes > 0
                        if empty { try checkEmpty() }
                        var progress: [ArchiveUpdater.CommitProgress] = []
                        if finish {
                            for _ in 0..<2 {
                                let pending = writer.pendingInputBytes, session = S.Session()
                                try writer.finishAdditions(progress: session.record)
                                session.check(total: pending)
                                progress += session.updates
                                if empty { try checkEmpty() }
                            }
                        }
                        try writer.finish()
                        let bytes = try Data(contentsOf: output)
                        if let expected {
                            XCTAssertEqual(bytes, expected)
                            XCTAssertEqual(progress, expectedProgress)
                        } else { expected = bytes; expectedProgress = progress }
                        if empty { try checkEmpty() }
                    }
                }
            }
        }
        XCTAssertTrue(sawPendingInput, "exercise an empty batch while compression output is pending")
    }

    func testFailedWritersAndEditorsStayFailedWithoutEvents() throws {
        for format in S.formats {
            let root = try TestSupport.directory("p7-empty-failed-\(format)")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try S.source(root, format: format)
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("writer"), format: format)
            XCTAssertThrowsError(try writer.addDirectory("../bad"))
            let before = try EmptyBatchTests.snapshot(root)
            try writer.add([], events: EmptyBatchTests.unexpectedEvent)
            XCTAssertEqual(try EmptyBatchTests.snapshot(root), before)
            XCTAssertThrowsError(try writer.finish()) { XCTAssertEqual($0 as? WriterError, .invalidState) }
            for rewrite in [false, true] {
                let editor = try S.editor(source, output: root.appendingPathComponent("editor-\(rewrite)"),
                                          format: format, rewrite: rewrite)
                XCTAssertThrowsError(try editor.rename(entryAt: -1, to: "bad"))
                try EmptyBatchTests.empty(editor, in: root)
                XCTAssertThrowsError(try editor.commit()) {
                    if rewrite { XCTAssertEqual($0 as? RewriterError, .invalidState) }
                    else { XCTAssertEqual($0 as? UpdaterError, .invalidState) }
                }
            }
        }
    }

    func testCancelledEmptyBatchDoesNotPrepareWritersOrEditors() async throws {
        for format in S.formats {
            for rewrite in [false, true] {
                try await Task.detached {
                    let root = try TestSupport.directory("p7-empty-cancelled-\(format)-\(rewrite)")
                    defer { try? FileManager.default.removeItem(at: root) }
                    let source = try S.source(root, format: format)
                    let writer = try ArchiveWriter.create(url: root.appendingPathComponent("writer"), format: format)
                    let editor = try S.editor(source, output: root.appendingPathComponent("editor"),
                                              format: format, rewrite: rewrite)
                    let before = try EmptyBatchTests.snapshot(root)
                    withUnsafeCurrentTask { $0?.cancel() }
                    try writer.add([], events: EmptyBatchTests.unexpectedEvent)
                    try EmptyBatchTests.empty(editor, in: root)
                    XCTAssertEqual(try EmptyBatchTests.snapshot(root), before)
                }.value
            }
        }
    }

    func testDefaultImplementationIsEmptyEvenWhenCancelled() async throws {
        try await Task.detached {
            let editor = DefaultEditor()
            try editor.add([], events: EmptyBatchTests.unexpectedEvent)
            let session = S.Session()
            try editor.finishAdditions(progress: session.record)
            session.check(total: 0)
            try editor.add([], events: EmptyBatchTests.unexpectedEvent)
            try editor.commit()
            withUnsafeCurrentTask { $0?.cancel() }
            try editor.add([], events: EmptyBatchTests.unexpectedEvent)
            XCTAssertEqual(editor.additions, 0)
            XCTAssertEqual(editor.commits, 1)
        }.value
    }

    private final class DefaultEditor: ArchiveEditing {
        var entryNames: [String] { [] }
        var additions = 0, commits = 0
        func add(contentsOf url: URL, as path: String) throws { additions += 1 }
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws { additions += 1 }
        func addDirectory(_ path: String) throws { additions += 1 }
        func remove(entriesAt indices: [Int]) throws {}
        func rename(entryAt index: Int, to path: String) throws {}
        func commit() throws { commits += 1 }
    }
}
