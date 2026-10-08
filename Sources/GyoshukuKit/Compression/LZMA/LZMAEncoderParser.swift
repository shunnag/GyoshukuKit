// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

extension LZMAEncodingEngine {
    @inline(__always) mutating func single(_ length: Int, _ code: Int, limit: Int) {
        actions[0] = LZMAAction(length: length, code: code); actionCount = 1; actionIndex = 0
        skip(to: cursor &+ length, limit: limit)
    }
    @inline(__always) static func changePair(_ small: Int, _ large: Int) -> Bool { (large &- 1) >> 7 > small &- 1 }

    /// GetOptimumFast の rep 優先、遠距離の短い一致の除外、次位置による遅延。
    mutating func parseFast(limit: Int) {
        if pendingMatches { pendingMatches = false } else { readMatches(limit: limit) }
        let available = min(273, limit &- cursor)
        let data = UnsafePointer(window + cursor)
        if available < 2 { single(1, -1, limit: limit); return }
        var mainLen = matchCount == 0 ? 0 : matches[matchCount &- 1].length
        var mainDistance = matchCount == 0 ? 1 : matches[matchCount &- 1].distance
        var repLen = 0, repIndex = 0
        for i in 0..<4 {
            let len = repLength(data, distance: reps[i], limit: available, history: min(cursor, dictionary))
            if len >= properties.niceLen { single(len, i, limit: limit); return }
            if len > repLen { repLen = len; repIndex = i }
        }
        if mainLen >= properties.niceLen { single(mainLen, mainDistance &+ 3, limit: limit); return }
        if mainLen >= 2 {
            while matchCount > 1 {
                let previous = matches[matchCount &- 2]
                if mainLen != previous.length &+ 1 || !Self.changePair(previous.distance, mainDistance) { break }
                matchCount &-= 1; mainLen &-= 1; mainDistance = previous.distance
            }
            if mainLen == 2 && mainDistance &- 1 >= 128 { mainLen = 1 }
        }
        if repLen >= 2 && (repLen &+ 1 >= mainLen || (repLen &+ 2 >= mainLen && mainDistance > 512)
                          || (repLen &+ 3 >= mainLen && mainDistance > 32768)) {
            single(repLen, repIndex, limit: limit); return
        }
        if mainLen < 2 || available <= 2 { single(1, -1, limit: limit); return }
        readMatches(limit: limit)
        pendingMatches = true
        if matchCount > 0 {
            let next = matches[matchCount &- 1]
            if (next.length >= mainLen && next.distance < mainDistance)
                || (next.length == mainLen &+ 1 && !Self.changePair(mainDistance, next.distance))
                || next.length > mainLen &+ 1
                || (next.length &+ 1 >= mainLen && mainLen >= 3 && Self.changePair(next.distance, mainDistance)) {
                single(1, -1, limit: limit); return
            }
        }
        for i in 0..<4 {
            let len = repLength(data + 1, distance: reps[i], limit: mainLen &- 1, history: min(cursor &+ 1, dictionary))
            if len >= max(2, mainLen &- 1) { single(1, -1, limit: limit); return }
        }
        pendingMatches = false
        single(mainLen, mainDistance &+ 3, limit: limit)
    }

    /// Optimum の価格と到達 state/reps を同じ node に保存する。
    /// SDK の extra を明示的な predecessor として表し、複合 edge も逆順に復元する。
    @inline(__always) mutating func relax(from: Int, length: Int, code: Int, price: Int,
                                         state: Int, reps: LZMARepetitions, extra: Int = 0, tail: Int = 0) {
        let target = from &+ length &+ (extra == 0 ? 0 : 1 &+ tail)
        if price < Int(opt[target].price) {
            // 既存 node の価格を越える edge は探索末尾も延ばさない。
            if target > optUsed { optUsed = target }
            opt[target] = LZMAOptimal(price: price, state: state, reps: reps, previous: from,
                                      length: length, code: code, extra: extra, tail: tail)
        }
    }
    /// match/rep : literal : rep0 の edge。literal を挟んだ後の rep0 を見落とさない。
    @inline(__always) mutating func compound(from cur: Int, length: Int, code: Int, basePrice: Int,
                                            state s: Int, reps r: LZMARepetitions, available: Int,
                                            data: UnsafePointer<UInt8>, position pos: UInt64) {
        let start = length &+ 1
        let bound = min(available, start &+ properties.niceLen)
        if start &+ 2 > bound { return }
        let tail = repLength(data + start, distance: r.a, limit: bound &- start,
                             history: min(cursor &+ cur &+ start, dictionary))
        if tail < 2 { return }
        assert(tail <= properties.niceLen)
        let litPos = pos &+ UInt64(length)
        let litState = Self.literalState(s)
        let p = basePrice &+ price(probs[s &* 16 &+ posState(litPos)], 0)
            &+ literalPrice(data + length, position: litPos, state: s, reps: r)
            &+ rep0Price(state: litState, pos: posState(litPos &+ 1))
            &+ repLengthPrices[posState(litPos &+ 1) &* 272 &+ tail &- 2]
        relax(from: cur, length: length, code: code, price: p, state: Self.repState(litState),
              reps: r, extra: length &+ 1, tail: tail)
    }

