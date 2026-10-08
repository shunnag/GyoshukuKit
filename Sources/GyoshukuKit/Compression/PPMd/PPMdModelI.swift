// 出自: 7-Zip 26.03 の公開ドメイン C/Ppmd8.c、C/Ppmd8.h。
// Igor Pavlov、原作 Dmitry Shkarin の公開ドメイン PPMd var.I。rev.1 restart / cut-off の純 Swift 移植。
import Foundation

extension PPMdEncodingModel {
    private mutating func refreshI(_ c: Int, oldUnits: Int, scale originalScale: Int) {
        let n = number(c, variantI: true)
        let start = arena.shrink(stats(c), oldUnits: oldUnits, newUnits: (n &+ 1) >> 1)
        arena.setRef(c &+ 4, start)
        let scale = originalScale | bit(sum(c) >= 1 << 15)
        var escape = sum(c), total = 0, flags = 0
        for i in 0..<n {
            let s = start &+ i &* 6, f = frequency(s)
            escape &-= f
            let adjusted = (f &+ scale) >> scale
            total &+= adjusted; setFrequency(s, adjusted)
            flags |= symbol(s) &+ 0xC0
        }
        setSum(c, total &+ ((escape &+ scale) >> scale))
        arena.setByte(c &+ 1, (arena.byte(c &+ 1) & (16 + 4 &* scale)) &+ ((flags >> 5) & 8))
    }

    private mutating func singleI(_ c: Int, from state: Int) {
        let sym = symbol(state), f = (frequency(state) &+ 11) >> 3
        arena.setByte(c &+ 1, (arena.byte(c &+ 1) & 16) &+ high3(sym))
        arena.copy(c &+ 2, state, 6); setFrequency(c &+ 2, f)
    }

    private mutating func cutOffI(_ c: Int, order: Int) -> Int {
        var ns = number(c, variantI: true) &- 1
        if ns == 0 {
            let s = c &+ 2
            var next = successor(s)
            if next >= arena.unitsStart {
                next = order < maximumOrder ? cutOffI(next, order: order &+ 1) : 0
                setSuccessor(s, next)
                if next != 0 || order <= 9 { return c }
            }
            arena.specialFree(c)
            return 0
        }
        let units = (ns &+ 2) >> 1
        var start = stats(c)
        let index = arena.unitIndex(units)
        if start &- arena.unitsStart <= 1 << 14 && start <= arena.freeList[index] {
            let moved = arena.remove(index)
            arena.setRef(c &+ 4, moved); arena.copy(moved, start, units &* 12)
            if start != arena.unitsStart { arena.insert(start, index) }
            else { arena.unitsStart &+= arena.indexToUnits[index] &* 12 }
            start = moved
        }
        let oldNS = ns
        for i in stride(from: ns, through: 0, by: -1) {
            let s = start &+ i &* 6, next = successor(s)
            if next < arena.unitsStart {
                let last = start &+ ns &* 6
                ns &-= 1
                if order != 0 {
                    if s != last { arena.copy(s, last, 6) }
                } else {
                    if s != last { arena.swapStates(s, last) }
                    setSuccessor(last, 0)
                }
            } else {
                setSuccessor(s, order < maximumOrder ? cutOffI(next, order: order &+ 1) : 0)
            }
        }
        if ns != oldNS && order != 0 {
            if ns < 0 {
                arena.insert(start, arena.unitIndex(units)); arena.specialFree(c)
                return 0
            }
            setNumber(c, ns &+ 1)
            if ns == 0 {
                singleI(c, from: start)
                arena.insert(start, arena.unitIndex(units))
            } else { refreshI(c, oldUnits: units, scale: bit(sum(c) > 16 &* ns)) }
        }
        return c
    }

