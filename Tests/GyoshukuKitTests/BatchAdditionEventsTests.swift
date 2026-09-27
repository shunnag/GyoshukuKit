import Foundation
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class BatchAdditionEventsTests: XCTestCase {
    private typealias S = AdditionProgressTestSupport
    private typealias B = BatchAdditionTestSupport

    func testCallerThreadOrderSessionsAndBoundedWindow() throws {
        let root = try ZipTestSupport.directory("p7-events")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try B.fixture(root, full: false)
        for format in S.formats {
            for threads in [1, 4, 8] {
                let items = B.applicable(fixture, format: format)
                let started = Mutex(Set<Int>())
                let counts = Mutex((current: 0, maximum: 0))
                var finished: [Int] = []
                var sessions: [Int: S.Session] = [:]
                var nextProgress = 0
                let caller = pthread_self()
                let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(format)-\(threads)"), format: format,
                                                     options: .init(compressionThreads: threads))
                try FileJob.$testingBeforeLstat.withValue({ index, _ in XCTAssertTrue(started.withLock { $0.contains(index) }) }) {
                try FileJob.$testingBeforeWorkerOpen.withValue({ index, _ in XCTAssertTrue(started.withLock { $0.contains(index) }) }) {
                try FileJob.$testingDescriptorChange.withValue({ delta in
                    counts.withLock { $0.current += delta; $0.maximum = max($0.maximum, $0.current) }
                }) {
                    try writer.add(items, events: { event in
                        XCTAssertNotEqual(pthread_equal(caller, pthread_self()), 0)
                        switch event {
                        case let .willStart(index):
                            started.withLock { _ = $0.insert(index) }
                            XCTAssertLessThanOrEqual(index - finished.count + 1, threads)
                        case let .progress(index, progress):
                            XCTAssertEqual(index, nextProgress)
                            if sessions[index] == nil { sessions[index] = S.Session() }
                            sessions[index]!.record(progress)
                        case let .didFinish(index):
                            XCTAssertEqual(index, nextProgress)
                            nextProgress += 1; finished.append(index)
                        }
                    })
                } } }
                XCTAssertEqual(finished, Array(items.indices))
                for index in items.indices {
                    let total = try items[index].sourceURL.map { try ArchiveWriter.inputByteCount($0) } ?? 0
                    sessions[index]!.check(total: total)
                }
                XCTAssertEqual(counts.withLock { $0.current }, 0)
                XCTAssertLessThanOrEqual(counts.withLock { $0.maximum }, min(threads, 4))
                try writer.finish()
            }
        }
    }

    func testEveryCallbackFailureIsUnwrappedAndWillStartFailureNeverOpensItem() throws {
        let root = try ZipTestSupport.directory("p7-event-errors")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try B.small(root, count: 12)
        for phase in ["start", "progress", "finish"] {
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(phase).zip"))
            let opened = Mutex(Set<Int>())
            try FileJob.$testingBeforeWorkerOpen.withValue({ i, _ in opened.withLock { _ = $0.insert(i) } }) {
                XCTAssertThrowsError(try writer.add(items, events: { event in
                    switch event {
                    case .willStart(2) where phase == "start", .progress(2, _) where phase == "progress", .didFinish(2) where phase == "finish":
                        throw WriterError.invalidDate
                    default: break
                    }
                })) { XCTAssertEqual($0 as? WriterError, .invalidDate) }
            }
            if phase == "start" { XCTAssertFalse(opened.withLock { $0.contains(2) }) }
            XCTAssertThrowsError(try writer.finish())
        }
    }

    func testDefaultImplementationPreservesOwnerDispatchAndCallbackIdentity() throws {
        let editor = DefaultEditor()
        let items: [ArchiveAddition] = [
            .init(path: "plain", source: .contents(of: URL(fileURLWithPath: "/unused"))),
            .init(path: "owned", source: .contents(of: URL(fileURLWithPath: "/unused")), ownerIDs: .init(user: 1, group: 2)),
            .init(path: "folder", source: .directory(modificationDate: nil))
        ]
        var events: [ArchiveAdditionEvent] = []
        try editor.add(items, events: { events.append($0) })
        XCTAssertEqual(editor.plain, 1); XCTAssertEqual(editor.owned, 1); XCTAssertEqual(editor.directories, 1)
        XCTAssertEqual(events.count, 12)
        for index in items.indices {
            XCTAssertEqual(Array(events[index * 4..<index * 4 + 4]), [
                .willStart(index: index), .progress(index: index, .init(completedBytes: 0, totalBytes: 0)),
                .progress(index: index, .init(completedBytes: 0, totalBytes: 0)), .didFinish(index: index)
            ])
        }
        XCTAssertThrowsError(try editor.add(items, events: { if case .progress = $0 { throw WriterError.invalidDate } })) {
            XCTAssertEqual($0 as? WriterError, .invalidDate)
        }
        editor.fail = true
        XCTAssertThrowsError(try editor.add(items, events: nil)) {
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 0)
            XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .invalidDate)
        }
    }

    private final class DefaultEditor: ArchiveEditing {
        var entryNames: [String] { [] }
        var plain = 0, owned = 0, directories = 0
        var fail = false
        func add(contentsOf url: URL, as path: String) throws {
            if fail { throw WriterError.invalidDate }; plain += 1
        }
        func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws { owned += 1 }
        func addDirectory(_ path: String) throws { directories += 1 }
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws {}
        func remove(entriesAt indices: [Int]) throws {}
        func rename(entryAt index: Int, to path: String) throws {}
        func commit() throws {}
    }

    private static func descriptors() -> Int32 {
        proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    }

    func testCancellationAt300JoinsDescriptorsBeforeReturning() async throws {
        let root = try ZipTestSupport.directory("p7-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try B.small(root, count: 1000)
        for format in [ArchiveFormat.zip, .tarGzip, .sevenZip] {
            let task = Task.detached {
                let before = BatchAdditionEventsTests.descriptors()
                XCTAssertGreaterThan(before, 0)
                let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(format)"), format: format,
                                                     options: .init(compressionThreads: 8))
                let counts = Mutex((current: 0, maximum: 0))
                var finishes = 0
                try FileJob.$testingDescriptorChange.withValue({ delta in
                    counts.withLock { $0.current += delta; $0.maximum = max($0.maximum, $0.current) }
                }) {
                    XCTAssertThrowsError(try writer.add(items, events: {
                        if case .didFinish = $0 {
                            finishes += 1
                            if finishes == 300 { withUnsafeCurrentTask { $0?.cancel() } }
                        }
                    })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
                }
                XCTAssertEqual(finishes, 300)
                XCTAssertEqual(counts.withLock { $0.current }, 0)
                XCTAssertLessThanOrEqual(counts.withLock { $0.maximum }, 4)
                XCTAssertEqual(BatchAdditionEventsTests.descriptors(), before)
            }
            try await task.value
        }
    }

    func testFinishAdditionsRejectsBatchWithoutPoisoningInstance() throws {
        let root = try ZipTestSupport.directory("p7-closed")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try B.small(root)
        for format in S.formats {
            let writer = try ArchiveWriter.create(url: root.appendingPathComponent("\(format)"), format: format)
            try writer.add(items, events: nil)
            try writer.finishAdditions(progress: nil)
            XCTAssertThrowsError(try writer.add(items, events: nil)) { XCTAssertEqual($0 as? WriterError, .invalidState) }
            try writer.finish()
        }
    }
}
