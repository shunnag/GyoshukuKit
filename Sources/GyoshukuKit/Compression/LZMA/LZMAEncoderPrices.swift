// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

extension LZMAEncodingEngine {
    // 価格は未到達値 1<<30 と4096位置以内の経路。加算は64 bit内に収まる。
    @inline(__always) func price(_ probability: UInt16, _ bit: Int) -> Int {
        Int(bitPrices[(bit &* 2048) &+ Int(probability)])
    }
    @inline(__always) func treePrice(_ p: UnsafePointer<UInt16>, bits: Int, symbol: Int, reverse: Bool = false) -> Int {
        var m = 1, total = 0
        for i in 0..<bits {
            let b = (symbol >> (reverse ? i : bits - 1 - i)) & 1
            total &+= price(p[m], b); m = m &* 2 &+ b
        }
        return total
    }
    @inline(__always) func literalPrice(_ data: UnsafePointer<UInt8>, position pos: UInt64, state s: Int, reps r: LZMARepetitions) -> Int {
        let previous: UInt8 = pos == 0 ? 0 : data[-1]
        let p = literalProbs(pos, previous: previous)
        var symbol = Int(data[0]) | 256
        var total = 0
        if s < 7 {
            repeat {
                total &+= price(p[symbol >> 8], (symbol >> 7) & 1)
                symbol <<= 1
            } while symbol < 65536
        } else {
            var match = Int(data[-r.a]), offset = 256
            repeat {
                match <<= 1
                total &+= price(p[offset &+ (match & offset) &+ (symbol >> 8)], (symbol >> 7) & 1)
                symbol <<= 1; offset &= ~(match ^ symbol)
            } while symbol < 65536
        }
        return total
    }
    @inline(__always) func pureRepPrice(_ index: Int, state s: Int, pos: Int) -> Int {
        if index == 0 { return price(probs[204 &+ s], 0) &+ price(probs[240 &+ s &* 16 &+ pos], 1) }
        return price(probs[204 &+ s], 1) &+ (index == 1 ? price(probs[216 &+ s], 0)
            : price(probs[216 &+ s], 1) &+ price(probs[228 &+ s], index &- 2))
    }
    @inline(__always) func rep0Price(state s: Int, pos: Int) -> Int {
        price(probs[s &* 16 &+ pos], 1) &+ price(probs[192 &+ s], 1) &+ pureRepPrice(0, state: s, pos: pos)
    }
    @inline(__always) func distancePrice(_ distance: Int, length: Int) -> Int {
        let ls = min(length &- 2, 3)
        if distance < 128 { return distancePrices[ls &* 128 &+ distance] }
        return slotPrices[ls &* 64 &+ Self.slot(distance)] &+ alignPrices[distance & 15]
    }
    /// 親の価格を二つの子で共有する。必要な葉まで展開し、作業領域も出力表を使う。
    @inline(__always) func fillTreePrices(_ p: UnsafePointer<UInt16>, bits: Int, base: Int,
                                         count: Int, destination: UnsafeMutablePointer<Int>) {
        destination[0] = base
        for depth in 0..<bits {
            let remaining = bits - depth - 1
            let width = 1 << depth
            let nodes = (count + (1 << (remaining + 1)) - 1) >> (remaining + 1)
            for prefix in stride(from: nodes - 1, through: 0, by: -1) {
                let value = destination[prefix], probability = p[width + prefix]
                let child = prefix * 2
                destination[child] = value &+ price(probability, 0)
                if (child + 1) << remaining < count { destination[child + 1] = value &+ price(probability, 1) }
            }
        }
    }
    func fillLengthPrices(offset: Int, destination: UnsafeMutablePointer<Int>) {
        let p = probs + offset
        let low = price(p[0], 0), middle = price(p[0], 1) + price(p[1], 0)
        let high = price(p[0], 1) + price(p[1], 1)
        // normal parser が価格を比較する長さは niceLen 以下。長い一致は即決する。
        let count = properties.niceLen - 1
        let highCount = max(0, count - 16)
        if highCount > 0 { fillTreePrices(p + 258, bits: 8, base: high, count: highCount, destination: destination + 16) }
        for pos in 0..<(1 << properties.pb) {
            let row = destination + pos * 272
            fillTreePrices(p + 2 + pos * 8, bits: 3, base: low, count: min(8, count), destination: row)
            if count > 8 { fillTreePrices(p + 130 + pos * 8, bits: 3, base: middle, count: min(8, count - 8), destination: row + 8) }
            if pos > 0 && highCount > 0 { (row + 16).update(from: destination + 16, count: highCount) }
        }
    }
    mutating func updatePrices(lengths: Bool, repetitions: Bool, distances: Bool) {
        if lengths { fillLengthPrices(offset: Self.lenOffset, destination: lengthPrices); matchCounter = 0 }
        if repetitions { fillLengthPrices(offset: Self.repLenOffset, destination: repLengthPrices); repCounter = 0 }
        if distances {
            for i in 0..<16 { alignPrices[i] = treePrice(probs + 802, bits: 4, symbol: i, reverse: true) }
            for ls in 0..<4 {
                fillTreePrices(probs + 432 + ls * 64, bits: 6, base: 0, count: 64, destination: slotPrices + ls * 64)
                for slot in 14..<64 { slotPrices[ls * 64 + slot] += ((slot >> 1) - 1 - 4) * 16 }
            }
            for distance in 0..<128 {
                let slot = Self.slot(distance)
                var suffix = 0
                if slot >= 4 {
                    let bits = (slot >> 1) - 1, base = (2 | (slot & 1)) << bits
                    suffix = treePrice(probs + 688 + base - slot - 1, bits: bits, symbol: distance - base, reverse: true)
                }
                for ls in 0..<4 { distancePrices[ls &* 128 &+ distance] = slotPrices[ls * 64 + slot] + suffix }
            }
        }
    }
}
