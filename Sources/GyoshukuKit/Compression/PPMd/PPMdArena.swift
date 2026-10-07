// 出自: LZMA SDK 26.03 C/Ppmd.h、C/Ppmd7.c と 7-Zip 26.03 の公開ドメイン C/Ppmd8.c。
// Igor Pavlov、原作 Dmitry Shkarin（公開ドメイン）。12 byte unit allocator の純 Swift 移植。
import Foundation

/// 一つの heap に 6 byte STATE と 12 byte CONTEXT を置く。永続参照は UInt32 offset。
/// Int は計算時だけ使用する。0 は null、text successor は unitsStart より下の領域。
struct PPMdArena: ~Copyable {
    let base: UnsafeMutableRawPointer
    let size: Int
    let alignment: Int
    let variantI: Bool
    var text = 0
    var unitsStart = 0
    var lowUnit = 0
    var highUnit = 0
    var glueCount = 0
    // SDK と同じ固定表。記号更新時の Array の bounds check / COW を避ける。
    let freeList: UnsafeMutablePointer<Int>
    let stamps: UnsafeMutablePointer<Int>
    let indexToUnits: UnsafeMutablePointer<Int>
    let unitsToIndex: UnsafeMutablePointer<Int>

    init(size: Int, variantI: Bool) throws {
        self.size = size
        self.variantI = variantI
        alignment = (4 - size) & 3
        guard let allocation = malloc(size + alignment) else { throw WriterError.compression(-1) }
        base = allocation
        freeList = .allocate(capacity: 38); freeList.initialize(repeating: 0, count: 38)
        stamps = .allocate(capacity: 38); stamps.initialize(repeating: 0, count: 38)
        indexToUnits = .allocate(capacity: 38); unitsToIndex = .allocate(capacity: 128)
        var units = 0
        for i in 0..<38 {
            let step = i >= 12 ? 4 : (i >> 2) + 1
            for _ in 0..<step { unitsToIndex[units] = i; units += 1 }
            indexToUnits[i] = units
        }
        reset()
    }

    deinit {
        free(base)
        freeList.deallocate(); stamps.deallocate()
        indexToUnits.deallocate(); unitsToIndex.deallocate()
    }

