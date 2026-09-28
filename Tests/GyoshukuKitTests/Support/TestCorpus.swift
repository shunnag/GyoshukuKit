import Foundation

/// 決定的な試験用の byte 列。seed を固定し、実行ごとの偶然の圧縮率で stored の判定や chunk の境界が変わらないようにする。
/// seed や式を変えると、その byte 列に合わせた期待値（stored への切り替え、圧縮後の大きさなど）が動く。
/// 7z の probe に使う単語と AES-CTR の corpus は `SevenZipProbePayload` にある。
enum TestCorpus {
    /// xorshift64* の上位 8 bit を `alphabetMask` で絞った byte 列。常に同じ seed から始める。
    static func random(_ count: Int, alphabetMask: UInt8 = 255) -> Data {
        var state: UInt64 = 0xD137_923A_6E25_9B41
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            bytes.append(UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56) & alphabetMask)
        }
        return Data(bytes)
    }

    /// 固定 seed の擬似ソースコード。512 KiB ごとの独立した内容を一度繰り返し、
    /// 256 KiB reset では失われる距離の一致を含める。16 MiB 境界は module の間に置く。
    static func pseudoSource(mebibytes: Int) -> Data {
        var state: UInt64 = 0x4D59_5DF4_D0F3_3173
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        let halfSize = 512 * 1024
        var result = Data()
        result.reserveCapacity(mebibytes * 1024 * 1024)
        for _ in 0..<mebibytes {
            var block = Data()
            block.reserveCapacity(halfSize)
            while block.count < halfSize {
                let line = Data("let item_\(String(next(), radix: 16)) = lookup(0x\(String(next(), radix: 16)));\n".utf8)
                block.append(line.prefix(halfSize - block.count))
            }
            result.append(block)
            result.append(block)
        }
        return result
    }

    /// Marsaglia の xorshift64（13, 7, 17）。呼び出し側が seed を選ぶ。
    struct XorShift64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }
}
