// Independent implementation from RFC 8878; no zstd source consulted.
// Hash/chain/tree search is an independently designed encoder policy, not part of the wire format.
import Foundation

final class ZstdMatchFinder {
    private let p: ZstdEncoderProperties
    private let heads: UnsafeMutablePointer<UInt32>
    private let shortHeads: UnsafeMutablePointer<UInt32>?
    private let links: UnsafeMutablePointer<UInt32>?
    private let hashCount: Int
    private let linkCount: Int
    init(properties: ZstdEncoderProperties) {
        p = properties; hashCount = 1 << p.hashLog
        heads = .allocate(capacity: hashCount); heads.initialize(repeating: 0, count: hashCount)
        if p.strategy != .fast {
            shortHeads = .allocate(capacity: 1 << 16); shortHeads!.initialize(repeating: 0, count: 1 << 16)
        } else { shortHeads = nil }
        linkCount = p.strategy == .optimal ? p.windowSize * 2
            : p.strategy == .lazy || p.strategy == .lazy2 ? p.windowSize : 0
        if linkCount > 0 {
            links = .allocate(capacity: linkCount); links!.initialize(repeating: 0, count: linkCount)
        } else { links = nil }
    }
    deinit { heads.deallocate(); shortHeads?.deallocate(); links?.deallocate() }

    /// Extremely long streams periodically renumber table positions, preserving the live window.
    func rebase(by amount: UInt32) {
        for i in 0..<hashCount { heads[i] = heads[i] > amount ? heads[i] - amount : 0 }
        if let shortHeads { for i in 0..<(1 << 16) { shortHeads[i] = shortHeads[i] > amount ? shortHeads[i] - amount : 0 } }
        if let links { for i in 0..<linkCount { links[i] = links[i] > amount ? links[i] - amount : 0 } }
    }
    @inline(__always) private func hash(_ cur: UnsafePointer<UInt8>, available: Int) -> (Int, Int) {
        let raw = UnsafeRawPointer(cur)
        let v = UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
        if p.strategy == .doubleHash && available >= 8 {
            let wide = UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self))
            return (Int((wide &* 0xCF1BBCDCB7A56463) >> (64 - p.hashLog)), Int((v &* 0x9E3779B1) >> 16))
        }
        let short = v & 0xFFFFFF
        return (Int((v &* 0x9E3779B1) >> (32 - p.hashLog)), Int((short &* 0x85EBCA77) >> 16))
    }
    @inline(__always) static func length(_ cur: UnsafePointer<UInt8>, distance: Int, limit: Int, start: Int = 0) -> Int {
        var n = start
        let a = UnsafeRawPointer(cur), b = UnsafeRawPointer(cur.advanced(by: -distance))
        // Both ranges contain initialized input. Unaligned reads never cross the current block end.
        while n + 8 <= limit {
            let diff = UInt64(littleEndian: a.loadUnaligned(fromByteOffset: n, as: UInt64.self))
                ^ UInt64(littleEndian: b.loadUnaligned(fromByteOffset: n, as: UInt64.self))
            if diff != 0 { return n + diff.trailingZeroBitCount / 8 }
            n += 8
        }
        while n < limit && cur[n] == cur[n - distance] { n += 1 }
        return n
    }
    /// Used inside a chosen long match or RLE block. Chain insertion is constant time;
    /// tree insertion deliberately starts a fresh root at sampled skipped positions.
    @inline(__always) func insert(_ cur: UnsafePointer<UInt8>, position: Int, available: Int) {
        guard available >= 4 else { return }
        let (h, s) = hash(cur, available: available), value = UInt32(position + 1)
        let previous = heads[h]; heads[h] = value; shortHeads?[s] = value
        if let links {
            let slot = position & (p.windowSize - 1)
            if p.strategy == .optimal { links[slot * 2] = 0; links[slot * 2 + 1] = 0 }
            else { links[slot] = previous }
        }
    }
    /// Improving matches in increasing length order. Caller supplies depth+2 cells.
    @inline(__always) func matches(_ cur: UnsafePointer<UInt8>, position: Int, available: Int,
                                  into result: UnsafeMutablePointer<ZstdMatch>) -> Int {
        guard available >= 4 else { return 0 }
        let (h, s) = hash(cur, available: available), value = UInt32(position + 1)
        var candidate = heads[h]; heads[h] = value
        let limit = min(available, p.niceLength)
        var best = p.strategy == .optimal ? 2 : 3, count = 0
        if let shortHeads {
            let old = shortHeads[s]; shortHeads[s] = value
            if old != 0 && old < value {
                let delta = Int(value - old)
                if delta <= p.windowSize {
                    let length = Self.length(cur, distance: delta, limit: limit)
                    if length > best { best = length; result[count] = ZstdMatch(length: length, distance: delta); count += 1 }
                }
            }
        }
        let slot = position & (p.windowSize - 1)
        if p.strategy == .optimal {
            let links = links!
            var lower = links + slot * 2, upper = lower + 1
            var lowerLength = 0, upperLength = 0, depth = p.depth
            while candidate != 0 && candidate < value && depth > 0 {
                let delta = Int(value - candidate)
                if delta >= p.windowSize { break } // exact-window candidate shares the cyclic slot
                let pair = links + ((position - delta) & (p.windowSize - 1)) * 2
                let length = Self.length(cur, distance: delta, limit: limit, start: min(lowerLength, upperLength))
                if length > best { best = length; result[count] = ZstdMatch(length: length, distance: delta); count += 1 }
                if length == limit {
                    // At a short block tail, the next block can change the key's suffix.
                    // Inheriting children ordered by an unknown suffix invalidates prefix bounds.
                    lower.pointee = limit == p.niceLength ? pair[0] : 0
                    upper.pointee = limit == p.niceLength ? pair[1] : 0
                    if count > 0 && best == limit {
                        result[count - 1].length = Self.length(cur, distance: result[count - 1].distance, limit: available, start: limit)
                    }
                    return count
                }
                if cur[length - delta] < cur[length] {
                    lower.pointee = candidate; lower = pair + 1; candidate = pair[1]; lowerLength = length
                } else {
                    upper.pointee = candidate; upper = pair; candidate = pair[0]; upperLength = length
                }
                depth -= 1
            }
            lower.pointee = 0; upper.pointee = 0
        } else {
            if let links { links[slot] = candidate }
            var depth = p.depth
            while candidate != 0 && candidate < value && depth > 0 && best < limit {
                let delta = Int(value - candidate)
                if delta > p.windowSize { break }
                if cur[best] == cur[best - delta] {
                    let length = Self.length(cur, distance: delta, limit: limit)
                    if length > best { best = length; result[count] = ZstdMatch(length: length, distance: delta); count += 1 }
                }
                if let links { candidate = links[(position - delta) & (p.windowSize - 1)] }
                else { break }
                depth -= 1
            }
        }
        if count > 0 && best == limit {
            let distance = result[count - 1].distance
            result[count - 1].length = Self.length(cur, distance: distance, limit: available, start: limit)
        }
        return count
    }
}
