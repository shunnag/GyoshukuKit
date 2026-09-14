import Foundation
import XCTest
@testable import GyoshukuKit

@MainActor
final class LH5EncoderTests: XCTestCase {
    func testMaximumLengthAndFullWindowDistance() throws {
        let seed = LHATestSupport.random(8192)
        let data = seed + seed.prefix(256) + Data([seed[256] ^ 0xFF]) + Data(repeating: 0xAB, count: 20_000)
        let encoded = try LH5Encoder.encode(data)
        let stream = try LH5Stream(encoded, size: data.count)
        XCTAssertTrue(stream.matches.contains { $0.offset == 8192 && $0.length == 256 && $0.distance == 8192 })
        XCTAssertEqual(stream.matches.map(\.length).max(), 256)
        try verify("lha-maximum-match", data: data, encoded: encoded)
    }

    func testMultipleBlocksWithoutBitAlignmentOrDictionaryReset() throws {
        let data = LHATestSupport.random(400_000, alphabetMask: 31)
        let encoded = try LH5Encoder.encode(data)
        XCTAssertLessThan(encoded.count, data.count)
        let stream = try LH5Stream(encoded, size: data.count)
        XCTAssertGreaterThan(stream.blocks.count, 1)
        XCTAssertTrue(stream.blocks.dropLast().allSatisfy { $0.count == 32_768 })
        XCTAssertTrue(stream.blocks.dropFirst().contains { $0.bitOffset % 8 != 0 })
        for block in stream.blocks.dropFirst() {
            XCTAssertTrue(stream.matches.contains { $0.offset >= block.outputOffset && $0.offset - $0.distance < block.outputOffset })
        }
        try verify("lha-multiple-blocks", data: data, encoded: encoded)
    }

    func testRepeatedByteCreatesConstantTreesAfterBlockBoundary() throws {
        let data = Data(repeating: 0xF0, count: 1 + 256 * (32_768 + 400))
        let encoded = try LH5Encoder.encode(data)
        let stream = try LH5Stream(encoded, size: data.count)
        XCTAssertEqual(stream.blocks.count, 2)
        XCTAssertEqual(stream.blocks.last?.commandConstant, 509)
        XCTAssertTrue(stream.blocks.allSatisfy { $0.positionConstant == 0 })
        try verify("lha-constant-match", data: data, encoded: encoded)
    }

    func testConstantLiteralAndConstantCodeLengthTrees() throws {
        for (index, data) in [Data(repeating: 0xA5, count: 1000), Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })].enumerated() {
            var bits = LH5Encoder.Bits()
            try LH5Encoder.writeBlock(data.map { .init(symbol: Int($0), position: 0) }, to: &bits)
            let encoded = bits.finish()
            let stream = try LH5Stream(encoded, size: data.count)
            if index == 0 {
                XCTAssertEqual(stream.blocks.first?.commandConstant, 0xA5)
                XCTAssertEqual(encoded.count, 7)
            } else {
                XCTAssertEqual(stream.blocks.first?.lengthConstant, 10) // 全 256 literal の長さは 8。
            }
            try verify("lha-constant-tree-\(index)", data: data, encoded: encoded)
        }
    }

    func testLengthLimitedCanonicalHuffmanWithSkewedFrequencies() throws {
        var frequencies = [Int](repeating: 0, count: 510)
        frequencies[0] = 1
        frequencies[1] = 1
        for index in 2..<21 { frequencies[index] = frequencies[index - 1] + frequencies[index - 2] }
        let tree = LH5Encoder.Huffman(frequencies)
        XCTAssertEqual(tree.lengths.max(), 16)
        XCTAssertEqual(tree.lengths.filter { $0 > 0 }.reduce(0) { $0 + (1 << (16 - $1)) }, 1 << 16)
        XCTAssertTrue(tree.lengths.dropFirst(21).allSatisfy { $0 == 0 })
        // LZSS の頻度変化を避け、実際の制限付き木を三つの decoder に渡す。
        var data = Data()
        for symbol in 0..<21 { data.append(Data(repeating: UInt8(symbol), count: frequencies[symbol])) }
        var bits = LH5Encoder.Bits()
        try LH5Encoder.writeBlock(data.map { .init(symbol: Int($0), position: 0) }, to: &bits)
        let encoded = bits.finish()
        XCTAssertEqual(try LH5Stream(encoded, size: data.count).maximumLength, 16)
        try verify("lha-limited-huffman", data: data, encoded: encoded)
    }

    func testCommandLengthZeroRunBoundaries() throws {
        for run in [1, 2, 3, 18, 19, 20, 254] {
            let data = Data([0, UInt8(run + 1), 0, UInt8(run + 1)])
            var bits = LH5Encoder.Bits()
            try LH5Encoder.writeBlock(data.map { .init(symbol: Int($0), position: 0) }, to: &bits)
            let encoded = bits.finish()
            _ = try LH5Stream(encoded, size: data.count)
            try verify("lha-zero-run-\(run)", data: data, encoded: encoded)
        }
    }

    func testTenMiBCompressionTimeAndRoundTrip() throws {
        // 履歴と一致しにくい入力も探索させる。単色だけの計測では全履歴を走査する実装を見逃す。
        let data = LHATestSupport.random(10 * 1024 * 1024, alphabetMask: 63)
        let directory = try ZipTestSupport.directory("lha-performance")
        let url = directory.appendingPathComponent("archive.lzh")
        let start = ContinuousClock.now
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        try writer.add(data: data, as: "ten-mib.bin", modificationDate: ZipTestSupport.date)
        try writer.finish()
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(30))
        ZipTestSupport.report("LHA PERFORMANCE: 10 MiB in \(elapsed), debug build; bound 30 seconds")
        XCTAssertEqual(try LHABytes(Data(contentsOf: url)).members.first?.method, "-lh5-")
        try LHATestSupport.verify(url, expected: [.init(name: "ten-mib.bin", data: data)])
    }

    private func verify(_ label: String, data: Data, encoded: Data) throws {
        let directory = try ZipTestSupport.directory(label)
        let url = directory.appendingPathComponent("archive.lzh")
        let entry = try LHARecords.Entry(name: "encoded.bin", mode: 0o100644, size: UInt64(data.count), date: ZipTestSupport.date)
        let header = try entry.header(method: "-lh5-", packedSize: UInt32(encoded.count), crc: LHATestSupport.crc(data))
        try (header + encoded + Data([0])).write(to: url)
        try LHATestSupport.verify(url, expected: [.init(name: "encoded.bin", data: data)])
    }
}

