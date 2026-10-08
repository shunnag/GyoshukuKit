// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

/// 所有は LZMAEncoder に限定する。bit loop は値型と pointer だけを使う。
struct LZMARangeEncoder {
    var low: UInt64 = 0
    var range: UInt32 = .max
    var cache: UInt8 = 0
    var cacheSize = 1
    var count = 0
    var capacity = 131_072
    var output: UnsafeMutablePointer<UInt8>
    var bufferLimit = 16 << 20
    var error: LZMAEncodingError?

    init() throws { output = try lzmaAllocate(UInt8.self, count: capacity) }
    mutating func reset() {
        low = 0; range = .max; cache = 0; cacheSize = 1; count = 0; error = nil
    }
    var estimatedSize: Int { count + cacheSize + 5 }

    @inline(__always) mutating func put(_ byte: UInt8) {
        // 通常は 128 KiB 内で drain する。強く偏った確率による膨張と長い carry 保留にも対応する。
        if count == capacity && !grow() { return }
        output[count] = byte
        count &+= 1
    }
    @inline(never) private mutating func grow() -> Bool {
        if error != nil { return false }
        let next = min(bufferLimit, capacity * 2)
        guard next > capacity else {
            error = .memoryLimit(required: capacity + 1, limit: bufferLimit)
            return false
        }
        guard let pointer = realloc(output, next) else { error = .allocationFailed; return false }
        output = pointer.bindMemory(to: UInt8.self, capacity: next)
        capacity = next
        return true
    }
    @inline(__always) mutating func shiftLow() {
        let lower = UInt32(truncatingIfNeeded: low)
        let carry = UInt8(truncatingIfNeeded: low >> 32)
        if lower < 0xFF00_0000 || carry != 0 {
            var byte = cache
            repeat {
                put(byte &+ carry)
                byte = 0xFF
                cacheSize &-= 1
            } while cacheSize != 0
            cache = UInt8(lower >> 24)
        }
        cacheSize &+= 1
        low = UInt64(lower << 8)
    }
    @inline(__always) mutating func bit(_ probability: UnsafeMutablePointer<UInt16>, _ bit: Int) {
        let p = UInt32(probability.pointee)
        // probability は 1...2047、low は carry を含めても33 bit内。
        let bound = (range >> 11) &* p
        if bit == 0 {
            range = bound
            probability.pointee = UInt16(truncatingIfNeeded: p &+ ((2048 &- p) >> 5))
        } else {
            low &+= UInt64(bound)
            range &-= bound
            probability.pointee = UInt16(truncatingIfNeeded: p &- (p >> 5))
        }
        if range < 1 << 24 { range <<= 8; shiftLow() }
    }
    @inline(__always) mutating func direct(_ symbol: UInt32, bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            range >>= 1
            if symbol >> i & 1 != 0 { low &+= UInt64(range) }
            if range < 1 << 24 { range <<= 8; shiftLow() }
        }
    }
    @inline(__always) mutating func tree(_ probs: UnsafeMutablePointer<UInt16>, bits: Int, symbol: Int) {
        var m = 1
        for i in stride(from: bits - 1, through: 0, by: -1) {
            let b = symbol >> i & 1
            bit(probs + m, b)
            m = m &* 2 &+ b
        }
    }
    @inline(__always) mutating func reverseTree(_ probs: UnsafeMutablePointer<UInt16>, bits: Int, symbol: Int) {
        var m = 1
        var value = symbol
        for _ in 0..<bits {
            let b = value & 1
            bit(probs + m, b)
            m = m &* 2 &+ b
            value >>= 1
        }
    }
    mutating func finish() { for _ in 0..<5 { shiftLow() } }
    mutating func take() -> Data {
        let result = Data(bytes: output, count: count)
        count = 0
        return result
    }
}
