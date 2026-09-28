import Foundation
import CryptoKit
import KaitoKit
import XCTest
@testable import GyoshukuKit

final class TarUpdaterDifferentialTests: XCTestCase {
    private struct Random {
        var state: UInt64 = 0x70a8e122
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 32) % upper
        }
    }
    private struct Member {
        var name: String
        var directory = false
        var target: Int?
        var data = Data()
    }
    private enum Edit { case remove(Int), rename(Int, String), add(String, Data) }

    func testSeededArchivesAndOperationOrdersAgainstIndependentModelAndRewriter() throws {
        let iterations = Int(ProcessInfo.processInfo.environment["GYOSHUKU_TAR_DIFF_ITERATIONS"] ?? "") ?? 300
        let root = try TestSupport.directory("p2-differential")
        var random = Random()
        for iteration in 0..<iterations {
            let directory = try TarP2Support.work(root)
            defer { try? FileManager.default.removeItem(at: directory) }
            var members: [Member] = []
            var targets: [Int] = []
            for index in 0..<(10 + random.next(291)) {
                var member = Member(name: "file-\(index)")
                if index % 29 == 0 { member.name += "-cafe\u{301}" }
                if index % 31 == 0 { member.name += String(repeating: "x", count: 120) }
                if random.next(12) == 0 { member.name += "/"; member.directory = true }
                else if !targets.isEmpty, random.next(5) == 0 { member.target = targets[random.next(targets.count)] }
                else { member.data = Data(repeating: UInt8(random.next(255)), count: random.next(2000)) }
                if !member.directory { targets.append(index) }
                members.append(member)
            }
            let source = directory.appendingPathComponent("source.tar")
            if iteration % 3 == 0 {
                let objects: [[String: Any]] = members.map { member in
                    ["name": member.name, "directory": member.directory, "link": member.target.map { members[$0].name } ?? "",
                     "data": member.data.base64EncodedString()]
                }
                let json = directory.appendingPathComponent("input.json")
                try JSONSerialization.data(withJSONObject: objects).write(to: json)
                let script = """
                import tarfile,io,json,base64,sys
                fmt=[tarfile.PAX_FORMAT,tarfile.GNU_FORMAT][int(sys.argv[3])%2]
                with tarfile.open(sys.argv[2],'w',format=fmt,pax_headers={'comment':'differential'} if fmt==tarfile.PAX_FORMAT else {}) as t:
                    for m in json.load(open(sys.argv[1])):
                        e=tarfile.TarInfo(m['name']);e.mtime=1700000001;e.uid=501;e.gid=20;e.uname='alice';e.gname='staff'
                        b=base64.b64decode(m['data'])
                        if m['directory']: e.type=tarfile.DIRTYPE;e.mode=0o755
                        elif m['link']: e.type=tarfile.LNKTYPE;e.linkname=m['link']
                        else: e.size=len(b)
                        t.addfile(e,io.BytesIO(b))
                """
                try TestSupport.run(ReferenceTool.python3, ["-c", script, json.path, source.path, String(iteration)], in: directory, log: "python-fixture")
            } else {
                try TarP2Support.archive(members.map { member in
                    (.init(name: Data(member.name.utf8), size: UInt64(member.data.count), mtime: 1700000001, uid: 501, gid: 20,
                           type: member.directory ? 0x35 : member.target == nil ? 0x30 : 0x31,
                           link: member.target.map { Data(members[$0].name.utf8) } ?? Data()), member.data)
                }, at: source)
            }
            var edits: [Edit] = []
            var removed: Set<Int> = []
            var renamed: [Int: String] = [:]
            var additions: [Member] = []
            for step in 0..<(3 + random.next(30)) {
                let index = random.next(members.count)
                switch random.next(3) {
                case 0:
                    edits.append(.remove(index)); removed.insert(index); renamed.removeValue(forKey: index)
                case 1:
                    if !removed.contains(index) {
                        let name = "rename-\(step)-\(index)" + (members[index].directory ? "/" : "")
                        edits.append(.rename(index, name)); renamed[index] = name
                    }
                default:
                    let item = Member(name: "add-\(step)", data: Data(repeating: UInt8(step), count: random.next(1600)))
                    additions.append(item); edits.append(.add(item.name, item.data))
                }
            }
            // 偶数回はアプリの予約先行、奇数回はランダムな呼出し順。
            if iteration % 2 == 0 {
                edits = edits.filter { if case .add = $0 { return false }; return true }
                    + edits.filter { if case .add = $0 { return true }; return false }
            }
            let output = directory.appendingPathComponent("out.tar"), rewritten = directory.appendingPathComponent("rewrite.tar")
            let updater = try TarUpdater.open(url: source, output: output)
            let rewriter = try ArchiveRewriter.open(url: source, output: rewritten, format: .tar)
            for editor: any ArchiveEditing in [updater, rewriter] {
                for edit in edits {
                    switch edit {
                    case .remove(let index): try editor.remove(entriesAt: [index])
                    case .rename(let index, let name): try editor.rename(entryAt: index, to: name)
                    case .add(let name, let data): try editor.add(data: data, as: name, modificationDate: TestSupport.date, permissions: 0o644)
                    }
                }
                try editor.commit()
            }
            func dataTarget(_ index: Int) -> Int {
                var cursor = index
                while let target = members[cursor].target { cursor = target }
                return cursor
            }
            func finalName(_ index: Int) -> String { renamed[index] ?? members[index].name }
            let survivors = members.indices.filter { !removed.contains($0) }
            let (oldLayout, oldBytes, _) = try TarP2Support.scan(source)
            let (layout, bytes, reader) = try TarP2Support.scan(output)
            let rewriteReader = try ArchiveReader.open(url: rewritten, options: .init(appleDoublePolicy: .expose))
            let expectedNames = survivors.map(finalName) + additions.map(\.name)
            XCTAssertEqual(reader.entries.map(\.name), expectedNames, "seed iteration \(iteration)")
            XCTAssertEqual(rewriteReader.entries.map(\.name), expectedNames)
            for (resultIndex, oldIndex) in survivors.enumerated() {
                let item = members[oldIndex]
                let entry = reader.entries[resultIndex]
                let target = dataTarget(oldIndex)
                var linkHolder: Int?
                if let direct = item.target {
                    if !removed.contains(direct) { linkHolder = direct }
                    else {
                        let holder = survivors.first { $0 <= oldIndex && dataTarget($0) == target }
                        if holder != oldIndex { linkHolder = holder }
                    }
                }
                XCTAssertEqual(entry.kind, item.directory ? .directory : linkHolder == nil ? .file : .hardlink)
                if let holder = linkHolder {
                    let actual = try XCTUnwrap(entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init))
                    XCTAssertEqual(reader.entries[actual].name, finalName(holder))
                }
                func payload(_ r: ArchiveReader, _ index: Int) throws -> Data {
                    var cursor = index
                    while let next = r.entries[cursor].formatSpecific["hardLinkTargetIndex"].flatMap(Int.init) { cursor = next }
                    return try r.read(r.entries[cursor])
                }
                XCTAssertEqual(SHA256.hash(data: try payload(reader, resultIndex)), SHA256.hash(data: members[target].data))
                XCTAssertEqual(SHA256.hash(data: try payload(rewriteReader, resultIndex)), SHA256.hash(data: members[target].data))
                let unchangedLink = item.target.map { !removed.contains($0) && renamed[$0] == nil } ?? true
                if renamed[oldIndex] == nil && unchangedLink {
                    let a = oldLayout.member(oldIndex), b = layout.member(resultIndex)
                    XCTAssertEqual(try oldBytes.bytes(at: a.groupStart, count: Int(a.paddedEnd - a.groupStart)),
                                   try bytes.bytes(at: b.groupStart, count: Int(b.paddedEnd - b.groupStart)))
                }
            }
            for (index, addition) in additions.enumerated() {
                XCTAssertEqual(try reader.read(reader.entries[survivors.count + index]), addition.data)
            }
        }
        TestSupport.report("TAR-DIFFERENTIAL iterations=\(iterations) seed=0x70a8e122")
    }
}
