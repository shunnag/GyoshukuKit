import Foundation

// 試験の byte 検査器（ZipBytes・SevenZipBytes・LHABytes など）が共有する little-endian の読み出し。
// 製品の `zip16` / `zip32` を oracle にしないため、別の名前で独立に持つ。
// `offset` は Data の実際の添字で、slice でも 0 始まりに直さない。
extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(uint16LE(at: offset)) | UInt32(uint16LE(at: offset + 2)) << 16
    }

    func uint64LE(at offset: Int) -> UInt64 {
        UInt64(uint32LE(at: offset)) | UInt64(uint32LE(at: offset + 4)) << 32
    }
}
