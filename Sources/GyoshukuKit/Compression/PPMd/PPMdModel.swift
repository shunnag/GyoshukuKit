// 出自: LZMA SDK 26.03 C/Ppmd.h、C/Ppmd7.c、C/Ppmd7Enc.c と
// 7-Zip 26.03 の公開ドメイン C/Ppmd8.c、C/Ppmd8Enc.c（Igor Pavlov、原作 Dmitry Shkarin）。純 Swift 移植。
import Foundation

struct PPMdSEE {
    var sum: UInt16 = 0
    var shift: UInt8 = 7
    var count: UInt8 = 64

    @inline(__always) mutating func escape() -> Int {
        let result = Int(sum) >> shift
        sum &-= UInt16(truncatingIfNeeded: result)
        return max(result, 1)
    }

    @inline(__always) mutating func update() {
        if shift < 7 {
            count &-= 1
            if count == 0 {
                sum &*= 2
                count = 3 << shift
                shift &+= 1
            }
        }
    }
}

/// H / I で共有する記号選択と頻度更新。successor の作成と復元は各 variant の extension に置く。
struct PPMdEncodingModel: ~Copyable {
    static let initialBinaryEscapes = [0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051]
    var arena: PPMdArena
    let variantI: Bool
    let maximumOrder: Int
    let restoration: PPMdRestorationMethod
    let binary: UnsafeMutablePointer<UInt16>
    let see: UnsafeMutablePointer<PPMdSEE>
    let mask: UnsafeMutablePointer<UInt8>
    let successorStack: UnsafeMutablePointer<Int>
    let nsToBinary: UnsafeMutablePointer<UInt8>
    let nsToIndex: UnsafeMutablePointer<UInt8>
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
        nsToBinary = .allocate(capacity: 256)
        nsToIndex = .allocate(capacity: 260)
        nsToBinary.initialize(repeating: 6, count: 256)
        nsToIndex.initialize(repeating: 0, count: 260)
        nsToBinary[0] = 0; nsToBinary[1] = 2
        for i in 2..<11 { nsToBinary[i] = 4 }
        let first = variantI ? 5 : 3
        for i in 0..<first { nsToIndex[i] = UInt8(i) }
        var m = first, k = 1
        for i in first..<260 {
            nsToIndex[i] = UInt8(m)
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
        nsToBinary.deallocate(); nsToIndex.deallocate()
    }

    // offset は最大 1 GiB 内、頻度は 16 bit、中間の積も 2^25 未満。Int の wrapping 算術で溢れない。
    // context の state 数は計算時には両 variant とも実数に揃える。
    // symbol / freq だけは byte 配置を LE word にまとめて読む。
    @inline(__always) func stateWord(_ s: Int) -> Int {
        Int(UInt16(littleEndian: arena.base.loadUnaligned(fromByteOffset: s, as: UInt16.self)))
    }
    // 14 bit probability の上位 4 bit。SDK の固定 16 byte 表を二つの整数に詰める。
    @inline(__always) private static func exponentialEscape(_ index: Int) -> Int {
        let table: UInt64 = index < 8 ? 0x0404_0505_0709_0E19 : 0x0202_0202_0303_0304
        return Int((table >> ((index & 7) &* 8)) & 255)
    }
    @inline(__always) func number(_ c: Int) -> Int { number(c, variantI: variantI) }
    @inline(__always) func number(_ c: Int, variantI: Bool) -> Int {
        variantI ? arena.byte(c) &+ 1 : arena.word(c)
    }
    @inline(__always) func setNumber(_ c: Int, _ n: Int) {
        if variantI { arena.setByte(c, n &- 1) } else { arena.setWord(c, n) }
    }
    @inline(__always) func sum(_ c: Int) -> Int { arena.word(c &+ 2) }
    @inline(__always) func setSum(_ c: Int, _ value: Int) { arena.setWord(c &+ 2, value) }
    @inline(__always) func stats(_ c: Int) -> Int { arena.ref(c &+ 4) }
    @inline(__always) func suffix(_ c: Int) -> Int { arena.ref(c &+ 8) }
    @inline(__always) func symbol(_ s: Int) -> Int { arena.byte(s) }
    @inline(__always) func frequency(_ s: Int) -> Int { arena.byte(s &+ 1) }
    @inline(__always) func successor(_ s: Int) -> Int { arena.ref(s &+ 2) }
    @inline(__always) func setFrequency(_ s: Int, _ value: Int) { arena.setByte(s &+ 1, value) }
    @inline(__always) func setSuccessor(_ s: Int, _ value: Int) { arena.setRef(s &+ 2, value) }
    @inline(__always) func high3(_ symbol: Int) -> Int { symbol >= 0x40 ? 8 : 0 }
    @inline(__always) func high4(_ symbol: Int) -> Int { symbol >= 0x40 ? 16 : 0 }
    @inline(__always) func bit(_ condition: Bool) -> Int { condition ? 1 : 0 }
    @inline(__always) func find(_ c: Int, _ symbol: Int, variantI: Bool) -> Int {
        if number(c, variantI: variantI) == 1 { return c &+ 2 }
        var s = stats(c)
        while self.symbol(s) != symbol { s &+= 6 }
        return s
    }

