import Foundation
private import zlib

// zlib の CRC-32（IEEE）。ZIP / gzip / XZ / 7z の照合値を同じ関数で積む。
func updateCRC(_ crc: UInt32, _ data: Data) -> UInt32 {
    data.withUnsafeBytes { updateCRC(crc, $0) }
}

func updateCRC(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
    guard !bytes.isEmpty else { return crc }
    return UInt32(crc32(uLong(crc), bytes.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
}
