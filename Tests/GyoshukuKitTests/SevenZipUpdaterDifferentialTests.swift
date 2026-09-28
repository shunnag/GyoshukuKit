import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipUpdaterDifferentialTests: XCTestCase {
    func testSeededEditsAgainstIndependentModelAndRewriter() throws {
        let iterations = Int(ProcessInfo.processInfo.environment["GYOSHUKU_7Z_DIFF_ITERATIONS"] ?? "200") ?? 200
        let root = try TestSupport.directory("7z-differential")
        func canonical(_ item: SevenZipEditSupport.Item) -> SevenZipEditSupport.Item {
            var result = item
            result.name = item.name.precomposedStringWithCanonicalMapping
            if item.kind == .directory && !result.name.hasSuffix("/") { result.name += "/" }
            return result
        }
        var seed: UInt64 = 0x5A24BEEF
        func random(_ limit: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 32) % UInt64(limit)) }
        for iteration in 0..<iterations {
            try autoreleasepool {
                let work = try SevenZipEditSupport.work(root)
                let source = work.appendingPathComponent("source.7z")
                let count = 10 + random(191)
                let password: String? = iteration % 3 == 0 ? nil : "secret"
                let headers = iteration % 3 == 2
                let external = iteration % 6 >= 3 && FileManager.default.isExecutableFile(atPath: ReferenceTool.sevenZip)
                let input = work.appendingPathComponent("input")
                if external { try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true) }
                let writer = try external ? nil : ArchiveWriter.create(url: source, format: .sevenZip,
                    options: WriterOptions(password: password, encryptsSevenZipHeaders: headers, compressionThreads: 1))
                var expected: [SevenZipEditSupport.Item] = []
                for index in 0..<count {
                    let name = index % 9 == 0 ? "日本語-\(index)" : index % 11 == 0 ? "e\u{301}-\(index)" : "file-\(index)"
                    let bytes = Data(repeating: UInt8(random(255)), count: index % 7 == 0 ? 0 : 1 + random(3000))
                    if external { try bytes.write(to: input.appendingPathComponent(name)) }
                    else { try writer!.add(data: bytes, as: name, modificationDate: TestSupport.date) }
                    expected.append(.init(name: name.precomposedStringWithCanonicalMapping, kind: .file, data: bytes))
                }
                if external { try FileManager.default.createDirectory(at: input.appendingPathComponent("dir"), withIntermediateDirectories: true) }
                else { try writer!.addDirectory("dir", modificationDate: TestSupport.date, ownerIDs: nil) }
                expected.append(.init(name: "dir/", kind: .directory, data: Data()))
                if external {
                    let solid = ["on", "16k", "off"][iteration % 3]
                    let arguments = ["a", "-t7z", "-mx=1", "-mmt=1", "-ms=" + solid]
                        + (password.map { ["-p" + $0] } ?? []) + (headers ? ["-mhe=on"] : []) + [source.path, "."]
                    try ReferenceTool.run(ReferenceTool.sevenZip, arguments, in: work, log: "7zz-create",
                                          environment: [:], workingDirectory: input)
                } else { try writer!.finish() }
                let before = try SevenZipEditSupport.reader(source, password: password)
                let old = try XCTUnwrap(SevenZipEditModel.read(before))
                let byName = Dictionary(uniqueKeysWithValues: expected.map { ($0.name, $0) })
                if external {
                    let ordered = try SevenZipEditSupport.items(before).map(canonical)
                    XCTAssertEqual(Set(ordered.map(\.name)), Set(byName.keys))
                    expected = try ordered.map { try XCTUnwrap(byName[$0.name]) }
                }
                XCTAssertEqual(try SevenZipEditSupport.items(before).map(canonical), expected)
                let remove = Set([random(count), random(count)])
                let rename = (0..<count).first { !remove.contains($0) }!
                let newName = "変更後-\(iteration)" + (expected[rename].kind == .directory ? "/" : "")
                let addition = Data([UInt8(truncatingIfNeeded: iteration), 7, 5])
                let replacement = iteration % 5 == 0
                let additionName = replacement ? expected[remove.min()!].name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : "addition"
                let convert = iteration % 4 == 0
                let target: String? = convert ? (password == nil ? "secret" : nil) : password
                let options = WriterOptions(password: target, encryptsSevenZipHeaders: target != nil && headers, compressionThreads: 1)
                var projected = expected.enumerated().filter { !remove.contains($0.offset) }.map { index, item in
                    var result = item; if index == rename { result.name = newName }; return result
                }
                projected.append(.init(name: additionName, kind: .file, data: addition))
                projected.append(.init(name: "newdir/", kind: .directory, data: Data()))
                var outputs: [URL] = []
                for rewrite in [false, true] {
                    let output = work.appendingPathComponent(rewrite ? "rewrite.7z" : "update.7z")
                    let editor: any ArchiveEditing = try rewrite
                        ? ArchiveRewriter.open(url: source, password: password, output: output, format: .sevenZip, options: options)
                        : SevenZipUpdater.open(url: source, password: password, output: output, options: options)
                    let late = iteration % 2 == 0 && !replacement
                    if late { try editor.add(data: addition, as: additionName, modificationDate: TestSupport.date, permissions: nil) }
                    try editor.remove(entriesAt: Array(remove))
                    try editor.rename(entryAt: rename, to: newName)
                    if let reencrypt = editor as? any ArchiveReencrypting, convert { try reencrypt.reencryptExistingEntries(currentPassword: password) }
                    if !late { try editor.add(data: addition, as: additionName, modificationDate: TestSupport.date, permissions: nil) }
                    try editor.addDirectory("newdir", modificationDate: TestSupport.date, ownerIDs: nil)
                    try editor.commit()
                    XCTAssertEqual(try SevenZipEditSupport.items(SevenZipEditSupport.reader(output, password: target)).map(canonical), projected, "seed iteration \(iteration) rewrite=\(rewrite)")
                    outputs.append(output)
                }
                if !convert {
                    let new = try XCTUnwrap(SevenZipEditModel.read(SevenZipEditSupport.reader(outputs[0], password: target)))
                    let oldFiles = old.filesByFolder
                    let survivingFolders = old.folders.indices.filter { folder in
                        oldFiles[folder].isEmpty || oldFiles[folder].contains { !remove.contains($0) }
                    }
                    let pairs = survivingFolders.enumerated().compactMap { offset, folder -> (Int, Int)? in
                        oldFiles[folder].contains(where: remove.contains) ? nil : (folder, offset)
                    }
                    try SevenZipEditSupport.assertCarried(source, outputs[0], originalModel: old, outputModel: new, pairs: pairs)
                }
                try FileManager.default.removeItem(at: work)
            }
        }
        print("7Z-DIFFERENTIAL iterations=\(iterations) seed=0x5A24BEEF")
    }
}
