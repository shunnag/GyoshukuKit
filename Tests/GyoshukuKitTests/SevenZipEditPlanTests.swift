import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

final class SevenZipEditPlanTests: XCTestCase {
    func testPurePlanAndStableOrdering() throws {
        let reader = try SevenZipEditSupport.reader(SevenZipEditSupport.fixture("m"))
        let model = try XCTUnwrap(SevenZipEditModel.read(reader))
        let names = reader.entries.map(\.name), byFolder = model.filesByFolder
        let removed = Set([byFolder[0][0]] + byFolder[1])
        let plan = SevenZipEditPlan.make(model: model, filesByFolder: byFolder, names: names, removed: removed,
            renamed: [byFolder[2][0]: "changed"], additions: 1, reencrypt: false, currentPassword: nil,
            headerPassword: nil, options: WriterOptions())
        XCTAssertEqual(plan.works, [.reencode(0, Array(byFolder[0].dropFirst())), .carry(2), .carry(3)])
        XCTAssertEqual(plan.survivingFiles, model.files.indices.filter { !removed.contains($0) })
        XCTAssertFalse(plan.unchanged)
        XCTAssertEqual(plan.renamed, [byFolder[2][0]: "changed"])
        let unchanged = SevenZipEditPlan.make(model: model, filesByFolder: byFolder, names: names, removed: [],
            renamed: [0: names[0]], additions: 0, reencrypt: false, currentPassword: nil, headerPassword: nil, options: WriterOptions())
        XCTAssertTrue(unchanged.unchanged)
        XCTAssertFalse(SevenZipEditPlan.samePassword("é", "e\u{301}"))
    }

    func testNFDNoOpRenameKeepsRawBytes() throws {
        let root = try ZipTestSupport.directory("7z-nfd")
        let base = try SevenZipEditSupport.source(root, count: 1)
        let reader = try SevenZipEditSupport.reader(base)
        var model = try XCTUnwrap(SevenZipEditModel.read(reader))
        model.files[0].rawName = SevenZipEditModel.nameBytes("e\u{301}")
        let header = try SevenZipHeaderSerializer.header(model)
        let data = try Data(contentsOf: base)
        let source = root.appendingPathComponent("nfd.7z")
        try (SevenZipRecords.signature(packedSize: model.mainPackEnd - 32, header: header)
             + data.subdata(in: 32..<Int(model.mainPackEnd)) + header).write(to: source)
        let output = root.appendingPathComponent("output.7z")
        let updater = try SevenZipUpdater.open(url: source, output: output)
        try updater.rename(entryAt: 0, to: "é")
        try updater.commit()
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: source))
    }

    func testHeaderSizeLimit() throws {
        var model = SevenZipEditModel()
        model.files = [.init(rawName: Array(repeating: 0x41, count: 16 * 1024 * 1024), isEmptyFile: true)]
        XCTAssertThrowsError(try SevenZipHeaderSerializer.header(model)) {
            guard case RewriterError.unrepresentable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testAddedAttributesUseOriginalVectorIncludingAfterAllEntriesAreReplaced() throws {
        let cases: [[UInt32?]] = [[], [nil, nil], [0x81240020, nil]]
        for attributes in cases {
            var original = SevenZipEditModel()
            original.files = attributes.enumerated().map {
                .init(rawName: SevenZipEditModel.nameBytes("file-\($0.offset)"), isEmptyFile: true, attributes: $0.element)
            }
            for removeAll in [false, true] {
                let removed = removeAll ? Set(original.files.indices) : []
                let plan = SevenZipEditPlan.make(model: original, filesByFolder: [],
                    names: original.files.indices.map { "file-\($0)" }, removed: removed, renamed: [:],
                    additions: 1, reencrypt: false, currentPassword: nil, headerPassword: nil, options: WriterOptions())
                let record = SevenZipRecords.Entry(name: "added", mode: 0o100755, size: 0, mtime: 123)
                let model = try plan.assemble(original: original, filesByFolder: [], replacements: [:],
                    additions: [.init(record: record, packRange: 32..<32)]).model
                XCTAssertEqual(Array(model.files.dropLast().map(\.attributes)), removeAll ? [] : attributes)
                let expected: UInt32? = attributes.isEmpty || attributes.contains(where: { $0 != nil })
                    ? UInt32(0o100755) << 16 | 0x8020 : nil
                XCTAssertEqual(model.files.last?.attributes, expected)
                XCTAssertEqual(model.files.last?.modificationTime, 123)
                if expected == nil { XCTAssertFalse(model.files.contains { $0.attributes != nil }) }
            }
        }
    }
}
