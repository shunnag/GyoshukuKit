import Foundation

// APPNOTE の公開 byte 表だけから構築する。local と central は別々に組み立てる。
enum ZipRecords {
    static let limit = UInt64(UInt32.max)
    static let madeBy: UInt16 = (3 << 8) | 63
    static let flags: UInt16 = 1 << 11

    /// record 先頭の signature（APPNOTE 4.3）。
    enum Signature {
        static let local: UInt32 = 0x04034B50
        static let central: UInt32 = 0x02014B50
        static let end: UInt32 = 0x06054B50
        static let end64: UInt32 = 0x06064B50
        static let locator64: UInt32 = 0x07064B50
    }

    /// extra field の header ID（APPNOTE 4.5.2、Info-ZIP、WinZip）。
    enum ExtraID {
        static let zip64: UInt16 = 0x0001
        static let extendedTimestamp: UInt16 = 0x5455
        static let infoZipUnicodePath: UInt16 = 0x7075
        static let infoZipUnixNew: UInt16 = 0x7875
        static let winZipAES: UInt16 = 0x9901
        /// 予約領域。圧縮の最大長で確保した ZIP64 の余白と、無効化した Unicode 名の跡に使う。
        static let reservedPadding: UInt16 = 0xFFFF
        /// 名前と他の metadata が混在し得る extra。改名時は黙って捨てず拒否する。
        static let nameBearing: Set<UInt16> = [0x0008, 0x2605, 0x334D, 0x4F4C, 0x554E]
    }

    /// 可変長部（名前・extra・comment）を除いた record の長さ。
    enum FixedLength {
        static let local = 30
        static let central = 46
        static let end = 22
        static let end64 = 56
        static let locator64 = 20
    }

    static func field(_ id: UInt16, _ body: Data) -> Data {
        var data = Data()
        data.le(id)
        data.le(UInt16(body.count))
        data.append(body)
        return data
    }

    static func timestamp(_ date: Date) throws -> UInt32 {
        let seconds = floor(date.timeIntervalSince1970)
        guard seconds.isFinite, seconds >= Double(Int32.min), seconds <= Double(Int32.max) else {
            throw WriterError.invalidDate
        }
        return UInt32(bitPattern: Int32(seconds))
    }

