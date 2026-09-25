import Foundation
internal import KaitoKit

struct TarLayout {
    @TaskLocal static var testingKaitoKitMismatch = false

    struct Unit {
        let groupStart: UInt64
        let headerStart: UInt64
        let dataStart: UInt64
        let storedSize: UInt64
        let paddedEnd: UInt64
        let typeFlag: UInt8
        let flags: UInt8
        var isGlobal: Bool { typeFlag == 0x67 }
        var isSparse: Bool { flags & 1 != 0 }
        var sparseName: Bool { flags & 2 != 0 }
        var range: Range<UInt64> { groupStart..<paddedEnd }
        var headerRange: Range<UInt64> { groupStart..<dataStart }
    }

    struct PaxRecord {
        let key: String
        let value: Data
        let raw: Data
    }
    struct Extension {
        let type: UInt8
        let bytes: Data
    }
    struct Group {
        var header: Data
        var extensions: [Extension]
        var records: [PaxRecord]
        var name: Data
        var link: Data
    }
    let units: [Unit]
    let memberUnitIndices: [Int]
    let membersEnd: UInt64
    let length: UInt64
    func member(_ index: Int) -> Unit { units[memberUnitIndices[index]] }

    static func refuse(_ reason: String) -> TarUpdaterError { .requiresRewrite(reason: reason) }

    static func scan(source: any ByteSource, length: UInt64, entries: [ArchiveEntry],
                     nameEncoding: String.Encoding?, hardLinkTargets: [Int: Int], dataTargets: [Int: Int]) throws -> TarLayout {
        if nameEncoding != nil { throw refuse("R10: name encoding") }
        let layout = try walk(source: source, range: 0..<length) { index, unit, group in
            guard index < entries.count, !testingKaitoKitMismatch else { throw refuse("R8: member count") }
            let entry = entries[index]
            let type = unit.typeFlag == 0 ? "NUL" : String(UnicodeScalar(unit.typeFlag))
            guard entry.formatSpecific["typeFlag"] == type, entry.compressedSize == unit.storedSize,
                  group.name.elementsEqual(entry.rawName.bytes) else { throw refuse("R8: reader mismatch") }
        }
        guard layout.memberUnitIndices.count == entries.count else { throw refuse("R8: member count") }
        for (link, _) in hardLinkTargets {
            let target = dataTargets[link]!
            if layout.member(target).isSparse { throw refuse("R5: sparse hard link target") }
            for index in [link, target] where entries[index].rawName.bytes != Array(entries[index].name.utf8) {
                throw refuse("R6: hard link raw name")
            }
        }
        return layout
    }

