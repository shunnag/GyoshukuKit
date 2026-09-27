import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class AdditionProgressTests: XCTestCase {
    private typealias S = AdditionProgressTestSupport

    func testWriterAndEditorSessionsAndBytesInEveryFormat() throws {
        for format in S.formats {
            let root = try ZipTestSupport.directory("p6-add-\(format)")
            let large = try S.file(root, "large", size: 9 * S.mib + 1)
            let empty = try S.file(root, "empty", size: 0)
            let special = root.appendingPathComponent("special")
            if format == .lha { try FileManager.default.createDirectory(at: special, withIntermediateDirectories: true) }
            else { try FileManager.default.createSymbolicLink(atPath: special.path, withDestinationPath: "large") }
            try S.timestamp(special)
            let source = try S.source(root, format: format)
            for kind in ["writer", "updater", "rewriter"] {
                var expected: Data?
                for observed in [false, true] {
                    let output = root.appendingPathComponent("\(kind)-\(observed)." + TarP2Support.suffix(format))
                    var options = S.options
                    options.additionPlacement = kind == "rewriter" ? .beginning : .end
                    let writer = kind == "writer" ? try ArchiveWriter.create(url: output, format: format, options: options) : nil
                    let editor = kind != "writer" ? try S.editor(source, output: output, format: format, options: options, rewrite: kind == "rewriter") : nil
                    for (file, total) in [(large, UInt64(9 * S.mib + 1)), (empty, 0), (special, 0)] {
                        try S.timestamp(file)
                        let session = S.Session()
                        let progress: ((ArchiveUpdater.CommitProgress) throws -> Void)? = observed ? session.record : nil
                        if let writer { try writer.add(contentsOf: file, as: file.lastPathComponent, ownerIDs: nil, progress: progress) }
                        else { try editor!.add(contentsOf: file, as: file.lastPathComponent, ownerIDs: nil, progress: progress) }
                        if observed { session.check(total: total) }
                    }
                    if let writer { try writer.finish() } else { try editor!.commit() }
                    let bytes = try Data(contentsOf: output)
                    if let expected { XCTAssertEqual(bytes, expected, "\(format) \(kind)") } else { expected = bytes }
                }
            }
        }
    }

    func testRecursiveTotalsAndGrowthAfterPrewalk() throws {
        for format in S.formats {
            for grow in [false, true] {
                let root = try ZipTestSupport.directory("p6-walk-\(format)-\(grow)")
                let tree = root.appendingPathComponent("tree")
                try FileManager.default.createDirectory(at: tree.appendingPathComponent("one/two"), withIntermediateDirectories: true)
                var total: UInt64 = 0
                for index in 0..<17 {
                    let directory = index % 3 == 0 ? tree : tree.appendingPathComponent(index % 3 == 1 ? "one" : "one/two")
                    let size = index == 0 ? 0 : index == 1 ? 5 * S.mib : index * 13
                    _ = try S.file(directory, "file-\(index)", size: size)
                    total += UInt64(size)
                }
                if format != .lha { try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "one") }
                let output = root.appendingPathComponent("output." + TarP2Support.suffix(format))
                let writer = try ArchiveWriter.create(url: output, format: format, options: S.options)
                let session = S.Session()
                try ArchiveWriter.$testingAfterPreWalk.withValue({
                    if grow {
                        let handle = try FileHandle(forWritingTo: tree.appendingPathComponent("file-0"))
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(repeating: 0x63, count: S.mib))
                    }
                }) {
                    try writer.add(contentsOf: tree, as: "tree", progress: session.record)
                }
                session.check(total: total)
                try writer.finish()
                let reader = try ArchiveReader.open(url: output)
                let changed = try XCTUnwrap(reader.entries.first { $0.name == "tree/file-0" })
                XCTAssertEqual(try reader.read(changed).count, grow ? S.mib : 0)
            }
        }
    }

    func testNilProgressDoesNotPrewalkAndLHASymlinkDoesNotFinish() throws {
        let root = try ZipTestSupport.directory("p6-nil-prewalk")
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let writer = try ArchiveWriter.create(url: root.appendingPathComponent("nil.tar"), format: .tar)
        try ArchiveWriter.$testingAfterPreWalk.withValue({ throw S.Failure.callback }) {
            try writer.add(contentsOf: tree, as: "tree", progress: nil)
        }
        try writer.finish()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "tree")
        let lha = try ArchiveWriter.create(url: root.appendingPathComponent("link.lha"), format: .lha)
        let session = S.Session()
        XCTAssertThrowsError(try lha.add(contentsOf: link, as: "link", progress: session.record)) {
            XCTAssertEqual($0 as? WriterError, .unsupportedFileType("link"))
        }
        XCTAssertEqual(session.updates.count, 1)
    }

    func testCallbackErrorsFailAndCleanUpEveryEditor() throws {
        for format in S.formats {
            for rewrite in [false, true] {
                for cancel in [false, true] {
                    let root = try ZipTestSupport.directory("p6-add-failure-\(format)-\(rewrite)-\(cancel)")
                    let source = try S.source(root, format: format)
                    let original = try Data(contentsOf: source), inode = try ZipP1Support.info(source).st_ino
                    let disk = try S.file(root, "disk", size: 9 * S.mib + 1)
                    let work = try TarP2Support.work(root), output = work.appendingPathComponent("output")
                    var options = S.options
                    options.additionPlacement = rewrite ? .beginning : .end
                    let editor = try S.editor(source, output: output, format: format, options: options, rewrite: rewrite)
                    var calls = 0
                    XCTAssertThrowsError(try editor.add(contentsOf: disk, as: "new", ownerIDs: nil, progress: { _ in
                        calls += 1
                        if calls == 2 { if cancel { throw CancellationError() }; throw S.Failure.callback }
                    })) { error in
                        if cancel { XCTAssertTrue(error is CancellationError) }
                        else { XCTAssertEqual(error as? S.Failure, .callback) }
                    }
                    XCTAssertEqual(calls, 2)
                    XCTAssertThrowsError(try editor.commit())
                    XCTAssertEqual(try Data(contentsOf: source), original)
                    XCTAssertEqual(try ZipP1Support.info(source).st_ino, inode)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
                }
            }
        }
    }

    func testDefaultImplementationsPreserveOwnerDispatch() throws {
        let concrete = DefaultEditor(), editor: any ArchiveEditing = concrete
        let url = URL(fileURLWithPath: "/unused")
        for ids: ArchiveOwnerIDs? in [nil, .init(user: 12, group: 34)] {
            let session = S.Session()
            try editor.add(contentsOf: url, as: "file", ownerIDs: ids, progress: session.record)
            session.check(total: 0)
        }
        XCTAssertEqual(concrete.plain, 1)
        XCTAssertEqual(concrete.owned, 1)
        let session = S.Session()
        try editor.finishAdditions(progress: session.record)
        session.check(total: 0)
        XCTAssertFalse(editor.readsAdditionsDuringCommit)
    }

    func testWriterCallbackAndTaskCancellationUseExistingCleanup() async throws {
        for format in S.formats {
            for phase in ["add", "drain", "task"] {
                let root = try ZipTestSupport.directory("p6-writer-failure-\(format)-\(phase)")
                let disk = try S.file(root, "disk", size: 9 * S.mib + 1)
                let output = root.appendingPathComponent("output")
                let task = Task {
                    let writer = try ArchiveWriter.create(url: output, format: format, options: S.options)
                    var fired = false
                    do {
                        if phase == "drain" {
                            for index in 0..<8 {
                                try writer.add(data: Data(repeating: 0x61, count: S.mib), as: "new-\(index)", modificationDate: ZipTestSupport.date)
                            }
                            try writer.finishAdditions(progress: { p in
                                if p.completedBytes > 0 || p.totalBytes == 0 { fired = true; throw S.Failure.callback }
                            })
                        } else {
                            try writer.add(contentsOf: disk, as: "disk", progress: { p in
                                if p.completedBytes >= 4 * S.mib {
                                    fired = true
                                    if phase == "task" { withUnsafeCurrentTask { $0?.cancel() } }
                                    else { throw S.Failure.callback }
                                }
                            })
                        }
                        XCTFail("operation succeeded after cancellation")
                    } catch {
                        if phase == "task" { XCTAssertTrue(error is CancellationError) }
                        else { XCTAssertEqual(error as? S.Failure, .callback) }
                    }
                    XCTAssertTrue(fired)
                    XCTAssertThrowsError(try writer.finish()) { XCTAssertEqual($0 as? WriterError, .invalidState) }
                    if format == .zip {
                        // 単体 ZIP writer は呼出側が部分出力を削除する既存の契約。
                        try FileManager.default.removeItem(at: output)
                    } else { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
                    XCTAssertEqual(try Data(contentsOf: disk).count, 9 * S.mib + 1)
                }
                try await task.value
            }
        }
    }

    private final class DefaultEditor: ArchiveEditing {
        var entryNames: [String] { [] }
        var plain = 0, owned = 0
        func add(contentsOf url: URL, as path: String) throws { plain += 1 }
        func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws { owned += 1 }
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws {}
        func addDirectory(_ path: String) throws {}
        func remove(entriesAt indices: [Int]) throws {}
        func rename(entryAt index: Int, to path: String) throws {}
        func commit() throws {}
    }
}
