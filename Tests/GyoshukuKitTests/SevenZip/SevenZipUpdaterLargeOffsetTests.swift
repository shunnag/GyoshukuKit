import Foundation
import Darwin
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterLargeOffsetTests: XCTestCase {
    func testSparseOffsetsPastFourGiB() throws {
        try OptInGate.flag("GYOSHUKU_7Z_LARGE")
        let root = try TestSupport.directory("7z-large-offset")
        let small = try SevenZipEditSupport.source(root, count: 1)
        let smallReader = try SevenZipEditSupport.reader(small)
        let smallModel = try XCTUnwrap(SevenZipEditModel.read(smallReader))
        let smallBytes = try Data(contentsOf: small)
        let length: UInt64 = (1 << 32) + (1 << 20)
        let zeros = Data(count: 4 * 1024 * 1024)
        var crc: UInt32 = 0, offset: UInt64 = 0
        while offset < length {
            let count = Int(min(UInt64(zeros.count), length - offset))
            crc = updateCRC(crc, zeros.prefix(count)); offset += UInt64(count)
        }
        var model = SevenZipEditModel()
        model.folders = [.init(coders: [.init(methodID: [0])], bindPairs: [], packedInputs: [0], unpackSizes: [length],
            finalOutput: 0, packIndices: 0..<1, substreamIndices: 0..<1), smallModel.folders[0]]
        model.folders[1].packIndices = 1..<2; model.folders[1].substreamIndices = 1..<2
        let end = 32 + length + smallModel.packs[0].length
        model.packs = [.init(range: 32..<(32 + length)), .init(range: (32 + length)..<end)]
        model.substreams = [.init(folderIndex: 0, offset: 0, size: length, crc32: crc), smallModel.substreams[0]]
        model.substreams[1].folderIndex = 1
        model.files = [.init(rawName: SevenZipEditModel.nameBytes("big"), substreamIndex: 0, isEmptyFile: false), smallModel.files[0]]
        model.files[1].substreamIndex = 1; model.mainPackEnd = end
        let header = try SevenZipHeaderSerializer.header(model)
        let source = root.appendingPathComponent("large.7z")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: SevenZipRecords.signature(packedSize: end - 32, header: header))
        try handle.seek(toOffset: 32 + length)
        let range = smallModel.packs[0].range
        try handle.write(contentsOf: smallBytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
        try handle.write(contentsOf: header); try handle.synchronize(); try handle.close()
        var info = stat(); XCTAssertEqual(stat(source.path, &info), 0)
        guard UInt64(info.st_blocks) * 512 < length / 2 else { throw XCTSkip("sparse file unavailable") }
        for operation in ["rename", "first", "add"] {
            let output = root.appendingPathComponent(operation + ".7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            guard updater.destination.isCloneMode else { throw XCTSkip("APFS clone unavailable") }
            let events = IOEvents(), start = ProcessInfo.processInfo.systemUptime
            try ZipCopyEngine.$writeObserver.withValue(events.write) {
                if operation == "rename" { try updater.rename(entryAt: 1, to: "renamed") }
                else if operation == "first" { try updater.remove(entriesAt: [0]) }
                else { try updater.add(data: Data([1, 2]), as: "added", modificationDate: TestSupport.date) }
                try updater.commit()
            }
            print(String(format: "7Z-LARGE\t%@\tcommit_ms=%.3f\twritten_bytes=%llu", operation, (ProcessInfo.processInfo.systemUptime - start) * 1000, events.bytes))
            let reader = try SevenZipEditSupport.reader(output)
            let entry = reader.entries[operation == "first" ? 0 : 1]
            XCTAssertEqual(try reader.read(entry), Data(repeating: 0, count: 1000))
            if operation != "first" {
                let stream = try reader.stream(reader.entries[0])
                var read: UInt64 = 0
                while true {
                    let bytes = try stream.readSome(upTo: 4 * 1024 * 1024)
                    if bytes.isEmpty { break }
                    XCTAssertFalse(bytes.contains { $0 != 0 }); read += UInt64(bytes.count)
                }
                XCTAssertEqual(read, length)
            }
            if FileManager.default.isExecutableFile(atPath: ReferenceTool.sevenZip) {
                try TestSupport.run(ReferenceTool.sevenZip, ["t", "-y", output.path], in: root, log: "7zz-" + operation)
            }
        }
    }
}
