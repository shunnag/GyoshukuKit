import Foundation
import XCTest
@testable import GyoshukuKit

final class ConcurrentWriterStarvationTests: XCTestCase {
    // 全taskが揃ってから同期writerへ進み、cooperative threadを同時に使う。
    private actor StartGate {
        let count: Int
        var waiting: [CheckedContinuation<Void, Never>] = []
        init(_ count: Int) { self.count = count }

        func arrive() async {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if waiting.count == count {
                    let ready = waiting
                    waiting.removeAll()
                    for continuation in ready { continuation.resume() }
                }
            }
        }
    }

    func testConcurrentZIPDeflateWriters() async throws {
        try await Self.check(format: .zip, options: .init(useCompressionHeuristic: false, compressionThreads: 2))
    }

    func testConcurrentSevenZipLZMA2Writers() async throws {
        // 速さ優先の2 MiB境界を使い、公開APIでも三片を同じpipelineへ投入する。
        try await Self.check(format: .sevenZip, options: .init(prefersSpeed: true, compressionThreads: 2))
    }

    private static func check(format: ArchiveFormat, options: WriterOptions) async throws {
        let count = max(12, 2 * ProcessInfo.processInfo.activeProcessorCount)
        let root = try TestSupport.directory("concurrent-writer-starvation-\(format)")
        let seed = TestCorpus.random(16 << 10) + Data(repeating: 65, count: 48 << 10)
        var input = Data()
        while input.count < (4 << 20) + 137 { input.append(seed) }
        let payload = Data(input.prefix((4 << 20) + 137))
        let gate = StartGate(count)
        // swift testが出力を保留しても、hang中のxctestをsampleできるようPIDを残す。
        try String(ProcessInfo.processInfo.processIdentifier).write(to: root.appendingPathComponent("xctest.pid"),
                                                                   atomically: true, encoding: .utf8)
        TestSupport.report("CONCURRENT WRITERS: \(format), \(count) tasks, \(ProcessInfo.processInfo.activeProcessorCount) active CPUs")
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<count {
                group.addTask {
                    await gate.arrive()
                    // awaitや別queueを挟まず、taskのcooperative thread上で完了まで書く。
                    try write(root.appendingPathComponent("\(index)"), format: format, options: options, payload: payload)
                    return 1
                }
            }
            var completed = 0
            for try await value in group { completed += value }
            return completed
        }
        XCTAssertEqual(completed, count)
        var serialOptions = options; serialOptions.compressionThreads = 1
        let serial = root.appendingPathComponent("serial")
        try write(serial, format: format, options: serialOptions, payload: payload)
        let expected = try Data(contentsOf: serial)
        for index in 0..<count {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(index)")), expected, "writer=\(index)")
        }
        try TestSupport.assertKaitoKitRoundTrip(root.appendingPathComponent("0"), expected: [.init(name: "mixed.bin", data: payload)])
    }

    private static func write(_ url: URL, format: ArchiveFormat, options: WriterOptions, payload: Data) throws {
        let writer = try ArchiveWriter.create(url: url, format: format, options: options)
        try writer.add(data: payload, as: "mixed.bin", modificationDate: TestSupport.date)
        try writer.finish()
    }
}