    mutating func restart(initial: Bool = false) {
        if !initial { restartCount += 1 }
        arena.reset()
        orderFall = maximumOrder
        initialRunLength = -Int32(min(maximumOrder, 12)) &- 1
        runLength = initialRunLength
        previousSuccess = 0
        arena.highUnit &-= 12
        maxContext = arena.highUnit; minContext = maxContext
        let s = arena.lowUnit
        arena.lowUnit &+= 128 * 12
        foundState = s
        setNumber(minContext, 256)
        if variantI { arena.setByte(minContext &+ 1, 0) }
        setSum(minContext, 257)
        arena.setRef(minContext &+ 4, s); arena.setRef(minContext &+ 8, 0)
        for i in 0..<256 {
            arena.setByte(s &+ 6 &* i, i); setFrequency(s &+ 6 &* i, 1); setSuccessor(s &+ 6 &* i, 0)
        }
        if variantI {
            var i = 0
            for m in 0..<25 {
                while Int(nsToIndex[i]) == m { i &+= 1 }
                initializeBinary(row: m, divisor: i &+ 1)
            }
            i = 0
            for m in 0..<24 {
                while Int(nsToIndex[i &+ 3]) == m &+ 3 { i &+= 1 }
                for k in 0..<32 {
                    see[m &* 32 &+ k] = PPMdSEE(sum: UInt16((2 &* i &+ 5) << 3), shift: 3, count: 7)
                }
            }
        } else {
            for i in 0..<128 { initializeBinary(row: i, divisor: i &+ 2) }
            for i in 0..<25 {
                for k in 0..<16 { see[i &* 16 &+ k] = PPMdSEE(sum: UInt16((5 &* i &+ 10) << 3), shift: 3, count: 4) }
            }
        }
        see[768] = PPMdSEE()
    }

    private func initializeBinary(row: Int, divisor: Int) {
        for k in 0..<8 {
            let value = UInt16(16_384 &- Self.initialBinaryEscapes[k] / divisor)
            for m in stride(from: 0, to: 64, by: 8) { binary[row &* 64 &+ m &+ k] = value }
        }
    }

    @inline(__always) private mutating func binaryIndex(packedState: Int, variantI: Bool) -> Int {
        let f = packedState >> 8
        let row = variantI ? Int(nsToIndex[f &- 1]) : f &- 1
        let suffixCount = number(suffix(minContext), variantI: variantI) &- 1
        var column = previousSuccess &+ Int((runLength >> 26) & 0x20) &+ Int(nsToBinary[suffixCount])
        if variantI { column &+= arena.byte(minContext &+ 1) }
        else {
            highBitsFlag = high3(symbol(foundState))
            column &+= high4(packedState & 255) &+ highBitsFlag
        }
        return row &* 64 &+ column
    }

    @inline(__always) private mutating func escapeFrequency(masked: Int, variantI: Bool) -> (index: Int, frequency: Int) {
        let n = number(minContext, variantI: variantI)
        if n == 256 { return (768, 1) }
        let index: Int
        if variantI {
            index = (Int(nsToIndex[n &+ 1]) &- 3) &* 32
                &+ bit(sum(minContext) > 11 &* n)
                &+ 2 &* bit(2 &* (n &- 1) < number(suffix(minContext), variantI: variantI) &+ masked &- 2)
                &+ arena.byte(minContext &+ 1)
        } else {
            let nonMasked = n &- masked
            index = Int(nsToIndex[nonMasked &- 1]) &* 16 &+ highBitsFlag
                &+ bit(nonMasked < number(suffix(minContext), variantI: variantI) &- n)
                &+ 2 &* bit(sum(minContext) < 11 &* n) &+ 4 &* bit(masked > nonMasked)
        }
        return (index, see[index].escape())
    }

