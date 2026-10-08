import Foundation
import CGyoshukuBzip2
import Synchronization
import XCTest
@testable import GyoshukuKit

final class Bzip2SpliceTests: XCTestCase {
    func testRandomTextAndExactBlockIdentityAtLevels1And5And9() throws {
        for level in [1, 5, 9] {
            let limit = 100_000 * level - 19
            let random = TestCorpus.random(2 * limit + 137)
            let text = Data(String(repeating: "bzip2 block boundary 日本語 0123456789\n", count: limit / 15).utf8)
            let exact = alternating(limit)
            for input in [random, text, exact, alternating(limit + 1)] {
                try assertIdentity(input, level: level)
            }
        }
    }

    func testRunsNearEveryPredictedBoundary() throws {
        try assertRunIdentity(level: 1, lengths: [3, 4, 5, 254, 255, 256, 1000], offsets: [-2, 0, 2])
    }

    func testRunsAtAllLevelsAndOffsetsFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        for level in [1, 5, 9] {
            try assertRunIdentity(level: level, lengths: [3, 4, 5, 254, 255, 256, 1000], offsets: Array(-2...2))
        }
    }

    func testOddReadsAndMultiBlockChunksKeepIdentity() throws {
        let input = TestCorpus.random(1_300_013)
        let expected = try Bzip2StreamEncoder.encode(input, level: 1)
        for threads in [2, 7] {
            let encoder = try ParallelBzip2StreamEncoder(level: 1, threads: threads, chunkSize: 499_905)
            var output = Data()
            for offset in stride(from: 0, to: input.count, by: 32_771) {
                try encoder.write(input.subdata(in: offset..<min(offset + 32_771, input.count)), finish: false) { output.append($0) }
            }
            try encoder.write(Data(), finish: true) { output.append($0) }
            XCTAssertEqual(encoder.forcedCuts, 0)
            XCTAssertEqual(output, expected)
            XCTAssertEqual(try decodeSingle(output), input)
        }
        // chunkのblock数が32ならCRCの回転量は0。後続chunkのCRCと結合して検査する。
        let manyBlocks = alternating(34 * 99_981 + 137)
        let encoder = try ParallelBzip2StreamEncoder(level: 1, threads: 2, chunkSize: 32 * 99_981)
        var output = Data()
        try encoder.write(manyBlocks, finish: true) { output.append($0) }
        XCTAssertEqual(output, try Bzip2StreamEncoder.encode(manyBlocks, level: 1))
        XCTAssertEqual(try decodeSingle(output), manyBlocks)
    }

    func testManyThreadsKeepFixedChunkCountAndIdentity() throws {
        let block = 99_981
        // level 1の約48 blockは常に5 blockずつ10片。並列数は片の境界を変えない。
        let input = TestCorpus.random(48 * block + 137)
        let size = UInt64(input.count)
        let expected = try Bzip2StreamEncoder.encode(input, level: 1)
        for threads in [1, 8, 36, 64] {
            let calls = Mutex(0)
            let encoder = try ParallelBzip2StreamEncoder(level: 1, threads: threads, size: size, encoder: { bytes, level in
                calls.withLock { $0 += 1 }
                return try Bzip2StreamEncoder.encode(bytes, level: level)
            })
            var output = Data()
            try encoder.write(input, finish: true) { output.append($0) }
            let chunks = calls.withLock { $0 }
            XCTAssertEqual(chunks, threads == 1 ? 0 : 10, "threads=\(threads)")
            if threads > 1 { XCTAssertEqual(chunks, ParallelBzip2StreamEncoder.estimatedChunkCount(size: size, level: 1)) }
            XCTAssertEqual(encoder.forcedCuts, 0)
            XCTAssertEqual(output, expected, "threads=\(threads)")
            XCTAssertEqual(try decodeSingle(output), input)
        }
    }

    func testAllEightEOSPaddingCandidates() throws {
        for prefix in 0...7 {
            var writer = Bzip2SpliceBits(), stream = Data([0x42, 0x5a, 0x68, 0x31])
            writer.append(0, count: prefix)
            writer.append(Bzip2SpliceBits.eosMagic, count: 48)
            writer.append(0x87654321, count: 32)
            try writer.finish { stream.append($0) }
            let trailer = try Bzip2SpliceBits.trailer(stream, level: 1)
            XCTAssertEqual(trailer.position, 32 + prefix)
            XCTAssertEqual(trailer.crc, 0x87654321)
        }
    }

    func testBulkPayloadAtEveryBitOffsetMatchesBitByBitReference() throws {
        let stream = Data([0x42, 0x5a, 0x68, 0x31]) + TestCorpus.random(IOChunk.size + 18)
        for offset in 0...7 {
            // wordの端数、EOS直前の端数、I/O境界、次payloadへの持越しを別々に検査する。
            for size in [0, 1, 7, 8, 9, 31, IOChunk.size + 17] {
                let tails = size > 31 ? [3] : Array(0...7)
                for tail in tails {
                    var writer = Bzip2SpliceBits(), actual = Data()
                    var reference: [UInt8] = [], pending: UInt8 = 0, live = 0
                    func bit(_ value: UInt8) {
                        pending |= value << (7 - live)
                        live += 1
                        if live == 8 { reference.append(pending); pending = 0; live = 0 }
                    }
                    func payload(_ end: Int) {
                        stream.withUnsafeBytes { raw in
                            let source = raw.bindMemory(to: UInt8.self)
                            for position in 32..<end { bit((source[position >> 3] >> (7 - (position & 7))) & 1) }
                        }
                    }
                    func emit(_ data: Data) {
                        XCTAssertLessThanOrEqual(data.count, IOChunk.size)
                        actual.append(data)
                    }
                    writer.append(0x55, count: offset)
                    for position in (0..<offset).reversed() { bit(UInt8((0x55 >> position) & 1)) }
                    let end = 32 + size * 8 + tail
                    try writer.appendPayload(stream, end: end, emit: emit)
                    payload(end)
                    try writer.appendPayload(stream, end: 32 + 13 * 8 + 5, emit: emit)
                    payload(32 + 13 * 8 + 5)
                    try writer.finish(emit: emit)
                    if live > 0 { reference.append(pending) }
                    XCTAssertEqual(actual, Data(reference), "offset=\(offset), size=\(size), tail=\(tail)")
                }
            }
        }
    }

    func testScannerCarriesPendingRunAndCountsFinalBlock() {
        for level in [1, 5, 9] {
            let limit = 100_000 * level - 19
            var scanner = Bzip2BlockScanner(level: level)
            XCTAssertNil(scanner.scan(alternating(limit), target: 1))
            XCTAssertEqual(scanner.finalBlockCount, 1)
            // 満杯にしたbyte自体は未確定run。次の入力が来て初めて前のblockを切る。
            XCTAssertNil(scanner.scan(alternating(limit + 1), target: 1))
            XCTAssertEqual(scanner.finalBlockCount, 1)
            XCTAssertEqual(scanner.scan(alternating(limit + 2), target: 1), limit)
            XCTAssertEqual(scanner.blocks, 1)
        }
    }

    func testForcedCutsDecodeAsExactlyOneStream() throws {
        let input = Data(repeating: 0, count: 200_013) + TestCorpus.random(201_007)
        var baseline: Data?
        for threads in [1, 8, 36, 64] {
            let encoder = try ParallelBzip2StreamEncoder(level: 1, threads: threads, chunkSize: 100_000, inputCap: 32_771)
            var output = Data()
            for offset in stride(from: 0, to: input.count, by: 997) {
                try encoder.write(input.subdata(in: offset..<min(offset + 997, input.count)), finish: false) { output.append($0) }
                XCTAssertLessThanOrEqual(encoder.pendingInputBytes, UInt64(threads + 1) * 32_771)
            }
            try encoder.write(Data(), finish: true) { output.append($0) }
            XCTAssertGreaterThan(encoder.forcedCuts, 0)
            if let baseline { XCTAssertEqual(output, baseline) } else { baseline = output }
            XCTAssertEqual(try decodeSingle(output), input)
        }
    }

    func testEmptyOneByteAndEOSCandidateValidation() throws {
        for level in [1, 5, 9] {
            for input in [Data(), Data([0x61])] { try assertIdentity(input, level: level) }
            let valid = try Bzip2StreamEncoder.encode(TestCorpus.random(12_345), level: level)
            let trailer = try Bzip2SpliceBits.trailer(valid, level: level)
            XCTAssertGreaterThan(trailer.position, 32)
            XCTAssertThrowsError(try Bzip2SpliceBits.trailer(valid + Data([0]), level: level))
            XCTAssertThrowsError(try Bzip2SpliceBits.trailer(valid, level: level == 9 ? 1 : 9))
            var damaged = valid
            let byte = trailer.position / 8
            damaged[byte] ^= UInt8(1 << (7 - trailer.position % 8))
            XCTAssertThrowsError(try Bzip2SpliceBits.trailer(damaged, level: level))
            if (trailer.position + 80) % 8 != 0 {
                damaged = valid; damaged[damaged.count - 1] |= 1
                XCTAssertThrowsError(try Bzip2SpliceBits.trailer(damaged, level: level))
            }
        }
    }

    func testChunkSizingAndFixedMemoryReservations() {
        XCTAssertEqual(ParallelBzip2StreamEncoder.chunkSize(level: 9), 5 * 899_981)
        for (size, count): (UInt64, Int) in [(0, 1), (1, 1), (16 << 20, 4), (64 << 20, 15), (.max, 1024)] {
            XCTAssertEqual(ParallelBzip2StreamEncoder.estimatedChunkCount(size: size, level: 9), count)
        }
        XCTAssertEqual(ParallelBzip2StreamEncoder.memoryReservation(level: 9, threads: 1), 41_501_063)
        XCTAssertEqual(ParallelBzip2StreamEncoder.memoryReservation(level: 9, threads: 2), 66_224_910)
        let options = WriterOptions(compressionMethod: .bzip2, sevenZipMethod: .bzip2, bzip2Level: 9,
            memoryLimit: 67_000_000, compressionThreads: 12)
        XCTAssertEqual(ParallelBzip2StreamEncoder.resolvedThreads(options: options, physicalMemory: 16 << 30), 2)
        XCTAssertEqual(options.maximumPendingInputBytes(for: .zip, physicalMemory: 16 << 30), 24 << 20)
        XCTAssertEqual(options.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), 24 << 20)
        let solid = WriterOptions(sevenZipMethod: .bzip2, sevenZipSolid: .on(blockSize: 64 << 20, filesPerBlock: nil), bzip2Level: 9,
            memoryLimit: 67_000_000, compressionThreads: 12)
        XCTAssertEqual(EntryCompressionConfiguration(options: solid, method: .bzip2, physicalMemory: 16 << 30, innerParallelism: true).threads, 1)
        XCTAssertEqual(solid.maximumPendingInputBytes(for: .sevenZip, physicalMemory: 16 << 30), 96 << 20)
    }

    private func assertIdentity(_ input: Data, level: Int) throws {
        let expected = try Bzip2StreamEncoder.encode(input, level: level)
        for threads in [1, 2, 7] {
            let encoder = try ParallelBzip2StreamEncoder(level: level, threads: threads, chunkSize: 100_000 * level - 19)
            var output = Data()
            try encoder.write(input, finish: true) { output.append($0) }
            XCTAssertEqual(encoder.forcedCuts, 0)
            XCTAssertEqual(output, expected, "level=\(level), threads=\(threads), input=\(input.count)")
            XCTAssertEqual(try decodeSingle(output), input)
        }
    }

    private func assertRunIdentity(level: Int, lengths: [Int], offsets: [Int]) throws {
        let limit = 100_000 * level - 19
        for offset in offsets {
            var input = Data()
            // 各blockの予測点は、それまでの入力をscannerで進めて求める。
            // runを差し込んだ後は予測点を更新し、過去のrunによるRLE1の伸縮も含める。
            for length in lengths {
                var prediction = Bzip2BlockScanner(level: level)
                var probe = input + alternating(2 * limit + 2_100)
                var boundaries: [Int] = []
                var base = 0
                while let cut = prediction.scan(probe, target: 1) {
                    boundaries.append(base + cut)
                    base += cut; probe = Data(probe.dropFirst(cut)); prediction = Bzip2BlockScanner(level: level)
                }
                let boundary = boundaries.first { $0 > input.count + 1000 }!
                let start = boundary + offset - min(2, length / 2)
                input.append(alternating(start - input.count))
                input.append(Data(repeating: 0x77, count: length))
            }
            input.append(alternating(limit + 137))
            try assertIdentity(input, level: level)
        }
    }

    private func alternating(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 & 1) })
    }

    private func decodeSingle(_ input: Data) throws -> Data {
        let stream = UnsafeMutablePointer<bz_stream>.allocate(capacity: 1)
        stream.initialize(to: bz_stream())
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        guard BZ2_bzDecompressInit(stream, 0, 0) == BZ_OK else { throw WriterError.compression(-1) }
        defer { BZ2_bzDecompressEnd(stream) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        try input.withUnsafeBytes { raw in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            stream.pointee.avail_in = UInt32(input.count)
            while true {
                let capacity = buffer.count
                let status = buffer.withUnsafeMutableBytes { destination in
                    stream.pointee.next_out = destination.baseAddress!.assumingMemoryBound(to: CChar.self)
                    stream.pointee.avail_out = UInt32(capacity)
                    return BZ2_bzDecompress(stream)
                }
                let count = buffer.count - Int(stream.pointee.avail_out)
                result.append(contentsOf: buffer.prefix(count))
                if status == BZ_STREAM_END {
                    XCTAssertEqual(stream.pointee.avail_in, 0, "連結streamまたは終端の余剰byte")
                    break
                }
                guard status == BZ_OK, count > 0 else { throw WriterError.compression(status) }
            }
        }
        return result
    }
}
