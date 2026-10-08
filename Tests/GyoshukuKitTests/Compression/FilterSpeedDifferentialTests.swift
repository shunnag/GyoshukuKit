import Foundation
import XCTest
@testable import GyoshukuKit

final class FilterSpeedDifferentialTests: XCTestCase {
    func testDeltaEveryDistanceAndRandomTinyPushes() {
        var random = Random(seed: 0xDE17_A)
        let input = random.data(2053)
        for distance in 1...256 {
            compareFilter(.delta(distance), input: input, random: &random)
            // 履歴より短い入力と、距離ちょうどの境界も各距離で確認する。
            for count in [0, 1, distance - 1, distance, distance + 1] {
                compareFilter(.delta(distance), input: input.prefix(count), random: &random)
            }
        }
    }

    func testBCJX86DenseBranchesAndOddStartOffsets() {
        var random = Random(seed: 0x86BC_0123)
        var dense = Data()
        for _ in 0..<4000 {
            // 重なった E8/E9、符号 byte 0/FF、変換を拒否する上位 byte を混ぜる。
            let choices: [UInt8] = [0xE8, 0xE9, 0, 0xFF, UInt8(truncatingIfNeeded: random.next())]
            for _ in 0..<5 { dense.append(choices[Int(random.next() % UInt64(choices.count))]) }
        }
        for start: UInt32 in [0, 1, 3, 0xFFF, 0xFFFF_FFFD] {
            compareFilter(.x86(start), input: dense, random: &random)
            for count in 0...32 { compareFilter(.x86(start), input: dense.prefix(count), random: &random) }
        }
        // operand 内で次の branch 候補を拒否する mask と、再変換の符号判定を通す。
        let overlapping = Data([0xE8, 0xE8, 0xE9, 0xFF, 0, 0xE9, 0, 0xFF, 0xE8, 0xFF, 0, 0, 0xE8, 0xFF, 0xFF, 0xFF, 0xFF])
        for start: UInt32 in [1, 0x00FF_FFFA, 0x7FFF_FFFD, 0xFFFF_FFFE] {
            compareFilter(.x86(start), input: overlapping, random: &random, exhaustive: true)
        }
    }

    func testBCJARM64DenseBLADRPAndOddStartOffsets() {
        var random = Random(seed: 0xA64B_C)
        var dense = Data()
        for index in 0..<6000 {
            let immediate = UInt32(truncatingIfNeeded: random.next())
            let instruction: UInt32
            switch index % 5 {
            case 0: instruction = 0x9400_0000 | (immediate & 0x03FF_FFFF)
            case 1: instruction = adrp(immediate & 0x1_FFFF, register: immediate & 31)
            case 2: instruction = adrp(0x1E_0000 | (immediate & 0x1_FFFF), register: immediate & 31)
            case 3: instruction = adrp(0x2_0000 + immediate % 0x1C_0000, register: immediate & 31)
            default: instruction = immediate
            }
            var word = instruction.littleEndian
            withUnsafeBytes(of: &word) { dense.append(contentsOf: $0) }
        }
        for start: UInt32 in [0, 1, 3, 0xFFF, 0xFFFF_FFFD] {
            compareFilter(.arm64(start), input: dense, random: &random)
            for count in 0...17 { compareFilter(.arm64(start), input: dense.prefix(count), random: &random, exhaustive: true) }
        }
    }

    func testLHACRC16RandomLengthsAlignmentsAndInitialValues() {
        var random = Random(seed: 0xC16_1234)
        let storage = random.data(16_400)
        let lengths = Array(0...40) + [63, 64, 65, 255, 256, 257, 4095, 4096, 4097, 16_384]
            + (0..<100).map { _ in Int(random.next() % 16_385) }
        for alignment in 0..<16 {
            for length in lengths {
                let input = storage[alignment..<(alignment + length)]
                for initial in [UInt16(0), 0xFFFF, UInt16(truncatingIfNeeded: random.next())] {
                    XCTAssertEqual(LHACRC16.update(initial, input), ReferenceLHACRC16.update(initial, input),
                                   "length=\(length), alignment=\(alignment), initial=\(initial)")
                }
            }
        }
        var actual: UInt16 = 0, expected: UInt16 = 0, offset = 0
        while offset < storage.count {
            let count = min(storage.count - offset, Int(random.next() % 37) + 1)
            let chunk = storage[offset..<(offset + count)]
            actual = LHACRC16.update(actual, chunk)
            expected = ReferenceLHACRC16.update(expected, chunk)
            XCTAssertEqual(actual, expected)
            offset += count
        }
    }

    func testLH5BitsAppendEveryRemainderAndWordBoundary() {
        var random = Random(seed: 0xB175_5678)
        let lengths = Array(0...25) + [31, 32, 33, 63, 64, 65, 255, 1025, 65_537]
        for leading in 0...7 {
            for trailing in 0...7 {
                for length in lengths {
                    var actual = LH5Encoder.Bits(), expected = ReferenceLH5Bits()
                    let first = Int(random.next() & ((1 << leading) - 1))
                    actual.write(first, count: leading); expected.write(first, count: leading)
                    // 既存の complete byte がある場合も追記先が正しいことを見る。
                    actual.write(0xD3, count: 8); expected.write(0xD3, count: 8)
                    let bytes = random.data(length)
                    let tail = random.next() & ((1 << trailing) - 1)
                    actual.append(bytes, remainder: .init(value: tail, count: trailing))
                    expected.append(bytes, remainder: .init(value: tail, count: trailing))
                    XCTAssertEqual(actual.remainder.count, expected.remainder.count)
                    XCTAssertEqual(actual.remainder.value, expected.remainder.value)
                    XCTAssertEqual(actual.takeCompleteBytes(), expected.takeCompleteBytes(),
                                   "leading=\(leading), trailing=\(trailing), length=\(length)")
                    // spool への取出し後にも端数を持ち越し、finish の padding まで一致させる。
                    for _ in 0..<9 {
                        let count = Int(random.next() % 8), tail = random.next() & ((1 << count) - 1)
                        let bytes = random.data(Int(random.next() % 31))
                        actual.append(bytes, remainder: .init(value: tail, count: count))
                        expected.append(bytes, remainder: .init(value: tail, count: count))
                        XCTAssertEqual(actual.takeCompleteBytes(), expected.takeCompleteBytes())
                    }
                    XCTAssertEqual(actual.finish(), expected.finish())
                }
            }
        }
    }