    /// -1 は ZIP の EOF escape。7z の stream は展開サイズが既知なので EOF を符号化しない。
    @inline(__always) mutating func encode(_ value: Int, variantI: Bool, using coder: inout PPMdRangeEncoder, emit: (Data) throws -> Void) throws {
        let n = number(minContext, variantI: variantI)
        if n != 1 {
            let total = variantI ? min(sum(minContext), Int(coder.range)) : sum(minContext)
            let start = stats(minContext), end = start &+ 6 &* n
            var s = start
            let firstState = stateWord(s)
            var accumulated = firstState >> 8
            // SDK の first-state fast path は探索 loop の外で処理する。
            if firstState & 255 == value {
                try coder.encode(start: 0, size: accumulated, total: total, variantI: variantI, emit: emit)
                foundState = s
                update1(first: true, variantI: variantI)
                return
            }
            previousSuccess = 0
            s &+= 6
            repeat {
                let state = stateWord(s), f = state >> 8
                if state & 255 == value {
                    try coder.encode(start: accumulated, size: f, total: total, variantI: variantI, emit: emit)
                    foundState = s
                    update1(first: false, variantI: variantI)
                    return
                }
                accumulated &+= f
                s &+= 6
            } while s != end
            try coder.encode(start: accumulated, size: total &- accumulated, total: total, normalize: false, variantI: variantI, emit: emit)
            if !variantI { highBitsFlag = high3(symbol(foundState)) }
            mask.update(repeating: 255, count: 256)
            clearMask(start: start, count: n)
        } else {
            let state = minContext &+ 2, packedState = stateWord(state)
            let index = binaryIndex(packedState: packedState, variantI: variantI)
            let probability = Int(binary[index])
            let reduced = probability &- ((probability &+ 32) >> 7)
            if packedState & 255 == value {
                binary[index] = UInt16(truncatingIfNeeded: reduced &+ 128)
                try coder.binary(probability: probability, success: true, variantI: variantI, emit: emit)
                foundState = state
                previousSuccess = 1
                runLength &+= 1
                let f = packedState >> 8
                setFrequency(state, f &+ bit(f < (variantI ? 196 : 128)))
                nextContext(variantI: variantI)
                return
            }
            binary[index] = UInt16(truncatingIfNeeded: reduced)
            initialEscape = Self.exponentialEscape(reduced >> 10)
            try coder.binary(probability: probability, success: false, variantI: variantI, emit: emit)
            mask.update(repeating: 255, count: 256)
            mask[packedState & 255] = 0
            previousSuccess = 0
        }
        while true {
            try coder.normalize(variantI: variantI, emit: emit)
            let masked = number(minContext, variantI: variantI)
            repeat {
                orderFall &+= 1
                if suffix(minContext) == 0 { return }
                minContext = suffix(minContext)
            } while number(minContext, variantI: variantI) == masked
            let escape = escapeFrequency(masked: masked, variantI: variantI)
            let start = stats(minContext), end = start &+ 6 &* number(minContext, variantI: variantI)
            var s = start, accumulated = 0
            // suffix で一致するまで累積し、その残りは SDK 同様に 2 state ずつ合計する。
            repeat {
                let state = stateWord(s), sym = state & 255, f = state >> 8
                if sym == value {
                    let low = accumulated, selectedState = s
                    var total = accumulated &+ escape.frequency
                    if ((end &- s) / 6) & 1 != 0 { total &+= f; s &+= 6 }
                    while s != end {
                        total &+= frequency(s) & Int(mask[symbol(s)])
                        total &+= frequency(s &+ 6) & Int(mask[symbol(s &+ 6)])
                        s &+= 12
                    }
                    see[escape.index].update()
                    if variantI { total = min(total, Int(coder.range)) }
                    try coder.encode(start: low, size: f, total: total, variantI: variantI, emit: emit)
                    foundState = selectedState
                    update2(variantI: variantI)
                    return
                }
                accumulated &+= f & Int(mask[sym])
                s &+= 6
            } while s != end
            var total = accumulated &+ escape.frequency
            see[escape.index].sum &+= UInt16(truncatingIfNeeded: total)
            if variantI { total = min(total, Int(coder.range)) }
            try coder.encode(start: accumulated, size: total &- accumulated, total: total, normalize: false, variantI: variantI, emit: emit)
            clearMask(start: start, count: number(minContext, variantI: variantI))
        }
    }

