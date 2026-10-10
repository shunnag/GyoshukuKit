import Darwin
import Foundation
import Synchronization
import XCTest
@testable import GyoshukuKit

final class OrderedChunkPipelineInlineTests: XCTestCase {
    private final class Input: @unchecked Sendable {
        let value: Int
        init(_ value: Int) { self.value = value }
    }

    func testSuspendedQueueEncodesOnceOnCallerAndReleasesInputBeforeLateBlocks() throws {
        let queue = DispatchQueue(label: "test.inline", attributes: .concurrent)
        queue.suspend()
        defer { queue.resume(); queue.sync(flags: .barrier) {} }
        let caller = pthread_mach_thread_np(pthread_self())
        let calls = Mutex([Int]())
        let pipeline = OrderedChunkPipeline<Input, Int, Int>(threads: 4, queue: queue) { input in
            XCTAssertEqual(pthread_mach_thread_np(pthread_self()), caller)
            calls.withLock { $0.append(input.value) }
            if input.value == 1 { throw WriterError.compression(-77) }
            return input.value
        }
        var input: Input? = Input(0)
        weak let captured = input
        var emitted: [Int] = []
        let emit: (Int, Int?) -> Void = { tag, value in
            XCTAssertEqual(value, tag)
            emitted.append(tag)
        }
        try pipeline.submit(input, tag: 0, weight: 7, emit: emit)
        input = nil
        XCTAssertNotNil(captured)
        try pipeline.submit(Input(1), tag: 1, emit: emit)
        try pipeline.submit(Input(2), tag: 2, emit: emit)
        try pipeline.emitNext(emit)
        XCTAssertNil(captured)
        XCTAssertEqual(emitted, [0])
        XCTAssertThrowsError(try pipeline.finish(emit: emit)) {
            XCTAssertEqual($0 as? WriterError, .compression(-77))
        }
        // 未着手jobと遅延blockをjoinへ含めず、着手済みbodyのenter/leaveだけを待つ。
        pipeline.abandonAndWait()
        XCTAssertEqual(pipeline.pendingInputBytes, 0)
        queue.resume()
        queue.sync(flags: .barrier) {}
        queue.suspend()
        XCTAssertEqual(calls.withLock { $0 }, [0, 1])
    }

    func testBorrowedEarlyJobRunsBeforeBlockedNormalJobAndDefersItsFailure() throws {
        for inline in [false, true] {
            let queue = DispatchQueue(label: "test.inline.early", attributes: .concurrent)
            queue.suspend()
            defer { queue.resume(); queue.sync(flags: .barrier) {} }
            let calls = Mutex([Int]())
            let pipeline = OrderedChunkPipeline<Int, Int, Int>(threads: 1, inlineSingleThread: inline, queue: queue) { value in
                calls.withLock { $0.append(value) }
                if value == 1 { throw WriterError.compression(-77) }
                return value
            }
            let early = try pipeline.startEarly(weight: 11, borrowsThread: true) { 1 }
            var emitted: [Int] = []
            let emit: (Int, Int?) -> Void = { tag, value in
                XCTAssertEqual(value, tag)
                emitted.append(tag)
            }
            try pipeline.submit(0, tag: 0, weight: 7, emit: emit)
            try pipeline.emitNext(emit)
            XCTAssertEqual(calls.withLock { $0 }, [1, 0])
            XCTAssertEqual(emitted, [0])
            XCTAssertTrue(pipeline.isEarlyComplete(early))
            try pipeline.joinEarly(early)
            try pipeline.submitEarly(early, tag: 1, emit: emit)
            XCTAssertThrowsError(try pipeline.finish(emit: emit)) {
                XCTAssertEqual($0 as? WriterError, .compression(-77))
            }
            pipeline.abandonAndWait()
            queue.resume()
            queue.sync(flags: .barrier) {}
            queue.suspend()
            XCTAssertEqual(calls.withLock { $0 }, [1, 0])
        }
    }

    func testAbandonReleasesUnstartedNormalAndBorrowedInputsWithoutDispatching() throws {
        let queue = DispatchQueue(label: "test.inline.abandon", attributes: .concurrent)
        queue.suspend()
        defer { queue.resume(); queue.sync(flags: .barrier) {} }
        let pipeline = OrderedChunkPipeline<Input, Int, Int>(threads: 2, queue: queue) { _ in
            XCTFail("abandoned encoder ran")
            return 0
        }
        var input: Input? = Input(0)
        weak let captured = input
        _ = try pipeline.startEarly(weight: 11, borrowsThread: true) { input! }
        try pipeline.submit(input, tag: 0, weight: 7) { _, _ in XCTFail("early emit") }
        input = nil
        XCTAssertNotNil(captured)
        pipeline.abandonAndWait()
        XCTAssertNil(captured)
        XCTAssertEqual(pipeline.pendingInputBytes, 0)
        XCTAssertEqual(pipeline.pendingCount, 0)
    }

    func testCancellationBeforeTakeDoesNotClaimQueuedWork() throws {
        let queue = DispatchQueue(label: "test.inline.cancel", attributes: .concurrent)
        queue.suspend()
        defer { queue.resume(); queue.sync(flags: .barrier) {} }
        let cancellation = CompressionCancellation()
        let pipeline = OrderedChunkPipeline<Int, Int, Int>(threads: 2, cancellation: cancellation, queue: queue) { _ in
            XCTFail("cancelled encoder ran")
            return 0
        }
        try pipeline.submit(0, tag: 0) { _, _ in XCTFail("early emit") }
        cancellation.cancel()
        XCTAssertThrowsError(try pipeline.finish { _, _ in XCTFail("cancelled emit") }) {
            XCTAssertTrue($0 is CancellationError)
        }
        pipeline.abandonAndWait()
        XCTAssertEqual(pipeline.pendingCount, 0)
    }
}
