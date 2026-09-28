import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class TarEditPlanTests: XCTestCase {
    func testContiguousSourcesMergeAndHeaderOnlyPatches() throws {
        let root = try TestSupport.directory("p2-plan")
        let source = try TarP2Support.fixture(root)
        let (layout, disk, reader) = try TarP2Support.scan(source)
        let plan = try TarEditPlan.make(layout: layout, source: disk, names: reader.entries.map(\.name), rawNames: reader.entries.map { Data($0.rawName.bytes) },
                                        hardLinkTargets: [:], dataTargets: [:], removed: [2], renamed: [4: "new"])
        XCTAssertEqual(plan.changed.count, 1)
        XCTAssertEqual(plan.prefix.count, 4)
        XCTAssertEqual(plan.unitOffsets[2], nil)
        XCTAssertEqual(plan.membersEnd, layout.membersEnd - (layout.member(2).paddedEnd - layout.member(2).groupStart))
    }
}
