import Foundation

/// 決定的な試験用の byte 列。seed を固定し、実行ごとの偶然の圧縮率で stored の判定や chunk の境界が変わらないようにする。
/// seed や式を変えると、その byte 列に合わせた期待値（stored への切り替え、圧縮後の大きさなど）が動く。
/// 7z の probe に使う単語と AES-CTR の corpus は `SevenZipProbePayload` にある。
enum TestCorpus {
    /// xorshift64* の上位 8 bit を `alphabetMask` で絞った byte 列。常に同じ seed から始める。
    static func random(_ count: Int, alphabetMask: UInt8 = 255) -> Data {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("corpus.random", phaseStart, input: count) }
        var state: UInt64 = 0xD137_923A_6E25_9B41
        // seed と各 byte は従来どおり。Array の append と最後のコピーを省く。
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for offset in 0..<count {
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                buffer[offset] = UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56) & alphabetMask
            }
        }
        return bytes
    }

    /// 固定 seed の擬似ソースコード。512 KiB ごとの独立した内容を一度繰り返し、
    /// 256 KiB reset では失われる距離の一致を含める。16 MiB 境界は module の間に置く。
    static func pseudoSource(mebibytes: Int) -> Data {
        let phaseStart = EncoderTestTiming.start()
        defer { EncoderTestTiming.end("corpus.source", phaseStart, input: mebibytes << 20) }
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

    /// PPMd の英文風 prose。固定 seed で語順を選び、同一 block の繰返しを作らない。
    static func englishLike(size: Int) -> Data {
        let subjects = ["The reader", "A writer", "Our neighbor", "The teacher", "A traveller", "The scientist",
                        "A young student", "The gardener", "An artist", "The librarian", "A careful observer"]
        let verbs = ["noticed", "described", "remembered", "considered", "examined", "discovered", "discussed",
                     "explained", "admired", "understood", "questioned", "studied"]
        let adjectives = ["quiet", "small", "distant", "familiar", "beautiful", "strange", "ancient", "ordinary",
                          "bright", "unusual", "delicate", "remarkable", "interesting", "unexpected"]
        let nouns = ["garden", "river", "story", "painting", "village", "house", "forest", "library", "mountain",
                     "letter", "window", "journey", "bridge", "question", "book", "conversation", "city"]
        let endings = ["in the early morning", "during the long winter", "before the rain began", "after the meeting",
                       "near the old station", "on a warm summer evening", "while the others waited", "at the end of the day"]
        var random = TestCorpus.XorShift64(state: 0x349A_7392_2190_7DB1)
        func choose(_ words: [String]) -> String { words[Int(random.next() % UInt64(words.count))] }
        var input = Data()
        while input.count < size {
            let sentence = "\(choose(subjects)) \(choose(verbs)) the \(choose(adjectives)) \(choose(nouns)) \(choose(endings)). "
            let bytes = Data(sentence.utf8)
            input.append(bytes.prefix(size - input.count))
        }
        return input
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
