import Foundation
import XCTest
import GyoshukuKit

// 公開 API だけを使い、基準の commit の展開先へそのままコピーして比較する。そのため Support/ の `OptInGate` と
// `ScaleProbe` を使わず、同じ skip の文面と同じ行の形式（tag と列を tab で区切り stderr へ）をここに書く。
final class ZipUpdaterScaleProbeTests: XCTestCase {
    func testScale() throws {
        guard let value = ProcessInfo.processInfo.environment["GYOSHUKU_ZIP_SCALE_ENTRIES"], let count = Int(value), count > 1 else {
            throw XCTSkip("Set GYOSHUKU_ZIP_SCALE_ENTRIES=<count ≥ 2> to run ZipUpdaterScaleProbeTests; see Tests/README.md")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyoshuku-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.zip")
        let date = Date(timeIntervalSince1970: 1_700_000_001)
        let writer = try ArchiveWriter.create(url: fixture, options: .init(compressionMethod: .stored))
        for index in 0..<count { try writer.add(data: Data([1]), as: String(format: "entry-%06d.txt", index), modificationDate: date) }
        try writer.finish()
        for operation in ["delete_start", "delete_end", "rename_same_length", "replace_file", "add_file", "new_folder", "rename_1000"] {
            let url = directory.appendingPathComponent(operation + ".zip")
            try FileManager.default.copyItem(at: fixture, to: url)
            let start = DispatchTime.now().uptimeNanoseconds
            let updater = try ArchiveUpdater.open(url: url, options: .init(compressionMethod: .stored))
            let opened = DispatchTime.now().uptimeNanoseconds
            var removed = opened
            switch operation {
            case "delete_start": try updater.remove(entriesAt: [0]); removed = DispatchTime.now().uptimeNanoseconds
            case "delete_end": try updater.remove(entriesAt: [count - 1]); removed = DispatchTime.now().uptimeNanoseconds
            case "rename_same_length": try updater.rename(entryAt: 0, to: "other-000000.txt")
            case "add_file": try updater.add(data: Data([2]), as: "added.txt", modificationDate: date)
            case "new_folder": try updater.addDirectory("new-folder", modificationDate: date, ownerIDs: nil)
            case "rename_1000":
                for index in 0..<min(1_000, count) {
                    try updater.rename(entryAt: index, to: String(format: "other-%06d.txt", index))
                }
            default:
                try updater.remove(entriesAt: [0]); removed = DispatchTime.now().uptimeNanoseconds
                try updater.add(data: Data([2]), as: "entry-000000.txt", modificationDate: date)
            }
            let mutated = DispatchTime.now().uptimeNanoseconds
            try updater.commit()
            let ended = DispatchTime.now().uptimeNanoseconds
            func ms(_ delta: UInt64) -> String { String(format: "%.3f", Double(delta) / 1_000_000) }
            let row = ["ZIP-SCALE", "entries=\(count)", "operation=\(operation)", "open_ms=\(ms(opened-start))", "remove_ms=\(ms(removed-opened))",
                       "mutate_ms=\(ms(mutated-opened))", "commit_ms=\(ms(ended-mutated))"]
            FileHandle.standardError.write(Data((row.joined(separator: "\t") + "\n").utf8))
        }
    }
}
