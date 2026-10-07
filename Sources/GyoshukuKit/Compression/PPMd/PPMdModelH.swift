// 出自: LZMA SDK 26.03 C/Ppmd7.c、C/Ppmd7.h（Igor Pavlov、原作 Dmitry Shkarin、公開ドメイン）。
// var.H の successor 作成とメモリ不足時の restart の純 Swift 移植。
import Foundation

extension PPMdEncodingModel {
    @inline(never) mutating func createSuccessorsH(suffixState: Int) -> Int {
        var c = minContext, branch = successor(foundState), count = 0
        var cachedState = suffixState
        let fSymbol = symbol(foundState)
        if orderFall != 0 { successorStack[count] = foundState; count &+= 1 }
        while suffix(c) != 0 {
            c = suffix(c)
            // UpdateModel が選択済みの直近 suffix は再探索しない。
            let s = cachedState != 0 ? cachedState : find(c, fSymbol, variantI: false)
            cachedState = 0
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
        let newFrequency: Int
        if number(c, variantI: false) == 1 { newFrequency = frequency(c &+ 2) }
        else {
            let cf = frequency(find(c, newSymbol, variantI: false)) &- 1
            let s0 = sum(c) &- number(c, variantI: false) &- cf
            newFrequency = 1 &+ (2 &* cf <= s0 ? bit(5 &* cf > s0) : (2 &* cf &+ s0 &- 1) / (2 &* s0) &+ 1)
        }
        repeat {
            let child = arena.allocateContext()
            if child == 0 { return 0 }
            setNumber(child, 1)
            arena.setByte(child &+ 2, newSymbol); setFrequency(child &+ 2, newFrequency)
            setSuccessor(child &+ 2, branch); arena.setRef(child &+ 8, c)
            count &-= 1
            setSuccessor(successorStack[count], child)
            c = child
        } while count != 0
        return c
    }

    @inline(never) mutating func updateModelH() {
        var suffixState = 0
        let fSymbol = symbol(foundState), fFrequency = frequency(foundState)
        if fFrequency < 31 && suffix(minContext) != 0 {
            let c = suffix(minContext)
            if number(c, variantI: false) == 1 {
                let s = c &+ 2
                suffixState = s
                if frequency(s) < 32 { setFrequency(s, frequency(s) &+ 1) }
            } else {
                var s = find(c, fSymbol, variantI: false)
                if s != stats(c) && frequency(s) >= frequency(s &- 6) {
                    arena.swapStates(s, s &- 6); s &-= 6
                }
                suffixState = s
                if frequency(s) < 115 { setFrequency(s, frequency(s) &+ 2); setSum(c, sum(c) &+ 2) }
            }
        }
        if orderFall == 0 {
            let child = createSuccessorsH(suffixState: suffixState)
            if child == 0 { restart(); return }
            minContext = child; maxContext = child
            setSuccessor(foundState, child)
            return
        }
        arena.setByte(arena.text, fSymbol); arena.text &+= 1
        if arena.text >= arena.unitsStart { restart(); return }
        var maxSuccessor = arena.text, minSuccessor = successor(foundState)
        if minSuccessor != 0 {
            if minSuccessor <= maxSuccessor {
                minSuccessor = createSuccessorsH(suffixState: suffixState)
                if minSuccessor == 0 { restart(); return }
            }
            orderFall &-= 1
            if orderFall == 0 {
                maxSuccessor = minSuccessor
                arena.text &-= bit(maxContext != minContext)
            }
        } else {
            setSuccessor(foundState, maxSuccessor)
            minSuccessor = minContext
        }
        let mc = minContext
        var c = maxContext
        minContext = minSuccessor; maxContext = minSuccessor
        if c == mc { return }
        let ns = number(mc), s0 = sum(mc) &- ns &- (fFrequency &- 1)
        repeat {
            let ns1 = number(c, variantI: false)
            var total: Int
            if ns1 != 1 {
                if ns1 & 1 == 0 {
                    let oldUnits = ns1 >> 1, index = arena.unitIndex(ns1 >> 1)
                    if index != arena.unitIndex(oldUnits &+ 1) {
                        let ptr = arena.allocate(index &+ 1)
                        if ptr == 0 { restart(); return }
                        let old = stats(c)
                        arena.copy(ptr, old, oldUnits &* 12); arena.insert(old, index)
                        arena.setRef(c &+ 4, ptr)
                    }
                }
                total = sum(c)
                total &+= bit(2 &* ns1 < ns) &+ 2 &* bit(4 &* ns1 <= ns && total <= 8 &* ns1)
            } else {
                let s = arena.allocate(0)
                if s == 0 { restart(); return }
                let f = frequency(c &+ 2)
                arena.copy(s, c &+ 2, 6); arena.setRef(c &+ 4, s)
                let adjusted = f < 30 ? f &* 2 : 120
                setFrequency(s, adjusted)
                total = adjusted &+ initialEscape &+ bit(ns > 3)
            }
            let s = stats(c) &+ ns1 &* 6
            var cf = 2 &* (total &+ 6) &* fFrequency
            let sf = s0 &+ total
            arena.setByte(s, fSymbol); setNumber(c, ns1 &+ 1); setSuccessor(s, maxSuccessor)
            if cf < 6 &* sf {
                cf = 1 &+ bit(cf > sf) &+ bit(cf >= 4 &* sf)
                total &+= 3
            } else {
                cf = 4 &+ bit(cf >= 9 &* sf) &+ bit(cf >= 12 &* sf) &+ bit(cf >= 15 &* sf)
                total &+= cf
            }
            setSum(c, total); setFrequency(s, cf)
            c = suffix(c)
        } while c != mc
    }
}
