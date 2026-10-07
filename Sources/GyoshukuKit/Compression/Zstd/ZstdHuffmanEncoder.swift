// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation

enum ZstdHuffmanEncoder {
    struct Code {
        private let packed: UInt16
        var value: Int { Int(packed >> 4) }
        var bits: Int { Int(packed & 15) }
        init(value: Int, bits: Int) { packed = UInt16((value << 4) | bits) }
    }
    private struct Node { let frequency: Int; let left: Int; let right: Int; let symbol: Int }

    /// RFC §3.1.1.3.1, selecting raw, RLE or a new Huffman tree by complete section size.
    static func literals(_ bytes: Data, profile: ((Double, Double, Double) -> Void)? = nil) -> Data {
        bytes.withUnsafeBytes { literals($0, profile: profile) }
    }
    static func literals(_ bytes: UnsafeRawBufferPointer, profile: ((Double, Double, Double) -> Void)? = nil) -> Data {
        let start = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        var histogramEnd = start, treeEnd = start
        defer { if let profile { profile(histogramEnd - start, treeEnd - histogramEnd, ProcessInfo.processInfo.systemUptime - treeEnd) } }
        let n = bytes.count
        var counts = [Int](repeating: 0, count: 256)
        // 四つの表で同じ symbol の連続加算を分散する。
        var lanes = [Int](repeating: 0, count: 1024)
        lanes.withUnsafeMutableBufferPointer { frequencies in
            if n > 0 {
                let f = frequencies.baseAddress!, p = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i + 4 <= n {
                    f[Int(p[i])] += 1; f[256 + Int(p[i + 1])] += 1
                    f[512 + Int(p[i + 2])] += 1; f[768 + Int(p[i + 3])] += 1
                    i += 4
                }
                while i < n { f[Int(p[i])] += 1; i += 1 }
            }
            for i in 0..<256 { counts[i] = frequencies[i] + frequencies[256 + i] + frequencies[512 + i] + frequencies[768 + i] }
        }
        if profile != nil { histogramEnd = ProcessInfo.processInfo.systemUptime; treeEnd = histogramEnd }
        if let symbol = counts.firstIndex(of: n), n > 0 { return rawHeader(n, type: 1) + Data([UInt8(symbol)]) }
        let rawSize = n + (n < 32 ? 1 : n < 4096 ? 2 : 3)
        guard n >= 64 else { return rawLiterals(bytes) }
        // 256種の頻度差が2倍以内なら8 bit固定の木が最適。表の分だけ raw より大きい。
        if let minimum = counts.min(), minimum > 0, 2 * minimum >= counts.max()! { return rawLiterals(bytes) }
        let codes = makeCodes(counts)
        let last = counts.lastIndex(where: { $0 > 0 })!
        let maxBits = codes.map(\.bits).max()!
        let weights = codes.prefix(last).map { $0.bits == 0 ? 0 : maxBits + 1 - $0.bits }
        let tree = describe(weights)
        let bitCount = counts.indices.reduce(0) { $0 + counts[$1] * codes[$1].bits }
        if profile != nil { treeEnd = ProcessInfo.processInfo.systemUptime }
        guard tree.count + (bitCount + 7) / 8 + (n < 1024 ? 4 : 15) < rawSize else { return rawLiterals(bytes) }
        var payload = tree
        let single = n < 1024
        if single {
            payload.append(stream(bytes, range: 0..<n, codes: codes))
        } else {
            let segment = (n + 3) / 4
            let streams = fourStreams(bytes, segment: segment, codes: codes)
            for s in streams.prefix(3) { zstdAppendLE(UInt64(s.count), bytes: 2, to: &payload) }
            for s in streams { payload.append(s) }
        }
        var header = Data()
        if single && payload.count < 1024 {
            zstdAppendLE(UInt64(2 | (n << 4) | (payload.count << 14)), bytes: 3, to: &header)
        } else if n < 16384 && payload.count < 16384 && !single {
            let small = n < 1024 && payload.count < 1024
            zstdAppendLE(UInt64(2 | ((small ? 1 : 2) << 2) | (n << 4) | (payload.count &<< (small ? 14 : 18))),
                         bytes: small ? 3 : 4, to: &header)
        } else if !single {
            zstdAppendLE(UInt64(14 | (n << 4) | (payload.count << 22)), bytes: 5, to: &header)
        } else { return rawLiterals(bytes) }
        header.append(payload)
        return header.count < rawSize ? header : rawLiterals(bytes)
    }
    private static func rawLiterals(_ bytes: UnsafeRawBufferPointer) -> Data {
        var result = rawHeader(bytes.count, type: 0)
        if !bytes.isEmpty { result.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count) }
        return result
    }
    private static func rawHeader(_ n: Int, type: Int) -> Data {
        var result = Data()
        if n < 32 { result.append(UInt8(type | (n << 3))) }
        else if n < 4096 { zstdAppendLE(UInt64(type | 4 | (n << 4)), bytes: 2, to: &result) }
        else { zstdAppendLE(UInt64(type | 12 | (n << 4)), bytes: 3, to: &result) }
        return result
    }
    private static func makeCodes(_ counts: [Int]) -> [Code] {
        var floor = 1
        var lengths = [Int](repeating: 0, count: 256)
        while true {
            // frequency / symbol を一つのキーにして leaf の順を保つ。
            var ordered: [Int] = []
            for symbol in counts.indices where counts[symbol] > 0 { ordered.append((max(floor, counts[symbol]) << 8) | symbol) }
            ordered.sort()
            var nodes = ordered.map { Node(frequency: $0 >> 8, left: -1, right: -1, symbol: $0 & 255) }
            let leaves = nodes.count
            var leaf = 0, parent = leaves
            func take() -> Int {
                if leaf < leaves && (parent >= nodes.count || nodes[leaf].frequency <= nodes[parent].frequency) {
                    defer { leaf += 1 }; return leaf
                }
                defer { parent += 1 }; return parent
            }
            for _ in 1..<leaves {
                let a = take(), b = take()
                nodes.append(Node(frequency: nodes[a].frequency + nodes[b].frequency, left: a, right: b, symbol: -1))
            }
            nodes.withUnsafeBufferPointer { nodes in
                lengths.withUnsafeMutableBufferPointer { lengths in
                    visit(nodes.baseAddress!, index: nodes.count - 1, depth: 0, lengths: lengths.baseAddress!)
                }
            }
            if lengths.max()! <= 11 { break }
            // Frequency flooring gives a valid bounded-depth tree without copying a length limiter.
            floor *= 2
        }
        let maxBits = lengths.max()!
        var codes = [Code](repeating: Code(value: 0, bits: 0), count: 256)
        var offset = 0
        // RFC §4.2.1.3: lowest weights (longest codes) first, natural symbol order within each rank.
        for width in stride(from: maxBits, through: 1, by: -1) {
            for symbol in 0..<256 where lengths[symbol] == width {
                codes[symbol] = Code(value: offset &>> (maxBits - width), bits: width)
                offset += 1 &<< (maxBits - width)
            }
        }
        assert(offset == 1 &<< maxBits)
        return codes
    }
    private static func visit(_ nodes: UnsafePointer<Node>, index: Int, depth: Int, lengths: UnsafeMutablePointer<Int>) {
        let node = nodes[index]
        if node.symbol >= 0 { lengths[node.symbol] = depth }
        else {
            visit(nodes, index: node.left, depth: depth + 1, lengths: lengths)
            visit(nodes, index: node.right, depth: depth + 1, lengths: lengths)
        }
    }
    private static func describe(_ weights: [Int]) -> Data {
        if weights.count <= 128 {
            var result = Data([UInt8(127 + weights.count)])
            for i in stride(from: 0, to: weights.count, by: 2) {
                result.append(UInt8((weights[i] << 4) | (i + 1 < weights.count ? weights[i + 1] : 0)))
            }
            return result
        }
        var counts = [Int](repeating: 0, count: 12)
        for weight in weights { counts[weight] += 1 }
        if counts.filter({ $0 > 0 }).count == 1 { counts[counts[0] == 0 ? 0 : 1] = 1 }
        let table = ZstdFSEEncoder(probabilities: ZstdFSEEncoder.normalize(counts, log: 6), log: 6)
        var states = [0, 0]
        states[(weights.count - 1) & 1] = table.start(weights.last!)
        states[(weights.count - 2) & 1] = table.start(weights[weights.count - 2])
        var bits = ZstdBitWriter()
        for i in stride(from: weights.count - 3, through: 0, by: -1) {
            table.encode(weights[i], state: &states[i & 1], to: &bits)
        }
        bits.append(states[1], bits: table.log); bits.append(states[0], bits: table.log)
        var payload = table.description; payload.append(bits.finish())
        precondition(payload.count < 128)
        return Data([UInt8(payload.count)]) + payload
    }
    /// 独立した四つの依存鎖を同じループで進める。
    private static func fourStreams(_ bytes: UnsafeRawBufferPointer, segment: Int, codes: [Code]) -> [Data] {
        var a = ZstdBitWriter(capacity: segment * 2 + 8), b = ZstdBitWriter(capacity: segment * 2 + 8)
        var c = ZstdBitWriter(capacity: segment * 2 + 8), d = ZstdBitWriter(capacity: segment * 2 + 8)
        codes.withUnsafeBufferPointer { codes in
            let p = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), table = codes.baseAddress!
            var i = segment, j = bytes.count - 3 * segment
            while j >= 4 {
                let ag = group(p, end: i, table: table)
                a.appendUnchecked(ag.0, bits: ag.1)
                let bg = group(p, end: segment + i, table: table)
                b.appendUnchecked(bg.0, bits: bg.1)
                let cg = group(p, end: 2 * segment + i, table: table)
                c.appendUnchecked(cg.0, bits: cg.1)
                let dg = group(p, end: 3 * segment + j, table: table)
                d.appendUnchecked(dg.0, bits: dg.1)
                i -= 4; j -= 4
            }
            while i > 0 {
                i -= 1
                let x = table[Int(p[i])], y = table[Int(p[segment + i])], z = table[Int(p[2 * segment + i])]
                a.appendUnchecked(x.value, bits: x.bits); b.appendUnchecked(y.value, bits: y.bits); c.appendUnchecked(z.value, bits: z.bits)
            }
            while j > 0 { j -= 1; let x = table[Int(p[3 * segment + j])]; d.appendUnchecked(x.value, bits: x.bits) }
        }
        return [a.finish(), b.finish(), c.finish(), d.finish()]
    }
    @inline(__always) private static func group(_ p: UnsafePointer<UInt8>, end: Int, table: UnsafePointer<Code>) -> (Int, Int) {
        let a = table[Int(p[end - 1])], b = table[Int(p[end - 2])]
        let c = table[Int(p[end - 3])], d = table[Int(p[end - 4])]
        return (a.value | (b.value &<< a.bits) | (c.value &<< (a.bits + b.bits)) | (d.value &<< (a.bits + b.bits + c.bits)),
                a.bits + b.bits + c.bits + d.bits)
    }
    private static func stream(_ bytes: UnsafeRawBufferPointer, range: Range<Int>, codes: [Code]) -> Data {
        var bits = ZstdBitWriter(capacity: range.count * 2 + 8)
        codes.withUnsafeBufferPointer { table in
            let raw = bytes
            var i = range.upperBound
            while i - range.lowerBound >= 4 {
                var value = 0, width = 0
                for back in 1...4 {
                    let code = table[Int(raw[i - back])]
                    value |= code.value &<< width; width += code.bits
                }
                bits.appendUnchecked(value, bits: width); i -= 4
            }
            while i > range.lowerBound {
                i -= 1
                let code = table[Int(raw[i])]
                bits.appendUnchecked(code.value, bits: code.bits)
            }
        }
        return bits.finish()
    }
}
