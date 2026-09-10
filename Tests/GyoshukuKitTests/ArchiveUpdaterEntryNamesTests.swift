import Foundation
import GyoshukuKit
import KaitoKit
import XCTest

final class ArchiveUpdaterEntryNamesTests: XCTestCase {
    private let names = ["zeta.txt", "folder/", "folder/child.txt", "alpha.txt"]

    private func original(_ label: String) throws -> URL {
        let directory = try ZipTestSupport.directory("entry-names-\(label)")
        let url = directory.appendingPathComponent("archive.zip")
        let writer = try ArchiveWriter.create(url: url)
        for name in names {
            if name.hasSuffix("/") {
                try writer.addDirectory(name)
            } else {
                try writer.add(data: Data(name.utf8), as: name)
            }
        }
        try writer.finish()
        return url
    }

    func testEntryNamesPreserveOpenTimeOrderAndDirectorySlash() throws {
        let url = try original("order")
        let reader = try ArchiveReader.open(url: url)
        let updater = try ArchiveUpdater.open(url: url)

        XCTAssertEqual(updater.entryNames, names)
        XCTAssertEqual(updater.entryNames.count, reader.entries.count)
        XCTAssertEqual(updater.entryNames, reader.entries.map(\.name))
        XCTAssertEqual(reader.entries[1].kind, .directory)
        XCTAssertEqual(updater.entryNames[1], "folder/")
        for entry in reader.entries {
            XCTAssertEqual(updater.entryNames[entry.index], entry.name)
        }
    }

    func testEntryNamesPreserveCP932Characters() throws {
        let directory = try ZipTestSupport.directory("entry-names-cp932")
        let url = directory.appendingPathComponent("archive.zip")
        // UTF-8 flag を立てず、名前を CP932 の byte 列で記録する。
        let script = #"""
        import struct, zlib, sys
        p = lambda f,*v: struct.pack('<'+f,*v)
        name = '日本語.txt'.encode('cp932')
        data = b'CP932 original\n'
        crc = zlib.crc32(data)
        local = p('IHHHHHIIIHH',0x04034b50,20,0,0,0,0x21,crc,len(data),len(data),len(name),0)+name+data
        cd = p('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,20,0,0,0,0x21,crc,len(data),len(data),len(name),0,0,0,0,0o100644<<16,0)+name
        end = p('IHHHHIIH',0x06054b50,0,0,1,1,len(cd),len(local),0)
        open(sys.argv[1],'wb').write(local+cd+end)
        """#
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, url.path], in: directory, log: "python-create")
        let reader = try ArchiveReader.open(url: url)
        let updater = try ArchiveUpdater.open(url: url)

        XCTAssertEqual(updater.entryNames, ["日本語.txt"])
        XCTAssertEqual(updater.entryNames, reader.entries.map(\.name))
        XCTAssertEqual(reader.entries[0].rawName.bytes, [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x2E, 0x74, 0x78, 0x74])
    }

    func testEntryNamesKeepOriginalNameAfterQueuedRename() throws {
        let updater = try ArchiveUpdater.open(url: original("rename"))

        try updater.rename(entryAt: 2, to: "renamed.txt")

        XCTAssertEqual(updater.entryNames[2], "folder/child.txt")
        XCTAssertEqual(updater.entryNames, names)
    }

    func testEntryNamesKeepCountAndContentAfterQueuedRemoval() throws {
        let updater = try ArchiveUpdater.open(url: original("remove"))

        try updater.remove(entriesAt: [0, 2])

        XCTAssertEqual(updater.entryNames.count, names.count)
        XCTAssertEqual(updater.entryNames, names)
    }

    func testEntryNamesExcludeAppendedEntries() throws {
        let updater = try ArchiveUpdater.open(url: original("add"))

        try updater.add(data: Data("new entry".utf8), as: "added.txt")

        XCTAssertEqual(updater.entryNames.count, names.count)
        XCTAssertEqual(updater.entryNames, names)
    }

    func testEntryNamesAreEmptyForEmptyArchive() throws {
        let directory = try ZipTestSupport.directory("entry-names-empty")
        let url = directory.appendingPathComponent("archive.zip")
        try ArchiveWriter.create(url: url).finish()
        let updater = try ArchiveUpdater.open(url: url)

        XCTAssertEqual(updater.entryNames, [])

        try updater.add(data: Data("new entry".utf8), as: "added.txt")
        XCTAssertEqual(updater.entryNames, [])
    }

    func testEntryNameAtIndexMatchesCommittedRemoval() throws {
        for index in names.indices {
            let url = try original("commit-remove-\(index)")
            let updater = try ArchiveUpdater.open(url: url)
            let originalNames = updater.entryNames
            XCTAssertEqual(originalNames, names)
            let removedName = originalNames[index]

            try updater.remove(entriesAt: [index])
            try updater.commit()

            let remainingNames = try ArchiveReader.open(url: url).entries.map(\.name)
            XCTAssertFalse(remainingNames.contains(removedName))
            XCTAssertEqual(remainingNames.count, originalNames.count - 1)
            XCTAssertEqual(remainingNames, originalNames.enumerated().filter { $0.offset != index }.map(\.element))
        }
    }
}