    // 4 KiB の header cache は本文を跨いで先読みしない。拡張 payload は別の範囲で読む。
    static func walk(source: any ByteSource, range: Range<UInt64>, headerReadLimit: UInt64? = nil,
                     visit: (Int, Unit, Group) throws -> Void) throws -> TarLayout {
        var cache = HeaderCache(source: source, length: headerReadLimit ?? range.upperBound)
        var offset = range.lowerBound
        var groupStart = offset
        var extensions: [Extension] = []
        var records: [PaxRecord] = []
        var pax: [String: Data] = [:]
        var longName: Data?
        var longLink: Data?
        var units: [Unit] = []
        var indices: [Int] = []
        var count = 0
        while offset < range.upperBound {
            if count & 1023 == 0 { try Task.checkCancellation() }
            count += 1
            let header = try cache.header(at: offset)
            if header.allSatisfy({ $0 == 0 }) { break }
            do { try validateChecksum(header) }
            catch { if offset == 0 { throw UpdaterError.invalidArchive("tar header がありません") }; throw error }
            let type = header[156]
            let declared = try number(header, range: 124..<136)
            let body = try checkedAdd(offset, 512)
            if [0x78, 0x58, 0x67, 0x4c, 0x4b].contains(type) {
                let end = try checkedAdd(body, checkedAdd(declared, UInt64(TarRecords.padding(declared))))
                guard end <= range.upperBound, declared <= UInt64(Int.max) else { throw refuse("R8: extension bounds") }
                let payload = try bytes(source, at: body, count: Int(declared))
                if type == 0x67 {
                    guard extensions.isEmpty, try parsePAX(payload).allSatisfy({ $0.key == "comment" }) else {
                        throw refuse("R1: global pax")
                    }
                    units.append(Unit(groupStart: offset, headerStart: offset, dataStart: body,
                                      storedSize: declared, paddedEnd: end, typeFlag: type, flags: 0))
                    groupStart = end
                } else {
                    let raw = header + payload + (try bytes(source, at: body + declared, count: TarRecords.padding(declared)))
                    extensions.append(Extension(type: type, bytes: raw))
                    if type == 0x78 || type == 0x58 {
                        guard records.isEmpty else { throw refuse("R8: duplicate pax") }
                        records = try parsePAX(payload)
                        for record in records {
                            if record.key == "hdrcharset" { throw refuse("R4: hdrcharset") }
                            if record.value.isEmpty { pax.removeValue(forKey: record.key) }
                            else { pax[record.key] = record.value }
                        }
                    } else if type == 0x4c { longName = Data(payload.reversed().drop(while: { $0 == 0 }).reversed()) }
                    else { longLink = Data(payload.reversed().drop(while: { $0 == 0 }).reversed()) }
                }
                offset = end
                continue
            }
            if type == 0x53 { throw refuse("R2: old GNU sparse") }
            let effective: UInt64
            if let size = pax["size"] {
                guard let parsed = UInt64(String(decoding: size, as: UTF8.self)) else { throw refuse("R8: pax size") }
                effective = parsed
            } else { effective = declared }
            if type == 0x31, effective != 0 { throw refuse("R3: hard link body") }
            let stored = (0x32...0x36).contains(type) && pax["size"] == nil ? 0 : effective
            let end = try checkedAdd(body, checkedAdd(stored, UInt64(TarRecords.padding(stored))))
            guard end <= range.upperBound else { throw refuse("R8: body bounds") }
            let sparse = [0, 0x30, 0x37].contains(type) && pax.keys.contains(where: { $0.hasPrefix("GNU.sparse.") })
            let sparseName = sparse ? pax["GNU.sparse.name"] : nil
            let name = sparseName ?? pax["path"] ?? longName ?? headerName(header)
            let link = pax["linkpath"] ?? longLink ?? field(header, 157..<257)
            let unit = Unit(groupStart: groupStart, headerStart: offset, dataStart: body, storedSize: stored,
                            paddedEnd: end, typeFlag: type, flags: (sparse ? 1 : 0) | (sparseName != nil ? 2 : 0))
            try visit(indices.count, unit, Group(header: header, extensions: extensions, records: records, name: name, link: link))
            indices.append(units.count)
            units.append(unit)
            offset = end
            groupStart = end
            extensions.removeAll(keepingCapacity: true)
            records.removeAll(keepingCapacity: true)
            pax.removeAll(keepingCapacity: true)
            longName = nil
            longLink = nil
        }
        guard extensions.isEmpty else { throw refuse("R8: orphan extension") }
        return TarLayout(units: units, memberUnitIndices: indices, membersEnd: offset, length: range.upperBound)
    }

    static func group(source: any ByteSource, unit: Unit) throws -> Group {
        var result: Group?
        // 本文は走査せず、末尾の座標だけを利用する。
        _ = try walk(source: source, range: unit.groupStart..<unit.paddedEnd, headerReadLimit: unit.dataStart) { _, _, group in result = group }
        guard let result else { throw refuse("R8: missing header") }
        return result
    }

