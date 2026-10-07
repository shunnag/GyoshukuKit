// Independent implementation from RFC 8878; no zstd source consulted.
import Foundation
import XCTest
@testable import GyoshukuKit

final class ZstdEncoderTests: XCTestCase {
    private let tool = "/opt/homebrew/bin/zstd"
    private let levels = [1,3,9,19]

    func testSmallAndRLEAtAllRequestedLevels() throws {
        let directory = try TestSupport.directory("zstd-small")
        for level in levels {
            for (name, input) in [("empty", Data()), ("one", Data([0xA7])), ("zeros-64k", Data(repeating: 0, count: 64 << 10))] {
                let output = try EncoderTestTiming.measure("encode.ZstdFrameEncoder.encode", input: input.count) { try ZstdFrameEncoder.encode(input, level: level) }
                try verify(output, input: input, label: "\(name)-\(level)", directory: directory)
                if name == "zeros-64k" {
                    let headerSize = frameHeaderSize(output)
                    XCTAssertEqual((output[headerSize] >> 1) & 3, 1)
                    XCTAssertLessThan(output.count, 24)
                }
            }
        }
    }
    func testTextAndRandomWithOddPiecesAtAllRequestedLevels() throws { try verifyOddPieces(large: false) }

    func testTextAndRandomWithOddPiecesAtAllRequestedLevelsFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyOddPieces(large: true)
    }

    private static let smallText = LZMAEncoderCorpus.text(size: (128 << 10) + 17)
    private static let smallRandom = TestCorpus.random((256 << 10) + 17)

    private func verifyOddPieces(large: Bool) throws {
        let directory = try TestSupport.directory("zstd-large")
        for (name, input) in [("text", large ? LZMAEncoderCorpus.text(size: 1 << 20) : Self.smallText), ("random", large ? TestCorpus.random(8 << 20) : Self.smallRandom)] {
            for level in levels {
                let encoder = try ZstdFrameEncoder(level: level, contentSize: UInt64(input.count))
                let output = try StreamEncoderTestSupport.encode(input) { data, finish, emit in
                    try encoder.write(data, finish: finish, emit: emit)
                    XCTAssertLessThanOrEqual(encoder.pendingInputBytes, UInt64(ZstdFrameEncoder.blockSize))
                }
                try verify(output, input: input, label: "\(name)-\(level)", directory: directory)
                let types = blockTypes(output)
                if name == "random" { XCTAssertTrue(types.allSatisfy { $0 == 0 }, "random must fall back to raw") }
                else { XCTAssertTrue(types.contains(2)); XCTAssertLessThan(output.count, input.count / 2) }
            }
        }
    }
    func testTwentyMiBMixedCrossesWindowAndRawRLECompressedTransitions() throws { try verifyTransitions(large: false) }

    func testTwentyMiBMixedCrossesWindowAndRawRLECompressedTransitionsFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyTransitions(large: true)
    }

    private static let windowRandom = TestCorpus.random(128 << 10)
    // 文字範囲の異なる二つの ASCII 区間。単独 frame と混合入力で block 境界をずらす。
    private static let windowText = Data(TestCorpus.random(64 << 10, alphabetMask: 31).map { $0 + 32 })
        + Data(TestCorpus.random((64 << 10) + 17, alphabetMask: 31).map { $0 + 64 })
    private static let largeMixed = LZMAEncoderCorpus.mixed(size: 20 << 20)

    private func verifyTransitions(large: Bool) throws {
        let directory = try TestSupport.directory("zstd-mixed")
        for level in levels {
            let window = try ZstdEncoderProperties.preset(level).windowSize
            let input: Data
            if large { input = Self.largeMixed }
            else {
                // 乱数の距離は window + 64 KiB。text は window - 4096 先で、二つ目の全体が compact 後に入る。
                var mixed = Self.windowRandom
                mixed.append(Data(repeating: 0, count: window - Self.windowRandom.count / 2))
                mixed.append(Self.windowRandom)
                mixed.append(Self.windowText)
                mixed.append(Data(repeating: 0, count: window - Self.windowText.count - 4096))
                mixed.append(Self.windowText)
                input = mixed
            }
            XCTAssertGreaterThan(input.count, 2 * window + ZstdFrameEncoder.blockSize)
            // No size supplied: an explicit window descriptor and unknown content size.
            let encoder = try ZstdFrameEncoder(level: level)
            let output = try StreamEncoderTestSupport.encode(input) { try encoder.write($0, finish: $1, emit: $2) }
            try verify(output, input: input, label: "mixed-\(level)", directory: directory)
            let types = blockTypes(output)
            XCTAssertTrue(types.contains(0)); XCTAssertTrue(types.contains(2))
            if !large {
                XCTAssertTrue(types.contains(1))
                let singleTextSize = try ZstdFrameEncoder.encode(Self.windowText, level: level).count
                // window 外の乱数は再利用せず、window 内の text は再利用する。
                XCTAssertGreaterThan(output.count, 2 * Self.windowRandom.count, "level \(level)")
                XCTAssertLessThan(output.count, 2 * Self.windowRandom.count + singleTextSize, "level \(level)")
            }
        }
    }
    func testOptimalTreeBlockTailWithLongText() throws { try verifyTreeTail(large: false) }

    func testOptimalTreeBlockTailWithLongTextFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyTreeTail(large: true)
    }

    private static let treeText = LZMAEncoderCorpus.text(size: (256 << 10) + 17)
    private static let largeTreeText = LZMAEncoderCorpus.text(size: 4 << 20)

    private func verifyTreeTail(large: Bool) throws {
        let directory = try TestSupport.directory("zstd-tree-tail")
        // tree parser の各 128 KiB block の末尾と、17 byte の frame tail を通す。
        let input = large ? Self.largeTreeText : Self.treeText
        for level in [13,19] {
            let output = try EncoderTestTiming.measure("encode.ZstdFrameEncoder.encode", input: input.count) {
                try ZstdFrameEncoder.encode(input, level: level)
            }
            XCTAssertGreaterThanOrEqual(blockTypes(output).count, 3)
            XCTAssertTrue(blockTypes(output).contains(2))
            try verify(output, input: input, label: "text-\(level)", directory: directory)
        }
    }
    func testConcatenatedIndependentFramesAndInputPartitionDeterminism() throws {
        let directory = try TestSupport.directory("zstd-concatenated")
        let parts = [Data(), Data([1]), LZMAEncoderCorpus.text(size: 160_003), TestCorpus.random(131_073), Data(repeating: 7, count: 131_072)]
        var input = Data(), frames = Data()
        for (i, part) in parts.enumerated() {
            input.append(part)
            let level = levels[i % levels.count]
            let frame = try EncoderTestTiming.measure("encode.ZstdFrameEncoder.encode", input: part.count) { try ZstdFrameEncoder.encode(part, level: level) }
            let streaming = try ZstdFrameEncoder(level: level, contentSize: UInt64(part.count))
            let partitioned = try StreamEncoderTestSupport.encode(part) { try streaming.write($0, finish: $1, emit: $2) }
            XCTAssertEqual(frame, partitioned)
            frames.append(frame)
        }
        try verify(frames, input: input, label: "frames", directory: directory)
    }
    func testHeadersContentSizeAndTerminalErrors() throws {
        let directory = try TestSupport.directory("zstd-headers")
        for size in [0,1,255,256,65_791,65_792,131_071,131_072,131_073,1 << 20,(1 << 20) + 1] {
            let input = Data(repeating: 0xA3, count: size)
            let frame = try EncoderTestTiming.measure("encode.ZstdFrameEncoder.encode", input: input.count) { try ZstdFrameEncoder.encode(input, level: 1) }
            XCTAssertEqual(frame.prefix(4), Data([0x28,0xB5,0x2F,0xFD]))
            XCTAssertEqual(frame[4] & 4, 4)
            XCTAssertEqual(frame[4] & 3, 0)
            XCTAssertEqual(frame[4] & 32, size <= 1 << 20 ? 32 : 0)
            try verify(frame, input: input, label: "size-\(size)", directory: directory)
        }
        XCTAssertThrowsError(try ZstdFrameEncoder(level: 0)); XCTAssertThrowsError(try ZstdFrameEncoder(level: 20))
        let encoder = try ZstdFrameEncoder(contentSize: 1)
        XCTAssertThrowsError(try encoder.write(Data(), finish: true) { _ in })
        XCTAssertThrowsError(try encoder.write(Data([1])) { _ in })
        let excess = try ZstdFrameEncoder(contentSize: 0)
        XCTAssertThrowsError(try excess.write(Data([1])) { _ in })
        let complete = try ZstdFrameEncoder()
        try complete.write(Data(), finish: true) { _ in }
        XCTAssertThrowsError(try complete.write(Data()) { _ in })
        let failed = try ZstdFrameEncoder()
        XCTAssertThrowsError(try failed.write(Data([1])) { _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertThrowsError(try failed.write(Data(), finish: true) { _ in })
        let hugeSize = try ZstdFrameEncoder(level: 1, contentSize: UInt64.max)
        var header = Data()
        try hugeSize.write(Data([1])) { header.append($0) }
        XCTAssertEqual(header, Data([0x28,0xB5,0x2F,0xFD,0xC4,80] + [UInt8](repeating: 255, count: 8)))
    }
    func testEveryLevelAndShortPeriodicInputs() throws {
        let directory = try TestSupport.directory("zstd-periodic")
        for level in 1...19 {
            var input = Data()
            for period in 1...17 {
                let unit = Data((0..<period).map { UInt8($0 + 129) })
                for _ in 0..<67 { input.append(unit) }
            }
            input.append(TestCorpus.random(733))
            try verify(ZstdFrameEncoder.encode(input, level: level), input: input, label: "periodic-\(level)", directory: directory)
        }
    }
    func testCancellationMakesEncoderTerminal() async throws {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            let encoder = try ZstdFrameEncoder()
            for await _ in gate { }
            do {
                try encoder.write(Data(), finish: true) { _ in }
                return false
            } catch is CancellationError {
                do {
                    try encoder.write(Data(), finish: true) { _ in }
                    return false
                } catch let error as WriterError { return error == .invalidState }
            }
        }
        task.cancel(); continuation.finish()
        let terminal = try await task.value
        XCTAssertTrue(terminal)
    }
    func testHuffmanOneAndFourStreamsWithDirectAndFSEWeights() throws {
        let directory = try TestSupport.directory("zstd-huffman")
        for size in [997,16_383,16_384,131_072] {
            for highBytes in [false,true] {
                var random = TestCorpus.XorShift64(state: 0x8743_2211)
                let bytes = Data((0..<size).map { _ in
                    let n = random.next()
                    return UInt8(n & 7 == 0 ? (highBytes ? (n >> 8) & 255 : (n >> 8) & 127) : n & 3)
                })
                let literals = ZstdHuffmanEncoder.literals(bytes)
                XCTAssertEqual(literals[0] & 3, 2)
                let payload = literals + Data([0])
                let frame = manualFrame(payload, input: bytes)
                try verify(frame, input: bytes, label: "huffman-\(size)-\(highBytes)", directory: directory)
            }
        }
    }
    func testSequenceLengthCodesRepeatRulesAndFSETables() throws {
        let directory = try TestSupport.directory("zstd-sequences")
        // All length-code boundaries; many offset symbols and both nonempty/empty literal runs.
        var input = Data(), literals = Data(), sequences: [ZstdSequence] = []
        let seed = TestCorpus.random(2048)
        input.append(seed); literals.append(seed)
        let lengths = Array(3...36) + [37,38,39,40,41,42,43,46,47,50,51,58,59,66,67,82,83,98,99,130,131,258,259,514,515,1026,1027,2050,2051,4098,4099,8194,8195,16386,16387,32770]
        for (i, length) in lengths.enumerated() {
            let distance = min(input.count, 1 << (i % 12))
            let ll = i == 0 ? seed.count : i % 3 == 0 ? i % 33 : 0
            if i != 0 && ll > 0 { let data = TestCorpus.random(ll); input.append(data); literals.append(data) }
            sequences.append(ZstdSequence(literals: ll, length: length, distance: distance))
            for _ in 0..<length { input.append(input[input.count - distance]) }
        }
        XCTAssertLessThanOrEqual(input.count, 131_072)
        var repeats = ZstdRepeatOffsets()
        let section = ZstdSequences.encode(sequences, repeats: &repeats)
        try verify(manualFrame(ZstdHuffmanEncoder.literals(literals) + section, input: input), input: input,
                   label: "lengths", directory: directory)
        var reps = ZstdRepeatOffsets()
        XCTAssertEqual(reps.value(distance: 1, literals: 2), 1)
        XCTAssertEqual(reps.value(distance: 4, literals: 0), 1)
        XCTAssertEqual(reps.a, 4)
        XCTAssertEqual(reps.value(distance: 8, literals: 0), 2)
        XCTAssertEqual(reps.value(distance: 7, literals: 0), 3)
        XCTAssertEqual(reps.a, 7); XCTAssertEqual(reps.b, 8); XCTAssertEqual(reps.c, 4)
        XCTAssertEqual(reps.value(distance: 4, literals: 2), 3)
        XCTAssertEqual(reps.value(distance: 8, literals: 2), 3)
        XCTAssertEqual(reps.value(distance: 8, literals: 0), 11)
    }
    func testSequenceCountOneTwoThreeByteHeadersAndRLETables() throws {
        let directory = try TestSupport.directory("zstd-sequence-count")
        for n in [1,127,128,0x7EFF,0x7F00,43_690] {
            let input = Data(repeating: 0x9B, count: 1 + 3 * n)
            var sequences = [ZstdSequence](repeating: ZstdSequence(literals: 0, length: 3, distance: 1), count: n)
            sequences[0].literals = 1
            var repeats = ZstdRepeatOffsets()
            let section = ZstdSequences.encode(sequences, repeats: &repeats)
            if n < 128 { XCTAssertEqual(section[0], UInt8(n)) }
            else if n < 0x7F00 { XCTAssertEqual(section[0], UInt8(128 + (n >> 8))) }
            else { XCTAssertEqual(section[0], 255) }
            try verify(manualFrame(ZstdHuffmanEncoder.literals(Data([0x9B])) + section, input: input),
                       input: input, label: "count-\(n)", directory: directory)
        }
    }
    private func verify(_ output: Data, input: Data, label: String, directory: URL) throws {
        let url = directory.appendingPathComponent(label + ".zst")
        try output.write(to: url)
        try ReferenceTool.run(tool, ["-t", url.path], in: directory, log: label + "-test")
        try StreamEncoderTestSupport.assertCLI(tool, arguments: ["-dc"], url: url, input: input, in: directory, label: label + "-decode")
        try StreamEncoderTestSupport.assertKaito(url, equals: input)
    }
    /// Test-owned wire framing, independent of the product's frame serializer.
    private func manualFrame(_ payload: Data, input: Data) -> Data {
        // Explicit 128 KiB window also permits tiny inputs with a larger compressed section.
        var frame = Data([0x28,0xB5,0x2F,0xFD,0x84,56])
        let size = UInt32(input.count)
        for i in 0..<4 { frame.append(UInt8(truncatingIfNeeded: size >> (i * 8))) }
        let block = (payload.count << 3) | 5
        for i in 0..<3 { frame.append(UInt8(truncatingIfNeeded: block >> (i * 8))) }
        frame.append(payload)
        var hash = ZstdXXH64(); hash.update(input)
        for i in 0..<4 { frame.append(UInt8(truncatingIfNeeded: hash.digest() >> (i * 8))) }
        return frame
    }
    private func frameHeaderSize(_ frame: Data) -> Int {
        let d = frame[4], single = d & 32 != 0
        let sizeBytes = [single ? 1 : 0,2,4,8][Int(d >> 6)]
        return 5 + (single ? 0 : 1) + sizeBytes
    }
    private func blockTypes(_ frame: Data) -> [Int] {
        var cursor = frameHeaderSize(frame), types: [Int] = []
        while cursor + 3 <= frame.count - 4 {
            let h = Int(frame[cursor]) | (Int(frame[cursor + 1]) << 8) | (Int(frame[cursor + 2]) << 16)
            let type = (h >> 1) & 3
            types.append(type); cursor += 3 + (type == 1 ? 1 : h >> 3)
            if h & 1 != 0 { break }
        }
        XCTAssertEqual(cursor, frame.count - 4)
        return types
    }
}
