// 出自: 公開ドメインの LZMA SDK 26.03 C/Ppmd7.c / C/Ppmd7Enc.c と 7-Zip 26.03 C/Ppmd8.c / C/Ppmd8Enc.c。
// framing は APPNOTE §5.10。復号 oracle は KaitoKit の公開 reader と外部 7zz。
import Foundation
import XCTest
@testable import GyoshukuKit

final class PPMdEncoderTests: XCTestCase {
    func testPropertiesAndPresets() throws {
        XCTAssertEqual(PPMdTestArchives.crc(Data("123456789".utf8)), 0xCBF4_3926)
        let h = try PPMd7EncoderProperties(order: 6, memorySize: 16 << 20)
        XCTAssertEqual(h.coderProperties, Data([6, 0, 0, 0, 1]))
        for method in PPMdRestorationMethod.allCases {
            let i = try PPMd8EncoderProperties(order: 16, memorySize: 256 << 20, restoration: method)
            XCTAssertEqual(i.parameterWord, 0x0FFF | (method.rawValue << 12))
            XCTAssertEqual(i.header, Data([0xFF, UInt8(0x0F | (method.rawValue << 4))]))
        }
        for level in 1...9 {
            XCTAssertEqual(try PPMd7EncoderProperties.preset(level).memorySize,
                           [1, 2, 4, 8, 16, 16, 32, 64, 192][level - 1] << 20)
            XCTAssertEqual(try PPMd8EncoderProperties.preset(level).order,
                           [3, 4, 5, 6, 8, 8, 10, 12, 16][level - 1])
        }
        for order in [1, 33] { XCTAssertThrowsError(try PPMd7EncoderProperties(order: order)) }
        for order in [1, 17] { XCTAssertThrowsError(try PPMd8EncoderProperties(order: order)) }
        for memory in [0, (1 << 20) - 1, (1 << 30) + 1] {
            XCTAssertThrowsError(try PPMd7EncoderProperties(memorySize: memory))
        }
        for memory in [0, (1 << 20) + 1, 257 << 20] {
            XCTAssertThrowsError(try PPMd8EncoderProperties(memorySize: memory))
        }
        for level in [0, 10] {
            XCTAssertThrowsError(try PPMd7EncoderProperties.preset(level))
            XCTAssertThrowsError(try PPMd8EncoderProperties.preset(level))
        }
    }

    func testSmallInputsAndOrderBounds() throws {
        let directory = try PPMdTestArchives.directory("ppmd-small")
        for (name, input) in [("empty", Data()), ("one", Data([0xA7])), ("zeros", Data(repeating: 0, count: 65_536))] {
            for order in [2, 6, 32] {
                try verifyH(input, order: order, memory: 1 << 20, name: "\(name)-h\(order)", directory: directory)
            }
            for order in [2, 6, 16] {
                for restoration in PPMdRestorationMethod.allCases {
                    try verifyI(input, order: order, memory: 1 << 20, restoration: restoration,
                                name: "\(name)-i\(order)-\(restoration.rawValue)", directory: directory)
                }
            }
        }
    }

    func testLargeTextAndRandom() throws { try verifyTextAndRandom(large: false) }

