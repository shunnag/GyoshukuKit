import XCTest
@testable import GyoshukuKit

final class EditPathReservationsTests: XCTestCase {
    func testDeepPathsReleaseTheirBranchesWithoutRecursiveDestruction() {
        let parent = Array(repeating: "x", count: 16_000).joined(separator: "/")
        let index = EditPathReservations([])
        index.insert(parent + "/first", directory: false)
        index.insert(parent + "/second", directory: false)
        XCTAssertThrowsError(try index.validate(parent, directory: false))
        XCTAssertNoThrow(try index.validate(parent + "/", directory: true))
        index.remove(parent + "/first", directory: false)
        XCTAssertThrowsError(try index.validate("x", directory: false))
        index.remove(parent + "/second", directory: false)
        XCTAssertNoThrow(try index.validate("x", directory: false))
        index.insert("new/file", directory: false)
        XCTAssertThrowsError(try index.validate("new", directory: false))
        XCTAssertNoThrow(try index.validate("x", directory: false))
    }

    func testCountedReservationsAgreeWithPairwiseScanIncludingDuplicateNames() throws {
        let paths = ["a", "ab", "a/child", "a//child", "a/", "./a", "/", "/a",
                     "café/file", "cafe\u{301}/file", "café", "a/\u{301}b", "a/\u{301}b/child"]
        var records: [(String, Bool)] = [], index = EditPathReservations([])
        var state: UInt64 = 0x9BFC
        func next(_ upper: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(upper))
        }
        func descendant(_ path: String, of parent: String) -> Bool {
            path.precomposedStringWithCanonicalMapping.utf8
                .starts(with: (parent + "/").precomposedStringWithCanonicalMapping.utf8)
        }
        func key(_ path: String) -> String { path.hasSuffix("/") ? String(path.dropLast()) : path }
        for step in 0..<400 {
            if !records.isEmpty, next(3) == 0 {
                let removed = records.remove(at: next(records.count))
                index.remove(removed.0, directory: removed.1)
            } else {
                let record = (paths[next(paths.count)], next(2) == 0)
                records.append(record)
                index.insert(record.0, directory: record.1)
            }
            for path in paths {
                for directory in [false, true] {
                    let collision = records.contains { other, otherDirectory in
                        key(other) == key(path) || (!directory && descendant(key(other), of: key(path))) ||
                            (!otherDirectory && descendant(key(path), of: key(other)))
                    }
                    do {
                        try index.validate(path, directory: directory)
                        XCTAssertFalse(collision, "step \(step), \(path)")
                    } catch {
                        XCTAssertTrue(collision, "step \(step), \(path): \(error)")
                    }
                }
            }
        }
        for (path, directory) in records { index.remove(path, directory: directory) }
        for path in paths { XCTAssertNoThrow(try index.validate(path, directory: false)) }
    }
}