    func testLZWMaxbits12Through16TextRandomAndClearWithPushSplits() throws {
        var random = Random(seed: 0x12_16_2A)
        let text = Data(String(repeating: "Swift LZW 辞書、幅変更、CLEAR と bit group の比較。0123456789\n", count: 1800).utf8)
        let noise = random.data(524_291)
        let samples = [text, noise, text + noise + text]
        for maxbits in 12...16 {
            for (index, input) in samples.enumerated() {
                let reference = try ReferenceLZWStreamEncoder(maxbits: maxbits)
                var expected = Data()
                try reference.write(input, finish: true) { expected.append($0) }
                if index == 2 { XCTAssertGreaterThan(reference.clearCount, 0, "maxbits=\(maxbits)") }
                for split in [false, true] {
                    let encoder = try LZWStreamEncoder(maxbits: maxbits)
                    let old = try ReferenceLZWStreamEncoder(maxbits: maxbits)
                    var actual = Data(), chunkedReference = Data(), offset = 0, calls = 0
                    while offset < input.count {
                        let requested = split ? Int(random.next() % (calls % 7 == 0 ? 4 : 8192)) + 1 : input.count
                        let count = min(input.count - offset, requested)
                        let chunk = input[offset..<(offset + count)]
                        try encoder.write(chunk) { actual.append($0) }
                        try old.write(chunk) { chunkedReference.append($0) }
                        XCTAssertEqual(actual, chunkedReference)
                        XCTAssertEqual(encoder.clearCount, old.clearCount)
                        offset += count; calls += 1
                    }
                    try encoder.write(Data(), finish: true) { actual.append($0) }
                    try old.write(Data(), finish: true) { chunkedReference.append($0) }
                    XCTAssertEqual(actual, expected, "maxbits=\(maxbits), sample=\(index), split=\(split)")
                    XCTAssertEqual(actual, chunkedReference)
                    XCTAssertEqual(encoder.clearCount, reference.clearCount)
                }
            }
            // EOF の partial group と、毎回1〜4 byteだけを渡す辞書成長。
            for length in Array(0...17) + [255, 256, 257, 511, 512, 513, 4097] {
                let input = noise.prefix(length)
                let encoder = try LZWStreamEncoder(maxbits: maxbits), old = try ReferenceLZWStreamEncoder(maxbits: maxbits)
                var actual = Data(), expected = Data(), offset = 0
                try encoder.write(Data()) { actual.append($0) }
                while offset < length {
                    let end = min(length, offset + Int(random.next() % 4) + 1)
                    try encoder.write(input[offset..<end]) { actual.append($0) }
                    try old.write(input[offset..<end]) { expected.append($0) }
                    offset = end
                }
                try encoder.write(Data(), finish: true) { actual.append($0) }
                try old.write(Data(), finish: true) { expected.append($0) }
                XCTAssertEqual(actual, expected, "maxbits=\(maxbits), length=\(length)")
            }
        }
    }

    private func adrp(_ immediate: UInt32, register: UInt32) -> UInt32 {
        0x9000_0000 | (immediate & 3) << 29 | ((immediate >> 2) & 0x7_FFFF) << 5 | register
    }

    private func compareFilter(_ filter: SevenZipWriteFilter, input: Data, random: inout Random, exhaustive: Bool = false) {
        let whole = ReferenceSevenZipFilterEncoder(filter).push(input, final: true)
        let policies = exhaustive ? Array(1...max(1, input.count)) : [1, 4, 509, max(1, input.count)]
        for maximum in policies {
            let actual = SevenZipFilterEncoder(filter), reference = ReferenceSevenZipFilterEncoder(filter)
            var output = Data(), offset = input.startIndex
            while offset < input.endIndex {
                let end = min(input.endIndex, offset + Int(random.next() % UInt64(maximum)) + 1)
                let final = end == input.endIndex && random.next() & 1 == 0
                let chunk = input[offset..<end]
                let bytes = actual.push(chunk, final: final)
                XCTAssertEqual(bytes, reference.push(chunk, final: final), "\(filter), maximum=\(maximum), offset=\(offset)")
                output.append(bytes)
                XCTAssertEqual(actual.push(Data(), final: false), reference.push(Data(), final: false))
                offset = end
            }
            let bytes = actual.push(Data(), final: true)
            XCTAssertEqual(bytes, reference.push(Data(), final: true))
            output.append(bytes)
            XCTAssertEqual(output, whole, "\(filter), maximum=\(maximum), count=\(input.count)")
        }
    }

    private struct Random {
        var seed: UInt64
        mutating func next() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        mutating func data(_ count: Int) -> Data {
            Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) })
        }
    }
}
