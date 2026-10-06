// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

/// 一つの stream を直列に操作する。push の戻り値を順に書き、最後に finish を書く。
/// expectedSize は入力検査と確保量削減用で、EOS の有無とは独立する。
final class LZMAEncoder {
    let properties: LZMAEncoderProperties
    private var engine: LZMAEncodingEngine
    private let expectedSize: UInt64?
    private let endMarker: Bool
    private var received: UInt64 = 0
    private var finished = false

    init(properties: LZMAEncoderProperties = .preset(6), expectedSize: UInt64? = nil,
         endMarker: Bool = true, memoryLimit: Int = 768 << 20) throws {
        try properties.validate()
        self.properties = properties; self.expectedSize = expectedSize; self.endMarker = endMarker
        engine = try LZMAEncodingEngine(properties: properties, sizeHint: expectedSize, memoryLimit: memoryLimit)
    }
    deinit { engine.release() }

    func push(_ input: Data) throws -> Data {
        guard !finished else { throw LZMAEncodingError.finished }
        let (total, overflow) = received.addingReportingOverflow(UInt64(input.count))
        guard !overflow, expectedSize.map({ total <= $0 }) ?? true else { throw LZMAEncodingError.sizeMismatch }
        received = total
        var output = Data()
        try input.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                if engine.capacity - engine.end < min(65536, bytes.count - offset) { engine.compact() }
                let n = min(65536, min(bytes.count - offset, engine.capacity - engine.end))
                engine.window.advanced(by: engine.end).update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: n)
                engine.end += n; offset += n
                engine.process(limit: engine.end, reserve: LZMAEncodingEngine.lookahead)
                if let error = engine.rc.error { finished = true; throw error }
                output.append(engine.rc.take())
            }
        }
        return output
    }
    func finish() throws -> Data {
        guard !finished else { throw LZMAEncodingError.finished }
        guard expectedSize.map({ received == $0 }) ?? true else { throw LZMAEncodingError.sizeMismatch }
        finished = true
        var output = Data()
        // 出力 buffer を drain しながら終端付近を処理する。
        while engine.cursor < engine.end {
            try Task.checkCancellation()
            engine.process(limit: min(engine.end, engine.cursor + 65536), reserve: 0)
            if let error = engine.rc.error { throw error }
            output.append(engine.rc.take())
        }
        if endMarker { engine.writeEndMarker() }
        engine.rc.finish()
        if let error = engine.rc.error { throw error }
        output.append(engine.rc.take())
        return output
    }
    static func encode(_ input: Data, properties: LZMAEncoderProperties = .preset(6), endMarker: Bool = true) throws -> Data {
        let encoder = try Self(properties: properties, expectedSize: UInt64(input.count), endMarker: endMarker)
        return try encoder.push(input) + encoder.finish()
    }
    /// .lzma の 13 byte header。未知サイズは all-ones と EOS を組にする。
    static func alone(_ input: Data, properties: LZMAEncoderProperties = .preset(6), knownSize: Bool = false) throws -> Data {
        try properties.validate()
        var output = properties.bytes
        output.le(knownSize ? UInt64(input.count) : UInt64.max)
        output.append(try encode(input, properties: properties, endMarker: !knownSize))
        return output
    }
}

struct LZMARepetitions {
    var a = 1, b = 1, c = 1, d = 1
    @inline(__always) subscript(_ i: Int) -> Int {
        switch i { case 0: a; case 1: b; case 2: c; default: d }
    }
    @inline(__always) func moved(_ i: Int) -> Self {
        switch i {
        case 0: self
        case 1: Self(a: b, b: a, c: c, d: d)
        case 2: Self(a: c, b: a, c: b, d: d)
        default: Self(a: d, b: a, c: b, d: c)
        }
    }
    @inline(__always) func inserting(_ distance: Int) -> Self { Self(a: distance, b: a, c: b, d: c) }
}
struct LZMAAction { var length = 1; var code = -1 }
struct LZMAOptimal {
    var price = 1 << 30
    var state = 0
    var reps = LZMARepetitions()
    var previous = 0
    var length = 1
    var code = -1
    /// 0: 一つの symbol、1: literal + rep0、2 以上: match/rep + literal + rep0。
    var extra = 0
    var tail = 0
}

