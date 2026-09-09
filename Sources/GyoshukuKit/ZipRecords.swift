import Foundation

// APPNOTE の公開 byte 表だけから構築する。local と central は別々に組み立てる。
enum ZipRecords {
    static let limit = UInt64(UInt32.max)
    static let madeBy: UInt16 = (3 << 8) | 63
    static let flags: UInt16 = 1 << 11

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

        var needsSize64: Bool { size >= limit || compressedSize >= limit }
        var version: UInt16 { needsSize64 || offset >= limit ? 45 : 20 }

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
            if !zip64.isEmpty { result.append(field(0x0001, zip64)) }
            if local && reservedZIP64 && zip64.isEmpty {
                // deflate の最大長で予約した領域。不要になっても payload 位置は動かさない。
                result.append(field(0xFFFF, Data(repeating: 0, count: 16)))
            }
            var timestamp = Data([local ? 3 : 1])
            timestamp.le(mtime)
            if local { timestamp.le(atime) }
            result.append(field(0x5455, timestamp))
            if let (uid, gid) = owners {
                var owner = Data([1, 4])
                owner.le(uid)
                owner.append(4)
                owner.le(gid)
                result.append(field(0x7875, owner))
            }
            return result
        }

        func local() -> Data {
            let extra = extras(local: true)
            var result = Data()
            result.le(UInt32(0x04034B50))
            result.le(version)
            result.le(flags)
            result.le(method.rawValue)
            result.le(dosTime)
            result.le(dosDate)
            result.le(crc)
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
            result.le(UInt32(0x02014B50))
            result.le(madeBy)
            result.le(version)
            result.le(flags)
            result.le(method.rawValue)
            result.le(dosTime)
            result.le(dosDate)
            result.le(crc)
            result.le(UInt32(min(compressedSize, limit)))
            result.le(UInt32(min(size, limit)))
            result.le(UInt16(name.count))
            result.le(UInt16(extra.count))
            result.le(UInt16(0)) // comment
            result.le(UInt16(0)) // disk start: 単一 volume なので sentinel は不要
            result.le(UInt16(0)) // internal attributes
            let dosByte: UInt32 = mode & 0xF000 == 0x4000 ? 0x10 : 0
            result.le((UInt32(mode) << 16) | dosByte)
            result.le(UInt32(min(offset, limit)))
            result.append(name)
            result.append(extra)
            return result
        }
    }

    static func end(count: UInt64, centralSize: UInt64, centralOffset: UInt64) throws -> Data {
        var result = Data()
        if count >= UInt16.max || centralSize >= limit || centralOffset >= limit {
            result.le(UInt32(0x06064B50))
            result.le(UInt64(44))
            result.le(madeBy)
            result.le(UInt16(45))
            result.le(UInt32(0))
            result.le(UInt32(0))
            result.le(count)
            result.le(count)
            result.le(centralSize)
            result.le(centralOffset)
            result.le(UInt32(0x07064B50))
            result.le(UInt32(0))
            result.le(try checkedAdd(centralOffset, centralSize))
            result.le(UInt32(1))
        }
        result.le(UInt32(0x06054B50))
        result.le(UInt16(0))
        result.le(UInt16(0))
        result.le(UInt16(min(count, UInt64(UInt16.max))))
        result.le(UInt16(min(count, UInt64(UInt16.max))))
        result.le(UInt32(min(centralSize, limit)))
        result.le(UInt32(min(centralOffset, limit)))
        result.le(UInt16(0))
        return result
    }
}

func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw WriterError.sizeOverflow }
    return result.partialValue
}

extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
