// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation

final class ZstdParser {
    let finder: ZstdMatchFinder
    private let p: ZstdEncoderProperties
    private let scratch: UnsafeMutablePointer<ZstdMatch>
    private let nodes: UnsafeMutablePointer<Node>
    private let literalCosts: UnsafeMutablePointer<Int>
    private let matchCosts: UnsafeMutablePointer<Int>
    private var retainedSequences: [ZstdSequence] = []
    private var llPrices = [Int](repeating: 0, count: 36)
    private var mlPrices = [Int](repeating: 0, count: 53)
    private var ofPrices = [Int](repeating: 0, count: 29)
    init(properties: ZstdEncoderProperties) {
        let capacity = properties.strategy == .optimal ? ZstdFrameEncoder.blockSize + 1 : 0
        nodes = .allocate(capacity: capacity)
        nodes.initialize(repeating: Node(), count: capacity)
        literalCosts = .allocate(capacity: capacity); literalCosts.initialize(repeating: 0, count: capacity)
        matchCosts = .allocate(capacity: capacity); matchCosts.initialize(repeating: 0, count: capacity)
        p = properties; finder = ZstdMatchFinder(properties: p)
        scratch = .allocate(capacity: p.depth + 4)
        func prices(_ distribution: [Int], size: Int) -> [Int] {
            distribution.map { Int(log2(Double(size) / Double(max(1, abs($0)))) * 256) }
        }
        if p.strategy == .optimal {
            llPrices = prices(ZstdFSEEncoder.literals.probabilities, size: 64)
            mlPrices = prices(ZstdFSEEncoder.matches.probabilities, size: 64)
            ofPrices = prices(ZstdFSEEncoder.offsets.probabilities, size: 32)
            refreshCosts()
        }
    }
    deinit {
        scratch.deallocate()
        let capacity = p.strategy == .optimal ? ZstdFrameEncoder.blockSize + 1 : 0
        nodes.deinitialize(count: capacity); nodes.deallocate()
        literalCosts.deinitialize(count: capacity); literalCosts.deallocate()
        matchCosts.deinitialize(count: capacity); matchCosts.deallocate()
    }
    private func refreshCosts() {
        guard p.strategy == .optimal else { return }
        for code in ZstdSequences.literalBases.indices {
            let start = ZstdSequences.literalBases[code]
            let end = code + 1 < ZstdSequences.literalBases.count ? ZstdSequences.literalBases[code + 1] : ZstdFrameEncoder.blockSize + 1
            (literalCosts + start).update(repeating: llPrices[code] + ZstdSequences.literalBits[code] * 256, count: end - start)
        }
        for code in ZstdSequences.matchBases.indices {
            let start = ZstdSequences.matchBases[code]
            let end = code + 1 < ZstdSequences.matchBases.count ? ZstdSequences.matchBases[code + 1] : ZstdFrameEncoder.blockSize + 1
            (matchCosts + start).update(repeating: mlPrices[code] + ZstdSequences.matchBits[code] * 256, count: end - start)
        }
    }
    /// Statistics from a successfully emitted compressed block price the next block.
    func updatePrices(_ sequences: [ZstdSequence], repeats: ZstdRepeatOffsets) {
        guard p.strategy == .optimal && sequences.count >= 16 else { return }
        var ll = [Int](repeating: 1, count: 36), ml = [Int](repeating: 1, count: 53), of = [Int](repeating: 1, count: 29)
        var reps = repeats
        for s in sequences {
            ll[ZstdSequences.literalCode(s.literals)] += 1; ml[ZstdSequences.matchCode(s.length)] += 1
            let v = reps.value(distance: s.distance, literals: s.literals)
            of[Int.bitWidth - 1 - v.leadingZeroBitCount] += 1
        }
        func prices(_ counts: [Int]) -> [Int] {
            let total = Double(counts.reduce(0, +))
            return counts.map { max(64, Int(log2(total / Double($0)) * 256)) }
        }
        llPrices = prices(ll); mlPrices = prices(ml); ofPrices = prices(of)
        refreshCosts()
    }
    func parse(_ bytes: UnsafePointer<UInt8>, count: Int, position: Int, repeats: ZstdRepeatOffsets) -> [ZstdSequence] {
        precondition(position >= 0 && count >= 0 && count <= ZstdFrameEncoder.blockSize
                     && UInt64(position) + UInt64(count) < UInt64(UInt32.max))
        precondition(repeats.a > 0 && repeats.b > 0 && repeats.c > 0
                     && max(repeats.a, repeats.b, repeats.c) <= min(p.windowSize, max(8, position)))
        let result: [ZstdSequence]
        if p.strategy == .optimal { result = optimal(bytes, count: count, position: position, repeats: repeats) }
        else if p.strategy == .fast { result = finder.withFastHeads { singleFast(bytes, count: count, position: position, repeats: repeats, heads: $0) } }
        else if p.strategy == .doubleHash { result = fast(bytes, count: count, position: position, repeats: repeats) }
        else { result = greedy(bytes, count: count, position: position, repeats: repeats) }
        retainedSequences = result
        return result
    }
    private func takeSequences(_ count: Int) -> [ZstdSequence] {
        var result: [ZstdSequence] = []
        swap(&result, &retainedSequences)
        result.removeAll(keepingCapacity: true)
        result.reserveCapacity(count / 8)
        return result
    }
    @inline(__always) private func best(_ bytes: UnsafePointer<UInt8>, index: Int, count: Int,
                                       position: Int, repeats: ZstdRepeatOffsets, literals: Int) -> ZstdMatch {
        var match = ZstdMatch(length: 0, distance: 0)
        let available = count - index
        let maximumDistance = min(p.windowSize, position + index)
        let cur = bytes + index
        repeatMatch(cur, distance: repeats.a, maximumDistance: maximumDistance, available: available, best: &match)
        repeatMatch(cur, distance: repeats.b, maximumDistance: maximumDistance, available: available, best: &match)
        repeatMatch(cur, distance: repeats.c, maximumDistance: maximumDistance, available: available, best: &match)
        let n = finder.matches(bytes + index, position: position + index, available: available, into: scratch)
        if n > 0 {
            let candidate = scratch[n - 1]
            // A short repeat can cost fewer bits than a slightly longer distant match.
            if candidate.length > match.length + (match.length >= 3 ? 1 : 0) { match = candidate }
        }
        return match
    }
    @inline(__always) private func repeatMatch(_ cur: UnsafePointer<UInt8>, distance: Int, maximumDistance: Int,
                                               available: Int, best: inout ZstdMatch) {
        guard distance > 0, distance <= maximumDistance, available >= 4 else { return }
        let a = UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self)
        let b = UnsafeRawPointer(cur - distance).loadUnaligned(as: UInt32.self)
        guard (a ^ b) & 0xFFFFFF == 0 else { return }
        let length = ZstdMatchFinder.length(cur, distance: distance, limit: available, start: 3)
        if length >= 3 && length > best.length { best = ZstdMatch(length: length, distance: distance) }
    }
    private func fast(_ bytes: UnsafePointer<UInt8>, count: Int, position: Int, repeats: ZstdRepeatOffsets) -> [ZstdSequence] {
        finder.withFastTables { heads, shorts in
            doubleFast(bytes, count: count, position: position, repeats: repeats, heads: heads, shorts: shorts)
        }
    }
    // parse 入口で block・position・repeat を検証済み。loop 内の整数も同じ有界範囲を保つ。
    private func doubleFast(_ bytes: UnsafePointer<UInt8>, count: Int, position: Int, repeats: ZstdRepeatOffsets,
                            heads: UnsafeMutablePointer<UInt32>, shorts: UnsafeMutablePointer<UInt32>) -> [ZstdSequence] {
        var reps = repeats, sequences = takeSequences(count)
        var index = 0, anchor = 0, misses = 0
        let hashLog = p.hashLog, window = p.windowSize, niceLength = p.niceLength
        while index &+ 4 <= count {
            let cur = bytes + index, available = count &- index
            var match = ZstdMatch(length: 0, distance: 0)
            let maximumDistance = min(window, position &+ index)
            let candidate: ZstdMatch
            if available >= 8 {
                let word = UnsafeRawPointer(cur).loadUnaligned(as: UInt64.self)
                match = Self.fastRepeats(cur, word: word, available: available, value: UInt32(truncatingIfNeeded: position &+ index &+ 1), repeats: reps)
                candidate = Self.doubleMatch(cur, word: word, position: position &+ index, available: available,
                                             hashLog: hashLog, window: window, niceLength: niceLength, heads: heads, shorts: shorts)
            } else {
                repeatMatch(cur, distance: reps.a, maximumDistance: maximumDistance, available: available, best: &match)
                repeatMatch(cur, distance: reps.b, maximumDistance: maximumDistance, available: available, best: &match)
                repeatMatch(cur, distance: reps.c, maximumDistance: maximumDistance, available: available, best: &match)
                candidate = finder.fastMatch(cur, position: position &+ index, available: available,
                                               hashLog: hashLog, window: window, niceLength: niceLength)
            }
            if candidate.length > match.length &+ (match.length >= 3 ? 1 : 0) { match = candidate }
            guard match.length >= 3 else {
                misses &+= 1
                // fast / doubleHash は非圧縮性の区間を徐々に間引く。
                index &+= min(16, 1 + (misses >> 5))
                continue
            }
            misses = 0
            let inserted = index
            var start = index
            // 後方への延長で fast の間引いた byte を回収する。
            while start > anchor && match.distance <= position &+ start &- 1
                    && bytes[start - 1] == bytes[start - 1 - match.distance] {
                start &-= 1; match.length &+= 1
            }
            let sequence = ZstdSequence(literals: start &- anchor, length: match.length, distance: match.distance)
            sequences.append(sequence); _ = reps.value(distance: match.distance, literals: sequence.literals)
            let end = start &+ match.length
            var insert = max(inserted &+ 1, start &+ 1)
            let step = match.length > 64 ? 4 : 1
            insert = Self.periodicInsertStart(insert, end: end, distance: match.distance, step: step)
            let bulkEnd = min(end &- 1, count &- 7)
            while insert < bulkEnd {
                let word = UnsafeRawPointer(bytes + insert).loadUnaligned(as: UInt64.self)
                let value = UInt32(truncatingIfNeeded: position &+ insert &+ 1)
                heads[Int((word &* 0xCF1BBCDCB7A56463) &>> (64 &- hashLog))] = value
                shorts[Int((UInt32(truncatingIfNeeded: word) &* 0x9E3779B1) >> 16)] = value
                insert &+= step
            }
            while insert < end &- 1 {
                finder.insertFast(bytes + insert, position: position + insert, available: count &- insert, hashLog: hashLog); insert &+= step
            }
            // Always preserve a recent root at the end of long matches.
            if end > inserted &+ 1 && end < count {
                if end &+ 7 <= count {
                    let word = UnsafeRawPointer(bytes + (end &- 1)).loadUnaligned(as: UInt64.self), value = UInt32(truncatingIfNeeded: position &+ end)
                    heads[Int((word &* 0xCF1BBCDCB7A56463) &>> (64 &- hashLog))] = value
                    shorts[Int((UInt32(truncatingIfNeeded: word) &* 0x9E3779B1) >> 16)] = value
                } else { finder.insertFast(bytes + (end &- 1), position: position &+ end &- 1, available: count &- end &+ 1, hashLog: hashLog) }
            }
            index = end; anchor = end
        }
        return sequences
    }

    @inline(__always) private static func doubleMatch(_ cur: UnsafePointer<UInt8>, word: UInt64, position: Int, available: Int,
                                                      hashLog: Int, window: Int, niceLength: Int,
                                                      heads: UnsafeMutablePointer<UInt32>, shorts: UnsafeMutablePointer<UInt32>) -> ZstdMatch {
        let h = Int((word &* 0xCF1BBCDCB7A56463) &>> (64 &- hashLog))
        let short = Int((UInt32(truncatingIfNeeded: word) &* 0x9E3779B1) >> 16)
        let value = UInt32(truncatingIfNeeded: position &+ 1), old = heads[h], shortOld = shorts[short]
        heads[h] = value; shorts[short] = value
        var best = ZstdMatch(length: 0, distance: 0)
        let maximumDistance = min(window, Int(value) &- 1)
        // 0 / 未来の head も、履歴長以内の差だけを採ることで排除する。
        let shortDistance = Int(value &- shortOld)
        if shortDistance > 0 && shortDistance <= maximumDistance {
            let diff = word ^ UnsafeRawPointer(cur - shortDistance).loadUnaligned(as: UInt64.self)
            if diff & 0xFFFFFFFF == 0 {
                let length = diff == 0 ? ZstdMatchFinder.length(cur, distance: shortDistance, limit: available, start: 8)
                    : diff.trailingZeroBitCount >> 3
                best = ZstdMatch(length: length, distance: shortDistance)
            }
        }
        let distance = Int(value &- old)
        if distance > 0 && distance <= maximumDistance && best.length < niceLength {
            let diff = word ^ UnsafeRawPointer(cur - distance).loadUnaligned(as: UInt64.self)
            if diff & 0xFFFFFFFF == 0 {
                let length = diff == 0 ? ZstdMatchFinder.length(cur, distance: distance, limit: available, start: 8)
                    : diff.trailingZeroBitCount >> 3
                if length > best.length { best = ZstdMatch(length: length, distance: distance) }
            }
        }
        return best
    }
    private func singleFast(_ bytes: UnsafePointer<UInt8>, count: Int, position: Int, repeats: ZstdRepeatOffsets,
                            heads: UnsafeMutablePointer<UInt32>) -> [ZstdSequence] {
        var reps = repeats, sequences = takeSequences(count)
        var index = 0, anchor = 0, misses = 0
        let hashLog = p.hashLog, window = p.windowSize
        while index &+ 8 <= count {
            let cur = bytes + index, available = count &- index
            let word = UnsafeRawPointer(cur).loadUnaligned(as: UInt64.self)
            let h = Self.singleHash(word, log: hashLog), value = UInt32(truncatingIfNeeded: position &+ index &+ 1)
            let old = heads[h]
            let paired = misses < 7 && available >= 9
            var nextWord: UInt64 = 0, nextOld: UInt32 = 0
            if paired {
                nextWord = UnsafeRawPointer(cur + 1).loadUnaligned(as: UInt64.self)
                let nextHash = Self.singleHash(nextWord, log: hashLog)
                nextOld = nextHash == h ? value : heads[nextHash]
                heads[h] = value; heads[nextHash] = value &+ 1
            } else { heads[h] = value }
            var match = Self.singleBest(cur, word: word, old: old, value: value, available: available,
                                        window: window, repeats: reps)
            if match.length < 3 && paired {
                index &+= 1; misses &+= 1
                match = Self.singleBest(cur + 1, word: nextWord, old: nextOld, value: value &+ 1, available: available &- 1,
                                         window: window, repeats: reps)
            }
            guard match.length >= 3 else {
                misses &+= 1
                // fast / doubleHash は非圧縮性の区間を徐々に間引く。
                index &+= min(16, 1 + (misses >> 3))
                continue
            }
            misses = 0
            let inserted = index
            var start = index
            // 後方への延長で fast の間引いた byte を回収する。
            while start > anchor && match.distance <= position &+ start &- 1
                    && bytes[start - 1] == bytes[start - 1 - match.distance] {
                start &-= 1; match.length &+= 1
            }
            let sequence = ZstdSequence(literals: start &- anchor, length: match.length, distance: match.distance)
            sequences.append(sequence); _ = reps.value(distance: match.distance, literals: sequence.literals)
            let end = start &+ match.length
            var insert = max(inserted &+ 1, start &+ 1)
            let step = match.length > 64 ? 4 : 2
            insert = Self.periodicInsertStart(insert, end: end, distance: match.distance, step: step)
            while insert < min(end &- 1, count &- 7) {
                let word = UnsafeRawPointer(bytes + insert).loadUnaligned(as: UInt64.self)
                heads[Self.singleHash(word, log: hashLog)] = UInt32(truncatingIfNeeded: position &+ insert &+ 1)
                insert &+= step
            }
            if end > inserted &+ 1 && end &+ 7 <= count {
                let word = UnsafeRawPointer(bytes + (end &- 1)).loadUnaligned(as: UInt64.self)
                heads[Self.singleHash(word, log: hashLog)] = UInt32(truncatingIfNeeded: position &+ end)
            }
            index = end; anchor = end
        }
        while index &+ 4 <= count {
            var match = ZstdMatch(length: 0, distance: 0)
            let cur = bytes + index, maximumDistance = min(window, position &+ index)
            repeatMatch(cur, distance: reps.a, maximumDistance: maximumDistance, available: count &- index, best: &match)
            repeatMatch(cur, distance: reps.b, maximumDistance: maximumDistance, available: count &- index, best: &match)
            repeatMatch(cur, distance: reps.c, maximumDistance: maximumDistance, available: count &- index, best: &match)
            if match.length < 3 { index &+= 1; continue }
            let sequence = ZstdSequence(literals: index &- anchor, length: match.length, distance: match.distance)
            sequences.append(sequence); _ = reps.value(distance: match.distance, literals: sequence.literals)
            index &+= match.length; anchor = index
        }
        return sequences
    }
    // 短い周期では同じ hash が繰り返される。最後の一周期と末尾の先読みだけで表は同じになる。
    @inline(__always) private static func periodicInsertStart(_ start: Int, end: Int, distance: Int, step: Int) -> Int {
        guard distance <= 16 else { return start }
        let suffix = end &- 7 &- distance &* step
        guard suffix > start else { return start }
        return start &+ ((suffix &- start &+ step &- 1) / step) &* step
    }
    @inline(__always) private static func singleHash(_ word: UInt64, log: Int) -> Int {
        Int(((word &<< 24) &* 0xCF1BBCDCB7A56463) &>> (64 &- log))
    }
    @inline(__always) private static func singleBest(_ cur: UnsafePointer<UInt8>, word: UInt64, old: UInt32, value: UInt32,
                                                   available: Int, window: Int, repeats: ZstdRepeatOffsets) -> ZstdMatch {
        let maximumDistance = min(window, Int(value) &- 1)
        var best = fastRepeats(cur, word: word, available: available, value: value, repeats: repeats)
        let distance = Int(value &- old)
        if distance > 0 && distance <= maximumDistance && distance != best.distance {
            let diff = word ^ UnsafeRawPointer(cur - distance).loadUnaligned(as: UInt64.self)
            if diff & 0xFFFFFFFF == 0 {
                let length = diff == 0 ? ZstdMatchFinder.length(cur, distance: distance, limit: available, start: 8)
                    : diff.trailingZeroBitCount >> 3
                if length > best.length &+ (best.length >= 3 ? 1 : 0) { best = ZstdMatch(length: length, distance: distance) }
            }
        }
        return best
    }
    // 最初の8 byte以後は初期 repeat も全て履歴内。選択した距離は常に現在位置以下。
    @inline(__always) private static func fastRepeats(_ cur: UnsafePointer<UInt8>, word: UInt64, available: Int,
                                                    value: UInt32, repeats: ZstdRepeatOffsets) -> ZstdMatch {
        if value <= 8 { return initialRepeats(cur, word: word, available: available, position: Int(value) &- 1, repeats: repeats) }
        var best = ZstdMatch(length: 0, distance: 0)
        singleRepeat(cur, word: word, distance: repeats.a, available: available, best: &best)
        if repeats.b != repeats.a { singleRepeat(cur, word: word, distance: repeats.b, available: available, best: &best) }
        if repeats.c != repeats.a && repeats.c != repeats.b { singleRepeat(cur, word: word, distance: repeats.c, available: available, best: &best) }
        return best
    }
    @inline(never) private static func initialRepeats(_ cur: UnsafePointer<UInt8>, word: UInt64, available: Int,
                                                    position: Int, repeats: ZstdRepeatOffsets) -> ZstdMatch {
        var best = ZstdMatch(length: 0, distance: 0)
        for distance in [repeats.a, repeats.b, repeats.c] where distance <= position {
            singleRepeat(cur, word: word, distance: distance, available: available, best: &best)
        }
        return best
    }
    @inline(__always) private static func singleRepeat(_ cur: UnsafePointer<UInt8>, word: UInt64, distance: Int,
                                                     available: Int, best: inout ZstdMatch) {
        let diff = word ^ UnsafeRawPointer(cur - distance).loadUnaligned(as: UInt64.self)
        guard diff & 0xFFFFFF == 0 else { return }
        let length = diff == 0 ? ZstdMatchFinder.length(cur, distance: distance, limit: available, start: 8)
            : diff.trailingZeroBitCount >> 3
        if length > best.length { best = ZstdMatch(length: length, distance: distance) }
    }

    private func greedy(_ bytes: UnsafePointer<UInt8>, count: Int, position: Int, repeats: ZstdRepeatOffsets) -> [ZstdSequence] {
        var reps = repeats, sequences = takeSequences(count)
        var index = 0, anchor = 0
        let lazy = p.strategy == .lazy ? 1 : p.strategy == .lazy2 ? 2 : 0
        while index + 4 <= count {
            var match = best(bytes, index: index, count: count, position: position, repeats: reps, literals: index - anchor)
            guard match.length >= 3 else {
                index += 1
                continue
            }
            var inserted = index, start = index
            if lazy > 0 && match.length < p.niceLength {
                for ahead in 1...lazy where index + ahead + 4 <= count {
                    // 先読み1で長い改善一致を得たら、先読み2は辞書挿入だけにする。
                    // 挿入位置を保ち、一致内のサンプリングの位相を変えない。
                    if ahead == 2 && start > index && match.length >= p.niceLength / 8 {
                        finder.insert(bytes + index + ahead, position: position + index + ahead, available: count - index - ahead)
                        inserted = index + ahead
                        break
                    }
                    let next = best(bytes, index: index + ahead, count: count, position: position, repeats: reps,
                                    literals: index + ahead - anchor)
                    inserted = index + ahead
                    if next.length > match.length + ahead {
                        match = next; start = index + ahead
                    }
                }
            }
            // 後方への延長で lazy の先読みに飛ばされた byte を回収する。
            while start > anchor && match.distance <= position + start - 1
                    && bytes[start - 1] == bytes[start - 1 - match.distance] {
                start -= 1; match.length += 1
            }
            let sequence = ZstdSequence(literals: start - anchor, length: match.length, distance: match.distance)
            sequences.append(sequence); _ = reps.value(distance: match.distance, literals: sequence.literals)
            let end = start + match.length
            var insert = max(inserted + 1, start + 1)
            // 深い探索では短い一致の辞書も密に保つ。
            let step = p.depth >= 96 ? 1 : 2
            while insert < end - 1 {
                finder.insert(bytes + insert, position: position + insert, available: count - insert); insert += step
            }
            // Always preserve a recent root at the end of long matches.
            if end > inserted + 1 && end < count { finder.insert(bytes + end - 1, position: position + end - 1, available: count - end + 1) }
            index = end; anchor = end
        }
        return sequences
    }

    private struct Node {
        var price = Int.max / 4
        var previous = 0
        var length = 0
        var distance = 0
        var literals = 0
        var reps = ZstdRepeatOffsets()
    }
    @inline(__always) private func literalPrice(_ n: Int) -> Int {
        literalCosts[n]
    }
    /// One best path per byte with repeat history, adaptive entropy prices, and candidate endpoints.
    /// This is an approximate shortest-path parser: histories are merged, rather than an exponential search.
    private func optimal(_ bytes: UnsafePointer<UInt8>, count: Int, position: Int, repeats: ZstdRepeatOffsets) -> [ZstdSequence] {
        var frequencies = [Int](repeating: 1, count: 256)
        for i in 0..<count { frequencies[Int(bytes[i])] += 1 }
        let literalPrices = frequencies.map { min(2048, max(256, Int(log2(Double(count + 256) / Double($0)) * 256))) }
        nodes.update(repeating: Node(), count: count + 1)
        nodes[0] = Node(price: literalPrice(0), previous: 0, length: 0, distance: 0, literals: 0, reps: repeats)
        var i = 0
        while i < count {
            let node = nodes[i]
            let literalCost = node.price + literalPrices[Int(bytes[i])]
                + literalPrice(min(131071, node.literals + 1)) - literalPrice(node.literals)
            if literalCost < nodes[i + 1].price {
                nodes[i + 1] = Node(price: literalCost, previous: i, length: 0, distance: 0,
                                    literals: node.literals + 1, reps: node.reps)
            }
            let n = finder.matches(bytes + i, position: position + i, available: count - i, into: scratch)
            var long = ZstdMatch(length: 0, distance: 0)
            // Repeats can have a much lower offset cost even if absent from the hash/tree candidates.
            for repeatIndex in 0..<4 {
                let distance = repeatIndex == 0 ? node.reps.a : repeatIndex == 1 ? node.reps.b
                    : repeatIndex == 2 ? node.reps.c : node.reps.a - 1
                if distance <= 0 || distance > min(p.windowSize, position + i) { continue }
                let length = ZstdMatchFinder.length(bytes + i, distance: distance, limit: count - i)
                if length >= 3 {
                    relax(nodes, from: i, match: ZstdMatch(length: length, distance: distance), node: node)
                    if length > long.length { long = ZstdMatch(length: length, distance: distance) }
                }
            }
            for m in 0..<n {
                let match = scratch[m]
                relax(nodes, from: i, match: match, node: node)
                if match.length > long.length { long = match }
            }
            if long.length >= p.niceLength && nodes[i + long.length].previous == i {
                // Long matches bound work on highly repetitive input. Preserve sampled dictionary roots.
                for skipped in stride(from: i + 1, to: i + long.length, by: 4) {
                    finder.insert(bytes + skipped, position: position + skipped, available: count - skipped)
                }
                i += long.length
            } else { i += 1 }
        }
        var matches: [(Int, ZstdMatch)] = [], end = count
        while end > 0 {
            let node = nodes[end]
            if node.length > 0 { matches.append((node.previous, ZstdMatch(length: node.length, distance: node.distance))) }
            end = node.previous
        }
        var sequences = takeSequences(count), anchor = 0
        for (start, match) in matches.reversed() {
            sequences.append(ZstdSequence(literals: start - anchor, length: match.length, distance: match.distance))
            anchor = start + match.length
        }
        return sequences
    }
    @inline(__always) private func relax(_ nodes: UnsafeMutablePointer<Node>, from index: Int, match: ZstdMatch, node: Node) {
        // Exact endpoints up to 32 bytes, then code boundaries and the full match.
        // Shortening matches lets a following match start earlier without quadratic long-run work.
        let full = match.length
        var reps = node.reps
        let value = reps.value(distance: match.distance, literals: node.literals)
        let of = Int.bitWidth - 1 - value.leadingZeroBitCount
        let basePrice = node.price + ofPrices[of] + of * 256 + literalPrice(0)
        @inline(__always) func endpoint(_ length: Int) {
            let price = basePrice + matchCosts[length]
            let end = index + length
            if price < nodes[end].price {
                nodes[end] = Node(price: price, previous: index, length: length, distance: match.distance, literals: 0, reps: reps)
            }
        }
        for length in 3...min(full, 32) { endpoint(length) }
        if full > 32 {
            for code in 32..<ZstdSequences.matchBases.count {
                let base = ZstdSequences.matchBases[code]
                if base >= full { break }
                endpoint(base - 1)
            }
            endpoint(full)
        }
    }
}
