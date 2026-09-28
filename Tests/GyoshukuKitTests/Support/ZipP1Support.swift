import Foundation
import Darwin
import KaitoKit
import Synchronization
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class ZipIOEvents: Sendable {
    struct Event: Sendable { let descriptor: Int32; let offset: UInt64; let count: Int; let inode: UInt64 }
    private let storage = Mutex<[Event]>([])
    var events: [Event] { storage.withLock { $0 } }
    var bytes: UInt64 { events.reduce(0) { $0 + UInt64($1.count) } }
    func read(_ descriptor: Int32, _ offset: UInt64, _ count: Int) {
        var info = stat()
        _ = fstat(descriptor, &info)
        storage.withLock { $0.append(.init(descriptor: descriptor, offset: offset, count: count, inode: UInt64(info.st_ino))) }
    }
    func write(_ offset: UInt64, _ count: Int) {
        storage.withLock { $0.append(.init(descriptor: -1, offset: offset, count: count, inode: 0)) }
    }
}

enum ZipP1Support {
    enum Operation {
        case remove([Int]), rename(Int, String), add(String, Data), directory(String, URL)
    }
    static let names = ["first.txt", "middle.txt", "last.txt", "folder/", "folder/file.txt"]
    static let salt: @Sendable (Int) throws -> Data = { Data(repeating: 0x5a, count: $0) }

    static func fixture(_ directory: URL, name: String = "source.zip", count: Int = 5,
                        payloadSize: Int = 96, options: WriterOptions = .init(compressionMethod: .stored)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = try ArchiveWriter.create(url: url, options: options)
        for index in 0..<count {
            let name = count == 5 ? names[index] : String(format: "entry-%06d.txt", index)
            if name.hasSuffix("/") {
                let disk = directory.appendingPathComponent("fixed-directory")
                try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.modificationDate: TestSupport.date], ofItemAtPath: disk.path)
                try writer.add(contentsOf: disk, as: name)
            } else {
                try writer.add(data: Data(repeating: UInt8(index % 251), count: payloadSize), as: name,
                               modificationDate: TestSupport.date)
            }
        }
        try writer.finish()
        return url
    }

    static func mutate(_ updater: ArchiveUpdater, _ operations: [Operation]) throws {
        for operation in operations {
            switch operation {
            case .remove(let indices): try updater.remove(entriesAt: indices)
            case .rename(let index, let name): try updater.rename(entryAt: index, to: name)
            case .add(let name, let bytes): try updater.add(data: bytes, as: name, modificationDate: TestSupport.date)
            case .directory(let name, let disk): try updater.add(contentsOf: disk, as: name)
            }
        }
    }

    // 混在は c0df9fb と同じ「旧 CD offset へ追加・finish → 段階 reader → legacy rebuild」。
    static func legacy(source url: URL, output: URL, operations: [Operation], options: WriterOptions = .init()) throws {
        try FileManager.default.copyItem(at: url, to: output)
        var removed: Set<Int> = []
        var renamed: [Int: String] = [:]
        var additions: [Operation] = []
        for op in operations {
            switch op {
            case .remove(let indices): for index in indices { removed.insert(index); renamed.removeValue(forKey: index) }
            case .rename(let index, let name): renamed[index] = name
            case .add, .directory: additions.append(op)
            }
        }
        if !additions.isEmpty {
            let source = try ZipUpdateSource(url: url)
            let layout = try ZipUpdateLayout(source: source)
            let handle = try FileHandle(forUpdating: output)
            let writer = ArchiveWriter(output: handle, url: output,
                                       format: .zip, options: options, zipSalt: { try salt(16) })
            try writer.prepareAppend(at: layout.centralOffset, existingPaths: [])
            for addition in additions {
                switch addition {
                case .add(let name, let bytes): try writer.add(data: bytes, as: name, modificationDate: TestSupport.date)
                case .directory(let name, let disk): try writer.add(contentsOf: disk, as: name)
                default: break
                }
            }
            try writer.finish(existingCount: layout.count, comment: layout.comment) { emit in
                try emit(source.bytes(at: layout.centralOffset, count: Int(layout.centralSize)))
            }
        }
        guard !removed.isEmpty || !renamed.isEmpty else { return }
        let staged = output.deletingLastPathComponent().appendingPathComponent("oracle-staged-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: output, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let source = try ZipUpdateSource(url: staged)
        let layout = try ZipUpdateLayout(source: source)
        let reader = try ArchiveReader.open(source: source, options: ArchiveUpdater.readerOptions)
        let handle = try FileHandle(forUpdating: output)
        defer { try? handle.close() }
        try LegacyZipRebuild.write(source: source, layout: layout, reader: reader, output: handle,
                                   removed: removed, renamed: renamed, rawRecord: { try $0.rawRecord(of: $1) })
    }

    @discardableResult
    static func compare(_ source: URL, operations: [Operation], label: String,
                        options: WriterOptions = .init(compressionMethod: .stored),
                        expectedStrategy: ArchiveUpdater.CommitStrategy? = nil,
                        byteIdentical: Bool = true) throws -> URL {
        let parent = source.deletingLastPathComponent()
        let output = parent.appendingPathComponent("new-\(label).zip")
        let old = parent.appendingPathComponent("old-\(label).zip")
        defer { try? FileManager.default.removeItem(at: old) }
        try legacy(source: source, output: old, operations: operations, options: options)
        try EncryptionPrimitives.$testingRandomBytes.withValue(salt) {
            let updater = try ArchiveUpdater.open(url: source, output: output, options: options)
            try mutate(updater, operations)
            try updater.commit()
            if let expectedStrategy { XCTAssertEqual(updater.lastCommitStrategy, expectedStrategy, label) }
        }
        if byteIdentical { try XCTAssertFilesEqual(output, old, label) }
        else {
            let a = try ArchiveReader.open(url: output, options: ReaderOptions(password: options.password)), b = try ArchiveReader.open(url: old, options: ReaderOptions(password: options.password))
            XCTAssertEqual(a.entries.map(\.name), b.entries.map(\.name))
            for (left, right) in zip(a.entries, b.entries) {
                XCTAssertEqual(left.compressedSize, right.compressedSize)
                XCTAssertEqual(try a.read(left), try b.read(right))
            }
        }
        return output
    }

    static func info(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw WriterError.io(operation: "test lstat", code: errno) }
        return info
    }
}
