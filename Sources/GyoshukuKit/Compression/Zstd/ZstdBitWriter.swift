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
    @inline(__always) private mutating func flush() {
        if written + 8 > capacity { grow() }
        flushUnchecked()
    }
    @inline(__always) private mutating func flushUnchecked() {
        assert(written + 8 <= capacity)
        // 公開するのは完了 byte だけ。余分な store は次の flush で上書きする。
        let word = accumulator.littleEndian
        withUnsafeBytes(of: word) {
            UnsafeMutableRawPointer(bytes + written).copyMemory(from: $0.baseAddress!, byteCount: 8)
        }
        let flushed = count & ~7
        written += flushed >> 3
        // count / flushed は0...63なので、幅の再判定を省く。
        accumulator &>>= flushed; count &= 7
    }
    @inline(__always) mutating func append(_ value: Int, bits: Int) {
        assert(bits >= 0 && bits <= 56)
        if count + bits > 63 { flush() }
        accumulator |= UInt64(value) &<< count
        count += bits
    }

    /// 呼出元が最大 bit 数+8 byte を予約した hot loop 専用。
    @inline(__always) mutating func appendUnchecked(_ value: Int, bits: Int) {
        assert(bits >= 0 && bits <= 56)
        if count + bits > 63 { flushUnchecked() }
        accumulator |= UInt64(value) &<< count
        count += bits
    }
    mutating func finish(marker: Bool = true) -> Data {
        if marker { append(1, bits: 1) }
        flush()
        if count > 0 { bytes[written] = UInt8(truncatingIfNeeded: accumulator); written += 1 }
        return Data(bytes: bytes, count: written)
    }
}

@inline(__always) func zstdAppendLE(_ value: UInt64, bytes: Int, to data: inout Data) {
    for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
}
