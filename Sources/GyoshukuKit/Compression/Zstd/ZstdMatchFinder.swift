// Independent implementation from RFC 8878; no zstd source consulted.
// Hash/row/tree search is an independently designed encoder policy, not part of the wire format.
import Foundation

final class ZstdMatchFinder {
    private let shortPositions: UnsafeMutablePointer<UInt32>?
    private let shortTags: UnsafeMutablePointer<UInt8>?
    private let shortCursors: UnsafeMutablePointer<UInt32>?
    private let shortWidth: Int
    private let rowPositions: UnsafeMutablePointer<UInt32>?
    private let rowTags: UnsafeMutablePointer<UInt8>?
    private let rowCursors: UnsafeMutablePointer<UInt32>?
    private let rowCount: Int
    private let rowWidth: Int
    private let rowLog: Int
    private let p: ZstdEncoderProperties
    private let fastTags: UnsafeMutablePointer<UInt8>?
    private let heads: UnsafeMutablePointer<UInt32>
    private let shortHeads: UnsafeMutablePointer<UInt32>
    private let links: UnsafeMutablePointer<UInt32>?
    private let hashCount: Int
    private let linkCount: Int
    init(properties: ZstdEncoderProperties) {
        p = properties; hashCount = 1 << p.hashLog
        let rows = p.strategy == .lazy || p.strategy == .lazy2
        rowWidth = p.depth <= 16 ? 16 : p.depth <= 32 ? 32 : p.depth <= 64 ? 64 : 128
        rowLog = p.hashLog - (rowWidth <= 32 ? 4 : rowWidth <= 64 ? 5 : 6)
        rowCount = rows ? 1 << rowLog : 0
        shortWidth = p.level <= 8 ? 16 : p.level <= 10 ? 32 : 64
        if rows {
            shortPositions = .allocate(capacity: rowCount * shortWidth); shortPositions!.initialize(repeating: 0, count: rowCount * shortWidth)
            shortTags = .allocate(capacity: rowCount * shortWidth); shortTags!.initialize(repeating: 0, count: rowCount * shortWidth)
            shortCursors = .allocate(capacity: rowCount); shortCursors!.initialize(repeating: 0, count: rowCount)

            rowPositions = .allocate(capacity: rowCount * rowWidth); rowPositions!.initialize(repeating: 0, count: rowCount * rowWidth)
            rowTags = .allocate(capacity: rowCount * rowWidth); rowTags!.initialize(repeating: 0, count: rowCount * rowWidth)
            rowCursors = .allocate(capacity: rowCount); rowCursors!.initialize(repeating: 0, count: rowCount)
        } else {
            rowPositions = nil; rowTags = nil; rowCursors = nil
            shortPositions = nil; shortTags = nil; shortCursors = nil
        }
        heads = .allocate(capacity: hashCount); heads.initialize(repeating: 0, count: hashCount)
        let shortCount = p.strategy == .fast ? 0 : 1 << 16
        shortHeads = .allocate(capacity: shortCount); shortHeads.initialize(repeating: 0, count: shortCount)
        if p.strategy == .fast {
            fastTags = .allocate(capacity: hashCount); fastTags!.initialize(repeating: 0, count: hashCount)
        } else { fastTags = nil }
        linkCount = p.strategy == .optimal ? p.windowSize * 2 : 0
        if linkCount > 0 {
            links = .allocate(capacity: linkCount); links!.initialize(repeating: 0, count: linkCount)
        } else { links = nil }
    }
    deinit {
        heads.deallocate(); fastTags?.deallocate(); shortHeads.deallocate(); links?.deallocate()
        rowPositions?.deallocate(); rowTags?.deallocate(); rowCursors?.deallocate()
        shortPositions?.deallocate(); shortTags?.deallocate(); shortCursors?.deallocate()
    }

