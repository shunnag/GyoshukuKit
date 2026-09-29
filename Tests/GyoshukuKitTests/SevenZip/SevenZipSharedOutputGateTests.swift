import Foundation
import XCTest
@testable import GyoshukuKit

final class SevenZipSharedOutputGateTests: XCTestCase {
    func testIdenticalScratchPrefixIsNotWrittenTwice() throws {
        let root = try TestSupport.directory("p5-generated-prefix-gate")
        let source = root.appendingPathComponent("source.bin")
        let path = root.appendingPathComponent("output.bin")
        try Data(count: 64).write(to: source)
        let snapshot = try ArchiveSourceSnapshot(url: source, directory: root,
                                                 pathExtension: "bin", disablesClone: true)
        let output = SplicedArchiveOutput(snapshot: snapshot, output: path,
                                          pathExtension: "bin", sequential: true)
        let scratch = try output.makeScratch(tag: "reencode")
        try scratch.append(Data([1, 2, 3, 4]))
        let prefix: [SplicedSegment] = [
            .literal(length: 32, bytes: { Data(count: 32) }),
            .scratch(scratch, 0..<4)
        ]
        let handle = try output.beginAppend(at: 36, prefix: prefix)
        try handle.write(contentsOf: Data([5, 6]))
        try handle.close()
        let plan = SplicedCommitPlan(prefix: prefix, appended: 36..<38,
            terminal: Data([7]), finalLength: 39,
            finalPatch: (offset: 0, bytes: Data(repeating: 9, count: 32)),
            formatVerificationUnits: 0)
        let writes = IOEvents()
        let units = output.units(for: plan)
        let meter = CommitProgressMeter(total: units, progress: nil)
        let strategy = try ZipCopyEngine.$writeObserver.withValue(writes.write) {
            try output.commit(plan, meter: meter) { _, _ in }
        }
        print("7Z-GATE strategy=\(strategy) units=\(units) commitWritten=\(writes.bytes)")
        XCTAssertEqual(try Data(contentsOf: path), Data(repeating: 9, count: 32) + Data([1, 2, 3, 4, 5, 6, 7]))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source.bin", "output.bin"])
        XCTAssertEqual(strategy, .sequential, "Unchanged scratch prefix must not relocate the appended block")
        XCTAssertEqual(units, 33, "Only terminal and finalPatch remain after beginAppend")
        XCTAssertEqual(writes.bytes, 33, "Prefix was already written during beginAppend")
    }
}
