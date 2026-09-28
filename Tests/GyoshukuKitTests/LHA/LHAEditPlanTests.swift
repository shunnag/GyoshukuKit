import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class LHAEditPlanTests: XCTestCase {
    func testMergingOffsetsBoundariesAndFreshTerminator() throws {
        let root = try TestSupport.directory("lha-plan")
        let url = try LHAUpdateSupport.generated(root)
        let (layout, _, _) = try LHAUpdateSupport.scan(url)
        let unchanged = try LHAEditPlan.make(layout: layout, removed: [], renamed: [:])
        XCTAssertEqual(unchanged.prefix.count, 1)
        XCTAssertTrue(unchanged.terminal.isEmpty)
        XCTAssertTrue(unchanged.boundaries.isEmpty)
        let removed = try LHAEditPlan.make(layout: layout, removed: [1, 3], renamed: [:])
        XCTAssertEqual(removed.prefix.count, 3)
        XCTAssertEqual(removed.boundaries.count, 3)
        XCTAssertNil(removed.memberOffsets[1])
        XCTAssertNil(removed.memberOffsets[3])
        XCTAssertEqual(removed.terminal, Data([0]))
        let all = try LHAEditPlan.make(layout: layout, removed: Set(0..<6), renamed: [:])
        XCTAssertTrue(all.prefix.isEmpty)
        XCTAssertEqual(all.membersEnd, 0)
        let header = try LHARecords.Entry(name: "renamed", mode: 0o100644, size: 513, date: TestSupport.date).header(method: "-lh5-", packedSize: 513, crc: 0)
        let renamed = try LHAEditPlan.make(layout: layout, removed: [], renamed: [2: header], additionLength: 1)
        XCTAssertEqual(renamed.prefix.count, 3)
        XCTAssertEqual(renamed.changed.count, 1)
        XCTAssertEqual(renamed.boundaries.count, 1)
    }
}