    private mutating func restoreI(_ errorContext: Int) {
        arena.text = arena.alignment
        var c = maxContext
        // 失敗までに追加済みの末尾 state を戻し、escape 頻度を調整する。
        while c != errorContext {
            setNumber(c, number(c, variantI: true) &- 1)
            if number(c, variantI: true) == 1 {
                let s = stats(c)
                singleI(c, from: s); arena.specialFree(s)
            } else { refreshI(c, oldUnits: (number(c, variantI: true) &+ 2) >> 1, scale: 0) }
            c = suffix(c)
        }
        while c != minContext {
            if number(c, variantI: true) == 1 { setFrequency(c &+ 2, (frequency(c &+ 2) &+ 1) >> 1) }
            else {
                setSum(c, sum(c) &+ 4)
                if sum(c) > 128 + 4 &* (number(c, variantI: true) &- 1) {
                    refreshI(c, oldUnits: (number(c, variantI: true) &+ 1) >> 1, scale: 1)
                }
            }
            c = suffix(c)
        }
        if restoration == .restart || arena.usedMemory < arena.size >> 1 {
            restart()
        } else {
            cutOffCount += 1
            while suffix(maxContext) != 0 { maxContext = suffix(maxContext) }
            repeat {
                _ = cutOffI(maxContext, order: 0)
                arena.expandTextArea()
            } while arena.usedMemory > 3 &* (arena.size >> 2)
            arena.glueCount = 0
            orderFall = maximumOrder
        }
        minContext = maxContext
    }

    @inline(never) private mutating func createSuccessorsI(skip: Bool, suffixState: Int, context: Int) -> Int {
        var c = context, s1 = suffixState, branch = successor(foundState), count = 0
        if !skip { successorStack[count] = foundState; count &+= 1 }
        while suffix(c) != 0 {
            c = suffix(c)
            let s: Int
            if s1 != 0 { s = s1; s1 = 0 }
            else if number(c, variantI: true) != 1 {
                s = find(c, symbol(foundState), variantI: true)
                if frequency(s) < 115 { setFrequency(s, frequency(s) &+ 1); setSum(c, sum(c) &+ 1) }
            } else {
                s = c &+ 2
                if number(suffix(c), variantI: true) == 1 && frequency(s) < 24 { setFrequency(s, frequency(s) &+ 1) }
            }
            let next = successor(s)
            if next != branch {
                c = next
                if count == 0 { return c }
                break
            }
            successorStack[count] = s; count &+= 1
        }
        let newSymbol = arena.byte(branch)
        branch &+= 1
        let flags = high4(symbol(foundState)) &+ high3(newSymbol)
        let newFrequency: Int
        if number(c, variantI: true) == 1 { newFrequency = frequency(c &+ 2) }
        else {
            let cf = frequency(find(c, newSymbol, variantI: true)) &- 1
            let s0 = sum(c) &- (number(c, variantI: true) &- 1) &- cf
            newFrequency = 1 &+ (2 &* cf <= s0 ? bit(5 &* cf > s0) : (cf &+ 2 &* s0 &- 3) / s0)
        }
        repeat {
            let child = arena.allocateContext()
            if child == 0 { return 0 }
            arena.setByte(child &+ 1, flags); setNumber(child, 1)
            arena.setByte(child &+ 2, newSymbol); setFrequency(child &+ 2, newFrequency)
            setSuccessor(child &+ 2, branch); arena.setRef(child &+ 8, c)
            count &-= 1
            setSuccessor(successorStack[count], child)
            c = child
        } while count != 0
        return c
    }

    private mutating func reduceOrderI(suffixState: Int, context: Int) -> Int {
        var c = context, s1 = suffixState, s = 0
        let originalContext = c, branch = arena.text
        setSuccessor(foundState, branch)
        orderFall &+= 1
        while true {
            if s1 != 0 { c = suffix(c); s = s1; s1 = 0 }
            else {
                if suffix(c) == 0 { return c }
                c = suffix(c)
                if number(c, variantI: true) != 1 {
                    s = find(c, symbol(foundState), variantI: true)
                    if frequency(s) < 115 { setFrequency(s, frequency(s) &+ 2); setSum(c, sum(c) &+ 2) }
                } else {
                    s = c &+ 2
                    if frequency(s) < 32 { setFrequency(s, frequency(s) &+ 1) }
                }
            }
            if successor(s) != 0 { break }
            setSuccessor(s, branch)
            orderFall &+= 1
        }
        if successor(s) <= branch {
            let saved = foundState
            foundState = s
            let next = createSuccessorsI(skip: false, suffixState: 0, context: c)
            setSuccessor(s, next)
            foundState = saved
        }
        let next = successor(s)
        if orderFall == 1 && originalContext == maxContext {
            setSuccessor(foundState, next)
            arena.text &-= 1
        }
        return next
    }