    static func dosDate(_ date: Date, timeZone: TimeZone = .current) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, year >= 1980 else { return (0, 0x21) }
        guard year <= 2107 else { return (0xBF7D, 0xFF9F) }
        return (
            UInt16((c.hour! << 11) | (c.minute! << 5) | (c.second! / 2)),
            UInt16(((year - 1980) << 9) | (c.month! << 5) | c.day!)
        )
    }

    struct Entry {
        var name: Data
        var method: CompressionMethod
        var mtime: UInt32
        var atime: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
        var mode: UInt16
        var owners: (UInt32, UInt32)?
        var offset: UInt64
        var size: UInt64
        var compressedSize: UInt64 = 0
        var crc: UInt32 = 0
        var reservedZIP64 = false
        var encryption: ZipEncryption?

        var aesVersion: UInt16? { encryption == .aes256 ? (size < 20 ? 1 : 2) : nil }
        var storedCRC: UInt32 { aesVersion == 2 ? 0 : crc }
        var storedMethod: UInt16 { aesVersion == nil ? method.rawValue : 99 }
        // APPNOTE §5.8.9: method 14 の stream は EOS 付きなので bit 1 を立てる。AES の内側も同じ。
        var entryFlags: UInt16 { flags | (encryption == nil ? 0 : 1) | (method == .lzma ? 2 : 0) }

        var needsSize64: Bool { size >= limit || compressedSize >= limit }
        var version: UInt16 {
            // APPNOTE 6.3.10 §4.4.3・§4.4.5: method 12 は4.6。method 95 の要求 version は明記されていない。
            // XZ は7-Zip 26.03の生成 ZIP と公開定義に合わせて2.0とし、LZMA（method 14）の6.3は流用しない。
            // https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
            // https://github.com/ip7z/7zip/blob/main/CPP/7zip/Archive/Zip/ZipHeader.h
            let compressionVersion: UInt16 = method == .lzma ? 63 : method == .bzip2 ? 46 : 20
            return max(compressionVersion, aesVersion != nil ? 51 : 20, needsSize64 || offset >= limit ? 45 : 20)
        }

        func extras(local: Bool) -> Data {
            var result = Data()
            var zip64 = Data()
            if local {
                // APPNOTE 4.5.3: local は両サイズのみ。offset を載せない。
                if needsSize64 {
                    zip64.le(size)
                    zip64.le(compressedSize)
                }
            } else {
                // sentinel のあるフィールドだけを規定順で載せる。
                if size >= limit { zip64.le(size) }
                if compressedSize >= limit { zip64.le(compressedSize) }
                if offset >= limit { zip64.le(offset) }
            }
            if !zip64.isEmpty { result.append(field(ExtraID.zip64, zip64)) }
            if local && reservedZIP64 && zip64.isEmpty {
                // 圧縮の最大長で予約した領域。不要になっても payload 位置は動かさない。
                result.append(field(ExtraID.reservedPadding, Data(repeating: 0, count: 16)))
            }
            var timestamp = Data([local ? 3 : 1])
            timestamp.le(mtime)
            if local { timestamp.le(atime) }
            result.append(field(ExtraID.extendedTimestamp, timestamp))
            if let (uid, gid) = owners {
                var owner = Data([1, 4])
                owner.le(uid)
                owner.append(4)
                owner.le(gid)
                result.append(field(ExtraID.infoZipUnixNew, owner))
            }
            if let aesVersion {
                var aes = Data()
                aes.le(aesVersion)
                aes.append(contentsOf: [0x41, 0x45, 3])
                aes.le(method.rawValue)
                result.append(field(ExtraID.winZipAES, aes))
            }
            return result
        }

        func local() -> Data {
            let extra = extras(local: true)
            var result = Data()
            result.le(Signature.local)
            result.le(version)
            result.le(entryFlags)
            result.le(storedMethod)
            result.le(dosTime)
            result.le(dosDate)
            result.le(storedCRC)
            // 4.5.3 の local 例外: extra に両サイズがあるので両欄を sentinel にする。
            // central へこの判定を流用すると per-field 規則を壊す。
            result.le(needsSize64 ? UInt32.max : UInt32(compressedSize))
            result.le(needsSize64 ? UInt32.max : UInt32(size))
            result.le(UInt16(name.count))
            result.le(UInt16(extra.count))
            result.append(name)
            result.append(extra)
            return result
        }

        func central() -> Data {
            let extra = extras(local: false)
            var result = Data()
            result.le(Signature.central)
            result.le(madeBy)
            result.le(version)
            result.le(entryFlags)
            result.le(storedMethod)
            result.le(dosTime)
            result.le(dosDate)
            result.le(storedCRC)
            result.le(UInt32(min(compressedSize, limit)))
            result.le(UInt32(min(size, limit)))
            result.le(UInt16(name.count))
            result.le(UInt16(extra.count))
            result.le(UInt16(0)) // comment
            result.le(UInt16(0)) // disk start: 単一 volume なので sentinel は不要
            result.le(UInt16(0)) // internal attributes
            let dosByte: UInt32 = mode.isDirectoryMode ? 0x10 : 0
            result.le((UInt32(mode) << 16) | dosByte)
            result.le(UInt32(min(offset, limit)))
            result.append(name)
            result.append(extra)
            return result
        }
    }

    static func end(count: UInt64, centralSize: UInt64, centralOffset: UInt64, comment: Data = Data()) throws -> Data {
        guard comment.count <= Int(UInt16.max) else { throw WriterError.sizeOverflow }
        var result = Data()
        if count >= UInt16.max || centralSize >= limit || centralOffset >= limit {
            result.le(Signature.end64)
            result.le(UInt64(44))
            result.le(madeBy)
            result.le(UInt16(45))
            result.le(UInt32(0))
            result.le(UInt32(0))
            result.le(count)
            result.le(count)
            result.le(centralSize)
            result.le(centralOffset)
            result.le(Signature.locator64)
            result.le(UInt32(0))
            result.le(try checkedAdd(centralOffset, centralSize))
            result.le(UInt32(1))
        }
        result.le(Signature.end)
        result.le(UInt16(0))
        result.le(UInt16(0))
        result.le(UInt16(min(count, UInt64(UInt16.max))))
        result.le(UInt16(min(count, UInt64(UInt16.max))))
        result.le(UInt32(min(centralSize, limit)))
        result.le(UInt32(min(centralOffset, limit)))
        result.le(UInt16(comment.count))
        result.append(comment)
        return result
    }
}
