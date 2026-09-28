import Foundation
import Darwin
import KaitoKit
import Synchronization
import XCTest
@testable import GyoshukuKit

final class LHAUpdaterLargeOffsetTests: XCTestCase {
    func testSparseOffsetsPastFourGiB() throws {
        guard ProcessInfo.processInfo.environment["GYOSHUKU_LHA_LARGE"] == "1" else { throw XCTSkip("Set GYOSHUKU_LHA_LARGE=1") }
        let root = try TestSupport.directory("lha-large-offset"), source = root.appendingPathComponent("source.lzh")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        for index in 0..<4 {
            let size: UInt64 = index < 2 ? 5 * 1024 * 1024 * 1024 / 2 : 1024
            let header = LHAHeaderBuilder.header(level: 2, name: Data("file-\(index)".utf8), packed: size, original: size, crc: 0)
            try handle.write(contentsOf: header)
            try handle.seek(toOffset: handle.offset() + size)
        }
        try handle.write(contentsOf: Data([0])); try handle.close()
        let layout = try LHAUpdateSupport.scan(source).0
        XCTAssertGreaterThan(try layout.member(2).headerRange.lowerBound, UInt64(UInt32.max))
        for operation in 0..<4 {
            let output = root.appendingPathComponent("out-\(operation).lzh")
            let editor = try LHAUpdater.open(url: source, output: output)
            switch operation {
            case 0: try editor.remove(entriesAt: [3])
            case 1: try editor.rename(entryAt: 2, to: "longer-third-name")
            case 2: try editor.add(data: Data([1]), as: "added")
            default: try editor.remove(entriesAt: [0])
            }
            try editor.commit()
            let reader = try ArchiveReader.open(url: output, options: .init(limits: .init(maxEntrySize: .max, maxTotalUncompressedSize: .max)))
            XCTAssertEqual(reader.entries.count, operation == 0 || operation == 3 ? 3 : operation == 2 ? 5 : 4)
            if FileManager.default.isExecutableFile(atPath: ReferenceTool.sevenZip) {
                let result = try LHATestSupport.run(ReferenceTool.sevenZip, ["l", output.path], in: root, log: "list-\(operation)")
                XCTAssertEqual(result.status, 0, result.text)
            }
            print("LHA-LARGE\toperation=\(operation)\tbytes=\(try ZipP1Support.info(output).st_size)")
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.removeItem(at: source)
    }
}