    static func bytes(_ source: any ByteSource, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= source.length, UInt64(count) <= source.length - offset else { throw refuse("R8: read bounds") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let size = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[done..<count]), at: offset + UInt64(done))
                guard size > 0 else { throw refuse("R8: short read") }
                done += size
            }
        }
        return data
    }

    static func parsePAX(_ data: Data) throws -> [PaxRecord] {
        var result: [PaxRecord] = []
        var cursor = 0
        while cursor < data.count {
            guard let space = data[cursor...].firstIndex(of: 32),
                  let size = Int(String(decoding: data[cursor..<space], as: UTF8.self)),
                  size > space - cursor + 2, size <= data.count - cursor else { throw refuse("R8: pax length") }
            let end = cursor + size
            guard data[end - 1] == 10, let equal = data[(space + 1)..<(end - 1)].firstIndex(of: 61) else {
                throw refuse("R8: pax record")
            }
            result.append(PaxRecord(key: String(decoding: data[(space + 1)..<equal], as: UTF8.self),
                                    value: data.subdata(in: (equal + 1)..<(end - 1)), raw: data.subdata(in: cursor..<end)))
            cursor = end
        }
        return result
    }

    static func number(_ data: Data, range: Range<Int>? = nil) throws -> UInt64 {
        try data.withUnsafeBytes { raw in
            try number(UnsafeRawBufferPointer(rebasing: raw[range ?? 0..<raw.count]))
        }
    }

    private static func number(_ data: UnsafeRawBufferPointer) throws -> UInt64 {
        var value: UInt64 = 0
        if data.first! & 0x80 != 0 {
            guard data.first! & 0x40 == 0 else { throw refuse("R8: negative field") }
            for (index, byte) in data.enumerated() {
                let (product, overflow) = value.multipliedReportingOverflow(by: 256)
                guard !overflow else { throw refuse("R8: field overflow") }
                value = try checkedAdd(product, UInt64(index == 0 ? byte & 0x7f : byte))
            }
        } else {
            var digit = false, trailing = false, nul = false
            for byte in data {
                if byte == 0 { nul = true; continue }
                if byte == 32 { if digit { trailing = true }; continue }
                guard !nul, !trailing, (48...55).contains(byte), value <= UInt64.max / 8 else { throw refuse("R8: octal field") }
                digit = true
                value = try checkedAdd(value * 8, UInt64(byte - 48))
            }
        }
        return value
    }

    static func validateChecksum(_ header: Data) throws {
        try header.withUnsafeBytes { bytes in
            let expected = try number(UnsafeRawBufferPointer(rebasing: bytes[148..<156]))
            var unsigned: UInt64 = 256
            for index in 0..<148 { unsigned += UInt64(bytes[index]) }
            for index in 156..<512 { unsigned += UInt64(bytes[index]) }
            if unsigned == expected { return }
            var signed: Int64 = 256
            for index in 0..<148 { signed += Int64(Int8(bitPattern: bytes[index])) }
            for index in 156..<512 { signed += Int64(Int8(bitPattern: bytes[index])) }
            guard signed >= 0 && UInt64(signed) == expected else { throw refuse("R8: checksum") }
        }
    }

    static func isPOSIX(_ header: Data) -> Bool { header[257..<265] == Data("ustar\0".utf8) + Data("00".utf8) }
    static func field(_ header: Data, _ range: Range<Int>) -> Data { Data(header[range].prefix(while: { $0 != 0 })) }
    static func headerName(_ header: Data) -> Data {
        let name = field(header, 0..<100)
        let prefix = field(header, 345..<500)
        return isPOSIX(header) && !prefix.isEmpty ? prefix + Data([47]) + name : name
    }

    private struct HeaderCache {
        let source: any ByteSource
        let length: UInt64
        var start: UInt64 = 0
        var data = Data()
        mutating func header(at offset: UInt64) throws -> Data {
            guard offset <= length, length - offset >= 512 else { throw refuse("R8: header bounds") }
            if offset < start || offset - start > UInt64(data.count) || UInt64(data.count) - (offset - start) < 512 {
                start = offset
                data = try bytes(source, at: offset, count: Int(min(4096, length - offset)))
            }
            let index = Int(offset - start)
            return data.subdata(in: index..<(index + 512))
        }
    }
}
