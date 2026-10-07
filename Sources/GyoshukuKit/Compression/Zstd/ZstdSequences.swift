// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation

struct ZstdMatch { var length: Int; var distance: Int }
struct ZstdSequence { var literals: Int; var length: Int; var distance: Int }

struct ZstdRepeatOffsets {
    var a = 1, b = 4, c = 8
    /// RFC §3.1.1.5, including the zero-literal shift and rep1-1 special case.
    @inline(__always) mutating func value(distance: Int, literals: Int) -> Int {
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
    private static let literalExtras = zip(literalBases, literalBits).map { ($0 << 5) | $1 }
    private static let matchExtras = zip(matchBases, matchBits).map { ($0 << 5) | $1 }
    private static let shortLiteralCodes = (0..<64).map { length in
        (literalBases.lastIndex { $0 <= length })!
    }
    private static let shortMatchCodes = (0..<131).map { length in
        matchBases.lastIndex { $0 <= length } ?? 0
    }
    @inline(__always) static func literalCode(_ length: Int) -> Int {
        if length < 16 { return length }
        if length >= 64 { return 25 + (Int.bitWidth - 1 - length.leadingZeroBitCount) - 6 }
        return shortLiteralCodes[length]
    }
    @inline(__always) static func matchCode(_ length: Int) -> Int {
        if length <= 34 { return length - 3 }
        if length >= 131 { return 43 + (Int.bitWidth - 1 - (length - 3).leadingZeroBitCount) - 7 }
        return shortMatchCodes[length]
    }
    static func encode(_ sequences: [ZstdSequence], repeats: inout ZstdRepeatOffsets,
                       workspace: Workspace? = nil, profile: ((Double, Double, Double) -> Void)? = nil) -> Data {
        let n = sequences.count
        precondition(n <= ZstdFrameEncoder.blockSize / 3)
        if n == 0 { return Data([0]) }
        let start = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let workspace = workspace ?? Workspace(capacity: n)
        precondition(n <= workspace.capacity)
        defer { withExtendedLifetime(workspace) {} }
        let histogram = workspace.histogram
        histogram.update(repeating: 0, count: 768)
        let commands = workspace.prepared
        var maxOf = 0
        // code・extra と4レーンの histogram を一度の走査で作る。
        literalExtras.withUnsafeBufferPointer { literalExtras in
        matchExtras.withUnsafeBufferPointer { matchExtras in
        sequences.withUnsafeBufferPointer { seq in
            let literals = literalExtras.baseAddress!, matches = matchExtras.baseAddress!, sp = seq.baseAddress!
            let lp = histogram, mp = histogram + 256, op = histogram + 512
            for i in 0..<n {
                let s = sp[i], l = literalCode(s.literals), m = matchCode(s.length)
                let v = repeats.value(distance: s.distance, literals: s.literals)
                let o = Int.bitWidth - 1 - v.leadingZeroBitCount, lane = (i & 3) << 6
                maxOf = max(maxOf, o)
                // sequence 数<=43690なので32 bitの加算は溢れない。
                lp[lane + l] &+= 1; mp[lane + m] &+= 1; op[lane + o] &+= 1
                // 短い長さは extra が0。表の参照と結合を省く。
                if s.literals < 16 && s.length <= 34 {
                    commands[i] = Prepared(codes: l | (m << 6) | (o << 12) | (o << 18), extra: v - (1 &<< o))
                } else {
                    let literal = literals[l], match = matches[m], lb = literal & 31, mb = match & 31
                    let extra = (s.literals - (literal >> 5))
                        | ((s.length - (match >> 5)) &<< lb)
                        | ((v - (1 &<< o)) &<< (lb + mb))
                    commands[i] = Prepared(codes: l | (m << 6) | (o << 12) | ((lb + mb + o) << 18), extra: extra)
                }
            }
        } } }
        func counts(_ offset: Int) -> [Int] {
            [Int](unsafeUninitializedCapacity: 53) { output, initialized in
                let p = histogram + offset, out = output.baseAddress!
                for i in 0..<53 { out[i] = Int(p[i] + p[64 + i] + p[128 + i] + p[192 + i]) }
                initialized = 53
            }
        }
        let lc = counts(0), mc = counts(256), oc = counts(512)
        precondition(maxOf <= 30)
        let last = commands[n - 1].codes
        let codesEnd = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let l = ZstdSequenceEntropy.choose(counts: lc, last: Int(last & 63), count: n, predefined: .literals, maximumLog: 9)
        let o = ZstdSequenceEntropy.choose(counts: oc, last: Int((last >> 12) & 63), count: n, predefined: .offsets, maximumLog: 8)
        let m = ZstdSequenceEntropy.choose(counts: mc, last: Int((last >> 6) & 63), count: n, predefined: .matches, maximumLog: 9)
        let tablesEnd = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        var result = Data()
        if n < 128 { result.append(UInt8(n)) }
        else if n < 0x7F00 { result.append(UInt8(128 + (n >> 8))); result.append(UInt8(truncatingIfNeeded: n)) }
        else { result.append(255); zstdAppendLE(UInt64(n - 0x7F00), bytes: 2, to: &result) }
        result.append(UInt8((l.mode << 6) | (o.mode << 4) | (m.mode << 2)))
        result.append(l.description); result.append(o.description); result.append(m.description)
        var ls = l.start(Int(last & 63)), os = o.start(Int((last >> 12) & 63)), ms = m.start(Int((last >> 6) & 63))
        // 遷移<=26 bit、長さ extra<=32 bit、offset<=30 bit。終端と store の余白を含む。
        var bits = ZstdBitWriter(capacity: n * 11 + 16)
        withTables(l, o, m) { lt, llog, ot, olog, mt, mlog in
            for i in stride(from: n - 1, through: 0, by: -1) {
                let command = commands[i], codes = command.codes
                var transition = 0, transitionBits = 0
                if i != n - 1 {
                    var value = 0, width = 0
                    if let ot {
                        let t = ot[(Int((codes >> 12) & 63) &<< olog) + os]
                        value = Int(t >> 13); width = Int((t >> 9) & 15); os = Int(t & 511)
                    }
                    if let mt {
                        let t = mt[(Int((codes >> 6) & 63) &<< mlog) + ms]
                        value |= Int(t >> 13) &<< width; width += Int((t >> 9) & 15); ms = Int(t & 511)
                    }
                    if let lt {
                        let t = lt[(Int(codes & 63) &<< llog) + ls]
                        value |= Int(t >> 13) &<< width; width += Int((t >> 9) & 15); ls = Int(t & 511)
                    }
                    transition = value; transitionBits = width
                }
                let extraBits = Int(codes >> 18), value = Int(command.extra)
                if transitionBits + extraBits <= 56 {
                    bits.appendUnchecked(transition | (value &<< transitionBits), bits: transitionBits + extraBits)
                } else {
                    bits.appendUnchecked(transition, bits: transitionBits)
                    if extraBits <= 56 { bits.appendUnchecked(value, bits: extraBits) }
                    else {
                        bits.appendUnchecked(value & 0xFFFFFFFF, bits: 32)
                        bits.appendUnchecked(value >> 32, bits: extraBits - 32)
                    }
                }
            }
        }
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
    // block 間で大きい command buffer を再利用する。
    final class Workspace {
        fileprivate let prepared: UnsafeMutablePointer<Prepared>
        fileprivate let histogram: UnsafeMutablePointer<UInt32>
        let capacity: Int
        init(capacity: Int) {
            self.capacity = capacity
            prepared = .allocate(capacity: capacity)
            histogram = .allocate(capacity: 768); histogram.initialize(repeating: 0, count: 768)
        }
        deinit { prepared.deallocate(); histogram.deallocate() }
    }
    fileprivate struct Prepared { var codes: Int; var extra: Int }
}
