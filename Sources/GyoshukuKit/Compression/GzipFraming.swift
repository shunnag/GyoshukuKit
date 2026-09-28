import Foundation
private import zlib

// 参照仕様: RFC 1952。deflate 本体は DeflateBlock、ここは stream の header・trailer と CRC の連結だけを持つ。
// GzipCompressor（新規作成）と CompressedTarSpliceOutput（区切り単位の更新）が同じ byte を出す。
enum GzipFraming {
    /// ID1 ID2、CM=8、FLG=0、MTIME=0、XFL、OS=3（Unix）。XFL は level 9 で 2、1 以下で 4、他は 0。
    static func header(level: Int) -> Data {
        Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, level == 9 ? 2 : (level <= 1 ? 4 : 0), 3])
    }

    /// CRC32 と ISIZE（入力長 mod 2^32）。
    static func trailer(crc: UInt32, imageLength: UInt64) -> Data {
        var trailer = Data()
        trailer.le(crc)
        trailer.le(UInt32(truncatingIfNeeded: imageLength))
        return trailer
    }

    /// prefix の CRC に、その後ろに続く length byte の suffix の CRC を連結する。
    static func combineCRC(_ prefix: UInt32, _ suffix: UInt32, length: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32_combine(uLong(prefix), uLong(suffix), Int(length)))
    }
}
