import Foundation
import Synchronization
import XCTest
@testable import GyoshukuKit

final class LZMAMultithreadedFinderTests: XCTestCase {
    private func encode(_ input: Data, properties: LZMAEncoderProperties, width: Int,
                        threads: Int, finishWithLastPush: Bool = false, unknownSize: Bool = false) throws -> Data {
        let encoder = try LZMAEncoder(properties: properties,
            expectedSize: unknownSize ? nil : UInt64(input.count), finderThreads: threads)
        var output = Data()
        for start in stride(from: 0, to: input.count, by: width) {
            let end = min(input.count, start + width)
            output.append(try encoder.push(input.subdata(in: start..<end)))
            if finishWithLastPush && end == input.count { output.append(try encoder.finish()) }
        }
        if !finishWithLastPush || input.isEmpty { output.append(try encoder.finish()) }
        return output
    }

    func testBT4AndHC4RecordAndSkipHaveIdenticalState() throws {
        let text = LZMAEncoderCorpus.text(size: 8192)
        let input = text + TestCorpus.random(4096) + Data(repeating: 65, count: 4096) + text
        let a = try lzmaAllocate(LZMAMatch.self, count: 274)
        let b = try lzmaAllocate(LZMAMatch.self, count: 274)
        let c = try lzmaAllocate(LZMAMatch.self, count: 274)
        defer { free(a); free(b); free(c) }
        for level in 0...9 {
            for extreme in [false, true] {
                var properties = LZMAEncoderProperties.preset(level, extreme: extreme)
                properties.dictSize = 4096
                var full = try LZMAMatchFinder(properties: properties, dictionary: 4096)
                var skipping = try LZMAMatchFinder(properties: properties, dictionary: 4096)
                var deferred = try LZMAMatchFinder(properties: properties, dictionary: 4096)
                defer { full.release(); skipping.release(); deferred.release() }
                input.withUnsafeBytes { bytes in
                    let data = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    for position in 0..<input.count {
                        // 可変長のskipと末尾のavailable=1...273を含む。
                        let record = position % 301 < 17
                        let n = full.matches(data + position, available: input.count - position, into: a)
                        let m = skipping.matches(data + position, available: input.count - position, into: b, record: record)
                        var k = deferred.matches(data + position, available: input.count - position, into: c,
                            extendMatches: false, recordShortMatches: !deferred.tree)
                        if deferred.tree {
                            k = deferred.finalizeTreeMatches(data + position, available: input.count - position, result: c, count: k)
                        } else if k > 0 { deferred.extend(data + position, available: input.count - position, result: c, count: k) }
                        XCTAssertEqual(n, k)
                        for i in 0..<n {
                            XCTAssertEqual(a[i].length, c[i].length)
                            XCTAssertEqual(a[i].distance, c[i].distance)
                        }
                        if record {
                            XCTAssertEqual(n, m)
                            for i in 0..<n {
                                XCTAssertEqual(a[i].length, b[i].length)
                                XCTAssertEqual(a[i].distance, b[i].distance)
                            }
                        }
                    }
                }
                XCTAssertEqual(full.position, skipping.position)
                XCTAssertEqual(full.cyclic, skipping.cyclic)
                XCTAssertEqual(memcmp(full.hash, skipping.hash, full.hashCount * 4), 0)
                XCTAssertEqual(memcmp(full.son, skipping.son, full.cyclicSize * (full.tree ? 8 : 4)), 0)
                XCTAssertEqual(memcmp(full.hash, deferred.hash, full.hashCount * 4), 0)
                XCTAssertEqual(memcmp(full.son, deferred.son, full.cyclicSize * (full.tree ? 8 : 4)), 0)
            }
        }
    }

    func testAllPresetsCorporaAndPushWidthsKeepByteIdentity() throws {
        let binary = try Data(contentsOf: Bundle(for: Self.self).executableURL!).prefix(8209)
        let inputs = [Data(), Data([0xA7]), LZMAEncoderCorpus.text(size: 8209), Data(binary),
                      TestCorpus.random(8209), Data(repeating: 65, count: 8209), LZMAEncoderCorpus.mixed(size: 8209)]
        for level in 0...9 {
            for extreme in [false, true] {
                var properties = LZMAEncoderProperties.preset(level, extreme: extreme)
                for dictionary in [4096, 1 << 20] {
                    properties.dictSize = dictionary
                    for (index, input) in inputs.enumerated() {
                        for width in [1, 7, 4096, 65537, 262144] {
                            let expected = try encode(input, properties: properties, width: width, threads: 1, unknownSize: true)
                            let actual = try encode(input, properties: properties, width: width, threads: 2,
                                finishWithLastPush: index.isMultiple(of: 2), unknownSize: true)
                            XCTAssertEqual(actual, expected, "level=\(level), extreme=\(extreme), dict=\(dictionary), corpus=\(index), width=\(width)")
                        }
                    }
                }
            }
        }
    }

