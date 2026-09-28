import Foundation
internal import KaitoKit

enum TarHeaderRewrite {
    static func rewrite(source: any ByteSource, unit: TarLayout.Unit, name: Data?, link: Data?,
                        materializedSize: UInt64?) throws -> Data {
        let group = try TarLayout.group(source: source, unit: unit)
        var header = group.header
        var records = group.records
        let finalName = name ?? group.name
        let canonical = ["path", "hdrcharset", "linkpath", "size", "uid", "gid", "mtime"]

        func replace(_ keys: Set<String>, key: String, value: Data?) {
            let first = records.firstIndex { keys.contains($0.key) }
            records.removeAll { keys.contains($0.key) }
            guard let value else { return }
            let insertion: Int
            if let first { insertion = min(first, records.count) }
            else {
                let rank = canonical.firstIndex(of: key) ?? canonical.count
                if let later = records.firstIndex(where: { (canonical.firstIndex(of: $0.key) ?? -1) > rank }) {
                    insertion = later
                } else { insertion = records.prefix(while: { canonical.contains($0.key) }).count }
            }
            records.insert(.init(key: key, value: value, raw: TarRecords.paxRecord(key, value: value)), at: insertion)
        }
        func field(_ range: Range<Int>, _ bytes: Data) {
            header.replaceSubrange(range, with: Data(count: range.count))
            header.replaceSubrange(range.lowerBound..<(range.lowerBound + min(range.count, bytes.count)), with: bytes.prefix(range.count))
        }
        let posix = TarLayout.isPOSIX(header)
        if let name {
            var storedName = name
            if unit.sparseName {
                replace(["path", "GNU.sparse.name"], key: "GNU.sparse.name", value: name)
                let trimmed = Data(name.reversed().drop(while: { $0 == 47 }).reversed())
                if let slash = trimmed.lastIndex(of: 47) {
                    storedName = Data(trimmed[...slash]) + Data("GNUSparseFile.0/".utf8) + Data(trimmed[(slash + 1)...])
                } else { storedName = Data("GNUSparseFile.0/".utf8) + trimmed }
            } else {
                let fits = !name.contains(where: { $0 >= 128 }) && (posix ? TarRecords.splitPath(name) != nil : name.count <= 100)
                replace(["path"], key: "path", value: fits ? nil : name)
            }
            let split = posix ? TarRecords.splitPath(storedName) : nil
            field(0..<100, split?.name ?? Data(storedName.prefix(100)))
            if posix { field(345..<500, split?.prefix ?? Data()) }
        }
        if let size = materializedSize {
            replace(["linkpath"], key: "linkpath", value: nil)
            replace(["size"], key: "size", value: size > TarRecords.octalSizeLimit ? Data(String(size).utf8) : nil)
            field(157..<257, Data())
            header[156] = 0x30
            TarRecords.number(size, in: &header, at: 124, width: 12)
        } else if let link {
            let fits = link.count <= 100 && !link.contains(where: { $0 >= 128 })
            replace(["linkpath"], key: "linkpath", value: fits ? nil : link)
            field(157..<257, Data(link.prefix(100)))
        }
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        TarRecords.number(checksum, in: &header, at: 148, width: 7)
        header[155] = 32
        var pax = Data()
        for record in records { pax.append(record.raw) }
        var extended = Data()
        if !pax.isEmpty {
            extended = TarRecords.Entry(name: TarRecords.extendedHeaderName(for: finalName),
                                        size: UInt64(pax.count), type: 0x78).ustar()
            extended.append(pax)
            extended.append(Data(count: TarRecords.padding(UInt64(pax.count))))
        }
        var result = Data()
        if !group.extensions.contains(where: { $0.type == 0x78 || $0.type == 0x58 }) { result.append(extended) }
        for item in group.extensions {
            switch item.type {
            case 0x78, 0x58: result.append(extended)
            case 0x4c: if name == nil { result.append(item.bytes) }
            case 0x4b: if link == nil && materializedSize == nil { result.append(item.bytes) }
            default: result.append(item.bytes)
            }
        }
        result.append(header)
        return result
    }
}
