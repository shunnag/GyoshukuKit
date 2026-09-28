import Foundation
import Darwin
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class TarUpdaterVerificationFaultTests: XCTestCase {
    func testV1ThroughV5RejectCorruptionAndCleanUp() throws {
        for kind in 0..<5 {
            let root = try TestSupport.directory("p2-fault-\(kind)")
            let source = try TarP2Support.fixture(root), work = try TestSupport.work(in: root)
            let before = try Data(contentsOf: source)
            let output = work.appendingPathComponent("out.tar")
            let editor = try TarUpdater.open(url: source, output: output)
            let fault: TarUpdater.Fault
            switch kind {
            case 0: try editor.rename(entryAt: 0, to: "new"); fault = .corruptWrittenHeader
            case 1: try editor.remove(entriesAt: [5]); fault = .flipWrittenByte(0)
            case 2: try editor.add(data: Data([1]), as: "new"); fault = .corruptWrittenHeader
            case 3: try editor.remove(entriesAt: [5]); fault = .dropTerminatorBlock
            default: try editor.remove(entriesAt: [0]); fault = .shiftSourceSegment
            }
            try TarUpdater.$testingFault.withValue(fault) {
                XCTAssertThrowsError(try editor.commit()) {
                    guard case TarUpdaterError.outputVerificationFailed(let reason) = $0 else { return XCTFail("\($0)") }
                    if kind != 2 { XCTAssertTrue(reason.contains("V\(kind + 1)"), reason) }
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }
}