    /// Extremely long streams periodically renumber table positions, preserving the live window.
    func rebase(by amount: UInt32) {
        for i in 0..<hashCount { heads[i] = heads[i] > amount ? heads[i] - amount : 0 }
        if fastTags == nil { for i in 0..<(1 << 16) { shortHeads[i] = shortHeads[i] > amount ? shortHeads[i] - amount : 0 } }
        if let links { for i in 0..<linkCount { links[i] = links[i] > amount ? links[i] - amount : 0 } }
        if let rowPositions { for i in 0..<(rowCount * rowWidth) { rowPositions[i] = rowPositions[i] > amount ? rowPositions[i] - amount : 0 } }
        if let shortPositions { for i in 0..<(rowCount * shortWidth) { shortPositions[i] = shortPositions[i] > amount ? shortPositions[i] - amount : 0 } }
    }
    @inline(__always) private func hash(_ cur: UnsafePointer<UInt8>, available: Int) -> (Int, Int) {
        let raw = UnsafeRawPointer(cur)
        let v = UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
        if p.strategy == .doubleHash || p.strategy == .fast {
            let word = available >= 8 ? raw.loadUnaligned(as: UInt64.self) : 0
            let key = p.strategy == .fast ? word << 24 : word
            let long = available >= 8
                ? Int((key &* 0xCF1BBCDCB7A56463) >> (64 - p.hashLog))
                : Int((v &* 0x9E3779B1) >> (32 - p.hashLog))
            return (long, Int((v &* 0x9E3779B1) >> 16))
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
    /// 一致内と RLE block の辞書更新。tree は間引いた位置を新しい root にする。
    @inline(__always) func insert(_ cur: UnsafePointer<UInt8>, position: Int, available: Int) {
        guard available >= 4 else { return }
        let (h, s) = hash(cur, available: available), value = UInt32(position + 1)
        if let fastTags {
            heads[h] = value
            fastTags[h] = Self.fastTag(UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self))
            return
        }
        let previous = heads[h]; heads[h] = value; shortHeads[s] = value
        if rowPositions != nil { insertRow(cur, value: value, available: available) }
        if let links {
            let slot = position & (p.windowSize - 1)
            if p.strategy == .optimal { links[slot * 2] = 0; links[slot * 2 + 1] = 0 }
            else { links[slot] = previous }
        }
    }
    @inline(__always) private static func tagBits(_ lanes: UInt64) -> UInt64 {
        ((lanes & 0x0101010101010101) &* 0x0102040810204080) >> 56
    }
    @inline(__always) private func insertRow(_ cur: UnsafePointer<UInt8>, value: UInt32, available: Int) {
        let v = available >= 8 ? UnsafeRawPointer(cur).loadUnaligned(as: UInt64.self) &* 0xCF1BBCDCB7A56463
            : UInt64(UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self)) &* 0xCF1BBCDCB7A56463
        let row = Int(v >> (64 - rowLog)), tag = UInt8(truncatingIfNeeded: v >> (56 - rowLog))
        let cursor = Int(rowCursors![row]), slot = row * rowWidth + cursor
        rowPositions![slot] = value; rowTags![slot] = tag
        rowCursors![row] = UInt32((cursor + 1) & (rowWidth - 1))
        insertShortRow(cur, value: value)
    }
    @inline(__always) private func insertShortRow(_ cur: UnsafePointer<UInt8>, value: UInt32) {
        let v = UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self) &* 0x9E3779B1
        let row = Int(v >> (32 - rowLog)), cursor = Int(shortCursors![row])
        let slot = row * shortWidth + cursor
        shortPositions![slot] = value; shortTags![slot] = UInt8(truncatingIfNeeded: v >> (24 - rowLog))
        shortCursors![row] = UInt32((cursor + 1) & (shortWidth - 1))
    }
    @inline(__always) private func shortRowMatch(_ cur: UnsafePointer<UInt8>, value: UInt32, available: Int, best: Int) -> ZstdMatch {
        let v = UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self) &* 0x9E3779B1
        let row = Int(v >> (32 - rowLog)), tag = UInt8(truncatingIfNeeded: v >> (24 - rowLog))
        let base = row * shortWidth, cursor = Int(shortCursors![row])
        var mask: UInt64
        if shortWidth == 16 {
            let tags = UnsafeRawPointer(shortTags! + base).loadUnaligned(as: SIMD16<UInt8>.self)
            let eq = unsafeBitCast(tags .== SIMD16<UInt8>(repeating: tag), to: SIMD2<UInt64>.self)
            mask = Self.tagBits(eq[0]) | (Self.tagBits(eq[1]) << 8)
        } else {
            mask = 0
            for group in stride(from: 0, to: shortWidth, by: 32) {
                let tags = UnsafeRawPointer(shortTags! + base + group).loadUnaligned(as: SIMD32<UInt8>.self)
                let eq = unsafeBitCast(tags .== SIMD32<UInt8>(repeating: tag), to: SIMD4<UInt64>.self)
                let packed = Self.tagBits(eq[0]) | (Self.tagBits(eq[1]) << 8) | (Self.tagBits(eq[2]) << 16) | (Self.tagBits(eq[3]) << 24)
                mask |= packed << group
            }
        }
        let widthMask: UInt64 = shortWidth == 64 ? .max : (1 << shortWidth) - 1
        mask = ((mask >> cursor) | (mask << (shortWidth - cursor))) & widthMask
        var match = ZstdMatch(length: best, distance: 0)
        let limit = min(8, available)
        while mask != 0 && match.length < limit {
            let slot = (63 - mask.leadingZeroBitCount + cursor) & (shortWidth - 1)
            mask &= ~(1 << (63 - mask.leadingZeroBitCount))
            let old = shortPositions![base + slot]
            if old == 0 || old >= value { continue }
            let delta = Int(value - old)
            if delta > p.windowSize || cur[match.length] != cur[match.length - delta] { continue }
            let length = Self.length(cur, distance: delta, limit: limit)
            if length > match.length { match = ZstdMatch(length: length, distance: delta) }
        }
        if match.distance > 0 && match.length == limit {
            match.length = Self.length(cur, distance: match.distance, limit: available, start: limit)
        }
        return match
    }
    // double hash の走査中は二つの辞書表を一度だけ借りる。
    func withFastTables<R>(_ body: (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> R) -> R {
        // .fast は shortHeads を確保しない。
        assert(p.strategy != .fast)
        return body(heads, shortHeads)
    }
    // fast の tag は衝突時の入力 load を省く。実一致と履歴範囲は別途検証する。
    func withFastHeads<R>(_ body: (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt8>) -> R) -> R { body(heads, fastTags!) }
    @inline(__always) static func fastTag(_ word: UInt32) -> UInt8 {
        UInt8(truncatingIfNeeded: (word &* 0x9E3779B1) >> 24)
    }
    /// greedy 専用。探索深さ1/2の候補を直接返し、strategy 分岐と scratch 書込を省く。
    @inline(__always) func fastMatch(_ cur: UnsafePointer<UInt8>, position: Int, available: Int,
                                    hashLog: Int, window: Int, niceLength: Int) -> ZstdMatch {
        // .fast は shortHeads を確保しない。
        assert(p.strategy != .fast)
        let raw = UnsafeRawPointer(cur), word = raw.loadUnaligned(as: UInt32.self)
        let h: Int
        if available >= 8 {
            h = Int((raw.loadUnaligned(as: UInt64.self) &* 0xCF1BBCDCB7A56463) >> (64 - hashLog))
        } else { h = Int((word &* 0x9E3779B1) >> (32 - hashLog)) }
        let value = UInt32(position + 1), previous = heads[h]
        heads[h] = value
        var best = ZstdMatch(length: 0, distance: 0)
        let limit = min(available, niceLength)
        do {
            let short = Int((word &* 0x9E3779B1) >> 16)
            let old = shortHeads[short]; shortHeads[short] = value
            if old > 0 && old < value {
                let distance = Int(value - old)
                if distance <= window && UnsafeRawPointer(cur - distance).loadUnaligned(as: UInt32.self) == word {
                    best = ZstdMatch(length: Self.length(cur, distance: distance, limit: limit, start: 4), distance: distance)
                }
            }
        }
        if previous > 0 && previous < value {
            let distance = Int(value - previous)
            if distance <= window && best.length < limit
                && UnsafeRawPointer(cur - distance).loadUnaligned(as: UInt32.self) == word {
                let length = Self.length(cur, distance: distance, limit: limit, start: 4)
                if length > best.length { best = ZstdMatch(length: length, distance: distance) }
            }
        }
        if best.length == limit && best.length > 0 {
            best.length = Self.length(cur, distance: best.distance, limit: available, start: limit)
        }
        return best
    }
    @inline(__always) func insertFast(_ cur: UnsafePointer<UInt8>, position: Int, available: Int,
                                     hashLog: Int) {
        // .fast は shortHeads を確保しない。
        assert(p.strategy != .fast)
        guard available >= 4 else { return }
        let raw = UnsafeRawPointer(cur), word = raw.loadUnaligned(as: UInt32.self)
        let h: Int
        if available >= 8 {
            h = Int((raw.loadUnaligned(as: UInt64.self) &* 0xCF1BBCDCB7A56463) >> (64 - hashLog))
        } else { h = Int((word &* 0x9E3779B1) >> (32 - hashLog)) }
        let value = UInt32(position + 1)
        heads[h] = value
        shortHeads[Int((word &* 0x9E3779B1) >> 16)] = value
    }
    /// Improving matches in increasing length order. Caller supplies depth+4 cells.
    @inline(__always) func matches(_ cur: UnsafePointer<UInt8>, position: Int, available: Int,
                                  into result: UnsafeMutablePointer<ZstdMatch>) -> Int {
        guard available >= 4 else { return 0 }
        let (h, s) = hash(cur, available: available), value = UInt32(position + 1)
        if let fastTags {
            let word = UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self), tag = Self.fastTag(word)
            let old = heads[h], oldTag = fastTags[h]
            heads[h] = value; fastTags[h] = tag
            let distance = Int(value &- old)
            guard oldTag == tag && distance > 0 && distance <= min(p.windowSize, position)
                && UnsafeRawPointer(cur - distance).loadUnaligned(as: UInt32.self) == word else { return 0 }
            let length = Self.length(cur, distance: distance, limit: available, start: 4)
            result[0] = ZstdMatch(length: length, distance: distance)
            return 1
        }
        var candidate = heads[h]; heads[h] = value
        let limit = min(available, p.niceLength)
        var best = p.strategy == .optimal ? 2 : 3, count = 0
        do {
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
        if let rowPositions, let rowTags, let rowCursors {
            if candidate > 0 && candidate < value && best < limit {
                let delta = Int(value - candidate)
                if delta <= p.windowSize && cur[best] == cur[best - delta] {
                    let length = Self.length(cur, distance: delta, limit: limit)
                    if length > best { best = length; result[count] = ZstdMatch(length: length, distance: delta); count += 1 }
                }
            }
            let v = available >= 8 ? UnsafeRawPointer(cur).loadUnaligned(as: UInt64.self) &* 0xCF1BBCDCB7A56463
                : UInt64(UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self)) &* 0xCF1BBCDCB7A56463
            let row = Int(v >> (64 - rowLog)), tag = UInt8(truncatingIfNeeded: v >> (56 - rowLog))
            let base = row * rowWidth, cursor = Int(rowCursors[row])
            // tag の16/32 lane をまとめて比較し、新しい一致候補から辿る。
            var mask0: UInt64 = 0, mask1: UInt64 = 0
            if rowWidth == 16 {
                let tags = UnsafeRawPointer(rowTags + base).loadUnaligned(as: SIMD16<UInt8>.self)
                let eq = unsafeBitCast(tags .== SIMD16<UInt8>(repeating: tag), to: SIMD2<UInt64>.self)
                mask0 = Self.tagBits(eq[0]) | (Self.tagBits(eq[1]) << 8)
            } else {
                for group in stride(from: 0, to: rowWidth, by: 32) {
                    let tags = UnsafeRawPointer(rowTags + base + group).loadUnaligned(as: SIMD32<UInt8>.self)
                    let eq = unsafeBitCast(tags .== SIMD32<UInt8>(repeating: tag), to: SIMD4<UInt64>.self)
                    let packed = Self.tagBits(eq[0]) | (Self.tagBits(eq[1]) << 8)
                        | (Self.tagBits(eq[2]) << 16) | (Self.tagBits(eq[3]) << 24)
                    if group < 64 { mask0 |= packed << group }
                    else { mask1 |= packed << (group - 64) }
                }
            }
            var remaining = p.depth, end = cursor
            while remaining > 0 && best < limit {
                if end == 0 { end = rowWidth }
                let group = (end - 1) >> 6, lower = max(group * 64, end - remaining)
                let highMask: UInt64 = end & 63 == 0 ? .max : (1 << (end & 63)) - 1
                let lowMask: UInt64 = lower & 63 == 0 ? 0 : (1 << (lower & 63)) - 1
                var bits = (group == 0 ? mask0 : mask1) & highMask & ~lowMask
                while bits != 0 && best < limit {
                    let lane = 63 - bits.leadingZeroBitCount
                    bits &= ~(1 << lane)
                    let old = rowPositions[base + group * 64 + lane]
                    if old == 0 || old >= value { continue }
                    let delta = Int(value - old)
                    if delta > p.windowSize || cur[best] != cur[best - delta] { continue }
                    let length = Self.length(cur, distance: delta, limit: limit)
                    if length > best { best = length; result[count] = ZstdMatch(length: length, distance: delta); count += 1 }
                }
                remaining -= end - lower; end = lower
            }
            if best < min(8, limit) {
                let match = shortRowMatch(cur, value: value, available: available, best: best)
                if match.length > best { best = match.length; result[count] = match; count += 1 }
            }
            insertShortRow(cur, value: value)
            rowPositions[base + cursor] = value; rowTags[base + cursor] = tag
            rowCursors[row] = UInt32((cursor + 1) & (rowWidth - 1))
        } else if p.strategy == .optimal {
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
