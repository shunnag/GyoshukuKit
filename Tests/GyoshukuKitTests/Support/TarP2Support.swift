import Foundation
import KaitoKit
import XCTest
@testable import GyoshukuKit

enum TarP2Support {
    static func suffix(_ format: GyoshukuKit.ArchiveFormat) -> String {
        switch format {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXZ: "tar.xz"
        case .sevenZip: "7z"
        case .lha: "lha"
        }
    }
    static func fixture(_ root: URL, count: Int = 6, size: Int = 513, format: GyoshukuKit.ArchiveFormat = .tar) throws -> URL {
        let url = root.appendingPathComponent("source.tar")
        let writer = try ArchiveWriter.create(url: url, format: format)
        for index in 0..<count {
            try writer.add(data: Data(repeating: UInt8(index % 251), count: size), as: String(format: "file-%06d", index),
                           modificationDate: ZipTestSupport.date)
        }
        try writer.finish()
        return url
    }
    static func scan(_ url: URL) throws -> (TarLayout, ZipUpdateSource, ArchiveReader) {
        let source = try ZipUpdateSource(url: url)
        let reader = try ArchiveReader.open(source: source, sourceURL: url, options: .init(
            limits: .init(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose))
        let gate = try ArchiveRepresentability.validateRepresentability(entries: reader.entries, format: .tar, reader: reader)
        let layout = try TarLayout.scan(source: source, length: source.length, entries: reader.entries,
                                        nameEncoding: reader.nameEncoding, hardLinkTargets: gate.hardLinkTargets, dataTargets: gate.dataTargets)
        return (layout, source, reader)
    }
    static func archive(_ members: [(TarRecords.Entry, Data)], at url: URL, prefix: Data = Data(), tail: Data? = nil) throws {
        var bytes = prefix
        for (entry, data) in members {
            bytes += entry.headers() + data + Data(count: TarRecords.padding(UInt64(data.count)))
        }
        bytes += tail ?? Data(count: 1024 + (10240 - (bytes.count + 1024) % 10240) % 10240)
        try bytes.write(to: url)
    }
    static func checksum(_ header: inout Data) {
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        TarRecords.number(header.reduce(UInt64(0)) { $0 + UInt64($1) }, in: &header, at: 148, width: 7)
        header[155] = 32
    }
    static func extensionBytes(_ type: UInt8, _ payload: Data) -> Data {
        TarRecords.Entry(name: Data("extension".utf8), size: UInt64(payload.count), type: type).ustar()
            + payload + Data(count: TarRecords.padding(UInt64(payload.count)))
    }
    static func work(_ root: URL) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