/// 所有する pointer は release まで有効。hot loop から class/closure 呼出しを取り除く。
struct LZMAEncodingEngine {
    static let lookahead = 4096 + 273
    static let literalOffset = 1846
    static let lenOffset = 818
    static let repLenOffset = 1332
    let properties: LZMAEncoderProperties
    let dictionary: Int
    let capacity: Int
    let window: UnsafeMutablePointer<UInt8>
    let probs: UnsafeMutablePointer<UInt16>
    let probCount: Int
    let bitPrices: UnsafeMutablePointer<Int>
    let lengthPrices: UnsafeMutablePointer<Int>
    let repLengthPrices: UnsafeMutablePointer<Int>
    let distancePrices: UnsafeMutablePointer<Int>
    let slotPrices: UnsafeMutablePointer<Int>
    let alignPrices: UnsafeMutablePointer<Int>
    let matches: UnsafeMutablePointer<LZMAMatch>
    let opt: UnsafeMutablePointer<LZMAOptimal>
    let actions: UnsafeMutablePointer<LZMAAction>
    var finder: LZMAMatchFinder
    var rc: LZMARangeEncoder
    var cursor = 0, end = 0, finderCursor = 0
    var position: UInt64 = 0
    var state = 0
    var reps = LZMARepetitions()
    var matchCount = 0
    var pendingMatches = false
    var actionCount = 0, actionIndex = 0
    var optUsed = 0
    var matchCounter = 0, repCounter = 0
    var modelNeedsReset = false

