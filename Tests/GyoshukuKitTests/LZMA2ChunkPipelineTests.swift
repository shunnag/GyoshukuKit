import Foundation
import XCTest
@testable import GyoshukuKit

final class LZMA2ChunkPipelineTests: XCTestCase {
    func testLightWeightsAreForwardedWithChecksumsAndOrderedMarkers() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let pipeline = LZMA2ChunkPipeline<Int>(threads: 2, checksum: true, lightWeightLimit: 64) { input in
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return Self.result(input)
            }
            var emitted: [Int] = []
            let emit: (Int, LZMA2ChunkPipeline<Int>.Output?) -> Void = { tag, output in
                if tag == 4 { XCTAssertNil(output) }
                else { XCTAssertEqual(output?.crc, updateCRC(0, Data([UInt8(tag)]))) }
                emitted.append(tag)
            }
            for index in 0..<4 { try pipeline.submit(Data([UInt8(index)]), tag: index, weight: 1, emit: emit) }
            try pipeline.submit(nil, tag: 4, emit: emit)
            try pipeline.finish(emit: emit)
            return emitted
        }
        defer { for _ in 0..<4 { release.signal() } }
        for _ in 0..<4 { try await Self.wait(started) }
        for _ in 0..<4 { release.signal() }
        let emitted = try await task.value
        XCTAssertEqual(emitted, Array(0..<5))
    }

    func testCompletedJobsRemainBoundedAndMarkersKeepSubmissionOrder() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let laterFinished = DispatchSemaphore(value: 0)
        let submitting = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let pipeline = LZMA2ChunkPipeline<Int>(threads: 3) { input in
                started.signal()
                if input.first == 0 { release.wait() } else { laterFinished.signal() }
                return Self.result(input)
            }
            var emitted: [Int] = []
            for index in 0..<3 {
                try pipeline.submit(Data([UInt8(index)]), tag: index) { tag, _ in emitted.append(tag) }
            }
            submitting.signal()
            try pipeline.submit(nil, tag: 3) { tag, _ in emitted.append(tag) }
            returned.signal()
            try pipeline.submit(Data([4]), tag: 4) { tag, _ in emitted.append(tag) }
            try pipeline.finish { tag, result in
                if tag == 3 { XCTAssertNil(result) }
                emitted.append(tag)
            }
            return emitted
        }
        defer { release.signal() }
        for _ in 0..<3 { try await Self.wait(started) }
        for _ in 0..<2 { try await Self.wait(laterFinished) }
        try await Self.wait(submitting)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(returned.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(started.wait(timeout: .now()), .timedOut)
        release.signal()
        let emitted = try await task.value
        XCTAssertEqual(emitted, [0, 1, 2, 3, 4])
    }

    func testErrorWaitsForItsTurnAndAbandonsLaterResults() async throws {
        let failed = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let pipeline = LZMA2ChunkPipeline<Int>(threads: 3) { input in
                if input.first == 0 {
                    release.wait()
                    return Self.result(input)
                }
                failed.signal()
                throw WriterError.compression(-77)
            }
            var emitted: [Int] = []
            try pipeline.submit(Data([0]), tag: 0) { tag, _ in emitted.append(tag) }
            try pipeline.submit(Data([1]), tag: 1) { tag, _ in emitted.append(tag) }
            try pipeline.submit(nil, tag: 2) { tag, _ in emitted.append(tag) }
            XCTAssertThrowsError(try pipeline.finish { tag, _ in emitted.append(tag) }) {
                XCTAssertEqual($0 as? WriterError, .compression(-77))
            }
            XCTAssertThrowsError(try pipeline.finish { _, _ in XCTFail("abandoned result") })
            return emitted
        }
        defer { release.signal() }
        try await Self.wait(failed)
        release.signal()
        let emitted = try await task.value
        XCTAssertEqual(emitted, [0])
    }

    func testAbandonAndDeinitDoNotWaitForRunningWork() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        var pipeline: LZMA2ChunkPipeline<Int>? = LZMA2ChunkPipeline(threads: 1) { input in
            started.signal()
            release.wait()
            defer { completed.signal() }
            return Self.result(input)
        }
        weak var weakPipeline: LZMA2ChunkPipeline<Int>?
        weakPipeline = pipeline
        try pipeline!.submit(Data([1]), tag: 1) { _, _ in XCTFail("unexpected emission") }
        defer { release.signal() }
        try await Self.wait(started)
        pipeline!.abandon()
        pipeline = nil
        XCTAssertNil(weakPipeline)
        XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
        release.signal()
        try await Self.wait(completed)
    }

    private static func result(_ input: Data) -> XZLZMA2 {
        XZLZMA2(payload: input + Data([0]), properties: 0, uncompressedSize: UInt64(input.count), payloadOffset: 0)
    }

    static func wait(_ semaphore: DispatchSemaphore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !hasSignal(semaphore) {
            guard ContinuousClock.now < deadline else {
                XCTFail("worker did not reach the expected stage")
                throw CocoaError(.executableRuntimeMismatch)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func hasSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }
}
