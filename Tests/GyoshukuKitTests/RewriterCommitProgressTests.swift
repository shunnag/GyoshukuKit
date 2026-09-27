import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class RewriterCommitProgressTests: XCTestCase {
    private typealias S = AdditionProgressTestSupport

    func testBothPlacementsUseFixedBudgetAndPreserveBytesAndDidCarry() throws {
        for format in S.formats {
            for placement in [AdditionPlacement.beginning, .end] {
                let root = try ZipTestSupport.directory("p6-rewrite-\(format)-\(placement)")
                let source = try S.source(root, format: .tar, size: 9 * S.mib + 1)
                let disk = try S.file(root, "disk", size: 5 * S.mib + 1)
                let tree = root.appendingPathComponent("tree")
                try FileManager.default.createDirectory(at: tree.appendingPathComponent("child"), withIntermediateDirectories: true)
                _ = try S.file(tree.appendingPathComponent("child"), "file", size: 1_027)
                var expected: Data?, expectedCarry: [Int]?
                for observed in [false, true] {
                    let output = root.appendingPathComponent("\(observed)." + TarP2Support.suffix(format))
                    var options = S.options
                    options.additionPlacement = placement
                    let editor = try ArchiveRewriter.open(url: source, output: output, format: format, options: options)
                    let existential: any ArchiveEditing = editor
                    XCTAssertEqual(existential.readsAdditionsDuringCommit, placement == .end)
                    try S.timestamp(disk)
                    try S.timestamp(tree)
                    try S.timestamp(tree.appendingPathComponent("child"))
                    try S.timestamp(tree.appendingPathComponent("child/file"))
                    let addition = S.Session()
                    try existential.add(contentsOf: disk, as: "added", ownerIDs: nil, progress: observed ? addition.record : nil)
                    if observed { addition.check(total: placement == .end ? 0 : UInt64(5 * S.mib + 1)) }
                    try existential.add(contentsOf: tree, as: "tree")
                    try existential.add(data: Data(repeating: 0x64, count: 17), as: "data", modificationDate: ZipTestSupport.date, permissions: nil)
                    try existential.addDirectory("dir", modificationDate: ZipTestSupport.date, ownerIDs: nil)
                    if observed {
                        let pending = editor.pendingInputBytes
                        let closing = S.Session()
                        try existential.finishAdditions(progress: closing.record)
                        closing.check(total: 0)
                        XCTAssertEqual(editor.pendingInputBytes, pending, "rewriter must not insert a block boundary")
                        XCTAssertThrowsError(try existential.addDirectory("closed")) { XCTAssertEqual($0 as? RewriterError, .invalidState) }
                    }
                    let c = UInt64(9 * S.mib + 1)
                    let a = placement == .end ? UInt64(5 * S.mib + 1 + 1_027 + 17) : 0
                    let d = min(c + a + editor.pendingInputBytes, options.maximumPendingInputBytes(for: format))
                    let session = S.Session()
                    var carried: [Int] = []
                    let didCarry: (Int, Int) throws -> Void = { done, total in
                        XCTAssertEqual(total, 1)
                        carried.append(done)
                    }
                    if observed { try editor.commit(progress: session.record, didCarry: didCarry); session.check(total: c + a + d) }
                    else { try editor.commit(didCarry: didCarry) }
                    let bytes = try Data(contentsOf: output)
                    if let expected { XCTAssertEqual(bytes, expected); XCTAssertEqual(carried, expectedCarry) }
                    else { expected = bytes; expectedCarry = carried }
                }
            }
        }
    }

    func testHardLinkMaterializationAndBufferReadsAreIncluded() throws {
        for format in [GyoshukuKit.ArchiveFormat.tar, .zip] {
            for removeTarget in [false, true] {
                let root = try ZipTestSupport.directory("p6-rewrite-links-\(format)-\(removeTarget)")
                let source = root.appendingPathComponent("source.tar")
                let size = 5 * S.mib + 1, payload = Data(repeating: 0x61, count: size)
                try TarP2Support.archive([
                    (.init(name: Data("target".utf8), size: UInt64(size), mtime: 1_700_000_001), payload),
                    (.init(name: Data("hard".utf8), mtime: 1_700_000_001, type: 0x31, link: Data("target".utf8)), Data()),
                    (.init(name: Data("link".utf8), mode: 0o120755, mtime: 1_700_000_001, type: 0x32, link: Data("target".utf8)), Data())
                ], at: source)
                let editor = try ArchiveRewriter.open(url: source, output: root.appendingPathComponent("out"), format: format, options: S.options)
                if removeTarget { try editor.remove(entriesAt: [0]) }
                let materializes = format == .zip || removeTarget
                let c = UInt64(size * ((removeTarget ? 0 : 1) + (materializes ? 2 : 0)))
                let session = S.Session()
                try editor.commit(progress: session.record)
                session.check(total: c + min(c, S.options.maximumPendingInputBytes(for: format)))
            }
        }
    }

    func testUnknownSizeGzipDoesNotCountReads() throws {
        let root = try ZipTestSupport.directory("p6-rewrite-unknown")
        let source = root.appendingPathComponent("single.gz")
        var bytes = Data()
        try GzipCompressor(level: 6).write(Data(repeating: 0x61, count: 9 * S.mib + 1), finish: true) { bytes.append($0) }
        try bytes.write(to: source)
        let reader = try ArchiveReader.open(url: source)
        XCTAssertNil(reader.entries.first?.uncompressedSize)
        let output = root.appendingPathComponent("out.zip")
        let editor = try ArchiveRewriter.open(url: source, output: output, format: .zip)
        let session = S.Session()
        try editor.commit(progress: session.record)
        session.check(total: 0)
        let written = try ArchiveReader.open(url: output)
        XCTAssertEqual(try written.read(written.entries[0]).count, 9 * S.mib + 1)
    }

    func testCarryAndDrainErrorsPrecedePublicationAndPreserveOriginal() throws {
        for phase in ["carry", "drain", "finish"] {
            for failure in ["cancel", "custom", "mapped", "kaito"] {
                let root = try ZipTestSupport.directory("p6-rewrite-fail-\(phase)-\(failure)")
                let source = try S.source(root, format: .tar, size: 40 * S.mib)
                let bytes = try Data(contentsOf: source), inode = try ZipP1Support.info(source).st_ino
                let editor = try ArchiveRewriter.open(url: source, format: .tarXZ, options: S.options)
                var fired = false
                XCTAssertThrowsError(try editor.commit(progress: { p in
                    let trigger = phase == "carry" ? p.completedBytes > 0
                        : phase == "drain" ? p.completedBytes > UInt64(40 * S.mib)
                        : p.completedBytes == p.totalBytes
                    if trigger {
                        fired = true
                        switch failure {
                        case "cancel": throw CancellationError()
                        case "mapped": throw WriterError.sourceChanged("callback")
                        case "kaito": throw KaitoError.passwordRequired
                        default: throw S.Failure.callback
                        }
                    }
                })) { error in
                    switch failure {
                    case "cancel": XCTAssertTrue(error is CancellationError)
                    case "mapped": XCTAssertEqual(error as? WriterError, .sourceChanged("callback"))
                    case "kaito":
                        guard case KaitoError.passwordRequired = error else { return XCTFail("\(error)") }
                    default: XCTAssertEqual(error as? S.Failure, .callback)
                    }
                }
                XCTAssertTrue(fired)
                XCTAssertThrowsError(try editor.commit()) { XCTAssertEqual($0 as? RewriterError, .invalidState) }
                XCTAssertEqual(try Data(contentsOf: source), bytes)
                XCTAssertEqual(try ZipP1Support.info(source).st_ino, inode)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
            }
        }
    }
}
