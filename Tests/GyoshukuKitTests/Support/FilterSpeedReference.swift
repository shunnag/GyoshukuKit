import Foundation
@testable import GyoshukuKit

// speed2 最適化前の実装をそのまま残す差分試験専用の参照。製品側の高速経路は再利用しない。
final class ReferenceSevenZipFilterEncoder {
    private let filter: SevenZipWriteFilter
    private var pending: [UInt8] = []
    private var offset: UInt32 = 0
    private var x86State: UInt32 = 0
    private var history = [UInt8](repeating: 0, count: 256)
    private var historyPosition = 0

    init(_ filter: SevenZipWriteFilter) {
        self.filter = filter
        switch filter { case .x86(let start), .arm64(let start): offset = start; default: break }
    }

    func push(_ data: Data, final: Bool) -> Data {
        pending.append(contentsOf: data)
        let consumed: Int
        switch filter {
        case .none: consumed = pending.count
        case .delta(let distance):
            for i in pending.indices {
                let value = pending[i]
                pending[i] = value &- history[historyPosition]
                history[historyPosition] = value
                historyPosition = (historyPosition + 1) % distance
            }
            consumed = pending.count
        case .x86: consumed = encodeX86()
        case .arm64: consumed = encodeARM64()
        }
        let count = final ? pending.count : consumed
        let output = Data(pending.prefix(count))
        pending.removeFirst(count)
        offset &+= UInt32(truncatingIfNeeded: count)
        return output
    }

    private static func uint32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private func put(_ value: UInt32, at i: Int) {
        for byte in 0..<4 { pending[i + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
    }
    private func signByte(_ value: UInt8) -> Bool { value == 0 || value == 0xFF }

    private func encodeX86() -> Int {
        guard pending.count >= 5 else { return 0 }
        let allowed = [true, true, true, false, true, false, false, false]
        let bits = [0, 1, 2, 2, 3, 3, 3, 3]
        let limit = pending.count - 4
        let base = offset &+ 5
        var position = 0, previous = -1, mask = Int(x86State & 7)
        while true {
            while position < limit, pending[position] & 0xFE != 0xE8 { position += 1 }
            guard position < limit else { break }
            let distance = position - previous
            if distance > 3 { mask = 0 }
            else {
                mask = (mask << (distance - 1)) & 7
                if mask != 0, !allowed[mask] || signByte(pending[position + 4 - bits[mask]]) {
                    previous = position; mask = ((mask << 1) | 1) & 7; position += 1
                    continue
                }
            }
            previous = position
            if signByte(pending[position + 4]) {
                var source = Self.uint32(pending, position + 1)
                var destination: UInt32
                while true {
                    destination = source &+ (base &+ UInt32(truncatingIfNeeded: position))
                    guard mask != 0 else { break }
                    let shift = bits[mask] * 8
                    guard signByte(UInt8(truncatingIfNeeded: destination >> (24 - shift))) else { break }
                    source = destination ^ ((UInt32(1) << (32 - shift)) &- 1)
                }
                // BCJ は25 bitの変位。bit 24を上位byteへ符号拡張する。
                destination = (destination & 0x00FF_FFFF) | (destination & 0x0100_0000 == 0 ? 0 : 0xFF00_0000)
                put(destination, at: position + 1)
                position += 5
            } else { mask = ((mask << 1) | 1) & 7; position += 1 }
        }
        let distance = position - previous
        x86State = distance > 3 ? 0 : UInt32((mask << (distance - 1)) & 7)
        return position
    }

    private func encodeARM64() -> Int {
        let count = pending.count & ~3
        for i in stride(from: 0, to: count, by: 4) {
            var instruction = Self.uint32(pending, i)
            let pc = offset &+ UInt32(truncatingIfNeeded: i)
            if instruction & 0xFC00_0000 == 0x9400_0000 {
                instruction = 0x9400_0000 | ((instruction &+ (pc >> 2)) & 0x03FF_FFFF)
                put(instruction, at: i)
            } else if instruction & 0x9F00_0000 == 0x9000_0000 {
                let immediate = ((instruction >> 29) & 3) | (((instruction >> 5) & 0x7_FFFF) << 2)
                guard immediate < 0x2_0000 || immediate >= 0x1E_0000 else { continue }
                var encoded = (immediate &+ (pc >> 12)) & 0x3_FFFF
                if encoded & 0x2_0000 != 0 { encoded |= 0x1C_0000 }
                instruction &= ~UInt32(0x60FF_FFE0)
                instruction |= (encoded & 3) << 29 | ((encoded >> 2) & 0x7_FFFF) << 5
                put(instruction, at: i)
            }
        }
        return count
    }
}

// data と header は同じ CRC-16/ARC。反射形 0xA001、初期値 0、終端 XOR なし。
enum ReferenceLHACRC16 {
    private static let table: [UInt16] = (0..<256).map { value in
        var crc = UInt16(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xA001) }
        return crc
    }

    static func update(_ initial: UInt16 = 0, _ data: Data) -> UInt16 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var crc = initial
            for byte in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)] }
            return crc
        }
    }
}

struct ReferenceLH5Bits {
    struct Remainder: Sendable {
        let value: UInt64
        let count: Int
    }

    private var bytes: [UInt8] = []
    private var pending: UInt64 = 0
    private var available = 0

    var remainder: Remainder { Remainder(value: pending, count: available) }

    mutating func append(_ completeBytes: Data, remainder: Remainder) {
        precondition((0..<8).contains(remainder.count) && remainder.value < (1 << remainder.count))
        bytes.reserveCapacity(bytes.count + completeBytes.count + 1)
        if available == 0 {
            bytes.append(contentsOf: completeBytes)
        } else {
            // 境界に padding を入れず、前の端数 bit と次の byte を順に継ぐ。
            let shift = 8 - available, mask = UInt64((1 << available) - 1)
            for byte in completeBytes {
                bytes.append(UInt8(truncatingIfNeeded: (pending << shift) | UInt64(byte >> available)))
                pending = UInt64(byte) & mask
            }
        }
        write(Int(remainder.value), count: remainder.count)
    }

    mutating func write(_ value: Int, count: Int) {
        guard count > 0 else { return }
        // LHA は MSB first。canonical code を反転する deflate の規約とは異なる。
        pending = (pending << count) | UInt64(value)
        available += count
        while available >= 8 {
            available -= 8
            bytes.append(UInt8(truncatingIfNeeded: pending >> available))
        }
        pending &= (1 << available) - 1
    }

    mutating func finish() -> Data {
        if available > 0 { write(0, count: 8 - available) }
        return takeCompleteBytes()
    }

    mutating func takeCompleteBytes() -> Data {
        let result = Data(bytes)
        bytes.removeAll(keepingCapacity: true)
        return result
    }
}



// 出典: UNIX compress の公開形式説明と Welch の LZW 辞書規則からの独立実装。
// https://ciderpress2.com/formatdoc/LZC-notes.html （header / 8-code group / padding）
// https://man.openbsd.org/compress.1 （maxbits / 圧縮率による辞書 reset）
// Welch, “A Technique for High Performance Data Compression”, IEEE Computer 17(6), 1984.
// KaitoKit Codecs/LZW/LZWDecoder.swift の幅変更・CLEAR の group 廃棄を読み、互換性を確認。
// 既存 codec の翻訳や vendoring は行わず、OS library も使わない。
final class ReferenceLZWStreamEncoder {
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
