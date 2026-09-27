import Foundation
import Darwin
import XCTest
@testable import GyoshukuKit

enum BatchAdditionTestSupport {
    typealias S = AdditionProgressTestSupport
    static func fixture(_ root: URL, full: Bool = true) throws -> [ArchiveAddition] {
        let disk = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let sizes = (0..<(full ? 580 : 20)).map { [0, 1, 4096][$0 % 3] }
            + (full ? [65535, 65536, 65537, S.mib, S.mib, S.mib + 1, S.mib + 1, 3 * S.mib, 3 * S.mib] : [65535, 65536, 65537])
        var items: [ArchiveAddition] = []
        let seed = LHATestSupport.random(8192) + Data(repeating: 0x61, count: 8192)
        for (index, size) in sizes.enumerated() {
            let url = disk.appendingPathComponent("f\(index)")
            var data = Data(); data.reserveCapacity(size)
            while data.count < size { data.append(seed.prefix(min(seed.count, size - data.count))) }
            try data.write(to: url)
            items.append(.init(path: "f\(index)", source: .contents(of: url)))
        }
        for index in 0..<2 {
            let url = try S.file(disk, "stored\(index).png", size: 4096)
            items.insert(.init(path: "stored\(index).png", source: .contents(of: url)), at: 2 + index * 3)
        }
        for index in 0..<3 {
            let url = disk.appendingPathComponent("link\(index)")
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "f2")
            items.insert(.init(path: "link\(index)", source: .contents(of: url)), at: 4 + index * 3)
            items.insert(.init(path: "dir\(index)", source: .directory(modificationDate: ZipTestSupport.date)), at: 3 + index * 3)
        }
        for index in 0..<2 {
            let first = try S.file(disk, "hard\(index)", size: 4096)
            let second = disk.appendingPathComponent("hard\(index)-alias")
            XCTAssertEqual(link(first.path, second.path), 0)
            items.append(.init(path: first.lastPathComponent, source: .contents(of: first)))
            items.append(.init(path: second.lastPathComponent, source: .contents(of: second)))
        }
        return items
    }

    static func resetDates(_ items: [ArchiveAddition]) throws {
        for item in items { if let url = item.sourceURL { try S.timestamp(url) } }
    }

    static func applicable(_ items: [ArchiveAddition], format: ArchiveFormat) -> [ArchiveAddition] {
        format == .lha ? items.filter { !$0.path.hasPrefix("link") } : items
    }

    static func singles(_ writer: ArchiveWriter, _ items: [ArchiveAddition]) throws {
        for item in items {
            switch item.source {
            case let .contents(url): try writer.add(contentsOf: url, as: item.path, ownerIDs: item.ownerIDs)
            case let .directory(date): try writer.addDirectory(item.path, modificationDate: date, ownerIDs: item.ownerIDs)
            }
        }
    }

    static func singles(_ editor: any ArchiveEditing, _ items: [ArchiveAddition]) throws {
        for item in items {
            switch item.source {
            case let .contents(url): try editor.add(contentsOf: url, as: item.path, ownerIDs: item.ownerIDs)
            case let .directory(date): try editor.addDirectory(item.path, modificationDate: date, ownerIDs: item.ownerIDs)
            }
        }
    }

    static func small(_ root: URL, count: Int = 5, size: Int = 4096) throws -> [ArchiveAddition] {
        try (0..<count).map { index in
            let url = root.appendingPathComponent("disk-\(index)")
            try Data(repeating: UInt8(index % 251), count: size).write(to: url)
            try S.timestamp(url)
            return .init(path: "item-\(index)", source: .contents(of: url))
        }
    }
}
