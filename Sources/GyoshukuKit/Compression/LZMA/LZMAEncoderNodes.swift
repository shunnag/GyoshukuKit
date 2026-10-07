// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c (public domain, Igor Pavlov)
import Foundation

struct LZMARepetitions {
    private var storedA: UInt32, storedB: UInt32, storedC: UInt32, storedD: UInt32
    var a: Int { Int(storedA) }
    var b: Int { Int(storedB) }
    var c: Int { Int(storedC) }
    var d: Int { Int(storedD) }
    init(a: Int = 1, b: Int = 1, c: Int = 1, d: Int = 1) {
        storedA = UInt32(truncatingIfNeeded: a); storedB = UInt32(truncatingIfNeeded: b)
        storedC = UInt32(truncatingIfNeeded: c); storedD = UInt32(truncatingIfNeeded: d)
    }
    @inline(__always) subscript(_ i: Int) -> Int {
        switch i { case 0: a; case 1: b; case 2: c; default: d }
    }
    @inline(__always) func moved(_ i: Int) -> Self {
        var result = self
        switch i {
        case 0: break
        case 1: result.storedA = storedB; result.storedB = storedA
        case 2: result.storedA = storedC; result.storedB = storedA; result.storedC = storedB
        default: result.storedA = storedD; result.storedB = storedA; result.storedC = storedB; result.storedD = storedC
        }
        return result
    }
    @inline(__always) func inserting(_ distance: Int) -> Self {
        var result = self
        result.storedA = UInt32(truncatingIfNeeded: distance); result.storedB = storedA
        result.storedC = storedB; result.storedD = storedC
        return result
    }
}
/// length <= 273、code は -1 または辞書距離 + 3。64 bit の Int を配列に複製しない。
struct LZMAAction {
    var length: UInt16
    var code: Int32
    init(length: Int = 1, code: Int = -1) {
        self.length = UInt16(truncatingIfNeeded: length)
        self.code = Int32(truncatingIfNeeded: code)
    }
}

/// 4096位置以内の predecessor、12 state、UInt32以内の辞書距離。node は32 byte。
struct LZMAOptimal {
    var price: Int32
    var code: Int32
    var previous: UInt16
    var length: UInt16
    /// 0: 一つの symbol、1: literal + rep0、2 以上: match/rep + literal + rep0。
    var extra: UInt16
    private var stateAndTail: UInt16
    var tail: UInt16 { stateAndTail >> 4 }
    var state: UInt8 { UInt8(truncatingIfNeeded: stateAndTail & 15) }
    var reps: LZMARepetitions

    init(price: Int = 1 << 30, state: Int = 0, reps: LZMARepetitions = LZMARepetitions(),
         previous: Int = 0, length: Int = 1, code: Int = -1, extra: Int = 0, tail: Int = 0) {
        self.price = Int32(truncatingIfNeeded: price)
        stateAndTail = UInt16(truncatingIfNeeded: (tail << 4) | state)
        self.previous = UInt16(truncatingIfNeeded: previous); self.length = UInt16(truncatingIfNeeded: length)
        self.code = Int32(truncatingIfNeeded: code); self.extra = UInt16(truncatingIfNeeded: extra)
        self.reps = reps
    }
}
