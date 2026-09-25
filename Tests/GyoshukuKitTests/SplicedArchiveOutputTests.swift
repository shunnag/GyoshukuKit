import Foundation
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class SplicedArchiveOutputTests: XCTestCase {
    private func setup(_ label: String, sequential: Bool) throws -> (URL, URL, SplicedArchiveOutput) {
        let root = try ZipTestSupport.directory("p2-output-" + label)
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
            try first.append(Data([3, 4]))
            XCTAssertEqual(try first.source().bytes(at: 0, count: 2), Data([3, 4]))
            let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".gyoshuku-test-") })
            try FileManager.default.removeItem(at: original)
            try Data([77]).write(to: original)
            XCTAssertEqual(try first.source().bytes(at: 0, count: 2), Data([3, 4]))
            _ = try output.makeScratch(tag: "owned")
            if finish {
                _ = try commit(output, .init(prefix: [.source(0..<100)], appended: nil, terminal: Data(), finalLength: 100, formatVerificationUnits: 0))
            } else if action == 2 {
                XCTAssertThrowsError(try commit(output, .init(prefix: [.literal(length: 2, bytes: { Data([1]) })],
                                                               appended: nil, terminal: Data(), finalLength: 2, formatVerificationUnits: 0)))
            } else { output.discard() }
            XCTAssertEqual(try Data(contentsOf: original), Data([77]))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".gyoshuku-owned-") })
        }
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