    func testLargeTextAndRandomFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyTextAndRandom(large: true)
    }

    private func verifyTextAndRandom(large: Bool) throws {
        let directory = try PPMdTestArchives.directory("ppmd-large")
        for (name, input) in [("text", large ? EncoderTestCorpus.sourceMiB : EncoderTestCorpus.shortSource),
                              ("random", large ? TestCorpus.random(8 << 20) : EncoderTestCorpus.random256KiB)] {
            try verifyH(input, order: 6, memory: 16 << 20, name: name + "-h", directory: directory)
            try verifyI(input, order: 6, memory: 16 << 20, restoration: .restart,
                        name: name + "-i", directory: directory)
        }
    }

    func testSmallMemoryRestorationOnTwentyMiBText() throws { try verifyRestoration(large: false) }

    func testSmallMemoryRestorationOnTwentyMiBTextFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyRestoration(large: true)
    }

    // 全256値を保って隣接byteを相関させ、I の cut-off 分岐も通す。
    private static let restorationRandom = Data(EncoderTestCorpus.random256KiB.prefix(128 << 10).flatMap { [$0, $0] })

    private func verifyRestoration(large: Bool) throws {
        let directory = try PPMdTestArchives.directory("ppmd-restoration")
        // text と全256値の乱数で、1 MiB heap の枯渇と復旧後の全 byte を照合する。
        let samples = large ? [("text-20m", EncoderTestCorpus.sourceTwentyMiB)]
            : [("text-restoration", EncoderTestCorpus.restoration), ("random-restoration", Self.restorationRandom)]
        if !large { XCTAssertEqual(Set(Self.restorationRandom).count, 256) }
        for (label, input) in samples {
            try verifyRestoration(input, label: label, directory: directory)
        }
    }

    private func verifyRestoration(_ input: Data, label: String, directory: URL) throws {
        let h = try PPMd7StreamEncoder(properties: .init(order: 6, memorySize: 1 << 20))
        let encoded = try StreamEncoderTestSupport.encode(input, write: h.write)
        XCTAssertGreaterThan(h.model.restartCount, 0)
        TestSupport.report("PPMD_RESTORATION H bytes=\(input.count) restarts=\(h.model.restartCount)")
        try PPMdTestArchives.verify(PPMdTestArchives.sevenZip(encoded, input: input, properties: h.properties),
                                    input: input, extension: "7z", method: "PPMD:o6:mem20", label: label + "-h", directory: directory)
        for restoration in PPMdRestorationMethod.allCases {
            let i = try PPMd8StreamEncoder(properties: .init(order: 6, memorySize: 1 << 20, restoration: restoration))
            let encoded = try StreamEncoderTestSupport.encode(input, write: i.write)
            TestSupport.report("PPMD_RESTORATION I method=\(restoration.rawValue) bytes=\(input.count) restarts=\(i.model.restartCount) cutoffs=\(i.model.cutOffCount)")
            if restoration == .restart { XCTAssertGreaterThan(i.model.restartCount, 0) }
            else { XCTAssertGreaterThan(i.model.cutOffCount, 0) }
            try PPMdTestArchives.verify(PPMdTestArchives.zip(encoded, input: input), input: input,
                                        extension: "zip", method: "PPMd", label: label + "-i\(restoration.rawValue)", directory: directory)
        }
    }

    func testStreamingIsDeterministicAndFailureIsTerminal() throws {
        let input = TestCorpus.random(65_537, alphabetMask: 31)
        for variantI in [false, true] {
            func encoder() throws -> PPMdStreamEncoder {
                if variantI { return try PPMd8StreamEncoder(properties: .init(order: 6, memorySize: 1 << 20)) }
                return try PPMd7StreamEncoder(properties: .init(order: 6, memorySize: 1 << 20))
            }
            let once = try encoder()
            var expected = Data()
            try once.write(input, finish: true) { expected.append($0) }
            XCTAssertThrowsError(try once.write(Data(), finish: true) { _ in })
            for width in [1, 7, 65_536] {
                let pieces = try encoder()
                var result = Data()
                for start in stride(from: 0, to: input.count, by: width) {
                    // Data slice の startIndex は 0 でない。
                    try pieces.write(input[start..<min(start + width, input.count)], finish: false) { result.append($0) }
                }
                try pieces.write(Data(), finish: true) { result.append($0) }
                XCTAssertEqual(result, expected, "variantI=\(variantI), width=\(width)")
            }
            let failed = try encoder()
            enum SinkFailure: Error { case expected }
            XCTAssertThrowsError(try failed.write(input, finish: true) { _ in throw SinkFailure.expected })
            XCTAssertThrowsError(try failed.write(Data(), finish: false) { _ in })
        }
    }

    func testEnglishLikeTextIsSmallerThanXZSix() throws {
        let directory = try PPMdTestArchives.directory("ppmd-compression")
        // 語順を固定 seed で変えた英文風の prose。長い同一 block の繰返しは作らない。
        let input = TestCorpus.englishLike(size: 1 << 20)
        let plain = directory.appendingPathComponent("english.txt")
        try input.write(to: plain)
        let referenceStart = EncoderTestTiming.start()
        let reference = try ReferenceTool.run(ReferenceTool.xz, ["-6", "-c", plain.path], in: directory,
                                              log: "xz-six", standardOutput: "english.xz")
        EncoderTestTiming.end("reference.xz-6", referenceStart, input: input.count, output: reference.bytes.count)
        let h = try PPMd7EncoderProperties(order: 6, memorySize: 16 << 20)
        let i = try PPMd8EncoderProperties(order: 6, memorySize: 16 << 20)
        let encodedH = try EncoderTestTiming.measure("encode.PPMd7StreamEncoder.encode", input: input.count) { try PPMd7StreamEncoder.encode(input, properties: h) }
        let encodedI = try EncoderTestTiming.measure("encode.PPMd8StreamEncoder.encode", input: input.count) { try PPMd8StreamEncoder.encode(input, properties: i) }
        TestSupport.report("PPMd English size: H=\(encodedH.count), I=\(encodedI.count), xz-6=\(reference.bytes.count)")
        XCTAssertLessThan(encodedH.count, reference.bytes.count)
        XCTAssertLessThan(encodedI.count, reference.bytes.count)
        try PPMdTestArchives.verify(PPMdTestArchives.sevenZip(encodedH, input: input, properties: h), input: input,
                                    extension: "7z", method: "PPMD:o6:mem24", label: "english-h", directory: directory)
        try PPMdTestArchives.verify(PPMdTestArchives.zip(encodedI, input: input), input: input,
                                    extension: "zip", method: "PPMd", label: "english-i", directory: directory)
    }

    private func verifyH(_ input: Data, order: Int, memory: Int, name: String, directory: URL) throws {
        let encoder = try PPMd7StreamEncoder(properties: .init(order: order, memorySize: memory))
        let encoded = try StreamEncoderTestSupport.encode(input, write: encoder.write)
        try PPMdTestArchives.verify(PPMdTestArchives.sevenZip(encoded, input: input, properties: encoder.properties),
                                    input: input, extension: "7z", method: "PPMD:o\(order):mem\(memory.trailingZeroBitCount)",
                                    label: name, directory: directory)
    }

    private func verifyI(_ input: Data, order: Int, memory: Int, restoration: PPMdRestorationMethod,
                         name: String, directory: URL) throws {
        let encoder = try PPMd8StreamEncoder(properties: .init(order: order, memorySize: memory, restoration: restoration))
        let encoded = try StreamEncoderTestSupport.encode(input, write: encoder.write)
        try PPMdTestArchives.verify(PPMdTestArchives.zip(encoded, input: input), input: input, extension: "zip",
                                    method: "PPMd", label: name, directory: directory)
    }
}
