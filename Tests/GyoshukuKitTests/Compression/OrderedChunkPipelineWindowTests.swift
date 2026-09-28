import Foundation
import Synchronization
import XCTest
@testable import GyoshukuKit

final class OrderedChunkPipelineWindowTests: XCTestCase {
    private struct Activity {
        var heavy = 0, light = 0, maximumHeavy = 0, maximumTotal = 0
    }

    func testAlternatingWeightsUseHeavyWindowAndPreserveOrder() async throws {
        for limit: UInt64 in [0, 64] {
            let activity = Mutex(Activity())
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let initialCount = limit == 0 ? 4 : 8
            let task = Task.detached {
                let pipeline = OrderedChunkPipeline<Int, Int, Int>(threads: 4, lightWeightLimit: limit) { index in
                    let heavy = index % 2 == 1
                    activity.withLock {
                        if heavy { $0.heavy += 1 } else { $0.light += 1 }
                        $0.maximumHeavy = max($0.maximumHeavy, $0.heavy)
                        $0.maximumTotal = max($0.maximumTotal, $0.heavy + $0.light)
                    }
                    defer { activity.withLock { if heavy { $0.heavy -= 1 } else { $0.light -= 1 } } }
                    if index < initialCount {
                        started.signal()
                        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                    }
                    if heavy { Thread.sleep(forTimeInterval: 0.01) }
                    return index
                }
                var emitted: [Int] = [], maximumPending = 0
                let emit: (Int, Int?) -> Void = { tag, value in
                    XCTAssertEqual(value, tag)
                    emitted.append(tag)
                }
                for index in 0..<32 {
                    try pipeline.submit(index, tag: index, weight: index % 2 == 0 ? 64 : 65, emit: emit)
                    maximumPending = max(maximumPending, index + 1 - emitted.count)
                }
                try pipeline.finish(emit: emit)
                return (emitted, maximumPending)
            }
            defer { for _ in 0..<initialCount { release.signal() } }
            for _ in 0..<initialCount { try await LZMA2ChunkPipelineTests.wait(started) }
            XCTAssertEqual(activity.withLock { $0.heavy }, limit == 0 ? 2 : 4)
            for _ in 0..<initialCount { release.signal() }
            let (emitted, pending) = try await task.value
            XCTAssertEqual(emitted, Array(0..<32))
            XCTAssertLessThanOrEqual(pending, limit == 0 ? 4 : 9)
            XCTAssertEqual(activity.withLock { $0.maximumHeavy }, limit == 0 ? 2 : 4)
            XCTAssertLessThanOrEqual(activity.withLock { $0.maximumTotal }, limit == 0 ? 4 : 9)
            XCTAssertEqual(activity.withLock { $0.heavy + $0.light }, 0)
        }
    }

    func testAllLightItemsAreBoundedAndZeroWeightRemainsHeavy() async throws {
        for weight: UInt64 in [0, 64] {
            let capacity = weight == 0 ? 4 : 9
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let atCapacity = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
            let task = Task.detached {
                let pipeline = OrderedChunkPipeline<Int, Int, Int>(threads: 4, lightWeightLimit: 64) { index in
                    started.signal()
                    if index < capacity { XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
                    return index
                }
                var emitted: [Int] = []
                for index in 0..<capacity {
                    try pipeline.submit(index, tag: index, weight: weight) { tag, _ in emitted.append(tag) }
                }
                atCapacity.signal()
                try pipeline.submit(capacity, tag: capacity, weight: weight) { tag, _ in emitted.append(tag) }
                returned.signal()
                try pipeline.finish { tag, _ in emitted.append(tag) }
                return emitted
            }
            defer { for _ in 0..<capacity { release.signal() } }
            for _ in 0..<capacity { try await LZMA2ChunkPipelineTests.wait(started) }
            try await LZMA2ChunkPipelineTests.wait(atCapacity)
            try await Task.sleep(for: .milliseconds(75))
            XCTAssertEqual(returned.wait(timeout: .now()), .timedOut)
            XCTAssertEqual(started.wait(timeout: .now()), .timedOut)
            for _ in 0..<capacity { release.signal() }
            let emitted = try await task.value
            XCTAssertEqual(emitted, Array(0...capacity))
        }
    }

    func testCancellationAndFailureAbandonExpandedWindow() async throws {
        for cancel in [false, true] {
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let fail = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
            let task = Task.detached {
                let pipeline = OrderedChunkPipeline<Int, Int, Int>(threads: 2, lightWeightLimit: 64) { index in
                    started.signal()
                    defer { completed.signal() }
                    if !cancel && index == 0 {
                        XCTAssertEqual(fail.wait(timeout: .now() + 5), .success)
                        throw WriterError.compression(-77)
                    }
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                    return index
                }
                do {
                    for index in 0..<6 {
                        try pipeline.submit(index, tag: index, weight: 1) { _, _ in XCTFail("unexpected output") }
                    }
                    XCTFail("full window did not wait")
                } catch {
                    if cancel { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? WriterError, .compression(-77)) }
                }
                XCTAssertThrowsError(try pipeline.finish { _, _ in XCTFail("abandoned output") })
                pipeline.abandon()
            }
            defer { fail.signal(); for _ in 0..<5 { release.signal() } }
            for _ in 0..<5 { try await LZMA2ChunkPipelineTests.wait(started) }
            if cancel { task.cancel() } else { fail.signal() }
            try await task.value
            for _ in 0..<5 { release.signal() }
            for _ in 0..<5 { try await LZMA2ChunkPipelineTests.wait(completed) }
        }
    }
}
