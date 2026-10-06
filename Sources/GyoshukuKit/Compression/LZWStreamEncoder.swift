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
    // key = (prefix code << 8) | suffix byte。entry 数は 2^maxbits - 257 以下。
    private var dictionary: [UInt32: Int] = [:]
    private var nextCode = 257
    private var prefix: Int?
    private var width = 9
    private var group = [UInt8](repeating: 0, count: 16)
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
        dictionary.reserveCapacity(dictionaryLimit - nextCode)
        output.reserveCapacity(IOChunk.size)
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
            try input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for offset in 0..<bytes.count {
                    if offset & 0x3FFF == 0 { try Task.checkCancellation() }
                    inputCount = try checkedAdd(inputCount, 1)
                    let byte = bytes[offset]
                    guard let previous = prefix else { prefix = Int(byte); continue }
                    let key = UInt32(previous) << 8 | UInt32(byte)
                    if let code = dictionary[key] {
                        prefix = code
                        continue
                    }
                    try put(previous, emit: emit)
                    prefix = Int(byte)
                    if nextCode < dictionaryLimit {
                        dictionary[key] = nextCode
                        nextCode += 1
                    } else if inputCount >= checkpoint {
                        // 満杯の辞書だけを定期評価する。累積圧縮率が悪化したら block を再学習する。
                        checkpoint = try checkedAdd(inputCount, 10_000)
                        let bytesWritten = try checkedAdd(outputCount, UInt64((groupBits + 7) / 8))
                        let ratio = Double(inputCount) / Double(bytesWritten)
                        if ratio < bestRatio {
                            try clear(emit: emit)
                        } else {
                            bestRatio = ratio
                        }
                    }
                }
            }
            if finish {
                if let prefix { try put(prefix, emit: emit) }
                try flushGroup(padded: false, emit: emit)
                if !output.isEmpty { try emit(output); output = Data() }
                dictionary.removeAll(keepingCapacity: false)
                prefix = nil
                finished = true
            }
        } catch {
            dictionary.removeAll(keepingCapacity: false)
            output = Data()
            finished = true
            throw error
        }
    }

    private func clear(emit: (Data) throws -> Void) throws {
        try put(256, emit: emit)
        // CLEAR を含む旧幅の group を丸ごと埋め、次は 9 bit literal から始める。
        try flushGroup(padded: true, emit: emit)
        dictionary.removeAll(keepingCapacity: true)
        nextCode = 257
        width = 9
        bestRatio = 0
        clearCount = try checkedAdd(clearCount, 1)
    }

    private func put(_ code: Int, emit: (Data) throws -> Void) throws {
        // LSB first。最大 16 bit の code は、byte 境界次第で三つの byte にまたがる。
        let byte = groupBits / 8, shift = groupBits & 7
        let bits = UInt32(code) << shift
        group[byte] |= UInt8(truncatingIfNeeded: bits)
        if byte + 1 < width { group[byte + 1] |= UInt8(truncatingIfNeeded: bits >> 8) }
        if byte + 2 < width { group[byte + 2] |= UInt8(truncatingIfNeeded: bits >> 16) }
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
        output.append(contentsOf: group.prefix(count))
        outputCount = try checkedAdd(outputCount, UInt64(count))
        group = [UInt8](repeating: 0, count: 16)
        groupBits = 0
        if output.count >= IOChunk.size {
            try emit(output)
            output.removeAll(keepingCapacity: true)
        }
    }
}
