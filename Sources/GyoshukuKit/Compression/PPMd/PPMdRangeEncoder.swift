// 出自: LZMA SDK 26.03 C/Ppmd7Enc.c と 7-Zip 26.03 の公開ドメイン C/Ppmd8Enc.c。
// Igor Pavlov、Dmitry Shkarin、carryless coder 原作 Dmitry Subbotin。純 Swift への移植。
import Foundation

/// 7z の carry 付き coder と ZIP の Subbotin coder。出力は固定 64 KiB で都度排出する。
final class PPMdRangeEncoder {
    let variantI: Bool
    var range: UInt32 = .max
    private var low: UInt64 = 0
    private var cache: UInt8 = 0
    private var cacheSize: UInt64 = 1
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
    private var count = 0

    init(variantI: Bool) { self.variantI = variantI }
    deinit { output.deallocate() }

    private func put(_ byte: UInt8, emit: (Data) throws -> Void) throws {
        output[count] = byte
        count += 1
        if count == 65_536 { try drain(emit: emit) }
    }

    func drain(emit: (Data) throws -> Void) throws {
        if count != 0 {
            let bytes = Data(bytes: output, count: count)
            count = 0
            try emit(bytes)
        }
    }

    private func shiftLow(emit: (Data) throws -> Void) throws {
        let lower = UInt32(truncatingIfNeeded: low)
        let carry = UInt8(truncatingIfNeeded: low >> 32)
        if lower < 0xFF00_0000 || carry != 0 {
            var byte = cache
            repeat {
                try put(byte &+ carry, emit: emit)
                byte = 0xFF
                cacheSize -= 1
            } while cacheSize != 0
            cache = UInt8(lower >> 24)
        }
        cacheSize += 1
        low = UInt64(lower << 8)
    }

    func normalize(emit: (Data) throws -> Void) throws {
        if variantI {
            var lower = UInt32(truncatingIfNeeded: low)
            while true {
                if lower ^ (lower &+ range) >= 1 << 24 {
                    if range >= 1 << 15 { break }
                    range = (0 &- lower) & ((1 << 15) - 1)
                }
                try put(UInt8(lower >> 24), emit: emit)
                range <<= 8
                lower <<= 8
            }
            low = UInt64(lower)
        } else {
            while range < 1 << 24 {
                range <<= 8
                try shiftLow(emit: emit)
            }
        }
    }

    func encode(start: Int, size: Int, total: Int, normalize: Bool = true,
                emit: (Data) throws -> Void) throws {
        let scale = variantI ? min(UInt32(total), range) : UInt32(total)
        range /= scale
        let increment = UInt32(start) &* range
        if variantI { low = UInt64(UInt32(truncatingIfNeeded: low) &+ increment) }
        else { low += UInt64(increment) }
        range &*= UInt32(size)
        if normalize { try self.normalize(emit: emit) }
    }

    func binary(probability: Int, success: Bool, emit: (Data) throws -> Void) throws {
        let bound = (range >> 14) * UInt32(probability)
        if success {
            range = bound
            try normalize(emit: emit)
        } else {
            if variantI {
                low = UInt64(UInt32(truncatingIfNeeded: low) &+ bound)
                range = (range & ~UInt32(16_383)) &- bound
            } else {
                low += UInt64(bound)
                range -= bound
            }
            // escape 後の normalize は suffix へ移る直前に行う。
        }
    }

    func finish(emit: (Data) throws -> Void) throws {
        if variantI {
            for _ in 0..<4 {
                try put(UInt8(UInt32(truncatingIfNeeded: low) >> 24), emit: emit)
                low = UInt64(UInt32(truncatingIfNeeded: low) << 8)
            }
        } else {
            for _ in 0..<5 { try shiftLow(emit: emit) }
        }
        try drain(emit: emit)
    }
}
