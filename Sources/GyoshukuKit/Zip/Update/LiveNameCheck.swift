import Foundation
private import Darwin

// open 時の名前だけを固定し、削除・改名・追加は検査のたびに別途反映する。
final class LiveNameCheck {
    enum Mode { case reservations, writer }

    private struct Record {
        let range: Range<Int>
        let directory: Bool
        let slowIndex: Int
    }

    private struct Keys {
        let reservations: [UInt8]
        let writer: [UInt8]

        init(_ name: String) {
            let key = (name.hasSuffix("/") ? String(name.dropLast()) : name)
                .precomposedStringWithCanonicalMapping
            reservations = Array(key.utf8)
            writer = Array(ArchiveWriter.pathComponents(key).joined(separator: "/").utf8)
        }
    }

    private struct Matches {
        var exact = false
        var subtree = false
        var ancestorFile = false

        mutating func include(_ other: Matches) {
            exact = exact || other.exact
            subtree = subtree || other.subtree
            ancestorFile = ancestorFile || other.ancestorFile
        }
    }

    private let bytes: [UInt8]
    private let records: [Record]
    private let slowKeys: [Keys]

    init(count: Int, pathAt: (Int) -> (String, Bool)) {
        var bytes: [UInt8] = []
        var records: [Record] = []
        var slowKeys: [Keys] = []
        records.reserveCapacity(count)
        bytes.reserveCapacity(count * 24)
        for index in 0..<count {
            var (name, directory) = pathAt(index)
            let start = bytes.count
            let simple = name.withUTF8 { utf8 in
                let key = utf8.dropLast(utf8.last == 47 ? 1 : 0)
                var simple = !key.isEmpty
                var previousSlash = true
                for byte in key {
                    if byte >= 128 || (byte == 47 && previousSlash) { simple = false }
                    previousSlash = byte == 47
                }
                bytes.append(contentsOf: key)
                return simple && !previousSlash
            }
            let slowIndex = simple ? -1 : slowKeys.count
            if !simple { slowKeys.append(Keys(name)) }
            records.append(Record(range: start..<bytes.count, directory: directory, slowIndex: slowIndex))
        }
        self.bytes = bytes
        self.records = records
        self.slowKeys = slowKeys
    }

    func validate(_ name: String, directory: Bool, mode: Mode, excluded: [Bool],
                  excluding: Int? = nil, renamed: [Int: String], appended: [(String, Bool)]) throws {
        precondition(excluded.count == records.count)
        let candidate = Keys(name).reservations
        var matches = Matches()
        candidate.withUnsafeBufferPointer { candidate in
            bytes.withUnsafeBufferPointer { bytes in
                for index in records.indices where !excluded[index] && index != excluding {
                    let record = records[index]
                    if record.slowIndex < 0 {
                        matches.include(Self.compare(UnsafeBufferPointer(rebasing: bytes[record.range]),
                                                     candidate, directory: record.directory))
                    } else {
                        matches.include(Self.compare(slowKeys[record.slowIndex], candidate,
                                                     directory: record.directory, mode: mode))
                    }
                }
            }
            for (index, name) in renamed where index != excluding {
                matches.include(Self.compare(Keys(name), candidate, directory: records[index].directory, mode: mode))
            }
            for (name, directory) in appended {
                matches.include(Self.compare(Keys(name), candidate, directory: directory, mode: mode))
            }
        }
        // 改名は祖先 file を先に、追加は同名を先に拒否する。
        if mode == .reservations, matches.ancestorFile { throw WriterError.invalidPath(name) }
        if matches.exact { throw WriterError.duplicatePath(name) }
        if (!directory && matches.subtree) || matches.ancestorFile { throw WriterError.invalidPath(name) }
    }

    private static func compare(_ keys: Keys, _ candidate: UnsafeBufferPointer<UInt8>,
                                directory: Bool, mode: Mode) -> Matches {
        var matches = keys.reservations.withUnsafeBufferPointer { compare($0, candidate, directory: directory) }
        if mode == .writer {
            // writer の必要 directory だけは、既存名の空成分を除いて数える。
            matches.subtree = keys.writer.withUnsafeBufferPointer { compare($0, candidate, directory: directory).subtree }
        }
        return matches
    }

    private static func compare(_ existing: UnsafeBufferPointer<UInt8>, _ candidate: UnsafeBufferPointer<UInt8>,
                                directory: Bool) -> Matches {
        let common = min(existing.count, candidate.count)
        guard common == 0 || memcmp(existing.baseAddress!, candidate.baseAddress!, common) == 0 else { return Matches() }
        if existing.count == candidate.count { return Matches(exact: true) }
        if existing.count > candidate.count { return Matches(subtree: existing[common] == 47) }
        return Matches(ancestorFile: !directory && candidate[common] == 47)
    }
}