    static func memorySize(properties: LZMAEncoderProperties, dictionary: Int, chunked: Bool = false) -> Int {
        dictionary + (chunked ? 2 << 20 : 65536) + lookahead + 65536
            + LZMAMatchFinder.memorySize(dictionary: dictionary, tree: properties.matchFinder == .bt4)
            + (literalOffset + (768 << (properties.lc + properties.lp))) * 2
            + 131072 + 4096 * (MemoryLayout<LZMAOptimal>.stride + MemoryLayout<LZMAAction>.stride)
            + (16 * 272 * 2 + 4 * 128 + 4 * 64 + 16 + 128) * MemoryLayout<Int>.stride
            + 274 * MemoryLayout<LZMAMatch>.stride
    }
    init(properties p: LZMAEncoderProperties, sizeHint: UInt64?, memoryLimit: Int, chunked: Bool = false) throws {
        properties = p
        dictionary = min(p.dictSize, Int(min(UInt64(p.dictSize), max(4096, sizeHint ?? UInt64(p.dictSize)))))
        capacity = dictionary + (chunked ? 2 << 20 : 65536) + Self.lookahead + 65536
        let required = Self.memorySize(properties: p, dictionary: dictionary, chunked: chunked)
        guard memoryLimit >= required else { throw LZMAEncodingError.memoryLimit(required: required, limit: memoryLimit) }
        // 確保を一つの group として扱い、途中の失敗時も全 pointer を解放する。
        var allocated: [UnsafeMutableRawPointer] = []
        func allocate<T: BitwiseCopyable>(_ type: T.Type, _ n: Int) throws -> UnsafeMutablePointer<T> {
            let pointer = try lzmaAllocate(type, count: n)
            allocated.append(UnsafeMutableRawPointer(pointer))
            return pointer
        }
        do {
            window = try allocate(UInt8.self, capacity)
            probCount = Self.literalOffset + (768 << (p.lc + p.lp))
            probs = try allocate(UInt16.self, probCount)
            bitPrices = try allocate(Int.self, 128)
            lengthPrices = try allocate(Int.self, 16 * 272)
            repLengthPrices = try allocate(Int.self, 16 * 272)
            distancePrices = try allocate(Int.self, 4 * 128)
            slotPrices = try allocate(Int.self, 4 * 64)
            alignPrices = try allocate(Int.self, 16)
            matches = try allocate(LZMAMatch.self, 274)
            opt = try allocate(LZMAOptimal.self, 4096)
            actions = try allocate(LZMAAction.self, 4096)
            rc = try LZMARangeEncoder()
            rc.bufferLimit = min(16 << 20, memoryLimit - required + rc.capacity)
            allocated.append(UnsafeMutableRawPointer(rc.output))
            finder = try LZMAMatchFinder(properties: p, dictionary: dictionary)
        } catch { for pointer in allocated { free(pointer) }; throw error }
        for i in 0..<4096 { opt[i] = LZMAOptimal() }
        // SDK の 1/16 bit 固定小数点 price table。
        for i in 0..<128 {
            var w = UInt32(i * 16 + 8)
            var bits = 0
            for _ in 0..<4 {
                w = w &* w; bits <<= 1
                while w >= 1 << 16 { w >>= 1; bits += 1 }
            }
            bitPrices[i] = 11 * 16 - 15 - bits
        }
        resetModel()
    }
    func release() {
        free(window); free(probs); free(bitPrices); free(lengthPrices); free(repLengthPrices)
        free(distancePrices); free(slotPrices); free(alignPrices); free(matches); free(opt); free(actions)
        free(rc.output); finder.release()
    }
    mutating func resetModel() {
        for i in 0..<probCount { probs[i] = 1024 }
        state = 0; reps = LZMARepetitions(); matchCounter = 0; repCounter = 0
        if properties.mode == .normal { updatePrices(lengths: true, repetitions: true, distances: true) }
        modelNeedsReset = false
    }
    mutating func compact() {
        let drop = max(0, cursor - dictionary)
        if drop > 0 {
            memmove(window, window + drop, end - drop)
            end -= drop; cursor -= drop; finderCursor -= drop
        }
    }
    @inline(__always) func posState(_ pos: UInt64) -> Int { Int(pos & UInt64((1 << properties.pb) - 1)) }
    @inline(__always) static func literalState(_ s: Int) -> Int { s < 4 ? 0 : s < 10 ? s - 3 : s - 6 }
    @inline(__always) static func matchState(_ s: Int) -> Int { s < 7 ? 7 : 10 }
    @inline(__always) static func repState(_ s: Int) -> Int { s < 7 ? 8 : 11 }
    @inline(__always) static func shortState(_ s: Int) -> Int { s < 7 ? 9 : 11 }
    @inline(__always) func literalProbs(_ pos: UInt64, previous: UInt8) -> UnsafeMutablePointer<UInt16> {
        let context = ((Int(pos & UInt64((1 << properties.lp) - 1)) << properties.lc)
                       + (Int(previous) >> (8 - properties.lc)))
        return probs + Self.literalOffset + context * 768
    }
    @inline(__always) func repLength(_ data: UnsafePointer<UInt8>, distance: Int, limit: Int, history: Int) -> Int {
        if distance > history { return 0 }
        var n = 0
        while n < limit && data[n] == data[n - distance] { n += 1 }
        return n
    }
    @inline(__always) mutating func readMatches(limit: Int) {
        matchCount = finder.matches(UnsafePointer(window + finderCursor), available: limit - finderCursor, into: matches)
        finderCursor += 1
    }
    @inline(__always) mutating func skip(to target: Int, limit: Int) {
        while finderCursor < target {
            _ = finder.matches(UnsafePointer(window + finderCursor), available: limit - finderCursor, into: matches, record: false)
            finderCursor += 1
        }
    }
    mutating func process(limit: Int, reserve: Int, packedLimit: Int = .max) {
        while cursor < limit && (actionIndex < actionCount || pendingMatches || limit - cursor > reserve) {
            if actionIndex == actionCount {
                if rc.estimatedSize >= packedLimit && !pendingMatches { break }
                if properties.mode == .fast { parseFast(limit: limit) } else { parseNormal(limit: limit) }
            }
            let action = actions[actionIndex]
            actionIndex += 1
            encode(action)
            if properties.mode == .normal && actionIndex == actionCount {
                let lengths = matchCounter >= 64, repetitions = repCounter >= 64
                if lengths || repetitions { updatePrices(lengths: lengths, repetitions: repetitions, distances: lengths) }
            }
        }
    }
    @inline(__always) mutating func encodeLength(_ length: Int, pos: Int, offset: Int) {
        let p = probs + offset
        let sym = length - 2
        if sym < 8 {
            rc.bit(p, 0); rc.tree(p + 2 + pos * 8, bits: 3, symbol: sym)
        } else {
            rc.bit(p, 1)
            if sym < 16 {
                rc.bit(p + 1, 0); rc.tree(p + 2 + 128 + pos * 8, bits: 3, symbol: sym - 8)
            } else {
                rc.bit(p + 1, 1); rc.tree(p + 258, bits: 8, symbol: sym - 16)
            }
        }
    }
    @inline(__always) static func slot(_ distance: Int) -> Int {
        if distance < 4 { return distance }
        let log = Int.bitWidth - 1 - distance.leadingZeroBitCount
        return log * 2 + ((distance >> (log - 1)) & 1)
    }
    @inline(__always) mutating func encodeDistance(_ distance: Int, length: Int) {
        let slot = Self.slot(distance)
        rc.tree(probs + 432 + min(length - 2, 3) * 64, bits: 6, symbol: slot)
        if slot >= 4 {
            let bits = (slot >> 1) - 1
            let base = (2 | (slot & 1)) << bits
            let reduced = distance - base
            if slot < 14 {
                rc.reverseTree(probs + 688 + base - slot - 1, bits: bits, symbol: reduced)
            } else {
                rc.direct(UInt32(reduced >> 4), bits: bits - 4)
                rc.reverseTree(probs + 802, bits: 4, symbol: reduced & 15)
            }
        }
    }
    @inline(__always) mutating func encode(_ action: LZMAAction) {
        let pos = posState(position)
        let code = action.code, length = action.length
        if code == -1 {
            rc.bit(probs + state * 16 + pos, 0)
            let previous: UInt8 = position == 0 ? 0 : window[cursor - 1]
            let p = literalProbs(position, previous: previous)
            var symbol = Int(window[cursor]) | 256
            if state < 7 {
                repeat {
                    rc.bit(p + (symbol >> 8), (symbol >> 7) & 1)
                    symbol <<= 1
                } while symbol < 65536
            } else {
                var match = Int(window[cursor - reps.a])
                var offset = 256
                repeat {
                    match <<= 1
                    rc.bit(p + offset + (match & offset) + (symbol >> 8), (symbol >> 7) & 1)
                    symbol <<= 1
                    offset &= ~(match ^ symbol)
                } while symbol < 65536
            }
            state = Self.literalState(state)
        } else {
            rc.bit(probs + state * 16 + pos, 1)
            if code < 4 {
                rc.bit(probs + 192 + state, 1)
                if code == 0 {
                    rc.bit(probs + 204 + state, 0)
                    rc.bit(probs + 240 + state * 16 + pos, length == 1 ? 0 : 1)
                } else {
                    rc.bit(probs + 204 + state, 1)
                    if code == 1 { rc.bit(probs + 216 + state, 0) }
                    else { rc.bit(probs + 216 + state, 1); rc.bit(probs + 228 + state, code - 2) }
                    reps = reps.moved(code)
                }
                if length == 1 { state = Self.shortState(state) }
                else { encodeLength(length, pos: pos, offset: Self.repLenOffset); state = Self.repState(state); repCounter += 1 }
            } else {
                rc.bit(probs + 192 + state, 0)
                encodeLength(length, pos: pos, offset: Self.lenOffset)
                let distance = code - 4
                encodeDistance(distance, length: length)
                reps = reps.inserting(distance + 1)
                state = Self.matchState(state); matchCounter += 1
            }
        }
        cursor += length; position += UInt64(length)
    }
    mutating func writeEndMarker() {
        let pos = posState(position)
        rc.bit(probs + state * 16 + pos, 1); rc.bit(probs + 192 + state, 0)
        encodeLength(2, pos: pos, offset: Self.lenOffset)
        encodeDistance(Int(UInt32.max), length: 2)
    }
}
