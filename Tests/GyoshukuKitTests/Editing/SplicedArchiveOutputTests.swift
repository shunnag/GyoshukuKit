import Foundation
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class SplicedArchiveOutputTests: XCTestCase {
    private func setup(_ label: String, sequential: Bool) throws -> (URL, URL, SplicedArchiveOutput) {
        let root = try TestSupport.directory("p2-output-" + label)
        let source = root.appendingPathComponent("source.bin")
        try Data((0..<100).map(UInt8.init)).write(to: source)
        let output = root.appendingPathComponent("output.bin")
        let snapshot = try ArchiveSourceSnapshot(url: source, directory: root, pathExtension: "bin", disablesClone: sequential)
        return (root, output, SplicedArchiveOutput(snapshot: snapshot, output: output, pathExtension: "bin", sequential: sequential))
    }

    private func commit(_ output: SplicedArchiveOutput, _ plan: SplicedCommitPlan) throws -> SplicedCommitStrategy {
        let writes = ZipIOEvents(), reads = ZipIOEvents()
        var progress: [ArchiveUpdater.CommitProgress] = []
        let meter = CommitProgressMeter(total: output.units(for: plan)) { progress.append($0) }
        try meter.start()
        let result = try ZipCopyEngine.$writeObserver.withValue(writes.write) {
            try SplicedArchiveOutput.$verificationReadObserver.withValue(reads.write) {
                try output.commit(plan, meter: meter) { _, advance in try advance(plan.formatVerificationUnits) }
            }
        }
        try meter.finish()
        XCTAssertEqual(meter.total, writes.bytes + reads.bytes + plan.formatVerificationUnits)
        XCTAssertEqual(progress.first?.completedBytes, 0)
        XCTAssertEqual(progress.last?.completedBytes, meter.total)
        XCTAssertTrue(progress.allSatisfy { $0.totalBytes == meter.total })
        return result
    }

    func testUnshiftedCloneAndSequentialPrefix() throws {
        for sequential in [false, true] {
            let (_, path, output) = try setup("prefix-\(sequential)", sequential: sequential)
            let before = ZipIOEvents()
            let handle = try ZipCopyEngine.$writeObserver.withValue(before.write) {
                try output.beginAppend(at: 50, prefix: [.source(0..<50)])
            }
            XCTAssertEqual(before.bytes, sequential ? 50 : 0)
            try handle.write(contentsOf: Data([101, 102]))
            try handle.close()
            let plan = SplicedCommitPlan(prefix: [.source(0..<50)], appended: 50..<52,
                                         terminal: Data([255]), finalLength: 53, formatVerificationUnits: 13)
            XCTAssertEqual(try commit(output, plan), sequential ? .sequential : .appendOnly)
            XCTAssertEqual(try Data(contentsOf: path), Data((0..<50).map(UInt8.init)) + Data([101, 102, 255]))
        }
    }

    func testRelocationInBothModesAndChangedSameLengthPrefix() throws {
        for sequential in [false, true] {
            for sameLength in [false, true] {
                let (root, path, output) = try setup("relocate-\(sequential)-\(sameLength)", sequential: sequential)
                let handle = try output.beginAppend(at: 50, prefix: [.source(0..<50)])
                try handle.write(contentsOf: Data([201, 202]))
                try handle.close()
                let length: UInt64 = sameLength ? 50 : 30
                let plan = SplicedCommitPlan(prefix: [.source(10..<(10 + length))], appended: 50..<52,
                    terminal: Data([254]), finalLength: length + 3, formatVerificationUnits: 0)
                let result = try commit(output, plan)
                XCTAssertEqual(result, (!sameLength || sequential) ? .relocatedAppend : .splice)
                XCTAssertEqual(try Data(contentsOf: path), Data((10..<Int(10 + length)).map(UInt8.init)) + Data([201, 202, 254]))
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.bin", "output.bin"])
            }
        }
    }

    func testGeneratedLengthMismatchCleansEverything() throws {
        for count in [2, 4] {
            let (root, _, output) = try setup("generated-\(count)", sequential: true)
            let scratch = try output.makeScratch(tag: "synthetic")
            try scratch.append(Data([9]))
            let plan = SplicedCommitPlan(prefix: [.generated(length: 3, write: { try $0.write(Data(count: count)) })],
                                         appended: nil, terminal: Data(), finalLength: 3, formatVerificationUnits: 0)
            XCTAssertThrowsError(try commit(output, plan)) {
                guard case TarUpdaterError.outputVerificationFailed = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.bin"])
        }
    }

    func testScratchPrefixIdentityAndRange() throws {
        for change in 0..<3 {
            let (root, path, output) = try setup("scratch-prefix-\(change)", sequential: true)
            let first = try output.makeScratch(tag: "first")
            try first.append(Data([1, 2, 3, 4, 5]))
            let second = try output.makeScratch(tag: "second")
            try second.append(Data([1, 2, 3, 4, 5]))
            let handle = try output.beginAppend(at: 4, prefix: [.scratch(first, 0..<4)])
            try handle.write(contentsOf: Data([6]))
            try handle.close()
            // 追記は既存の範囲の byte を変えない。
            try first.append(Data([7]))
            let range: Range<UInt64> = change == 1 ? 1..<5 : 0..<4
            let plan = SplicedCommitPlan(prefix: [.scratch(change == 2 ? second : first, range)], appended: 4..<5,
                                         terminal: Data([8]), finalLength: 6, formatVerificationUnits: 0)
            XCTAssertEqual(output.units(for: plan), change == 0 ? 1 : 7)
            XCTAssertEqual(try commit(output, plan), change == 0 ? .sequential : .relocatedAppend)
            XCTAssertEqual(try Data(contentsOf: path), Data(change == 1 ? [2, 3, 4, 5, 6, 8] : [1, 2, 3, 4, 6, 8]))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.bin", "output.bin"])
        }
    }

    func testInvalidScratchRangeFailsAndCleansUp() throws {
        for atAppend in [true, false] {
            let (root, _, output) = try setup("scratch-range-\(atAppend)", sequential: true)
            let scratch = try output.makeScratch(tag: "invalid")
            try scratch.append(Data([1, 2]))
            let prefix: [SplicedSegment] = [.scratch(scratch, 1..<3)]
            XCTAssertThrowsError(try {
                if atAppend { _ = try output.beginAppend(at: 2, prefix: prefix) }
                else {
                    _ = try commit(output, .init(prefix: prefix, appended: nil, terminal: Data(), finalLength: 2,
                                                  formatVerificationUnits: 0))
                }
            }()) { XCTAssertEqual($0 as? UpdaterRouteError, .outputVerificationFailed(reason: "scratch range")) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.bin"])
        }
    }

    func testGeneratedPrefixRemainsConservative() throws {
        let (_, path, output) = try setup("generated-conservative", sequential: true)
        var calls = 0
        let prefix: [SplicedSegment] = [.generated(length: 2, write: { sink in
            calls += 1
            try sink.write(Data([3, 4]))
        })]
        let handle = try output.beginAppend(at: 2, prefix: prefix)
        try handle.write(contentsOf: Data([5]))
        try handle.close()
        let plan = SplicedCommitPlan(prefix: prefix, appended: 2..<3, terminal: Data(), finalLength: 3,
                                     formatVerificationUnits: 0)
        XCTAssertEqual(try commit(output, plan), .relocatedAppend)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try Data(contentsOf: path), Data([3, 4, 5]))
    }

    func testFinalPatchAfterFirstSyncAndGeneratedCopy() throws {
        let (_, path, output) = try setup("patch", sequential: true)
        let scratch = try output.makeScratch(tag: "generated")
        try scratch.append(Data([0, 1, 2, 3]))
        let source = try scratch.source()
        let events = Mutex<[String]>([])
        let plan = SplicedCommitPlan(prefix: [.generated(length: 4, write: { try $0.copy(0..<4, from: source) })],
            appended: nil, terminal: Data([4]), finalLength: 5, finalPatch: (0, Data([9])), formatVerificationUnits: 0)
        let meter = CommitProgressMeter(total: output.units(for: plan), progress: nil)
        try SplicedArchiveOutput.$testingDidSynchronize.withValue({ events.withLock { $0.append("sync") } }) {
            try ZipCopyEngine.$writeObserver.withValue({ offset, count in events.withLock { $0.append("write:\(offset):\(count)") } }) {
                _ = try output.commit(plan, meter: meter) { _, _ in }
            }
        }
        XCTAssertEqual(events.withLock { $0 }, ["write:0:4", "write:4:1", "sync", "write:0:1", "sync"])
        XCTAssertEqual(try Data(contentsOf: path), Data([9, 1, 2, 3, 4]))
    }

    func testScratchCleanupPreservesReplacementInode() throws {
        for action in 0..<3 {
            let finish = action == 1
            let (root, _, output) = try setup("scratch-\(action)", sequential: true)
            let first = try output.makeScratch(tag: "test")
            let fd = first.handle.fileDescriptor
            XCTAssertEqual(try first.append(Data([3, 4])), 0..<2)
            XCTAssertEqual(try first.source().bytes(at: 0, count: 2), Data([3, 4]))
            var info = stat()
            XCTAssertEqual(fstat(fd, &info), 0)
            XCTAssertEqual(info.st_nlink, 0)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.bin"])
            if finish {
                _ = try commit(output, .init(prefix: [.source(0..<100)], appended: nil, terminal: Data(), finalLength: 100, formatVerificationUnits: 0))
            } else if action == 2 {
                XCTAssertThrowsError(try commit(output, .init(prefix: [.literal(length: 2, bytes: { Data([1]) })],
                                                               appended: nil, terminal: Data(), finalLength: 2, formatVerificationUnits: 0)))
            } else { output.discard() }
            XCTAssertEqual(fcntl(fd, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            first.close()
            XCTAssertEqual(fcntl(fd, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertEqual(Set(files), finish ? ["source.bin", "output.bin"] : ["source.bin"])
            XCTAssertFalse(files.contains { $0.hasPrefix(".gyoshuku-") })
        }
    }

    func testScratchChunkReadsAndAppendsKeepExistingBytes() throws {
        let (root, _, output) = try setup("scratch-chunks", sequential: true)
        defer { output.discard() }
        let scratch = try output.makeScratch(tag: "chunks")
        let bytes = Data(repeating: 7, count: IOChunk.size + 1)
        XCTAssertEqual(try scratch.append(bytes), 0..<UInt64(bytes.count))
        var chunks: [Data] = []
        try scratch.forEachChunk { chunks.append($0) }
        XCTAssertEqual(chunks, [Data(repeating: 7, count: IOChunk.size), Data([7])])
        XCTAssertEqual(try scratch.append(Data([8])), UInt64(bytes.count)..<UInt64(bytes.count + 1))
        XCTAssertEqual(try scratch.source().bytes(at: 0, count: bytes.count), bytes)
        chunks.removeAll()
        try scratch.forEachChunk { chunks.append($0) }
        XCTAssertEqual(chunks, [Data(repeating: 7, count: IOChunk.size), Data([7, 8])])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.bin"])
    }

    func testMeterIsMonotonicCappedAndFinishesOnceIncludingZero() throws {
        for total: UInt64 in [0, 10, 12 * 1024 * 1024] {
            var values: [ArchiveUpdater.CommitProgress] = []
            let meter = CommitProgressMeter(total: total) { values.append($0) }
            try meter.start()
            try meter.advance(5 * 1024 * 1024)
            try meter.advance(.max)
            try meter.finish()
            try meter.finish()
            XCTAssertEqual(values.first?.completedBytes, 0)
            XCTAssertEqual(values.last?.completedBytes, total)
            XCTAssertTrue(values.allSatisfy { $0.totalBytes == total && $0.completedBytes <= total })
            XCTAssertEqual(values.map(\.completedBytes), values.map(\.completedBytes).sorted())
            XCTAssertEqual(values.filter { $0.completedBytes == total }.count, total == 0 ? 2 : 1)
        }
    }
}
