import Foundation
import XCTest
@testable import GyoshukuKit

/// 改名で旧名の予約を外し新名を予約する `EditPathReservations` の経過時間を、1,000〜4,000 entry の ZIP と tar で測る。
/// 内容の検査は既定の試験 `EditPathReservationsTests.testBulkRenamesAfterAddingPreserveEveryPayloadAndReleaseOldPaths` が行う。
// 旧名: ArchiveEditingScaleTests（既定の試験の中で時間も assert していた）
final class EditPathReservationScaleProbeTests: XCTestCase {
    func testBulkRenameReservationTiming() throws {
        try OptInGate.flag("GYOSHUKU_SCALE_PROBES")
        let root = try TestSupport.directory("edit-reservation-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        ScaleProbe.report(tag: "EDIT-RESERVATION-SCALE", columns: ["format", "entries", "rename_ms", "limit_ms"])
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar] {
            for count in [1_000, 2_000, 4_000] {
                let (editor, elapsed) = try EditPathReservationsTests.bulkRename(root.appendingPathComponent("\(format)-\(count)"),
                                                                                  format: format, count: count)
                try editor.commit()
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                ScaleProbe.report(tag: "EDIT-RESERVATION-SCALE", columns: ["\(format)", "\(count)", String(format: "%.3f", seconds * 1000), "2000"])
                ScaleProbe.threshold(seconds, limit: 2, "\(format), \(count) entries")
            }
        }
    }
}
