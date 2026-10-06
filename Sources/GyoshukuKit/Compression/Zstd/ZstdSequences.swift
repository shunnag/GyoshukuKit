// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation

struct ZstdMatch { var length: Int; var distance: Int }
struct ZstdSequence { var literals: Int; var length: Int; var distance: Int }

struct ZstdRepeatOffsets {
    var a = 1, b = 4, c = 8
    /// RFC §3.1.1.5, including the zero-literal shift and rep1-1 special case.
    mutating func value(distance: Int, literals: Int) -> Int {
        if literals > 0 && distance == a { return 1 }
        if distance == b { swap(&a, &b); return literals == 0 ? 1 : 2 }
        if distance == c { (a,b,c) = (c,a,b); return literals == 0 ? 2 : 3 }
        let special = literals == 0 && distance == a - 1
        (a,b,c) = (distance,a,b)
        return special ? 3 : distance + 3
    }
}

enum ZstdSequences {
    static let literalBases = Array(0...15) + [16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,65536]
    static let literalBits = [Int](repeating: 0, count: 16) + [1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16]
    static let matchBases = Array(3...34) + [35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,65539]
    static let matchBits = [Int](repeating: 0, count: 32) + [1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16]
    @inline(__always) static func literalCode(_ length: Int) -> Int {
        if length < 16 { return length }
        if length >= 64 { return 25 + (Int.bitWidth - 1 - length.leadingZeroBitCount) - 6 }
        for i in 16..<25 where length < literalBases[i + 1] { return i }
        return 24
    }
    @inline(__always) static func matchCode(_ length: Int) -> Int {
        if length <= 34 { return length - 3 }
        if length >= 131 { return 43 + (Int.bitWidth - 1 - (length - 3).leadingZeroBitCount) - 7 }
        for i in 32..<43 where length < matchBases[i + 1] { return i }
        return 42
    }
    static func encode(_ sequences: [ZstdSequence], repeats: inout ZstdRepeatOffsets,
                       profile: ((Double, Double, Double) -> Void)? = nil) -> Data {
        let n = sequences.count
        if n == 0 { return Data([0]) }
        let start = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        var ll: [Int] = [], ml: [Int] = [], of: [Int] = [], values: [Int] = []
        ll.reserveCapacity(n); ml.reserveCapacity(n); of.reserveCapacity(n); values.reserveCapacity(n)
        for s in sequences {
            ll.append(literalCode(s.literals)); ml.append(matchCode(s.length))
            let value = repeats.value(distance: s.distance, literals: s.literals)
            values.append(value); of.append(Int.bitWidth - 1 - value.leadingZeroBitCount)
        }
        let codesEnd = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let l = ZstdSequenceEntropy.choose(ll, predefined: .literals, maximumLog: 9)
        let o = ZstdSequenceEntropy.choose(of, predefined: .offsets, maximumLog: 8)
        let m = ZstdSequenceEntropy.choose(ml, predefined: .matches, maximumLog: 9)
        let tablesEnd = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        var result = Data()
        if n < 128 { result.append(UInt8(n)) }
        else if n < 0x7F00 { result.append(UInt8(128 + (n >> 8))); result.append(UInt8(truncatingIfNeeded: n)) }
        else { result.append(255); zstdAppendLE(UInt64(n - 0x7F00), bytes: 2, to: &result) }
        result.append(UInt8((l.mode << 6) | (o.mode << 4) | (m.mode << 2)))
        result.append(l.description); result.append(o.description); result.append(m.description)
        var ls = l.start(ll[n - 1]), os = o.start(of[n - 1]), ms = m.start(ml[n - 1])
        var bits = ZstdBitWriter(capacity: n * 3)
        withTables(l, o, m) { lt, llog, ot, olog, mt, mlog in
        withCodes(ll, ml, of, sequences, values) { lcodes, mcodes, ocodes, commands, offsets in
            for i in stride(from: n - 1, through: 0, by: -1) {
                if i != n - 1 {
                    var value = 0, width = 0
                    if let ot {
                        let t = ot[(ocodes[i] << olog) + os]
                        value = Int(t >> 13); width = Int((t >> 9) & 15); os = Int(t & 511)
                    }
                    if let mt {
                        let t = mt[(mcodes[i] << mlog) + ms]
                        value |= Int(t >> 13) << width; width += Int((t >> 9) & 15); ms = Int(t & 511)
                    }
                    if let lt {
                        let t = lt[(lcodes[i] << llog) + ls]
                        value |= Int(t >> 13) << width; width += Int((t >> 9) & 15); ls = Int(t & 511)
                    }
                    bits.append(value, bits: width)
                }
                let lb = literalBits[lcodes[i]], mb = matchBits[mcodes[i]], ob = ocodes[i]
                let value = (commands[i].literals - literalBases[lcodes[i]])
                    | ((commands[i].length - matchBases[mcodes[i]]) << lb)
                    | ((offsets[i] - (1 << ob)) << (lb + mb))
                // LL+ML+OF <= 16+16+23: fits together with the writer's <8 pending bits.
                bits.append(value, bits: lb + mb + ob)
            }
        } }
        bits.append(ms, bits: m.log); bits.append(os, bits: o.log); bits.append(ls, bits: l.log)
        result.append(bits.finish())
        if let profile { profile(codesEnd - start, tablesEnd - codesEnd, ProcessInfo.processInfo.systemUptime - tablesEnd) }
        return result
    }

    // These scopes keep every borrowed buffer alive for the complete reverse encoding loop.
    private static func withTables<R>(_ l: ZstdSequenceEntropy, _ o: ZstdSequenceEntropy, _ m: ZstdSequenceEntropy,
                                     _ body: (UnsafePointer<UInt32>?, Int, UnsafePointer<UInt32>?, Int, UnsafePointer<UInt32>?, Int) -> R) -> R {
        l.withTransitions { lt, ll in
            o.withTransitions { ot, ol in
                m.withTransitions { mt, ml in body(lt, ll, ot, ol, mt, ml) }
            }
        }
    }
    private static func withCodes<R>(_ l: [Int], _ m: [Int], _ o: [Int], _ commands: [ZstdSequence], _ offsets: [Int],
                                    _ body: (UnsafeBufferPointer<Int>, UnsafeBufferPointer<Int>, UnsafeBufferPointer<Int>,
                                             UnsafeBufferPointer<ZstdSequence>, UnsafeBufferPointer<Int>) -> R) -> R {
        l.withUnsafeBufferPointer { ll in
            m.withUnsafeBufferPointer { ml in
                o.withUnsafeBufferPointer { of in
                    commands.withUnsafeBufferPointer { seq in
                        offsets.withUnsafeBufferPointer { body(ll, ml, of, seq, $0) }
                    }
                }
            }
        }
    }
}
