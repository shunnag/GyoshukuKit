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
         endMarker: Bool = true, memoryLimit: Int = 768 << 20, finderThreads: Int = 1) throws {
        try properties.validate()
        guard finderThreads == 1 || finderThreads == 2 else { throw LZMAEncodingError.invalidProperties }
        self.properties = properties; self.expectedSize = expectedSize; self.endMarker = endMarker
        engine = try LZMAEncodingEngine(properties: properties, sizeHint: expectedSize, memoryLimit: memoryLimit, finderThreads: finderThreads)
    }
    deinit { engine.release() }

    func push(_ input: Data) throws -> Data {
        guard !finished else { throw LZMAEncodingError.finished }
        let (total, overflow) = received.addingReportingOverflow(UInt64(input.count))
        guard !overflow, expectedSize.map({ total <= $0 }) ?? true else {
            engine.finderPipeline?.stopAndWait()
            throw LZMAEncodingError.sizeMismatch
        }
        received = total
        do { return try pushInput(input) }
        catch { abandon(); throw error }
    }
    private func pushInput(_ input: Data) throws -> Data {
        var output = Data()
        try input.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                if engine.capacity - engine.end < min(65536, bytes.count - offset) { engine.compact() }
                let n = min(65536, min(bytes.count - offset, engine.capacity - engine.end))
                engine.window.advanced(by: engine.end).update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: n)
                engine.end += n; offset += n
                try engine.process(limit: engine.end, reserve: LZMAEncodingEngine.lookahead)
                if let error = engine.rc.error { finished = true; throw error }
                output.append(engine.rc.take())
            }
        }
        return output
    }
    func finish() throws -> Data {
        guard !finished else { throw LZMAEncodingError.finished }
        guard expectedSize.map({ received == $0 }) ?? true else {
            engine.finderPipeline?.stopAndWait()
            throw LZMAEncodingError.sizeMismatch
        }
        defer { engine.finderPipeline?.stopAndWait() }
        do { return try finishInput() }
        catch { abandon(); throw error }
    }
    /// error / 取消し / writer abandon でも window 解放より先に join する。
    func abandon() { finished = true; engine.finderPipeline?.stopAndWait() }
    private func finishInput() throws -> Data {
        guard !finished else { throw LZMAEncodingError.finished }
        guard expectedSize.map({ received == $0 }) ?? true else { throw LZMAEncodingError.sizeMismatch }
        finished = true
        var output = Data()
        // 出力 buffer を drain しながら終端付近を処理する。
        while engine.cursor < engine.end {
            try Task.checkCancellation()
            try engine.process(limit: min(engine.end, engine.cursor + 65536), reserve: 0)
            if let error = engine.rc.error { throw error }
            output.append(engine.rc.take())
        }
        if endMarker { engine.writeEndMarker() }
        engine.rc.finish()
        if let error = engine.rc.error { throw error }
        output.append(engine.rc.take())
        return output
    }
    static func encode(_ input: Data, properties: LZMAEncoderProperties = .preset(6), endMarker: Bool = true, finderThreads: Int = 1) throws -> Data {
        let encoder = try Self(properties: properties, expectedSize: UInt64(input.count), endMarker: endMarker, finderThreads: finderThreads)
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

/// 所有する pointer は release まで有効。hot loop から class/closure 呼出しを取り除く。
struct LZMAEncodingEngine {
    static let lookahead = 4096 + 273
    // byte 同一性の試験だけで旧 raw window を使う。LZMA2 の容量には影響しない。
    @TaskLocal static var testingLegacyRawWindowSlack = false
    static func windowSlack(dictionary: Int, chunked: Bool = false) -> Int {
        if chunked { return 2 << 20 }
        if testingLegacyRawWindowSlack { return 65536 }
        // 履歴の移動を数 MiB ごとにまとめ、push の64 KiB処理境界は保つ。
        return min(4 << 20, max(65536, dictionary / 2))
    }
    static let literalOffset = 1846
    static let lenOffset = 818
    static let repLenOffset = 1332
    let properties: LZMAEncoderProperties
    let dictionary: Int
    let posMask: UInt8
    let literalPosMask: UInt8
    let literalContextWidth: UInt16
    let literalShift: UInt8
    let capacity: Int
    let window: UnsafeMutablePointer<UInt8>
    let probs: UnsafeMutablePointer<UInt16>
    let probCount: Int
    let bitPrices: UnsafeMutablePointer<UInt8>
    let lengthPrices: UnsafeMutablePointer<Int>
    let repLengthPrices: UnsafeMutablePointer<Int>
    let distancePrices: UnsafeMutablePointer<Int>
    let slotPrices: UnsafeMutablePointer<Int>
    let alignPrices: UnsafeMutablePointer<Int>
    let matches: UnsafeMutablePointer<LZMAMatch>
    let opt: UnsafeMutablePointer<LZMAOptimal>
    let actions: UnsafeMutablePointer<LZMAAction>
    var finder: LZMAMatchFinder
    let finderPipeline: LZMAMatchFinderPipeline?
    var rc: LZMARangeEncoder
    var cursor = 0, end = 0, finderCursor = 0
    var position: UInt64 = 0
    private var storedState: UInt8 = 0
    var state: Int {
        @inline(__always) get { Int(storedState) }
        @inline(__always) set { storedState = UInt8(truncatingIfNeeded: newValue) }
    }
    var reps = LZMARepetitions()
    var matchCount = 0
    var pendingMatches = false
    var actionCount = 0, actionIndex = 0
    var optUsed = 0
    var matchCounter = 0, repCounter = 0
    var modelNeedsReset = false

    static func memorySize(properties: LZMAEncoderProperties, dictionary: Int, chunked: Bool = false, finderThreads: Int = 1) -> Int {
        dictionary + windowSlack(dictionary: dictionary, chunked: chunked) + lookahead + 65536
            + LZMAMatchFinder.memorySize(dictionary: dictionary, tree: properties.matchFinder == .bt4)
            + (literalOffset + (768 << (properties.lc + properties.lp))) * 2
            + 131072 + 4096 * (MemoryLayout<LZMAOptimal>.stride + MemoryLayout<LZMAAction>.stride)
            + (16 * 272 * 2 + 4 * 128 + 4 * 64 + 16) * MemoryLayout<Int>.stride + 4096
            + 274 * MemoryLayout<LZMAMatch>.stride
            + (finderThreads == 2 ? LZMAMatchFinderPipeline.memorySize : 0)
    }
    init(properties p: LZMAEncoderProperties, sizeHint: UInt64?, memoryLimit: Int, chunked: Bool = false, finderThreads: Int = 1) throws {
        properties = p
        posMask = UInt8((1 << p.pb) - 1); literalPosMask = UInt8((1 << p.lp) - 1)
        literalContextWidth = UInt16(1 << p.lc); literalShift = UInt8(8 - p.lc)
        dictionary = min(p.dictSize, Int(min(UInt64(p.dictSize), max(4096, sizeHint ?? UInt64(p.dictSize)))))
        capacity = dictionary + Self.windowSlack(dictionary: dictionary, chunked: chunked) + Self.lookahead + 65536
        let required = Self.memorySize(properties: p, dictionary: dictionary, chunked: chunked, finderThreads: finderThreads)
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
            bitPrices = try allocate(UInt8.self, 4096)
            // 各行は272 symbol分。価格を埋めるのは長さ2...niceLen（symbol 0...niceLen-2）だけ。
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
            do {
                finderPipeline = finderThreads == 2 ? try LZMAMatchFinderPipeline(finder: finder, window: window) : nil
            } catch { finder.release(); throw error }
        } catch { for pointer in allocated { free(pointer) }; throw error }
        for i in 0..<4096 { opt[i] = LZMAOptimal() }
        // SDK の 1/16 bit 固定小数点価格。0 / 1 を別行に展開し、lookup の shift / xor を除く。
        for i in 0..<128 {
            var w = UInt32(i * 16 + 8)
            var bits = 0
            for _ in 0..<4 {
                w = w &* w; bits <<= 1
                while w >= 1 << 16 { w >>= 1; bits += 1 }
            }
            let value = UInt8(11 * 16 - 15 - bits)
            for offset in 0..<16 {
                let probability = i * 16 + offset
                bitPrices[probability] = value
                bitPrices[2048 + (probability ^ 2047)] = value
            }
        }
        resetModel()
    }
    func release() {
        finderPipeline?.stopAndWait()
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
            finderPipeline?.compact(by: drop)
            memmove(window, window + drop, end - drop)
            end -= drop; cursor -= drop; finderCursor -= drop
        }
    }
    @inline(__always) func posState(_ pos: UInt64) -> Int { Int(pos & UInt64(posMask)) }
    @inline(__always) static func literalState(_ s: Int) -> Int { s < 4 ? 0 : s < 10 ? s - 3 : s - 6 }
    @inline(__always) static func matchState(_ s: Int) -> Int { s < 7 ? 7 : 10 }
    @inline(__always) static func repState(_ s: Int) -> Int { s < 7 ? 8 : 11 }
    @inline(__always) static func shortState(_ s: Int) -> Int { s < 7 ? 9 : 11 }
    @inline(__always) func literalProbs(_ pos: UInt64, previous: UInt8) -> UnsafeMutablePointer<UInt16> {
        let context = Int(pos & UInt64(literalPosMask)) * Int(literalContextWidth)
            + (Int(previous) >> Int(literalShift))
        return probs + Self.literalOffset + context * 768
    }
    @inline(__always) func repLength(_ data: UnsafePointer<UInt8>, distance: Int, limit: Int, history: Int) -> Int {
        if distance > history { return 0 }
        return lzmaMatchLength(data, data.advanced(by: 0 &- distance), limit: limit)
    }
    @inline(__always) mutating func readMatches(limit: Int) {
        if let finderPipeline {
            matchCount = finderPipeline.matches(at: finderCursor, into: matches)
            // 短いhash候補とniceLen以降の延長は表を変更しない。skip位置には不要なので読取時だけ確定する。
            if finder.tree {
                matchCount = finder.finalizeTreeMatches(UnsafePointer(window + finderCursor), available: limit - finderCursor,
                    result: matches, count: matchCount)
            } else if matchCount > 0 {
                finder.extend(UnsafePointer(window + finderCursor), available: limit - finderCursor,
                    result: matches, count: matchCount)
            }
        }
        else { matchCount = finder.matches(UnsafePointer(window + finderCursor), available: limit - finderCursor, into: matches) }
        finderCursor &+= 1
    }
    @inline(__always) mutating func skip(to target: Int, limit: Int) {
        if let finderPipeline {
            finderPipeline.skip(from: finderCursor, to: target)
            finderCursor = max(finderCursor, target)
            return
        }
        while finderCursor < target {
            _ = finder.matches(UnsafePointer(window + finderCursor), available: limit - finderCursor, into: matches, record: false)
            finderCursor &+= 1
        }
    }
    mutating func process(limit: Int, reserve: Int, packedLimit: Int = .max) throws {
        guard cursor < limit && (actionIndex < actionCount || pendingMatches || limit - cursor > reserve) else { return }
        finderPipeline?.begin(limit: limit)
        defer { finderPipeline?.pause() }
        var cancellationPosition = cursor
        while cursor < limit && (actionIndex < actionCount || pendingMatches || limit - cursor > reserve) {
            if cursor >= cancellationPosition {
                try Task.checkCancellation()
                cancellationPosition = cursor + 4096
            }
            if actionIndex == actionCount {
                if rc.estimatedSize >= packedLimit && !pendingMatches { break }
                if properties.mode == .fast { parseFast(limit: limit) } else { parseNormal(limit: limit) }
            }
            let action = actions[actionIndex]
            actionIndex &+= 1
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
        // model の pointer 書込みにまたがる symbol の入力と state は不変。
        let s = state, r = reps, current = cursor, absolute = position
        let data = UnsafePointer(window + current)
        let pos = posState(absolute)
        let code = Int(action.code), length = Int(action.length)
        if code == -1 {
            rc.bit(probs + s * 16 + pos, 0)
            let previous: UInt8 = absolute == 0 ? 0 : data[-1]
            let p = literalProbs(absolute, previous: previous)
            var symbol = Int(data[0]) | 256
            if s < 7 {
                repeat {
                    rc.bit(p + (symbol >> 8), (symbol >> 7) & 1)
                    symbol <<= 1
                } while symbol < 65536
            } else {
                var match = Int(data[-r.a])
                var offset = 256
                repeat {
                    match <<= 1
                    rc.bit(p + offset + (match & offset) + (symbol >> 8), (symbol >> 7) & 1)
                    symbol <<= 1
                    offset &= ~(match ^ symbol)
                } while symbol < 65536
            }
            state = Self.literalState(s)
        } else {
            rc.bit(probs + s * 16 + pos, 1)
            if code < 4 {
                rc.bit(probs + 192 + s, 1)
                if code == 0 {
                    rc.bit(probs + 204 + s, 0)
                    rc.bit(probs + 240 + s * 16 + pos, length == 1 ? 0 : 1)
                } else {
                    rc.bit(probs + 204 + s, 1)
                    if code == 1 { rc.bit(probs + 216 + s, 0) }
                    else { rc.bit(probs + 216 + s, 1); rc.bit(probs + 228 + s, code - 2) }
                    reps = r.moved(code)
                }
                if length == 1 { state = Self.shortState(s) }
                else { encodeLength(length, pos: pos, offset: Self.repLenOffset); state = Self.repState(s); repCounter &+= 1 }
            } else {
                rc.bit(probs + 192 + s, 0)
                encodeLength(length, pos: pos, offset: Self.lenOffset)
                let distance = code - 4
                encodeDistance(distance, length: length)
                reps = r.inserting(distance + 1)
                state = Self.matchState(s); matchCounter &+= 1
            }
        }
        cursor = current &+ length; position = absolute &+ UInt64(length)
    }
    mutating func writeEndMarker() {
        let pos = posState(position)
        rc.bit(probs + state * 16 + pos, 1); rc.bit(probs + 192 + state, 0)
        encodeLength(2, pos: pos, offset: Self.lenOffset)
        encodeDistance(Int(UInt32.max), length: 2)
    }
}
