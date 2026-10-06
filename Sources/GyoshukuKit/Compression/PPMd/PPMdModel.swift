// 出自: LZMA SDK 26.03 C/Ppmd.h、C/Ppmd7.c、C/Ppmd7Enc.c と
// 7-Zip 26.03 の公開ドメイン C/Ppmd8.c、C/Ppmd8Enc.c（Igor Pavlov、原作 Dmitry Shkarin）。純 Swift 移植。
import Foundation

struct PPMdSEE {
    var sum: UInt16 = 0
    var shift: Int = 7
    var count: Int = 64

    mutating func escape() -> Int {
        let result = Int(sum) >> shift
        sum &-= UInt16(result)
        return max(result, 1)
    }

    mutating func update() {
        if shift < 7 {
            count -= 1
            if count == 0 {
                sum &*= 2
                count = 3 << shift
                shift += 1
            }
        }
    }
}

/// H / I で共有する記号選択と頻度更新。successor の作成と復元は各 variant の extension に置く。
final class PPMdEncodingModel {
    static let initialBinaryEscapes = [0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051]
    static let exponentialEscape = [25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2]
    let arena: PPMdArena
    let variantI: Bool
    let maximumOrder: Int
    let restoration: PPMdRestorationMethod
    let binary: UnsafeMutablePointer<UInt16>
    let see: UnsafeMutablePointer<PPMdSEE>
    let mask: UnsafeMutablePointer<UInt8>
    let successorStack: UnsafeMutablePointer<Int>
    var nsToBinary = [Int](repeating: 6, count: 256)
    var nsToIndex = [Int](repeating: 0, count: 260)
    var minContext = 0
    var maxContext = 0
    var foundState = 0
    var orderFall = 0
    var initialEscape = 0
    var previousSuccess = 0
    var highBitsFlag = 0
    var runLength: Int32 = 0
    var initialRunLength: Int32 = 0
    /// 内部の検証用。初期化は数えず、メモリ不足による復元だけを数える。
    private(set) var restartCount = 0
    var cutOffCount = 0

    init(order: Int, memorySize: Int, variantI: Bool, restoration: PPMdRestorationMethod = .restart) throws {
        self.variantI = variantI
        self.maximumOrder = order
        self.restoration = restoration
        arena = try PPMdArena(size: memorySize, variantI: variantI)
        binary = .allocate(capacity: 128 * 64)
        binary.initialize(repeating: 0, count: 128 * 64)
        see = .allocate(capacity: 24 * 32 + 1)
        see.initialize(repeating: PPMdSEE(), count: 24 * 32 + 1)
        mask = .allocate(capacity: 256)
        mask.initialize(repeating: 1, count: 256)
        successorStack = .allocate(capacity: 33)
        nsToBinary[0] = 0; nsToBinary[1] = 2
        for i in 2..<11 { nsToBinary[i] = 4 }
        let first = variantI ? 5 : 3
        for i in 0..<first { nsToIndex[i] = i }
        var m = first, k = 1
        for i in first..<260 {
            nsToIndex[i] = m
            k -= 1
            if k == 0 { m += 1; k = m - (variantI ? 4 : 2) }
        }
        restart(initial: true)
    }

    deinit {
        binary.deinitialize(count: 128 * 64); binary.deallocate()
        see.deinitialize(count: 24 * 32 + 1); see.deallocate()
        mask.deinitialize(count: 256); mask.deallocate()
        successorStack.deallocate()
    }

    // context の state 数は計算時には両 variant とも実数に揃える。
    @inline(__always) func number(_ c: Int) -> Int { variantI ? arena.byte(c) + 1 : arena.word(c) }
    @inline(__always) func setNumber(_ c: Int, _ n: Int) {
        if variantI { arena.setByte(c, n - 1) } else { arena.setWord(c, n) }
    }
    @inline(__always) func sum(_ c: Int) -> Int { arena.word(c + 2) }
    @inline(__always) func setSum(_ c: Int, _ value: Int) { arena.setWord(c + 2, value) }
    @inline(__always) func stats(_ c: Int) -> Int { arena.ref(c + 4) }
    @inline(__always) func suffix(_ c: Int) -> Int { arena.ref(c + 8) }
    @inline(__always) func symbol(_ s: Int) -> Int { arena.byte(s) }
    @inline(__always) func frequency(_ s: Int) -> Int { arena.byte(s + 1) }
    @inline(__always) func successor(_ s: Int) -> Int { arena.ref(s + 2) }
    @inline(__always) func setFrequency(_ s: Int, _ value: Int) { arena.setByte(s + 1, value) }
    @inline(__always) func setSuccessor(_ s: Int, _ value: Int) { arena.setRef(s + 2, value) }
    @inline(__always) func high3(_ symbol: Int) -> Int { symbol >= 0x40 ? 8 : 0 }
    @inline(__always) func high4(_ symbol: Int) -> Int { symbol >= 0x40 ? 16 : 0 }
    @inline(__always) func bit(_ condition: Bool) -> Int { condition ? 1 : 0 }
    @inline(__always) func find(_ c: Int, _ symbol: Int) -> Int {
        if number(c) == 1 { return c + 2 }
        var s = stats(c)
        while self.symbol(s) != symbol { s += 6 }
        return s
    }