    @inline(__always) func byte(_ offset: Int) -> Int {
        Int(base.load(fromByteOffset: offset, as: UInt8.self))
    }
    @inline(__always) func word(_ offset: Int) -> Int {
        Int(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inline(__always) func ref(_ offset: Int) -> Int {
        Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inline(__always) func setByte(_ offset: Int, _ value: Int) {
        base.storeBytes(of: UInt8(truncatingIfNeeded: value), toByteOffset: offset, as: UInt8.self)
    }
    @inline(__always) func setWord(_ offset: Int, _ value: Int) {
        base.storeBytes(of: UInt16(truncatingIfNeeded: value), toByteOffset: offset, as: UInt16.self)
    }
    @inline(__always) func setRef(_ offset: Int, _ value: Int) {
        // raw store は alignment を要求しない。STATE の successor は 2 byte 境界にも置く。
        base.storeBytes(of: UInt32(truncatingIfNeeded: value), toByteOffset: offset, as: UInt32.self)
    }
    @inline(__always) func copy(_ destination: Int, _ source: Int, _ count: Int) {
        base.advanced(by: destination).copyMemory(from: base.advanced(by: source), byteCount: count)
    }
    @inline(__always) func swapStates(_ first: Int, _ second: Int) {
        let symbol = byte(first), frequency = byte(first &+ 1), successor = ref(first &+ 2)
        copy(first, second, 6)
        setByte(second, symbol); setByte(second &+ 1, frequency); setRef(second &+ 2, successor)
    }
    @inline(__always) func unitIndex(_ units: Int) -> Int { unitsToIndex[units - 1] }

    mutating func reset() {
        freeList.update(repeating: 0, count: 38)
        stamps.update(repeating: 0, count: 38)
        text = alignment
        highUnit = text + size
        lowUnit = highUnit - size / 8 / 12 * 7 * 12
        unitsStart = lowUnit
        glueCount = 0
    }

    @inline(__always) mutating func insert(_ node: Int, _ index: Int) {
        if variantI {
            setRef(node, 0xFFFF_FFFF)
            setRef(node + 4, freeList[index])
            setRef(node + 8, indexToUnits[index])
            stamps[index] += 1
        } else {
            setRef(node, freeList[index])
        }
        freeList[index] = node
    }

    @inline(__always) mutating func remove(_ index: Int) -> Int {
        let node = freeList[index]
        freeList[index] = ref(node + (variantI ? 4 : 0))
        if variantI { stamps[index] -= 1 }
        return node
    }

    @inline(__always) mutating func split(_ node: Int, oldIndex: Int, newIndex: Int) {
        let units = indexToUnits[oldIndex] - indexToUnits[newIndex]
        let tail = node + 12 * indexToUnits[newIndex]
        var i = unitIndex(units)
        if indexToUnits[i] != units {
            i -= 1
            let k = indexToUnits[i]
            insert(tail + 12 * k, units - k - 1)
        }
        insert(tail, i)
    }

    @inline(__always) mutating func allocate(_ index: Int) -> Int {
        if freeList[index] != 0 { return remove(index) }
        let bytes = 12 * indexToUnits[index]
        if highUnit - lowUnit >= bytes {
            let result = lowUnit
            lowUnit += bytes
            return result
        }
        return allocateRare(index)
    }

    @inline(__always) mutating func allocateContext() -> Int {
        if highUnit != lowUnit { highUnit -= 12; return highUnit }
        if freeList[0] != 0 { return remove(0) }
        return allocateRare(0)
    }

    @inline(never) mutating func allocateRare(_ index: Int) -> Int {
        if glueCount == 0 {
            glue()
            if freeList[index] != 0 { return remove(index) }
        }
        var i = index + 1
        while i < 38 && freeList[i] == 0 { i += 1 }
        if i == 38 {
            let bytes = 12 * indexToUnits[index]
            glueCount -= 1
            if unitsStart - text <= bytes { return 0 }
            unitsStart -= bytes
            return unitsStart
        }
        let node = remove(i)
        split(node, oldIndex: i, newIndex: index)
        return node
    }

    mutating func shrink(_ node: Int, oldUnits: Int, newUnits: Int) -> Int {
        let old = unitIndex(oldUnits), new = unitIndex(newUnits)
        if old == new { return node }
        if freeList[new] != 0 {
            let result = remove(new)
            copy(result, node, newUnits * 12)
            insert(node, old)
            return result
        }
        split(node, oldIndex: old, newIndex: new)
        return node
    }

    mutating func specialFree(_ node: Int) {
        if node != unitsStart { insert(node, 0) }
        else { unitsStart += 12 }
    }

    private mutating func glue() {
        if variantI { glueI() } else { glueH() }
    }

    private mutating func fill(_ head: Int, nextOffset: Int, unitsOffset: Int) {
        var n = head
        while n != 0 {
            var node = n, units = variantI ? ref(n + unitsOffset) : word(n + unitsOffset)
            n = ref(n + nextOffset)
            if units == 0 { continue }
            while units > 128 { insert(node, 37); units -= 128; node += 128 * 12 }
            var i = unitIndex(units)
            if indexToUnits[i] != units {
                i -= 1
                let k = indexToUnits[i]
                insert(node + k * 12, units - k - 1)
            }
            insert(node, i)
        }
    }

    private mutating func glueH() {
        glueCount = 255
        if lowUnit != highUnit { setWord(lowUnit, 1) }
        var head = 0
        for i in 0..<38 {
            var next = freeList[i]
            freeList[i] = 0
            while next != 0 {
                let node = next
                next = ref(node)
                setWord(node, 0); setWord(node + 2, indexToUnits[i]); setRef(node + 4, head)
                head = node
            }
        }
        var n = head, previous = 0
        while n != 0 {
            let node = n
            var units = word(node + 2)
            n = ref(node + 4)
            if units == 0 {
                if previous == 0 { head = n } else { setRef(previous + 4, n) }
                continue
            }
            previous = node
            while true {
                let next = node + units * 12
                if word(next) != 0 { break }
                let sum = units + word(next + 2)
                if sum >= 0x10000 { break }
                units = sum
                setWord(node + 2, units); setWord(next + 2, 0)
            }
        }
        fill(head, nextOffset: 4, unitsOffset: 2)
    }

    private mutating func glueI() {
        glueCount = 1 << 13
        stamps.update(repeating: 0, count: 38)
        if lowUnit != highUnit { setRef(lowUnit, 0) }
        var head = 0, previous = 0
        for i in 0..<38 {
            var next = freeList[i]
            freeList[i] = 0
            while next != 0 {
                let node = next
                var units = ref(node + 8)
                if previous == 0 { head = node } else { setRef(previous + 4, node) }
                next = ref(node + 4)
                if units == 0 { continue }
                previous = node
                while ref(node + units * 12) == 0xFFFF_FFFF {
                    let other = node + units * 12
                    units += ref(other + 8)
                    setRef(other + 8, 0); setRef(node + 8, units)
                }
            }
        }
        if previous == 0 { head = 0 } else { setRef(previous + 4, 0) }
        fill(head, nextOffset: 4, unitsOffset: 8)
    }

    mutating func expandTextArea() {
        var counts = [Int](repeating: 0, count: 38)
        if lowUnit != highUnit { setRef(lowUnit, 0) }
        while ref(unitsStart) == 0xFFFF_FFFF {
            let units = ref(unitsStart + 8)
            setRef(unitsStart, 0)
            counts[unitIndex(units)] += 1
            unitsStart += units * 12
        }
        for i in 0..<38 where counts[i] != 0 {
            var remaining = counts[i], previous = 0, n = freeList[i]
            stamps[i] -= remaining
            while remaining != 0 {
                let node = n
                n = ref(node + 4)
                if ref(node) != 0 { previous = node; continue }
                if previous == 0 { freeList[i] = n } else { setRef(previous + 4, n) }
                remaining -= 1
            }
        }
    }

    var usedMemory: Int {
        var freeUnits = 0
        for i in 0..<38 { freeUnits += stamps[i] * indexToUnits[i] }
        return size - (highUnit - lowUnit) - (unitsStart - text) - freeUnits * 12
    }
}
