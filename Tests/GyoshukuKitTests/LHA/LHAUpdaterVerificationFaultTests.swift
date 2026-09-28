import Foundation
import Darwin
import KaitoKit
import XCTest
import Synchronization
@_spi(Testing) @testable import GyoshukuKit

final class LHAUpdaterVerificationFaultTests: XCTestCase {
    func testV1ThroughV5RejectFaultsAndCleanUp() throws {
        for stage in 1...5 {
            let root = try TestSupport.directory("lha-fault-\(stage)"), source = try LHAUpdateSupport.generated(root)
            let before = try Data(contentsOf: source), work = try TestSupport.work(in: root)
            let editor = try LHAUpdater.open(url: source, output: work.appendingPathComponent("out.lzh"))
            let fault: LHAUpdater.Fault
            switch stage {
            case 1: try editor.rename(entryAt: 2, to: "edit-000002"); fault = .corruptWrittenHeader
            case 2: try editor.remove(entriesAt: [5]); fault = .shiftSourceSegment
            case 3: try editor.add(data: Data([1, 2, 3]), as: "added"); fault = .corruptAppendedPayload
            case 4: try editor.remove(entriesAt: [5]); fault = .dropTerminator
            default: try editor.remove(entriesAt: [0]); fault = .flipWrittenByte(100)
            }
            try LHAUpdater.$testingFault.withValue(fault) {
                XCTAssertThrowsError(try editor.commit()) {
                    guard case UpdaterRouteError.outputVerificationFailed(let reason) = $0 else { return XCTFail("\($0)") }
                    XCTAssertTrue(reason.contains("V\(stage)"), reason)
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }
}
