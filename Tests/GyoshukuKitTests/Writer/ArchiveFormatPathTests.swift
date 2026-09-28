import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class ArchiveFormatPathTests: XCTestCase {
    private let tarFormats: [(GyoshukuKit.ArchiveFormat, String)] = [
        (.tar, "tar"), (.tarGzip, "tar.gz"), (.tarBzip2, "tar.bz2"), (.tarXZ, "tar.xz")
    ]
    private let carried = [("a:b", Data("colon payload".utf8)), ("dir\\name", Data([0, 58, 92, 255]))]

    private func fixture(_ label: String) throws -> URL {
        let directory = try TestSupport.directory("format-path-" + label)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.tar")
        var bytes = Data()
        // writer の名前検査を通さず、既存 tar の名前を再現する。
        for (name, payload) in carried + [("remove", Data("unrelated".utf8))] {
            bytes.append(TarRecords.Entry(name: Data(name.utf8), size: UInt64(payload.count),
                                          mtime: 1_700_000_001).headers())
            bytes.append(payload)
            bytes.append(Data(count: (512 - payload.count % 512) % 512))
        }
        bytes.append(Data(count: 1024))
        try bytes.write(to: url)
        return url
    }

    func testProbeAcceptsColonAndBackslashOnlyForTarFormats() throws {
        let source = try fixture("probe")
        let entries = try ArchiveReader.open(url: source).entries
        XCTAssertEqual(entries.map(\.name), carried.map { $0.0 } + ["remove"])
        XCTAssertEqual(entries.prefix(2).map { $0.rawName.bytes }, carried.map { Array($0.0.utf8) })
        for (format, _) in tarFormats {
            XCTAssertNoThrow(try ArchiveRewriter.probe(entries: entries, format: format), "\(format)")
            XCTAssertNoThrow(try ArchiveRewriter.open(url: source, format: format), "\(format)")
        }
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .lha] {
            for entry in entries.prefix(2) {
                XCTAssertThrowsError(try ArchiveRewriter.probe(entries: [entry], format: format), "\(format): \(entry.name)") {
                    guard case RewriterError.unrepresentable(let name, _) = $0 else { return XCTFail("\($0)") }
                    XCTAssertEqual(name, entry.name)
                }
            }
        }
    }

    func testTarRewriteDeletionPreservesNameBytesAndPayloads() throws {
        for (format, suffix) in tarFormats {
            let source = try fixture("delete-\(format)")
            let output = format == .tar ? source
                : source.deletingLastPathComponent().appendingPathComponent("output." + suffix)
            let rewriter = try ArchiveRewriter.open(url: source, output: output == source ? nil : output, format: format)
            try rewriter.remove(entriesAt: [2])
            try rewriter.commit()
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries.map { $0.rawName.bytes }, carried.map { Array($0.0.utf8) })
            for (entry, expected) in zip(reader.entries, carried) {
                XCTAssertEqual(try reader.read(entry), expected.1, "\(format): \(expected.0)")
            }
        }
    }

    func testTarWriterAddsDiskNamesAndRemembersHardLinkTargets() throws {
        let directory = try TestSupport.directory("format-path-disk")
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "1:2 recipe.txt"
        let file = directory.appendingPathComponent(name)
        let alias = directory.appendingPathComponent("dir\\name")
        let payload = Data("recipe contents".utf8)
        try payload.write(to: file)
        try FileManager.default.linkItem(at: file, to: alias)
        for (format, suffix) in tarFormats {
            let output = directory.appendingPathComponent("output." + suffix)
            let writer = try ArchiveWriter.create(url: output, format: format)
            try writer.add(contentsOf: file, as: name)
            try writer.add(contentsOf: alias, as: alias.lastPathComponent)
            try writer.finish()
            let reader = try ArchiveReader.open(url: output)
            XCTAssertEqual(reader.entries.map { $0.rawName.bytes }, [Array(name.utf8), Array("dir\\name".utf8)])
            XCTAssertEqual(reader.entries.map(\.kind), [.file, .hardlink])
            guard reader.entries.count == 2 else { continue }
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            XCTAssertEqual(reader.entries[1].formatSpecific["hardLinkTargetIndex"], "0")
        }
    }

    func testTarRewriterRenamesAndAddsColonAndBackslashNames() throws {
        for (format, suffix, placement) in tarFormats.flatMap({ format, suffix in [AdditionPlacement.end, .beginning].map { (format, suffix, $0) } }) {
            let source = try fixture("edit-\(format)-\(placement)")
            let output = source.deletingLastPathComponent().appendingPathComponent("output." + suffix)
            let disk = source.deletingLastPathComponent().appendingPathComponent("1:2 recipe.txt")
            let payload = Data("new contents".utf8)
            try payload.write(to: disk)
            let rewriter = try ArchiveRewriter.open(url: source, output: output, format: format, options: .init(additionPlacement: placement))
            try rewriter.rename(entryAt: 0, to: "man3/File::Spec.3pm")
            try rewriter.rename(entryAt: 1, to: "folder\\name")
            try rewriter.remove(entriesAt: [2])
            try rewriter.add(data: payload, as: "Maildir/cur/message:2,S")
            try rewriter.addDirectory("new\\dir:")
            try rewriter.add(contentsOf: disk, as: disk.lastPathComponent)
            try rewriter.commit()
            let reader = try ArchiveReader.open(url: output)
            var expected = [("Maildir/cur/message:2,S", payload), ("new\\dir:/", Data()),
                            ("1:2 recipe.txt", payload), ("man3/File::Spec.3pm", carried[0].1),
                            ("folder\\name", carried[1].1)]
            if placement == .end { expected = Array(expected.suffix(2)) + Array(expected.prefix(3)) }
            XCTAssertEqual(reader.entries.map { $0.rawName.bytes }, expected.map { Array($0.0.utf8) })
            for (entry, item) in zip(reader.entries, expected) where entry.kind == .file {
                XCTAssertEqual(try reader.read(entry), item.1, "\(format): \(item.0)")
            }
        }
    }
}
