import Foundation

// little-endian の固定長読み書き。ZIP / LHA / XZ の byte 表で共有し、範囲検査は呼出側が行う。
extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func le16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func le32(_ at: Int) -> UInt32 { UInt32(le16(at)) | UInt32(le16(at + 2)) << 16 }
    func le64(_ at: Int) -> UInt64 { UInt64(le32(at)) | UInt64(le32(at + 4)) << 32 }
    mutating func leSet<T: FixedWidthInteger>(_ value: T, at: Int) {
        let relative = at - startIndex
        precondition(relative >= 0 && relative <= count && MemoryLayout<T>.size <= count - relative)
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { encoded in
            withUnsafeMutableBytes { bytes in
                bytes.baseAddress!.advanced(by: relative).copyMemory(from: encoded.baseAddress!, byteCount: encoded.count)
            }
        }
    }
}
