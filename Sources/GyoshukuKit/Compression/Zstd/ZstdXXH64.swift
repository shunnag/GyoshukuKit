// Independent implementation from RFC 8878; no zstd source consulted.
// XXH64 independently implemented from the public xxHash specification (XXH64 section):
// https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
import Foundation

struct ZstdXXH64 {
    private static let p1: UInt64 = 0x9E3779B185EBCA87
    private static let p2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let p3: UInt64 = 0x165667B19E3779F9
    private static let p4: UInt64 = 0x85EBCA77C2B2AE63
    private static let p5: UInt64 = 0x27D4EB2F165667C5
    private let seed: UInt64
    private var a: UInt64, b: UInt64, c: UInt64, d: UInt64
    private var length: UInt64 = 0
    private var tail = [UInt8](repeating: 0, count: 32)
    private var tailCount = 0

    init(seed: UInt64 = 0) {
        self.seed = seed
        a = seed &+ Self.p1 &+ Self.p2; b = seed &+ Self.p2
        c = seed; d = seed &- Self.p1
    }
    @inline(__always) private static func rotate(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
    @inline(__always) private static func round(_ a: UInt64, _ x: UInt64) -> UInt64 {
        rotate(a &+ x &* p2, 31) &* p1
    }
    private mutating func stripe(_ p: UnsafeRawPointer) {
        a = Self.round(a, UInt64(littleEndian: p.loadUnaligned(as: UInt64.self)))
        b = Self.round(b, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        c = Self.round(c, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
        d = Self.round(d, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 24, as: UInt64.self)))
    }
    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        if tailCount > 0 {
            let n = min(32 - tailCount, bytes.count)
            tail.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: tailCount).copyMemory(from: base, byteCount: n) }
            tailCount += n; offset += n
            if tailCount != 32 { return }
            // A temporary copy avoids overlapping access to self during stripe.
            let copy = tail
            copy.withUnsafeBytes { stripe($0.baseAddress!) }
            tailCount = 0
        }
        while offset + 32 <= bytes.count { stripe(base.advanced(by: offset)); offset += 32 }
        tailCount = bytes.count - offset
        if tailCount > 0 {
            tail.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: base.advanced(by: offset), byteCount: tailCount) }
        }
    }
    func digest() -> UInt64 {
        var h: UInt64
        if length >= 32 {
            h = Self.rotate(a, 1) &+ Self.rotate(b, 7) &+ Self.rotate(c, 12) &+ Self.rotate(d, 18)
            for lane in [a,b,c,d] { h = (h ^ Self.round(0, lane)) &* Self.p1 &+ Self.p4 }
        } else { h = seed &+ Self.p5 }
        h &+= length
        tail.withUnsafeBytes { bytes in
            let p = bytes.baseAddress!
            var i = 0
            while i + 8 <= tailCount {
                h ^= Self.round(0, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                h = Self.rotate(h, 27) &* Self.p1 &+ Self.p4; i += 8
            }
            if i + 4 <= tailCount {
                h ^= UInt64(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* Self.p1
                h = Self.rotate(h, 23) &* Self.p2 &+ Self.p3; i += 4
            }
            while i < tailCount {
                h ^= UInt64(bytes[i]) &* Self.p5
                h = Self.rotate(h, 11) &* Self.p1; i += 1
            }
        }
        h ^= h >> 33; h &*= Self.p2; h ^= h >> 29; h &*= Self.p3; h ^= h >> 32
        return h
    }
}
