import Foundation

// 出典: xxHash specification v0.2.0 の XXH32（独立実装、第三者 source の同梱なし）。
// https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
// LZ4 frame の header / block / content checksum は seed 0 を使う。
struct XXH32 {
    private static let prime1: UInt32 = 2_654_435_761
    private static let prime2: UInt32 = 2_246_822_519
    private static let prime3: UInt32 = 3_266_489_917
    private static let prime4: UInt32 = 668_265_263
    private static let prime5: UInt32 = 374_761_393
    private let seed: UInt32
    private var lane1: UInt32
    private var lane2: UInt32
    private var lane3: UInt32
    private var lane4: UInt32
    private var length: UInt32 = 0
    private var hasStripe = false
    private var tail = [UInt8]()

    init(seed: UInt32 = 0) {
        self.seed = seed
        lane1 = seed &+ Self.prime1 &+ Self.prime2
        lane2 = seed &+ Self.prime2
        lane3 = seed
        lane4 = seed &- Self.prime1
        tail.reserveCapacity(16)
    }

    /// 全入力を集めず、16 byte stripe 未満の末尾だけを保持する。
    mutating func update(_ data: Data) {
        data.withUnsafeBytes { bytes in
            length &+= UInt32(truncatingIfNeeded: bytes.count)
            var offset = 0
            if !tail.isEmpty {
                let count = min(16 - tail.count, bytes.count)
                tail.append(contentsOf: bytes.prefix(count))
                offset += count
                if tail.count == 16 {
                    // self と tail の同時の排他的 access を避ける。
                    let stripe = tail
                    stripe.withUnsafeBytes { consumeStripe($0, at: 0) }
                    tail.removeAll(keepingCapacity: true)
                }
            }
            while bytes.count - offset >= 16 {
                consumeStripe(bytes, at: offset)
                offset += 16
            }
            tail.append(contentsOf: bytes.dropFirst(offset))
        }
    }

    /// snapshot を取っても次の update に影響しない。長さは仕様どおり mod 2^32。
    var value: UInt32 {
        var hash = hasStripe
            ? Self.rotate(lane1, 1) &+ Self.rotate(lane2, 7) &+ Self.rotate(lane3, 12) &+ Self.rotate(lane4, 18)
            : seed &+ Self.prime5
        hash &+= length
        tail.withUnsafeBytes { bytes in
            var offset = 0
            while bytes.count - offset >= 4 {
                hash = Self.rotate(hash &+ Self.word(bytes, at: offset) &* Self.prime3, 17) &* Self.prime4
                offset += 4
            }
            while offset < bytes.count {
                hash = Self.rotate(hash &+ UInt32(bytes[offset]) &* Self.prime5, 11) &* Self.prime1
                offset += 1
            }
        }
        hash = (hash ^ (hash >> 15)) &* Self.prime2
        hash = (hash ^ (hash >> 13)) &* Self.prime3
        return hash ^ (hash >> 16)
    }

    static func digest(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var hash = Self(seed: seed)
        hash.update(data)
        return hash.value
    }

    private mutating func consumeStripe(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
        lane1 = Self.round(lane1, Self.word(bytes, at: offset))
        lane2 = Self.round(lane2, Self.word(bytes, at: offset + 4))
        lane3 = Self.round(lane3, Self.word(bytes, at: offset + 8))
        lane4 = Self.round(lane4, Self.word(bytes, at: offset + 12))
        hasStripe = true
    }

    private static func word(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private static func rotate(_ word: UInt32, _ bits: Int) -> UInt32 {
        (word << bits) | (word >> (32 - bits))
    }

    private static func round(_ accumulator: UInt32, _ word: UInt32) -> UInt32 {
        rotate(accumulator &+ word &* prime2, 13) &* prime1
    }
}
