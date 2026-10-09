import Foundation

// 出典: UNIX compress の公開形式説明と Welch の LZW 辞書規則からの独立実装。
// https://ciderpress2.com/formatdoc/LZC-notes.html （header / 8-code group / padding）
// https://man.openbsd.org/compress.1 （maxbits / 圧縮率による辞書 reset）
// Welch, “A Technique for High Performance Data Compression”, IEEE Computer 17(6), 1984.
// KaitoKit Codecs/LZW/LZWDecoder.swift の幅変更・CLEAR の group 廃棄を読み、互換性を確認。
// 既存 codec の翻訳や vendoring は行わず、OS library も使わない。
final class LZWStreamEncoder {
    private let maxbits: Int
    private let dictionaryLimit: Int
    // key = (prefix code << 8) | suffix byte。占有率は1/2未満の線形探索表。
    // 上位に key、下位16 bitに code を詰める。code >= 257 なのでゼロを空き欄にできる。
    private var dictionary: UnsafeMutablePointer<UInt64>?
    private let tableCount: Int
    private let tableMask: Int
    private let hashShift: Int
    private var nextCode = 257
    private var prefix: Int?
    private var width = 9
    private var groupLow: UInt64 = 0
    private var groupHigh: UInt64 = 0
    private var groupBits = 0
    private var output = Data()
    private var inputCount: UInt64 = 0
    private var outputCount: UInt64 = 3
    private var checkpoint: UInt64 = 10_000
    private var bestRatio = 0.0
    private var started = false
    private var finished = false
    private(set) var clearCount: UInt64 = 0

    init(maxbits: Int = 16) throws {
        // 形式自体は 9...16 だが、macOS の実ツールで読める 12...16 のみを提供する。
        guard (12...16).contains(maxbits) else { throw WriterError.invalidOption("compressMaxbits") }
        self.maxbits = maxbits
        dictionaryLimit = 1 << maxbits
        tableCount = 1 << (maxbits + 1)
        tableMask = tableCount - 1
        hashShift = 31 - maxbits
        let table = UnsafeMutablePointer<UInt64>.allocate(capacity: tableCount)
        table.initialize(repeating: 0, count: tableCount)
        dictionary = table
        output.reserveCapacity(IOChunk.size)
    }

    deinit { releaseDictionary() }

    private func releaseDictionary() {
        dictionary?.deinitialize(count: tableCount)
        dictionary?.deallocate()
        dictionary = nil
    }

    func write(_ input: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if input.isEmpty && !finish { return }
            if !started {
                try emit(Data([0x1F, 0x9D, 0x80 | UInt8(maxbits)]))
                started = true
            }
            // chunk 全体で一度だけ溢れを検査し、内側では入力数と prefix をレジスタへ置く。
            let endCount = try checkedAdd(inputCount, UInt64(input.count))
            var inputCount = self.inputCount, prefix = self.prefix ?? -1, nextCode = self.nextCode
            let dictionary = self.dictionary!, tableMask = self.tableMask, hashShift = self.hashShift
            try input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                let source = base.assumingMemoryBound(to: UInt8.self)
                for offset in 0..<bytes.count {
                    if offset & 0x3FFF == 0 { try Task.checkCancellation() }
                    inputCount &+= 1
                    let byte = source[offset]
                    guard prefix >= 0 else { prefix = Int(byte); continue }
                    let key = UInt32(prefix) << 8 | UInt32(byte)
                    var slot = Int((key &* 0x9E37_79B1) >> hashShift)
                    var entry = dictionary[slot]
                    while entry != 0, entry >> 16 != UInt64(key) {
                        slot = (slot + 1) & tableMask
                        entry = dictionary[slot]
                    }
                    if entry != 0 {
                        prefix = Int(entry & 0xFFFF)
                        continue
                    }
                    try put(prefix, nextCode: nextCode, emit: emit)
                    prefix = Int(byte)
                    if nextCode < dictionaryLimit {
                        dictionary[slot] = UInt64(key) << 16 | UInt64(nextCode)
                        nextCode += 1
                    } else if inputCount >= checkpoint {
                        // 満杯の辞書だけを定期評価する。累積圧縮率が悪化したら block を再学習する。
                        checkpoint = try checkedAdd(inputCount, 10_000)
                        let bytesWritten = try checkedAdd(outputCount, UInt64((groupBits + 7) / 8))
                        let ratio = Double(inputCount) / Double(bytesWritten)
                        if ratio < bestRatio {
                            try clear(nextCode: nextCode, emit: emit)
                            dictionary.update(repeating: 0, count: tableCount)
                            nextCode = 257
                        } else {
                            bestRatio = ratio
                        }
                    }
                }
            }
            assert(inputCount == endCount)
            self.inputCount = endCount
            self.prefix = prefix >= 0 ? prefix : nil
            self.nextCode = nextCode
            if finish {
                if prefix >= 0 { try put(prefix, nextCode: nextCode, emit: emit) }
                try flushGroup(padded: false, emit: emit)
                if !output.isEmpty { try emit(output); output = Data() }
                releaseDictionary()
                self.prefix = nil
                finished = true
            }
        } catch {
            releaseDictionary()
            output = Data()
            finished = true
            throw error
        }
    }

    private func clear(nextCode: Int, emit: (Data) throws -> Void) throws {
        try put(256, nextCode: nextCode, emit: emit)
        // CLEAR を含む旧幅の group を丸ごと埋め、次は 9 bit literal から始める。
        try flushGroup(padded: true, emit: emit)
        width = 9
        bestRatio = 0
        clearCount = try checkedAdd(clearCount, 1)
    }

    private func put(_ code: Int, nextCode: Int, emit: (Data) throws -> Void) throws {
        // LSB first。8 code の group は最大128 bitなので、二つのレジスタだけで保持する。
        let bits = UInt64(code)
        if groupBits < 64 {
            groupLow |= bits << groupBits
            if groupBits + width > 64 { groupHigh |= bits >> (64 - groupBits) }
        } else {
            groupHigh |= bits << (groupBits - 64)
        }
        groupBits += width
        if groupBits == width * 8 { try flushGroup(padded: true, emit: emit) }
        // encoder の辞書は decoder より一つ先行する。幅を変えるのは code を出した直後で、
        // 新しい prefix/suffix entry を追加する前。maxbits に達したら幅を増やさない。
        if width < maxbits && nextCode > (1 << width) - 1 {
            try flushGroup(padded: true, emit: emit)
            width += 1
        }
    }

    private func flushGroup(padded: Bool, emit: (Data) throws -> Void) throws {
        guard groupBits > 0 else { return }
        // 幅変更と CLEAR は width byte（8 code 分）、EOF だけは byte 境界まで。
        let count = padded ? width : (groupBits + 7) / 8
        withUnsafeBytes(of: (groupLow.littleEndian, groupHigh.littleEndian)) { group in
            output.append(group.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
        }
        outputCount = try checkedAdd(outputCount, UInt64(count))
        groupLow = 0
        groupHigh = 0
        groupBits = 0
        if output.count >= IOChunk.size {
            try emit(output)
            output.removeAll(keepingCapacity: true)
        }
    }
}