    /// GetOptimum: literal、short rep、全 rep 長、全 match 長、複合 edge を比較する。
    /// 位置は検査済み window 内、node は4096以内なので hot loop の加減算は wrap しない。
    mutating func parseNormal(limit: Int) {
        actionCount = 0; actionIndex = 0
        if pendingMatches { pendingMatches = false } else { readMatches(limit: limit) }
        let initial = UnsafePointer(window + cursor)
        let available = min(273, limit &- cursor)
        if available < 2 { single(1, -1, limit: limit); return }
        var bestRepLength = 0, bestRep = 0
        for i in 0..<4 {
            let n = repLength(initial, distance: reps[i], limit: available, history: min(cursor, dictionary))
            if n > bestRepLength { bestRepLength = n; bestRep = i }
        }
        if bestRepLength >= properties.niceLen { single(bestRepLength, bestRep, limit: limit); return }
        let mainLen = matchCount == 0 ? 0 : matches[matchCount &- 1].length
        if mainLen >= properties.niceLen { single(mainLen, matches[matchCount &- 1].distance &+ 3, limit: limit); return }
        if bestRepLength < 2 && mainLen < 2 && (reps.a > cursor || initial[0] != initial[-reps.a]) {
            single(1, -1, limit: limit); return
        }
        for i in 0...optUsed { opt[i].price = 1 << 30 }
        optUsed = 1
        opt[0] = LZMAOptimal(price: 0, state: state, reps: reps)
        var cur = 0, last = 1
        while cur < last {
            if cur >= 4032 {
                var best = cur
                for i in (cur &+ 1)...last where opt[i].price <= opt[best].price { best = i }
                skip(to: cursor &+ best, limit: limit)
                cur = best
                break
            }
            if cur > 0 {
                readMatches(limit: limit)
                if matchCount > 0 && matches[matchCount &- 1].length >= properties.niceLen {
                    pendingMatches = true
                    break
                }
            }
            let node = opt[cur], s = Int(node.state), r = node.reps
            let pos = position &+ UInt64(cur), ps = posState(pos)
            let data = UnsafePointer(window + (cursor &+ cur))
            let full = min(limit &- cursor &- cur, 4095 &- cur)
            if full <= 0 { break }
            let maxLength = min(full, properties.niceLen)
            let lengthRow = lengthPrices + ps &* 272
            let repLengthRow = repLengthPrices + ps &* 272
            let matchByte: UInt8? = r.a <= min(cursor &+ cur, dictionary) ? data[-r.a] : nil
            let matchPrice = Int(node.price) &+ price(probs[s &* 16 &+ ps], 1)
            var litPrice = Int(node.price) &+ price(probs[s &* 16 &+ ps], 0)
            var nextIsLiteral = false
            if cur > 0 && ((opt[cur &+ 1].price < 1 << 30 && matchByte == data[0]) || litPrice > Int(opt[cur &+ 1].price)) {
                litPrice = 0
            } else {
                litPrice &+= literalPrice(data, position: pos, state: s, reps: r)
                nextIsLiteral = litPrice < Int(opt[cur &+ 1].price)
                relax(from: cur, length: 1, code: -1, price: litPrice, state: Self.literalState(s), reps: r)
            }
            let repPrice = matchPrice &+ price(probs[192 &+ s], 1)
            if (cur == 0 || s < 7), matchByte == data[0],
               (cur == 0 || opt[cur &+ 1].length < 2 || opt[cur &+ 1].code != 0) {
                let short = repPrice &+ price(probs[204 &+ s], 0) &+ price(probs[240 &+ s &* 16 &+ ps], 0)
                if short < Int(opt[cur &+ 1].price) {
                    relax(from: cur, length: 1, code: 0, price: short, state: Self.shortState(s), reps: r)
                    nextIsLiteral = false
                }
            }
            if full >= 2 {
                if cur > 0 && !nextIsLiteral && litPrice != 0 && matchByte != data[0] && full > 2 {
                    let tail = repLength(data + 1, distance: r.a, limit: min(properties.niceLen, full &- 1),
                                         history: min(cursor &+ cur &+ 1, dictionary))
                    if tail >= 2 {
                        assert(tail <= properties.niceLen)
                        let s2 = Self.literalState(s), ps2 = posState(pos &+ 1)
                        // length=0 と extra=1 は literal : rep0 を表す。
                        relax(from: cur, length: 0, code: -1,
                              price: litPrice &+ rep0Price(state: s2, pos: ps2) &+ repLengthPrices[ps2 &* 272 &+ tail &- 2],
                              state: Self.repState(s2), reps: r, extra: 1, tail: tail)
                    }
                }
                var startLength = 2
                for i in 0..<4 {
                    let n = repLength(data, distance: r[i], limit: maxLength, history: min(cursor &+ cur, dictionary))
                    if n < 2 { continue }
                    let pure = repPrice &+ pureRepPrice(i, state: s, pos: ps)
                    let moved = r.moved(i), s2 = Self.repState(s)
                    var len = n
                    while len >= 2 {
                        assert(len <= properties.niceLen)
                        relax(from: cur, length: len, code: i, price: pure &+ repLengthRow[len &- 2], state: s2, reps: moved)
                        len &-= 1
                    }
                    if i == 0 { startLength = n &+ 1 }
                    if cur > 0 {
                        assert(n <= properties.niceLen)
                        compound(from: cur, length: n, code: i, basePrice: pure &+ repLengthRow[n &- 2],
                                 state: s2, reps: moved, available: full, data: data, position: pos)
                    }
                }
                let normalPrice = matchPrice &+ price(probs[192 &+ s], 0)
                var start = startLength
                for i in 0..<matchCount {
                    let match = matches[i], maxLen = min(match.length, maxLength)
                    let moved = r.inserting(match.distance), s2 = Self.matchState(s)
                    if start <= maxLen {
                        // length >= 5 の距離価格は同じ。slot と align を長さごとに求め直さない。
                        let distance = match.distance &- 1
                        let slot = distance < 128 ? 0 : Self.slot(distance)
                        let longDistancePrice = distance < 128 ? distancePrices[384 &+ distance]
                            : slotPrices[192 &+ slot] &+ alignPrices[distance & 15]
                        var len = start
                        while len < 5 && len <= maxLen {
                            assert(len <= properties.niceLen)
                            let ls = len &- 2
                            let dp = distance < 128 ? distancePrices[ls &* 128 &+ distance]
                                : slotPrices[ls &* 64 &+ slot] &+ alignPrices[distance & 15]
                            relax(from: cur, length: len, code: match.distance &+ 3,
                                  price: normalPrice &+ lengthRow[len &- 2] &+ dp, state: s2, reps: moved)
                            len &+= 1
                        }
                        while len <= maxLen {
                            assert(len <= properties.niceLen)
                            relax(from: cur, length: len, code: match.distance &+ 3,
                                  price: normalPrice &+ lengthRow[len &- 2] &+ longDistancePrice, state: s2, reps: moved)
                            len &+= 1
                        }
                        if cur > 0 {
                            assert(maxLen <= properties.niceLen)
                            let dp = maxLen >= 5 ? longDistancePrice : distancePrice(distance, length: maxLen)
                            compound(from: cur, length: maxLen, code: match.distance &+ 3,
                                     basePrice: normalPrice &+ lengthRow[maxLen &- 2] &+ dp,
                                     state: s2, reps: moved, available: full, data: data, position: pos)
                        }
                    }
                    start = max(start, maxLen &+ 1)
                }
            }
            last = max(last, optUsed)
            cur &+= 1
        }
        // Backward: extra を展開し、符号化順に反転する。
        var back = cur
        while back > 0 {
            let node = opt[back]
            if node.extra != 0 {
                actions[actionCount] = LZMAAction(length: Int(node.tail), code: 0); actionCount &+= 1
                actions[actionCount] = LZMAAction(length: 1, code: -1); actionCount &+= 1
                if node.extra > 1 { actions[actionCount] = LZMAAction(length: Int(node.length), code: Int(node.code)); actionCount &+= 1 }
            } else { actions[actionCount] = LZMAAction(length: Int(node.length), code: Int(node.code)); actionCount &+= 1 }
            back = Int(node.previous)
        }
        for i in 0..<(actionCount / 2) {
            let temp = actions[i]; actions[i] = actions[actionCount &- i &- 1]; actions[actionCount &- i &- 1] = temp
        }
        skip(to: cursor &+ cur, limit: limit)
    }
}
