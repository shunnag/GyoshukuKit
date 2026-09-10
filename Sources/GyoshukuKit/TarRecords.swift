import Foundation

// POSIX ustar / pax の公開 byte 表に従う。拡張が不要な member は ustar だけで書く。
enum TarRecords {
    static let blockSize = 512
    static let recordSize = 20 * blockSize
    static let octalSizeLimit: UInt64 = 0o77777777777

    struct Entry {
        var name: Data
        var mode: UInt16 = 0o644
        var size: UInt64 = 0
        var mtime: Int64 = 0
        var uid: UInt32 = 0
        var gid: UInt32 = 0
        var type: UInt8 = 0x30
        var link = Data()

        func headers() -> Data {
            let split = TarRecords.splitPath(name)
            var pax = Data()
            // ustar に文字集合の宣言はない。非 ASCII は pax の UTF-8 として保存する。
            if split == nil || name.contains(where: { $0 >= 0x80 }) {
                pax.append(TarRecords.paxRecord("path", value: name))
            }
            if link.count > 100 || link.contains(where: { $0 >= 0x80 }) {
                if String(data: link, encoding: .utf8) == nil {
                    pax.append(TarRecords.paxRecord("hdrcharset", value: Data("BINARY".utf8)))
                }
                pax.append(TarRecords.paxRecord("linkpath", value: link))
            }
            for (key, value, limit) in [
                ("size", size, TarRecords.octalSizeLimit),
                ("uid", UInt64(uid), UInt64(0o7777777)),
                ("gid", UInt64(gid), UInt64(0o7777777))
            ] where value > limit {
                pax.append(TarRecords.paxRecord(key, value: Data(String(value).utf8)))
            }
            if mtime < 0 || mtime > Int64(TarRecords.octalSizeLimit) {
                pax.append(TarRecords.paxRecord("mtime", value: Data(String(mtime).utf8)))
            }
            var result = Data()
            if !pax.isEmpty {
                // 拡張 header 自身には拡張を要する値を置かず、次の member だけに適用する。
                // 名前は bsdtar と同じ <親>/PaxHeader/<葉> にする。pax を解さない古い
                // tar はこの名前で実体を取り出すため、固定名だと複数の拡張 header が
                // 同名で衝突する。ustar の 100 byte に収まらない場合だけ葉を詰める。
                let extended = Entry(name: TarRecords.extendedHeaderName(for: name),
                                     size: UInt64(pax.count), type: 0x78)
                result.append(extended.ustar())
                result.append(pax)
                result.append(Data(count: TarRecords.padding(UInt64(pax.count))))
            }
            result.append(ustar())
            return result
        }

        private func ustar() -> Data {
            var header = Data(count: TarRecords.blockSize)
            let split = TarRecords.splitPath(name)
            header.replaceSubrange(0..<(split?.name.count ?? min(name.count, 100)),
                                   with: split?.name ?? Data(name.prefix(100)))
            if let prefix = split?.prefix {
                header.replaceSubrange(345..<(345 + prefix.count), with: prefix)
            }
            TarRecords.number(UInt64(mode & 0o7777), in: &header, at: 100, width: 8)
            TarRecords.number(UInt64(uid), in: &header, at: 108, width: 8)
            TarRecords.number(UInt64(gid), in: &header, at: 116, width: 8)
            TarRecords.number(size, in: &header, at: 124, width: 12)
            if mtime < 0 {
                TarRecords.base256(UInt64(bitPattern: mtime), negative: true, in: &header, at: 136, width: 12)
            } else {
                TarRecords.number(UInt64(mtime), in: &header, at: 136, width: 12)
            }
            header[156] = type
            header.replaceSubrange(157..<(157 + min(link.count, 100)), with: link.prefix(100))
            header.replaceSubrange(257..<265, with: Data("ustar\0".utf8) + Data("00".utf8))
            // uname / gname は空のまま。作者のアカウント名を持ち出さない。
            header.replaceSubrange(148..<156, with: Data(repeating: 0x20, count: 8))
            let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
            TarRecords.number(checksum, in: &header, at: 148, width: 7)
            header[155] = 0x20
            return header
        }
    }

    static func timestamp(_ date: Date) throws -> Int64 {
        let seconds = floor(date.timeIntervalSince1970)
        guard seconds.isFinite, seconds >= Double(Int64.min), seconds < -Double(Int64.min) else {
            throw WriterError.invalidDate
        }
        return Int64(seconds)
    }

    /// pax 拡張 header 自身の名前。bsdtar は <親>/PaxHeader/<葉> を使う。
    /// ustar の name は 100 byte までなので、超える場合は葉を末尾から詰める。
    static func extendedHeaderName(for name: Data) -> Data {
        let slash = Data([0x2F])
        let text = Data(name.reversed().drop { $0 == 0x2F }.reversed())
        let cut = text.lastIndex(of: 0x2F)
        let parent = cut.map { text[..<$0] } ?? Data()
        let leaf = cut.map { text[text.index(after: $0)...] } ?? text[...]
        var head = Data(parent)
        if !head.isEmpty { head.append(slash) }
        head.append(Data("PaxHeader".utf8))
        head.append(slash)
        let room = 100 - head.count
        guard room > 0 else { return Data("PaxHeader".utf8) }
        return head + Data(leaf.suffix(room))
    }

    static func padding(_ size: UInt64) -> Int {
        Int((UInt64(blockSize) - size % UInt64(blockSize)) % UInt64(blockSize))
    }

    private static func splitPath(_ path: Data) -> (name: Data, prefix: Data)? {
        if path.count <= 100 { return (path, Data()) }
        // prefix は区切り位置でしか分けない。directory の末尾の / は name に残す。
        for index in path.indices.reversed() where path[index] == 0x2F && index < path.count - 1 {
            if index <= 155 && path.count - index - 1 <= 100 {
                return (Data(path[(index + 1)...]), Data(path[..<index]))
            }
        }
        return nil
    }

    private static func paxRecord(_ key: String, value: Data) -> Data {
        let body = Data((" " + key + "=").utf8) + value + Data([0x0A])
        var length = body.count + 1
        // 桁数も record 長に含むので、桁が増える境界では収束するまで計算する。
        while body.count + String(length).utf8.count != length {
            length = body.count + String(length).utf8.count
        }
        return Data(String(length).utf8) + body
    }

    private static func number(_ value: UInt64, in header: inout Data, at offset: Int, width: Int) {
        let octal = Array(String(value, radix: 8).utf8)
        if octal.count < width {
            let field = Data(repeating: 0x30, count: width - 1 - octal.count) + Data(octal) + Data([0])
            header.replaceSubrange(offset..<(offset + width), with: field)
        } else {
            // あふれた値は pax が真。旧 reader にも値を渡せるよう base-256 を併記する。
            base256(value, negative: false, in: &header, at: offset, width: width)
        }
    }

    private static func base256(_ value: UInt64, negative: Bool, in header: inout Data, at offset: Int, width: Int) {
        var field = Data(repeating: negative ? 0xFF : 0, count: width)
        for index in 0..<min(width, 8) {
            field[width - index - 1] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
        field[0] |= 0x80
        header.replaceSubrange(offset..<(offset + width), with: field)
    }
}
