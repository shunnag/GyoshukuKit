import Foundation
import CryptoKit
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterInteropTests: XCTestCase {
    func testExternalReadersAndExtractionHashes() throws {
        guard SevenZipExternalOracles.available else { throw XCTSkip("7zz / bsdtar unavailable") }
        let root = try TestSupport.directory("7z-interop")
        for name in ["g_plain", "g_aes", "g_aesh", "z_default", "z_aes", "z_aesh", "z_aesonlyh", "z_special", "anti", "lib", "bcj", "bcj2", "ppmd", "solid_zero"] {
            let source = SevenZipEditSupport.fixture(name)
            let old = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(source)))
            for operation in ["rename", "delete", "all"] {
                let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
                let updater = try SevenZipUpdater.open(url: source, password: "secret", output: output,
                    options: WriterOptions(password: "secret", encryptsSevenZipHeaders: old.header.encrypted))
                let first = old.files.firstIndex(where: \.hasStream) ?? 0
                if operation == "all" { try updater.remove(entriesAt: Array(old.files.indices)) }
                else if operation == "delete" { try updater.remove(entriesAt: [first]) }
                else { try updater.rename(entryAt: first, to: old.files[first].isEmptyFile || old.files[first].hasStream ? "renamed" : "renamed/") }
                try updater.commit()
                try SevenZipExternalOracles.check(output, password: "secret")
            }
        }
    }

    // Orchestrator's AC-G13 amendment: the frozen StartPos fixture already fails 7zz x
    // (7-Zip 26.03, exit 2, Unsupported Method). Preserve that value, including its bytes;
    // require the same rejection only while a StartPos entry remains. No other exception.
    func testStartPosBaselineAndPreservation() throws {
        guard SevenZipExternalOracles.available else { throw XCTSkip("7zz / bsdtar unavailable") }
        let root = try TestSupport.directory("7z-startpos-interop")
        let source = SevenZipEditSupport.fixture("startpos")
        let original = try SevenZipEditSupport.reader(source)
        let model = try XCTUnwrap(SevenZipEditModel.read(original))
        let items = try SevenZipEditSupport.items(original)
        let startIndex = try XCTUnwrap(model.files.firstIndex { $0.startPosition != nil })
        XCTAssertFalse(model.header.encoded)
        try SevenZipExternalOracles.check(source, password: nil, permitsStartPosRejection: true)
        for operation in ["rename", "delete", "all"] {
            let output = root.appendingPathComponent(operation + ".7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            var expected = items
            if operation == "rename" { try updater.rename(entryAt: startIndex, to: "renamed"); expected[startIndex].name = "renamed" }
            else if operation == "delete" { try updater.remove(entriesAt: [startIndex]); expected.remove(at: startIndex) }
            else { try updater.remove(entriesAt: Array(items.indices)); expected = [] }
            try updater.commit()
            let reader = try SevenZipEditSupport.reader(output)
            let edited = try XCTUnwrap(SevenZipEditModel.read(reader))
            XCTAssertEqual(try SevenZipEditSupport.items(reader), expected)
            if operation == "rename" {
                XCTAssertEqual(edited.files.map(\.startPosition), model.files.map(\.startPosition))
                let bytes = try Data(contentsOf: output)
                let header = bytes.subdata(in: Int(edited.nextHeaderRange.lowerBound)..<Int(edited.nextHeaderRange.upperBound))
                var rawValue = Data(); rawValue.le(model.files[startIndex].startPosition!)
                XCTAssertNotNil(header.range(of: rawValue))
                XCTAssertEqual(edited.substreams.map(\.crc32), model.substreams.map(\.crc32))
            } else { XCTAssertTrue(edited.files.allSatisfy { $0.startPosition == nil }) }
            for (index, entry) in reader.entries.enumerated() {
                if let crc = entry.crc32 { XCTAssertEqual(crc, CRC32.checksum(expected[index].data)) }
            }
            try SevenZipExternalOracles.check(output, password: nil, permitsStartPosRejection: true)
        }
    }
}