    @inline(__always) private func clearMask(start: Int, count: Int) {
        let end = start &+ count &* 6
        var s = start
        if count & 1 != 0 { mask[symbol(s)] = 0; s &+= 6 }
        while s != end {
            mask[symbol(s)] = 0; mask[symbol(s &+ 6)] = 0
            s &+= 12
        }
    }

    @inline(__always) private mutating func nextContext(variantI: Bool) {
        let c = successor(foundState)
        if orderFall == 0 && (variantI ? c >= arena.unitsStart : c > arena.text) {
            minContext = c; maxContext = c
        } else { updateModel(variantI: variantI) }
    }

    @inline(__always) private mutating func updateModel(variantI: Bool) {
        if variantI { updateModelI() } else { updateModelH() }
    }

    @inline(__always) private mutating func update1(first: Bool, variantI: Bool) {
        let s = foundState, f = frequency(s)
        let total = sum(minContext)
        if first {
            previousSuccess = bit(variantI ? 2 &* f >= total : 2 &* f > total)
            runLength &+= Int32(previousSuccess)
        } else { previousSuccess = 0 }
        setSum(minContext, total &+ 4); setFrequency(s, f &+ 4)
        if first {
            if f &+ 4 > 124 { rescale() }
        } else if f &+ 4 > frequency(s &- 6) {
            arena.swapStates(s, s &- 6)
            foundState &-= 6
            if f &+ 4 > 124 { rescale() }
        }
        nextContext(variantI: variantI)
    }

    @inline(__always) private mutating func update2(variantI: Bool) {
        let f = frequency(foundState) &+ 4
        runLength = initialRunLength
        setSum(minContext, sum(minContext) &+ 4); setFrequency(foundState, f)
        if f > 124 { rescale() }
        updateModel(variantI: variantI)
    }

    @inline(never) private mutating func rescale() {
        let base = stats(minContext), n = number(minContext)
        var s = foundState
        // 選択した state を先頭へ移し、半減した頻度で安定な降順に並べる。
        if s != base {
            let sym = symbol(s), f = frequency(s), next = successor(s)
            repeat { arena.copy(s, s &- 6, 6); s &-= 6 } while s != base
            arena.setByte(s, sym); setFrequency(s, f); setSuccessor(s, next)
        }
        let adder = bit(orderFall != 0)
        var total = frequency(s), escape = sum(minContext) &- total
        total = (total &+ 4 &+ adder) >> 1
        setFrequency(s, total)
        for i in 1..<n {
            s = base &+ 6 &* i
            let old = frequency(s), f = (old &+ adder) >> 1
            escape &-= old; total &+= f; setFrequency(s, f)
            if f > frequency(s &- 6) {
                let sym = symbol(s), next = successor(s)
                var sorted = s
                repeat {
                    arena.copy(sorted, sorted &- 6, 6); sorted &-= 6
                } while sorted != base && f > frequency(sorted &- 6)
                arena.setByte(sorted, sym); setFrequency(sorted, f); setSuccessor(sorted, next)
            }
        }
        if frequency(s) == 0 {
            var remaining = n
            while frequency(base &+ (remaining &- 1) &* 6) == 0 { remaining &-= 1 }
            escape &+= n &- remaining
            setNumber(minContext, remaining)
            let oldUnits = (n &+ 1) >> 1
            if remaining == 1 {
                var f = frequency(base)
                if variantI {
                    f = min(124 / 3, (2 &* f &+ escape &- 1) / escape)
                    arena.setByte(minContext &+ 1, (arena.byte(minContext &+ 1) & 16) &+ high3(symbol(base)))
                } else {
                    repeat { escape >>= 1; f = (f &+ 1) >> 1 } while escape > 1
                }
                arena.copy(minContext &+ 2, base, 6)
                setFrequency(minContext &+ 2, f); foundState = minContext &+ 2
                arena.insert(base, arena.unitIndex(oldUnits))
                return
            }
            let newUnits = (remaining &+ 1) >> 1
            if oldUnits != newUnits {
                let shrunk = arena.shrink(base, oldUnits: oldUnits, newUnits: newUnits)
                arena.setRef(minContext &+ 4, shrunk)
            }
        }
        setSum(minContext, total &+ escape &- (escape >> 1))
        if variantI { arena.setByte(minContext &+ 1, arena.byte(minContext &+ 1) | 4) }
        foundState = stats(minContext)
    }
}