    func restart(initial: Bool = false) {
        if !initial { restartCount += 1 }
        arena.reset()
        orderFall = maximumOrder
        initialRunLength = -Int32(min(maximumOrder, 12)) - 1
        runLength = initialRunLength
        previousSuccess = 0
        arena.highUnit -= 12
        maxContext = arena.highUnit; minContext = maxContext
        let s = arena.lowUnit
        arena.lowUnit += 128 * 12
        foundState = s
        setNumber(minContext, 256)
        if variantI { arena.setByte(minContext + 1, 0) }
        setSum(minContext, 257)
        arena.setRef(minContext + 4, s); arena.setRef(minContext + 8, 0)
        for i in 0..<256 {
            arena.setByte(s + 6 * i, i); setFrequency(s + 6 * i, 1); setSuccessor(s + 6 * i, 0)
        }
        if variantI {
            var i = 0
            for m in 0..<25 {
                while nsToIndex[i] == m { i += 1 }
                initializeBinary(row: m, divisor: i + 1)
            }
            i = 0
            for m in 0..<24 {
                while nsToIndex[i + 3] == m + 3 { i += 1 }
                for k in 0..<32 {
                    see[m * 32 + k] = PPMdSEE(sum: UInt16((2 * i + 5) << 3), shift: 3, count: 7)
                }
            }
        } else {
            for i in 0..<128 { initializeBinary(row: i, divisor: i + 2) }
            for i in 0..<25 {
                for k in 0..<16 { see[i * 16 + k] = PPMdSEE(sum: UInt16((5 * i + 10) << 3), shift: 3, count: 4) }
            }
        }
        see[768] = PPMdSEE()
    }

    private func initializeBinary(row: Int, divisor: Int) {
        for k in 0..<8 {
            let value = UInt16(16_384 - Self.initialBinaryEscapes[k] / divisor)
            for m in stride(from: 0, to: 64, by: 8) { binary[row * 64 + m + k] = value }
        }
    }

    private func binaryIndex() -> Int {
        let state = minContext + 2
        let row = variantI ? nsToIndex[frequency(state) - 1] : frequency(state) - 1
        let suffixCount = number(suffix(minContext)) - 1
        var column = previousSuccess + Int((runLength >> 26) & 0x20) + nsToBinary[suffixCount]
        if variantI { column += arena.byte(minContext + 1) }
        else {
            highBitsFlag = high3(symbol(foundState))
            column += high4(symbol(state)) + highBitsFlag
        }
        return row * 64 + column
    }

    private func escapeFrequency(masked: Int) -> (index: Int, frequency: Int) {
        let n = number(minContext)
        if n == 256 { return (768, 1) }
        let index: Int
        if variantI {
            index = (nsToIndex[n + 1] - 3) * 32
                + bit(sum(minContext) > 11 * n)
                + 2 * bit(2 * (n - 1) < number(suffix(minContext)) + masked - 2)
                + arena.byte(minContext + 1)
        } else {
            let nonMasked = n - masked
            index = nsToIndex[nonMasked - 1] * 16 + highBitsFlag
                + bit(nonMasked < number(suffix(minContext)) - n)
                + 2 * bit(sum(minContext) < 11 * n) + 4 * bit(masked > nonMasked)
        }
        return (index, see[index].escape())
    }