// テスト入力が本当に block 境界・最大距離・固定木を通ったことを、wire の bit 列から検査する。
// compressor の token や table は再利用せず、1 bit ずつ canonical code を探す。
struct LH5Stream {
    struct Block {
        let count: Int
        let bitOffset: Int
        let outputOffset: Int
        let commandConstant: Int?
        let positionConstant: Int?
        let lengthConstant: Int?
    }
    struct Match {
        let offset: Int
        let length: Int
        let distance: Int
    }
    var blocks: [Block] = []
    var matches: [Match] = []
    var maximumLength = 0

    init(_ data: Data, size: Int) throws {
        var bits = Cursor(bytes: Array(data))
        var produced = 0
        while produced < size {
            let start = bits.offset
            let count = try bits.read(16)
            guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let lengths = try bits.pt(symbols: 19, width: 5, special: true)
            let encodedCount = try bits.read(9)
            let commands: Tree
            if encodedCount == 0 {
                commands = Tree(constant: try bits.read(9))
            } else {
                var values: [Int] = []
                while values.count < encodedCount {
                    let symbol = try bits.symbol(lengths)
                    if symbol > 2 {
                        values.append(symbol - 2)
                    } else {
                        let run = symbol == 0 ? 1 : try bits.read(symbol == 1 ? 4 : 9) + (symbol == 1 ? 3 : 20)
                        values.append(contentsOf: repeatElement(0, count: run))
                    }
                }
                XCTAssertEqual(values.count, encodedCount)
                commands = try Tree(lengths: values)
            }
            let positions = try bits.pt(symbols: 14, width: 4, special: false)
            maximumLength = max(maximumLength, lengths.maximum, commands.maximum, positions.maximum)
            blocks.append(Block(count: count, bitOffset: start, outputOffset: produced,
                                commandConstant: commands.constant, positionConstant: positions.constant,
                                lengthConstant: lengths.constant))
            for _ in 0..<count {
                let symbol = try bits.symbol(commands)
                if symbol < 256 {
                    produced += 1
                } else {
                    let length = symbol - 253
                    let position = try bits.symbol(positions)
                    let distance = position == 0 ? 1 : (1 << (position - 1)) + (try bits.read(position - 1)) + 1
                    XCTAssertTrue((3...256).contains(length))
                    XCTAssertTrue((1...8192).contains(distance))
                    matches.append(Match(offset: produced, length: length, distance: distance))
                    produced += length
                }
            }
        }
        XCTAssertEqual(produced, size)
        XCTAssertLessThan(data.count * 8 - bits.offset, 8)
        XCTAssertEqual(try bits.read(data.count * 8 - bits.offset), 0)
    }

    private struct Tree {
        var constant: Int?
        var symbols: [Int: Int] = [:]
        var maximum = 0

        init(constant: Int) { self.constant = constant }

        init(lengths: [Int]) throws {
            let sorted = lengths.indices.filter { lengths[$0] > 0 }.sorted {
                lengths[$0] == lengths[$1] ? $0 < $1 : lengths[$0] < lengths[$1]
            }
            var previous = 0
            var code = 0
            for symbol in sorted {
                let length = lengths[symbol]
                guard length <= 16 else { throw CocoaError(.fileReadCorruptFile) }
                code <<= length - previous
                symbols[(1 << length) | code] = symbol
                code += 1
                previous = length
            }
            maximum = previous
            XCTAssertEqual(code, 1 << previous)
        }
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0

        mutating func read(_ count: Int) throws -> Int {
            guard count >= 0, count <= 16, offset + count <= bytes.count * 8 else { throw CocoaError(.fileReadCorruptFile) }
            var value = 0
            for _ in 0..<count {
                value = value * 2 + Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }

        mutating func symbol(_ tree: Tree) throws -> Int {
            if let symbol = tree.constant { return symbol }
            var key = 1
            for _ in 1...16 {
                key = key * 2 + (try read(1))
                if let symbol = tree.symbols[key] { return symbol }
            }
            throw CocoaError(.fileReadCorruptFile)
        }

        mutating func pt(symbols: Int, width: Int, special: Bool) throws -> Tree {
            let count = try read(width)
            if count == 0 { return Tree(constant: try read(width)) }
            guard count <= symbols else { throw CocoaError(.fileReadCorruptFile) }
            var values: [Int] = []
            while values.count < count {
                var length = try read(3)
                if length == 7 { while try read(1) == 1 { length += 1 } }
                values.append(length)
                if special, values.count == 3 {
                    values.append(contentsOf: repeatElement(0, count: try read(2)))
                }
            }
            XCTAssertEqual(values.count, count)
            return try Tree(lengths: values)
        }
    }
}