    func testEveryPresetCompactsBeyondTwoWindows() throws {
        for dictionary in [4096, 1 << 20] {
            let window = dictionary + LZMAEncodingEngine.windowSlack(dictionary: dictionary)
                + LZMAEncodingEngine.lookahead + 65536
            let input = LZMAEncoderCorpus.mixed(size: 2 * window + 777)
            for level in 0...9 {
                for extreme in [false, true] {
                    var properties = LZMAEncoderProperties.preset(level, extreme: extreme)
                    properties.dictSize = dictionary
                    let expected = try encode(input, properties: properties, width: 65537, threads: 1, unknownSize: true)
                    let actual = try encode(input, properties: properties, width: 65537, threads: 2,
                        finishWithLastPush: extreme, unknownSize: true)
                    XCTAssertEqual(actual, expected, "dict=\(dictionary), level=\(level), extreme=\(extreme)")
                }
            }
        }
    }

    func testLookaheadFinishAndCompactionAtSmallAndLargeDictionaries() throws {
        for dictionary in [4096, 1 << 20] {
            for level in [0, 3, 6] {
                var properties = LZMAEncoderProperties.preset(level)
                properties.dictSize = dictionary
                let window = dictionary + LZMAEncodingEngine.windowSlack(dictionary: dictionary)
                    + LZMAEncodingEngine.lookahead + 65536
                let large = LZMAEncoderCorpus.mixed(size: 2 * window + 777)
                for (index, size) in [3, 272, 273, 274, 4368, 4369, 4370, 65535, 65536, 65537, large.count].enumerated() {
                    let input = Data(large.prefix(size))
                    // 全widthは小入力の全preset試験で網羅し、compactも全widthで検査する。
                    let widths = size == large.count ? [1, 7, 4096, 65537, 262144] : [7, 65537]
                    for width in widths {
                        let expected = try encode(input, properties: properties, width: width, threads: 1, unknownSize: true)
                        let actual = try encode(input, properties: properties, width: width, threads: 2,
                            finishWithLastPush: index.isMultiple(of: 2), unknownSize: true)
                        XCTAssertEqual(actual, expected, "dict=\(dictionary), level=\(level), size=\(size), width=\(width)")
                    }
                }
            }
        }
    }

    func testCancellationDuringFindingJoinsWithinTwoSeconds() async throws {
        let started = DispatchSemaphore(value: 0)
        let live = Mutex(0)
        let input = LZMAEncoderCorpus.text(size: 8 << 20)
        let task = Task.detached {
            try LZMAMatchFinderPipeline.$testingWorkerActivity.withValue({ active in live.withLock { $0 += active ? 1 : -1 } }) {
                try LZMAMatchFinderPipeline.$testingDidFindBlock.withValue({ started.signal() }) {
                    let encoder = try LZMAEncoder(finderThreads: 2)
                    do {
                        _ = try encoder.push(input)
                        _ = try encoder.finish()
                    } catch {
                        // errorを返した時点で、encoderを保持していてもThreadはjoin済み。
                        XCTAssertEqual(live.withLock { $0 }, 0)
                        throw error
                    }
                }
            }
        }
        try await LZMA2ChunkPipelineTests.wait(started)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { try await task.value; XCTFail("取消しが成功した") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(live.withLock { $0 }, 0)
    }

    func testErrorsAbandonAndMemoryLimitReleaseWorkers() throws {
        let live = Mutex(0)
        try LZMAMatchFinderPipeline.$testingWorkerActivity.withValue({ active in live.withLock { $0 += active ? 1 : -1 } }) {
            for _ in 0..<20 {
                let encoder = try LZMAEncoder(expectedSize: 10000, finderThreads: 2)
                _ = try encoder.push(Data(repeating: 65, count: 9999))
                XCTAssertThrowsError(try encoder.finish()) { XCTAssertTrue($0 is LZMAEncodingError) }
                XCTAssertEqual(live.withLock { $0 }, 0)
            }
            var encoder: LZMAEncoder? = try LZMAEncoder(finderThreads: 2)
            _ = try encoder!.push(TestCorpus.random(65537))
            encoder = nil
            XCTAssertEqual(live.withLock { $0 }, 0)
            // 逐次APIと同じく、サイズ検査で拒否した入力・早すぎるfinishの後は再試行できる。
            let retry = try LZMAEncoder(expectedSize: 65537, finderThreads: 2)
            let input = TestCorpus.random(65537)
            var output = try retry.push(input.prefix(65536))
            XCTAssertThrowsError(try retry.push(Data([1, 2])))
            XCTAssertEqual(live.withLock { $0 }, 0)
            XCTAssertThrowsError(try retry.finish())
            output.append(try retry.push(input.suffix(1)))
            output.append(try retry.finish())
            XCTAssertEqual(output, try LZMAEncoder.encode(input))
            XCTAssertEqual(live.withLock { $0 }, 0)
            let p = LZMAEncoderProperties.preset(6)
            let memory = LZMAEncodingEngine.memorySize(properties: p, dictionary: p.dictSize, finderThreads: 2)
            XCTAssertThrowsError(try LZMAEncoder(memoryLimit: memory - 1, finderThreads: 2))
            XCTAssertEqual(live.withLock { $0 }, 0)
        }
    }
}
