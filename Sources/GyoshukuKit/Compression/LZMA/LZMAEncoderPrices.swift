// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

extension LZMAEncodingEngine {
    @inline(__always) func price(_ probability: UInt16, _ bit: Int) -> Int {
        bitPrices[(Int(probability) ^ (bit == 0 ? 0 : 2047)) >> 4]
    }
    @inline(__always) func treePrice(_ p: UnsafePointer<UInt16>, bits: Int, symbol: Int, reverse: Bool = false) -> Int {
        var m = 1, total = 0
        for i in 0..<bits {
            let b = (symbol >> (reverse ? i : bits - 1 - i)) & 1
            total += price(p[m], b); m = m * 2 + b
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
                total += price(p[symbol >> 8], (symbol >> 7) & 1)
                symbol <<= 1
            } while symbol < 65536
        } else {
            var match = Int(data[-r.a]), offset = 256
            repeat {
                match <<= 1
                total += price(p[offset + (match & offset) + (symbol >> 8)], (symbol >> 7) & 1)
                symbol <<= 1; offset &= ~(match ^ symbol)
            } while symbol < 65536
        }
        return total
    }
    @inline(__always) func pureRepPrice(_ index: Int, state s: Int, pos: Int) -> Int {
        if index == 0 { return price(probs[204 + s], 0) + price(probs[240 + s * 16 + pos], 1) }
        return price(probs[204 + s], 1) + (index == 1 ? price(probs[216 + s], 0)
            : price(probs[216 + s], 1) + price(probs[228 + s], index - 2))
    }
    @inline(__always) func rep0Price(state s: Int, pos: Int) -> Int {
        price(probs[s * 16 + pos], 1) + price(probs[192 + s], 1) + pureRepPrice(0, state: s, pos: pos)
    }
    @inline(__always) func distancePrice(_ distance: Int, length: Int) -> Int {
        let ls = min(length - 2, 3)
        if distance < 128 { return distancePrices[ls * 128 + distance] }
        return slotPrices[ls * 64 + Self.slot(distance)] + alignPrices[distance & 15]
    }
    func fillLengthPrices(offset: Int, destination: UnsafeMutablePointer<Int>) {
        let p = probs + offset
        let low = price(p[0], 0), middle = price(p[0], 1) + price(p[1], 0)
        let high = price(p[0], 1) + price(p[1], 1)
        for pos in 0..<(1 << properties.pb) {
            for sym in 0..<272 {
                destination[pos * 272 + sym] = sym < 8
                    ? low + treePrice(p + 2 + pos * 8, bits: 3, symbol: sym)
                    : sym < 16 ? middle + treePrice(p + 130 + pos * 8, bits: 3, symbol: sym - 8)
                    : high + treePrice(p + 258, bits: 8, symbol: sym - 16)
            }
        }
    }
    mutating func updatePrices(lengths: Bool, repetitions: Bool, distances: Bool) {
        if lengths { fillLengthPrices(offset: Self.lenOffset, destination: lengthPrices); matchCounter = 0 }
        if repetitions { fillLengthPrices(offset: Self.repLenOffset, destination: repLengthPrices); repCounter = 0 }
        if distances {
            for i in 0..<16 { alignPrices[i] = treePrice(probs + 802, bits: 4, symbol: i, reverse: true) }
            for ls in 0..<4 {
                for slot in 0..<64 {
                    var value = treePrice(probs + 432 + ls * 64, bits: 6, symbol: slot)
                    if slot >= 14 { value += ((slot >> 1) - 1 - 4) * 16 }
                    slotPrices[ls * 64 + slot] = value
                }
                for distance in 0..<128 {
                    let slot = Self.slot(distance)
                    var value = slotPrices[ls * 64 + slot]
                    if slot >= 4 {
                        let bits = (slot >> 1) - 1, base = (2 | (slot & 1)) << bits
                        value += treePrice(probs + 688 + base - slot - 1, bits: bits, symbol: distance - base, reverse: true)
                    }
                    distancePrices[ls * 128 + distance] = value
                }
            }
        }
    }
}