    @inline(never) mutating func updateModelI() {
        var minSuccessor = successor(foundState)
        let fFrequency = frequency(foundState), fSymbol = symbol(foundState)
        var s = 0
        if fFrequency < 31 && suffix(minContext) != 0 {
            let c = suffix(minContext)
            if number(c, variantI: true) == 1 {
                s = c &+ 2
                if frequency(s) < 32 { setFrequency(s, frequency(s) &+ 1) }
            } else {
                s = find(c, fSymbol, variantI: true)
                if s != stats(c) && frequency(s) >= frequency(s &- 6) {
                    arena.swapStates(s, s &- 6); s &-= 6
                }
                if frequency(s) < 115 { setFrequency(s, frequency(s) &+ 2); setSum(c, sum(c) &+ 2) }
            }
        }
        var c = maxContext
        if orderFall == 0 && minSuccessor != 0 {
            let child = createSuccessorsI(skip: true, suffixState: s, context: minContext)
            if child == 0 { setSuccessor(foundState, 0); restoreI(c); return }
            setSuccessor(foundState, child); minContext = child; maxContext = child
            return
        }
        arena.setByte(arena.text, fSymbol); arena.text &+= 1
        if arena.text >= arena.unitsStart { restoreI(c); return }
        var maxSuccessor = arena.text
        if minSuccessor == 0 {
            minSuccessor = reduceOrderI(suffixState: s, context: minContext)
            if minSuccessor == 0 { restoreI(c); return }
        } else if minSuccessor < arena.unitsStart {
            minSuccessor = createSuccessorsI(skip: false, suffixState: s, context: minContext)
            if minSuccessor == 0 { restoreI(c); return }
        }
        orderFall &-= 1
        if orderFall == 0 {
            maxSuccessor = minSuccessor
            arena.text &-= bit(maxContext != minContext)
        }
        let flag = high3(fSymbol), ns = number(minContext, variantI: true) &- 1
        let s0 = sum(minContext) &- ns &- fFrequency
        while c != minContext {
            let ns1 = number(c, variantI: true) &- 1
            var total: Int
            if ns1 != 0 {
                if ns1 & 1 != 0 {
                    let oldUnits = (ns1 &+ 1) >> 1, index = arena.unitIndex((ns1 &+ 1) >> 1)
                    if index != arena.unitIndex(oldUnits &+ 1) {
                        let ptr = arena.allocate(index &+ 1)
                        if ptr == 0 { restoreI(c); return }
                        let old = stats(c)
                        arena.copy(ptr, old, oldUnits &* 12); arena.insert(old, index)
                        arena.setRef(c &+ 4, ptr)
                    }
                }
                total = sum(c) &+ bit(3 &* ns1 &+ 1 < ns)
            } else {
                let state = arena.allocate(0)
                if state == 0 { restoreI(c); return }
                let f = frequency(c &+ 2)
                arena.copy(state, c &+ 2, 6); arena.setRef(c &+ 4, state)
                let adjusted = f < 30 ? f &* 2 : 120
                setFrequency(state, adjusted)
                total = adjusted &+ initialEscape &+ bit(ns > 2)
            }
            let state = stats(c) &+ (ns1 &+ 1) &* 6
            var cf = 2 &* (total &+ 6) &* fFrequency
            let sf = s0 &+ total
            arena.setByte(state, fSymbol); setNumber(c, ns1 &+ 2); setSuccessor(state, maxSuccessor)
            arena.setByte(c &+ 1, arena.byte(c &+ 1) | flag)
            if cf < 6 &* sf {
                cf = 1 &+ bit(cf > sf) &+ bit(cf >= 4 &* sf)
                total &+= 4
            } else {
                cf = 4 &+ bit(cf > 9 &* sf) &+ bit(cf > 12 &* sf) &+ bit(cf > 15 &* sf)
                total &+= cf
            }
            setSum(c, total); setFrequency(state, cf)
            c = suffix(c)
        }
        minContext = minSuccessor; maxContext = minSuccessor
    }
}