    /// -1 は ZIP の EOF escape。7z の stream は展開サイズが既知なので EOF を符号化しない。
    func encode(_ value: Int, using coder: PPMdRangeEncoder, emit: (Data) throws -> Void) throws {
        let n = number(minContext)
        if n != 1 {
            let total = variantI ? min(sum(minContext), Int(coder.range)) : sum(minContext)
            let start = stats(minContext)
            var accumulated = 0
            for i in 0..<n {
                let s = start + 6 * i, f = frequency(s)
                if symbol(s) == value {
                    try coder.encode(start: accumulated, size: f, total: total, emit: emit)
                    foundState = s
                    update1(first: i == 0)
                    return
                }
                accumulated += f
            }
            previousSuccess = 0
            try coder.encode(start: accumulated, size: total - accumulated, total: total, normalize: false, emit: emit)
            if !variantI { highBitsFlag = high3(symbol(foundState)) }
            mask.update(repeating: 1, count: 256)
            for i in 0..<n { mask[symbol(start + 6 * i)] = 0 }
        } else {
            let index = binaryIndex(), state = minContext + 2
            let probability = Int(binary[index])
            let reduced = probability - ((probability + 32) >> 7)
            if symbol(state) == value {
                binary[index] = UInt16(reduced + 128)
                try coder.binary(probability: probability, success: true, emit: emit)
                foundState = state
                previousSuccess = 1
                runLength &+= 1
                let f = frequency(state)
                setFrequency(state, f + bit(f < (variantI ? 196 : 128)))
                nextContext()
                return
            }
            binary[index] = UInt16(reduced)
            initialEscape = Self.exponentialEscape[reduced >> 10]
            try coder.binary(probability: probability, success: false, emit: emit)
            mask.update(repeating: 1, count: 256)
            mask[symbol(state)] = 0
            previousSuccess = 0
        }
        while true {
            try coder.normalize(emit: emit)
            let masked = number(minContext)
            repeat {
                orderFall += 1
                if suffix(minContext) == 0 { return }
                minContext = suffix(minContext)
            } while number(minContext) == masked
            let escape = escapeFrequency(masked: masked)
            let start = stats(minContext), n = number(minContext)
            var total = escape.frequency, low = 0, selected = 0
            for i in 0..<n {
                let s = start + 6 * i
                if symbol(s) == value { selected = s; low = total - escape.frequency }
                if mask[symbol(s)] != 0 { total += frequency(s) }
            }
            if selected != 0 {
                see[escape.index].update()
                if variantI { total = min(total, Int(coder.range)) }
                try coder.encode(start: low, size: frequency(selected), total: total, emit: emit)
                foundState = selected
                update2()
                return
            }
            var unmasked = 0
            for i in 0..<n {
                let s = start + 6 * i
                if mask[symbol(s)] != 0 { unmasked += frequency(s) }
                mask[symbol(s)] = 0
            }
            see[escape.index].sum &+= UInt16(total)
            if variantI { total = min(total, Int(coder.range)) }
            try coder.encode(start: unmasked, size: total - unmasked, total: total, normalize: false, emit: emit)
        }
    }

    private func nextContext() {
        let c = successor(foundState)
        if orderFall == 0 && (variantI ? c >= arena.unitsStart : c > arena.text) {
            minContext = c; maxContext = c
        } else { updateModel() }
    }

    private func updateModel() {
        if variantI { updateModelI() } else { updateModelH() }
    }

    private func update1(first: Bool) {
        let s = foundState, f = frequency(s)
        let total = sum(minContext)
        if first {
            previousSuccess = bit(variantI ? 2 * f >= total : 2 * f > total)
            runLength &+= Int32(previousSuccess)
        } else { previousSuccess = 0 }
        setSum(minContext, total + 4); setFrequency(s, f + 4)
        if first {
            if f + 4 > 124 { rescale() }
        } else if f + 4 > frequency(s - 6) {
            arena.swapStates(s, s - 6)
            foundState -= 6
            if f + 4 > 124 { rescale() }
        }
        nextContext()
    }

    private func update2() {
        let f = frequency(foundState) + 4
        runLength = initialRunLength
        setSum(minContext, sum(minContext) + 4); setFrequency(foundState, f)
        if f > 124 { rescale() }
        updateModel()
    }

    private func rescale() {
        let base = stats(minContext), n = number(minContext)
        var s = foundState
        // 選択した state を先頭へ移し、半減した頻度で安定な降順に並べる。
        while s != base { arena.swapStates(s, s - 6); s -= 6 }
        let adder = bit(orderFall != 0)
        var total = frequency(s), escape = sum(minContext) - total
        total = (total + 4 + adder) >> 1
        setFrequency(s, total)
        for i in 1..<n {
            s = base + 6 * i
            let old = frequency(s), f = (old + adder) >> 1
            escape -= old; total += f; setFrequency(s, f)
            var sorted = s
            while sorted != base && f > frequency(sorted - 6) {
                arena.swapStates(sorted, sorted - 6); sorted -= 6
            }
        }
        if frequency(s) == 0 {
            var remaining = n
            while frequency(base + (remaining - 1) * 6) == 0 { remaining -= 1 }
            escape += n - remaining
            setNumber(minContext, remaining)
            let oldUnits = (n + 1) >> 1
            if remaining == 1 {
                var f = frequency(base)
                if variantI {
                    f = min(124 / 3, (2 * f + escape - 1) / escape)
                    arena.setByte(minContext + 1, (arena.byte(minContext + 1) & 16) + high3(symbol(base)))
                } else {
                    repeat { escape >>= 1; f = (f + 1) >> 1 } while escape > 1
                }
                arena.copy(minContext + 2, base, 6)
                setFrequency(minContext + 2, f); foundState = minContext + 2
                arena.insert(base, arena.unitIndex(oldUnits))
                return
            }
            let newUnits = (remaining + 1) >> 1
            if oldUnits != newUnits {
                let shrunk = arena.shrink(base, oldUnits: oldUnits, newUnits: newUnits)
                arena.setRef(minContext + 4, shrunk)
            }
        }
        setSum(minContext, total + escape - (escape >> 1))
        if variantI { arena.setByte(minContext + 1, arena.byte(minContext + 1) | 4) }
        foundState = stats(minContext)
    }
}
