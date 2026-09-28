import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarRepeatEditTests: XCTestCase {
    func testFiftySeededEditsUsingAdoptedAndReopenedSnapshots() throws {
        for format in CompressedTarTestSupport.formats {
            let root = try TestSupport.directory("p3-repeat-\(format)")
            var current = try CompressedTarTestSupport.fixture(root, format)
            var plainURL = root.appendingPathComponent("input.tar")
            var reader = try CompressedTarTestSupport.open(current)
            var seed: UInt64 = 17, largestSmallCount = 0
            for step in 0..<50 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let session = try (step % 2 == 0 ? reader.reopen() : CompressedTarTestSupport.open(current))
                let base = session.tarEditingSnapshot()!
                let index = 2 + Int((seed >> 16) % UInt64(session.entries.count - 2))
                let oldName = session.entries[index].name
                let operation = Int((seed >> 32) % 4)
                let mutate: (any ArchiveEditing) throws -> Void = { editor in
                    switch operation {
                    case 0: try editor.remove(entriesAt: [index])
                    case 1: try editor.rename(entryAt: index, to: "renamed-\(step)-" + String(repeating: "n", count: step % 2 == 0 ? 140 : 8))
                    case 2: try editor.add(data: Data(repeating: UInt8(step), count: 4096), as: "added-\(step)", modificationDate: TestSupport.date, permissions: nil)
                    default:
                        try editor.remove(entriesAt: [index])
                        try editor.add(data: Data([UInt8(step)]), as: oldName, modificationDate: TestSupport.date, permissions: nil)
                    }
                }
                let output = root.appendingPathComponent("step-\(step)." + format.testFileExtension)
                let plainOutput = root.appendingPathComponent("step-\(step).tar")
                let plain = try TarUpdater.open(url: plainURL, output: plainOutput)
                try mutate(plain); try plain.commit()
                let editor = try CompressedTarUpdater.open(reader: session.reopen(), output: output, format: format)
                try mutate(editor)
                let result = try editor.commit(progress: nil)
                reader = try CompressedTarTestSupport.verify(output, base: base, result: result, oracle: plainOutput)
                let limit = UInt64(CompressedTarSplicePlan.limits(format, options: WriterOptions()).packing / 16)
                let small = reader.tarEditingSnapshot()!.chunkMap!.chunks.filter { $0.imageRange.upperBound - $0.imageRange.lowerBound < limit }.count
                largestSmallCount = max(largestSmallCount, small)
                XCTAssertLessThanOrEqual(small, 8, "\(format) step \(step)")
                if step == 49 {
                    let encoded = root.appendingPathComponent("full." + format.testFileExtension)
                    let full = try CompressedTarUpdater.open(reader: session.reopen(), output: encoded, format: format)
                    try mutate(full)
                    let forced = try CompressedTarUpdater.$testingForcesFullEncode.withValue(true) { try full.commit(progress: nil) }
                    _ = try CompressedTarTestSupport.verify(encoded, base: base, result: forced, oracle: plainOutput)
                    XCTAssertLessThanOrEqual(Double(result.output.size), Double(forced.output.size) * 1.01)
                    TestSupport.report("TAR-REPEAT \(format)\tseed=17\tedits=50\tsplice=\(result.output.size)\tfull=\(forced.output.size)\tsmall_max=\(largestSmallCount)")
                }
                current = output; plainURL = plainOutput
            }
        }
    }
}
