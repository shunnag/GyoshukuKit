// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation

/// RFC §4.1.1 state spreading, inverted by enumerating each cell's next-state interval.
/// No reference encoder table construction or normalization algorithm is used.
struct ZstdFSEEncoder: Sendable {
    let log: Int
    let probabilities: [Int]
    let description: Data
    private let transitions: [UInt32]
    private let initial: [Int]

    init(probabilities: [Int], log: Int) {
        self.log = log; self.probabilities = probabilities
        let size = 1 << log
        precondition((5...9).contains(log) && probabilities.filter { $0 != 0 }.count >= 2)
        precondition(probabilities.reduce(0) { $0 + abs($1) } == size)
        var symbols = [Int](repeating: 0, count: size)
        var high = size - 1
        for (symbol, p) in probabilities.enumerated() where p == -1 {
            symbols[high] = symbol; high -= 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        var position = 0
        for (symbol, p) in probabilities.enumerated() where p > 0 {
            for _ in 0..<p {
                symbols[position] = symbol
                repeat { position = (position + step) & (size - 1) } while position > high
            }
        }
        precondition(position == 0)
        var next = probabilities.map { max(1, $0) }
        var first = [Int](repeating: -1, count: probabilities.count)
        var inverse = [UInt32](repeating: 0, count: size * probabilities.count)
        inverse.withUnsafeMutableBufferPointer { target in
            for state in 0..<size {
                let symbol = symbols[state], n = next[symbol]
                next[symbol] += 1
                let width = log - (Int.bitWidth - 1 - n.leadingZeroBitCount)
                let base = (n << width) - size
                // The terminal state must consume bits for the Huffman-weight overflow rule.
                if first[symbol] < 0 || width > 0 { first[symbol] = state }
                for value in 0..<(1 << width) {
                    target[symbol * size + base + value] = UInt32(state | (width << 9) | (value << 13))
                }
            }
        }
        transitions = inverse; initial = first
        description = Self.describe(probabilities, log: log)
    }

    @inline(__always) func start(_ symbol: Int) -> Int { initial[symbol] }
    func withTransitions<R>(_ body: (UnsafePointer<UInt32>, Int) -> R) -> R {
        transitions.withUnsafeBufferPointer { body($0.baseAddress!, log) }
    }
    @inline(__always) func encode(_ symbol: Int, state: inout Int, to bits: inout ZstdBitWriter) {
        let t = transitions[(symbol << log) + state]
        bits.append(Int(t >> 13), bits: Int((t >> 9) & 15))
        state = Int(t & 511)
    }
    /// Expected transition cost in 1/256 bits, assuming uniformly distributed next states.
    /// Inversion intervals cover every next state once for each present symbol. Thus the
    /// average width follows directly from a symbol's normalized count, without encoding a trial stream.
    static func estimatedCost(_ counts: [Int], last: Int, probabilities: [Int], log: Int) -> Int {
        var cost = log * 256
        for symbol in counts.indices where counts[symbol] > 0 {
            guard symbol < probabilities.count, probabilities[symbol] != 0 else { return Int.max }
            let n = abs(probabilities[symbol])
            let upper = 1 << (Int.bitWidth - n.leadingZeroBitCount)
            let width = log - (Int.bitWidth - 1 - n.leadingZeroBitCount)
            let average = width * 256 - (2 * n - upper) * 256 / upper
            cost += (counts[symbol] - (symbol == last ? 1 : 0)) * average
        }
        return cost
    }
    static func normalize(_ counts: [Int], log: Int) -> [Int] {
        let size = 1 << log, total = counts.reduce(0, +)
        let last = counts.lastIndex(where: { $0 > 0 })!
        var result = counts.prefix(last + 1).map { $0 == 0 ? 0 : max(1, $0 * size / total) }
        var sum = result.reduce(0, +)
        // Allocate rounding residual by distance from the exact target; stable ties by symbol.
        while sum != size {
            let adding = sum < size
            var best = -1, error = Int.min
            for i in result.indices where counts[i] > 0 && (adding || result[i] > 1) {
                let e = adding ? counts[i] * size - result[i] * total : result[i] * total - counts[i] * size
                if e > error { error = e; best = i }
            }
            precondition(best >= 0)
            result[best] += adding ? 1 : -1; sum += adding ? 1 : -1
        }
        return result.map { $0 == 1 ? -1 : $0 }
    }
    static func describe(_ p: [Int], log: Int) -> Data {
        var bits = ZstdBitWriter()
        bits.append(log - 5, bits: 4)
        var remaining = 1 << log, index = 0
        while remaining > 0 {
            let maximum = remaining + 1
            let width = Int.bitWidth - maximum.leadingZeroBitCount
            let shortCount = (1 << width) - 1 - maximum
            let value = p[index] + 1
            if value < shortCount { bits.append(value, bits: width - 1) }
            else { bits.append(value < (1 << (width - 1)) ? value : value + shortCount, bits: width) }
            remaining -= abs(p[index]); index += 1
            if value == 1 {
                var zeros = 0
                while index < p.count && p[index] == 0 { zeros += 1; index += 1 }
                while zeros >= 3 { bits.append(3, bits: 2); zeros -= 3 }
                bits.append(zeros, bits: 2)
            }
        }
        return bits.finish(marker: false)
    }

    // RFC §3.1.1.3.2.2 normative distributions.
    static let literals = Self(probabilities: [4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1], log: 6)
    static let matches = Self(probabilities: [1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1], log: 6)
    static let offsets = Self(probabilities: [1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1], log: 5)
}

struct ZstdSequenceEntropy {
    let mode: Int
    let description: Data
    let table: ZstdFSEEncoder?
    let rleSymbol: Int?
    var log: Int { table?.log ?? 0 }
    @inline(__always) func start(_ symbol: Int) -> Int { table?.start(symbol) ?? 0 }
    func withTransitions<R>(_ body: (UnsafePointer<UInt32>?, Int) -> R) -> R {
        if let table { return table.withTransitions { body($0, $1) } }
        return body(nil, 0)
    }
    @inline(__always) func encode(_ symbol: Int, state: inout Int, to bits: inout ZstdBitWriter) {
        table?.encode(symbol, state: &state, to: &bits)
    }
    static func choose(_ symbols: [Int], predefined: ZstdFSEEncoder, maximumLog: Int) -> Self {
        var best = Self(mode: 0, description: Data(), table: predefined, rleSymbol: nil)
        var counts = [Int](repeating: 0, count: 53)
        counts.withUnsafeMutableBufferPointer { frequencies in
            for symbol in symbols { frequencies[symbol] += 1 }
        }
        var cost = ZstdFSEEncoder.estimatedCost(counts, last: symbols.last!, probabilities: predefined.probabilities, log: predefined.log)
        let present = counts.filter { $0 > 0 }.count
        if present == 1 {
            if 8 * 256 < cost { best = Self(mode: 1, description: Data([UInt8(symbols[0])]), table: nil, rleSymbol: symbols[0]) }
            return best
        }
        let minimum = max(5, Int.bitWidth - (present - 1).leadingZeroBitCount)
        // More than 2 candidate logs seldom repay table construction on small blocks.
        let preferred = min(maximumLog, max(minimum, Int.bitWidth - max(1, symbols.count / 8).leadingZeroBitCount))
        var selected: ([Int], Int)?
        for log in Set([minimum, preferred]).sorted() {
            let probabilities = ZstdFSEEncoder.normalize(counts, log: log)
            let description = ZstdFSEEncoder.describe(probabilities, log: log)
            let candidate = description.count * 8 * 256
                + ZstdFSEEncoder.estimatedCost(counts, last: symbols.last!, probabilities: probabilities, log: log)
            if candidate < cost {
                cost = candidate; selected = (probabilities, log)
            }
        }
        if let (probabilities, log) = selected {
            let table = ZstdFSEEncoder(probabilities: probabilities, log: log)
            best = Self(mode: 2, description: table.description, table: table, rleSymbol: nil)
        }
        return best
    }
}
