import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterTests: XCTestCase {
    func testBasicOperationsBothModes() throws {
        for sequential in [false, true] {
            for operation in ["unchanged", "same", "long", "first", "last", "empty", "all", "add", "replace", "late"] {
                let root = try ZipTestSupport.directory("7z-update-\(sequential)-\(operation)")
                let source = try SevenZipEditSupport.source(root)
                let before = try Data(contentsOf: source)
                let original = try SevenZipEditSupport.reader(source)
                let model = try XCTUnwrap(SevenZipEditModel.read(original))
                var expected = try SevenZipEditSupport.items(original)
                let work = try SevenZipEditSupport.work(root), output = work.appendingPathComponent("output.7z")
                let updater = try SevenZipUpdater.$testingDisablesClone.withValue(sequential) { try SevenZipUpdater.open(url: source, output: output) }
                var expectedStrategy: SevenZipUpdater.CommitStrategy = .headerOnly
                switch operation {
                case "unchanged": expectedStrategy = .unchanged
                case "same", "long":
                    let name = operation == "same" ? "other" : "日本語と長い名前.txt"
                    try updater.rename(entryAt: 1, to: name); expected[1].name = name
                case "first": try updater.remove(entriesAt: [0]); expected.remove(at: 0); expectedStrategy = .compacted
                case "last": try updater.remove(entriesAt: [3]); expected.remove(at: 3)
                case "empty": try updater.remove(entriesAt: [4, 5]); expected.removeLast(2)
                case "all": try updater.remove(entriesAt: Array(expected.indices)); expected.removeAll()
                case "add":
                    try updater.add(data: Data([9]), as: "added", modificationDate: ZipTestSupport.date)
                    try updater.addDirectory("new", modificationDate: ZipTestSupport.date, ownerIDs: nil)
                    expected += [.init(name: "added", kind: .file, data: Data([9])), .init(name: "new/", kind: .directory, data: Data())]
                    expectedStrategy = .appendOnly
                case "replace":
                    try updater.remove(entriesAt: [0]); expected.remove(at: 0)
                    try updater.add(data: Data([9]), as: "file0", modificationDate: ZipTestSupport.date)
                    expected.append(.init(name: "file0", kind: .file, data: Data([9]))); expectedStrategy = .compacted
                default:
                    try updater.add(data: Data([9]), as: "added", modificationDate: ZipTestSupport.date)
                    try updater.remove(entriesAt: [0]); expected.remove(at: 0)
                    expected.append(.init(name: "added", kind: .file, data: Data([9]))); expectedStrategy = .relocatedAppend
                }
                var updates: [ArchiveUpdater.CommitProgress] = []
                try updater.commit { updates.append($0) }
                try updater.commit()
                let actual = try SevenZipEditSupport.reader(output)
                XCTAssertEqual(try SevenZipEditSupport.items(actual), expected, "\(operation) sequential=\(sequential)")
                XCTAssertEqual(try Data(contentsOf: source), before)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), ["output.7z"])
                if sequential && expectedStrategy != .unchanged && expectedStrategy != .relocatedAppend { expectedStrategy = .sequential }
                XCTAssertEqual(updater.lastCommitStrategy, expectedStrategy, operation)
                XCTAssertEqual(updates.last?.completedBytes, updates.last?.totalBytes)
                XCTAssertTrue(updates.allSatisfy { $0.totalBytes == updates.first!.totalBytes && $0.completedBytes <= $0.totalBytes })
                XCTAssertEqual(updates.map(\.completedBytes), updates.map(\.completedBytes).sorted())
                if operation == "same" || operation == "long" || operation == "add" {
                    try SevenZipEditSupport.assertCarried(source, output, originalModel: model,
                        outputModel: XCTUnwrap(SevenZipEditModel.read(actual)), pairs: model.folders.indices.map { ($0, $0) })
                }
                if operation == "all" { XCTAssertEqual(try Data(contentsOf: output).suffix(5), Data([1, 5, 0, 0, 0])) }
                try SevenZipExternalOracles.check(output, password: nil)
            }
        }
    }

    func testFrozenFixturesRenameAndMetadata() throws {
        let excluded: Set<String> = ["archive_properties", "comment", "unknown_1a", "external_names", "sfx", "packpos16", "empty_7zz"]
        let root = try ZipTestSupport.directory("7z-frozen-edits")
        for source in try FileManager.default.contentsOfDirectory(at: SevenZipEditSupport.fixtures, includingPropertiesForKeys: nil)
            where source.pathExtension == "7z" && !excluded.contains(source.deletingPathExtension().lastPathComponent) {
            let reader = try SevenZipEditSupport.reader(source)
            let old = try XCTUnwrap(SevenZipEditModel.read(reader))
            if reader.entries.isEmpty { continue }
            let output = root.appendingPathComponent(source.lastPathComponent)
            var expected = try SevenZipEditSupport.items(reader)
            let index = reader.entries.firstIndex { $0.kind == .file } ?? 0
            let directory = reader.entries[index].kind == .directory
            let name = directory ? "renamed/" : "renamed-long-日本語"
            let updater = try SevenZipUpdater.open(url: source, password: "secret", output: output,
                options: WriterOptions(password: "secret", encryptsSevenZipHeaders: old.header.encrypted))
            try updater.rename(entryAt: index, to: name); expected[index].name = name
            try updater.commit()
            let actual = try SevenZipEditSupport.reader(output)
            XCTAssertEqual(try SevenZipEditSupport.items(actual), expected, source.lastPathComponent)
            let new = try XCTUnwrap(SevenZipEditModel.read(actual))
            try SevenZipEditSupport.assertCarried(source, output, originalModel: old, outputModel: new, pairs: old.folders.indices.map { ($0, $0) })
            for i in old.files.indices where i != index { XCTAssertEqual(old.files[i], new.files[i], source.lastPathComponent) }
        }
    }
    func testAllDeletedThenDiskTreeAddedAndLateReservations() throws {
        let root = try ZipTestSupport.directory("7z-disk-add")
        let source = try SevenZipEditSupport.source(root)
        let input = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: input.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data([1, 2, 7]).write(to: input.appendingPathComponent("file"))
        try Data().write(to: input.appendingPathComponent("empty"))
        try FileManager.default.createSymbolicLink(atPath: input.appendingPathComponent("link").path, withDestinationPath: "file")
        let reference = root.appendingPathComponent("reference.7z")
        let writer = try ArchiveWriter.create(url: reference, format: .sevenZip)
        try writer.add(contentsOf: input, as: "tree")
        try writer.finish()
        let expected = try SevenZipEditSupport.items(SevenZipEditSupport.reader(reference))
        for late in [false, true] {
            let output = root.appendingPathComponent("output-\(late).7z")
            let updater = try SevenZipUpdater.open(url: source, output: output)
            if !late { try updater.remove(entriesAt: Array(updater.entryNames.indices)) }
            try updater.add(contentsOf: input, as: "tree", ownerIDs: nil)
            if late { try updater.remove(entriesAt: Array(updater.entryNames.indices)) }
            try updater.commit()
            XCTAssertEqual(try SevenZipEditSupport.items(SevenZipEditSupport.reader(output)), expected)
        }
    }

}
