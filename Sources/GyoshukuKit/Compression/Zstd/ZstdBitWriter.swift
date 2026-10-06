// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation

/// Low bits are appended first. Reverse streams finish with RFC §4.1's one-bit marker.
struct ZstdBitWriter: ~Copyable {
    private var accumulator: UInt64 = 0
    private var count = 0
    private var bytes: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    private var written = 0
    init(capacity: Int = 0) {
        self.capacity = max(64, capacity)
        bytes = .allocate(capacity: self.capacity)
    }
    deinit { bytes.deallocate() }
    @inline(never) private mutating func grow() {
        let next = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * 2)
        next.initialize(from: bytes, count: written)
        bytes.deallocate(); bytes = next; capacity *= 2
    }
    @inline(__always) mutating func append(_ value: Int, bits: Int) {
        assert(bits >= 0 && bits <= 56)
        accumulator |= UInt64(value) << count
        count += bits
        if written + 8 > capacity { grow() }
        while count >= 8 {
            bytes[written] = UInt8(truncatingIfNeeded: accumulator); written += 1
            accumulator >>= 8; count -= 8
        }
    }
    mutating func finish(marker: Bool = true) -> Data {
        if marker { append(1, bits: 1) }
        if count > 0 { bytes[written] = UInt8(truncatingIfNeeded: accumulator); written += 1 }
        return Data(bytes: bytes, count: written)
    }
}

@inline(__always) func zstdAppendLE(_ value: UInt64, bytes: Int, to data: inout Data) {
    for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
}
