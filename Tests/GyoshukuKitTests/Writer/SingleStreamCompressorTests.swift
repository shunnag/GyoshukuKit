import Darwin
import Foundation
import XCTest
@testable import GyoshukuKit

final class SingleStreamCompressorTests: XCTestCase {
    func testEveryFormatOnEmptyOneByteTextAndRandomFiles() throws { try verifyEveryFormat(large: false) }

    func testEveryFormatOnEmptyOneByteTextAndRandomFilesFullSize() throws {
        try OptInGate.flag("GYOSHUKU_LARGE_ENCODER_TESTS")
        try verifyEveryFormat(large: true)
    }

    // bzip2 level 9 の 900,000 byte 境界も越え、二つの block を入力順に復号する。
    private static let smallRandom = TestCorpus.random((1 << 20) + 17)

    func testBzip2UsesSizeBasedSingleStreamAcrossThreads() throws {
        let directory = try TestSupport.directory("single-stream-bzip2-size")
        for (label, input, level): (String, Data, Int) in [
            ("normal", TestCorpus.random(4 * 99_981 + 137), 1),
            ("forced", Data(repeating: 65, count: ParallelBzip2StreamEncoder.inputCap + 4096), 9)
        ] {
            let source = directory.appendingPathComponent(label + ".raw")
            try input.write(to: source)
            // 単一stream encoderとの一致で、tar用の独立stream連結へ戻らないことも検査する。
            let encoder = try ParallelBzip2StreamEncoder(level: level, threads: 1, size: UInt64(input.count))
            var expected = Data()
            try encoder.write(input, finish: true) { expected.append($0) }
            XCTAssertEqual(encoder.forcedCuts, label == "forced" ? 1 : 0)
            for threads in [1, 2, 7, 12, 36, 64] {
                let output = directory.appendingPathComponent("\(label)-\(threads).bz2")
                try SingleStreamCompressor.compress(file: source, to: output, format: .bzip2,
                    options: WriterOptions(bzip2Level: level, compressionThreads: threads))
                XCTAssertEqual(try Data(contentsOf: output), expected, "\(label), threads=\(threads)")
                if threads == 1 { try StreamEncoderTestSupport.assertKaito(output, equals: input) }
            }
        }
    }

    private func verifyEveryFormat(large: Bool) throws {
        let samples = [("empty", Data()), ("one", Data([0xA7])),
                       ("text", large ? EncoderTestCorpus.sourceMiB : EncoderTestCorpus.shortSource),
                       ("random", large ? EncoderTestCorpus.randomNineMiB : Self.smallRandom)]
        for format in SingleStreamFormat.allCases {
            let directory = try TestSupport.directory("single-stream-\(format)")
            for (name, bytes) in samples {
                let source = directory.appendingPathComponent(name + ".raw")
                try bytes.write(to: source)
                let output = directory.appendingPathComponent(name + "." + SingleStreamTestSupport.suffix(format))
                let progress = Progress(totalUnitCount: -1)
                try SingleStreamWriter.$testingDidRead.withValue({ read in
                    XCTAssertEqual(progress.completedUnitCount, Int64(read))
                    XCTAssertEqual(progress.totalUnitCount, Int64(bytes.count))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                }) {
                    try EncoderTestTiming.measure("encode.single-stream.\(format)+io", input: bytes.count) {
                    try SingleStreamCompressor.compress(file: source, to: output, format: format,
                                                        options: WriterOptions(compressionThreads: 2), progress: progress)
                    }
                }
                XCTAssertEqual(progress.totalUnitCount, Int64(bytes.count))
                XCTAssertEqual(progress.completedUnitCount, Int64(bytes.count))
                try SingleStreamTestSupport.assertCLI(output, format: format, input: bytes, in: directory, label: name)
                try StreamEncoderTestSupport.assertKaito(output, equals: bytes)
                try FileManager.default.removeItem(at: source)
            }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".gyoshuku-") })
        }
    }

    func testRefusesDirectoriesSymlinksAndExistingOutputs() throws {
        let directory = try TestSupport.directory("single-stream-refuse")
        let source = directory.appendingPathComponent("file")
        try Data([1]).write(to: source)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
        let output = directory.appendingPathComponent("output")
        for format in SingleStreamFormat.allCases {
            for invalid in [directory, link] {
                XCTAssertThrowsError(try SingleStreamCompressor.compress(file: invalid, to: output, format: format)) {
                    XCTAssertEqual($0 as? WriterError, .unsupportedFileType(invalid.path))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
            try Data("existing".utf8).write(to: output)
            XCTAssertThrowsError(try SingleStreamCompressor.compress(file: source, to: output, format: format)) {
                XCTAssertEqual($0 as? WriterError, .io(operation: "create", code: EEXIST))
            }
            XCTAssertEqual(try Data(contentsOf: output), Data("existing".utf8))
            try FileManager.default.removeItem(at: output)
        }
        // 出力 symlink の target も置換しない。
        try FileManager.default.createSymbolicLink(atPath: output.path, withDestinationPath: source.path)
        XCTAssertThrowsError(try SingleStreamCompressor.compress(file: source, to: output, format: .gzip))
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }

    func testCancellationDuringReadingCleansTemporaryFiles() async throws {
        for format in SingleStreamFormat.allCases {
            let directory = try TestSupport.directory("single-stream-cancel-\(format)")
            let source = directory.appendingPathComponent("source")
            try TestCorpus.random(2 << 20).write(to: source)
            let output = directory.appendingPathComponent("output." + SingleStreamTestSupport.suffix(format))
            let task = Task.detached {
                try SingleStreamWriter.$testingDidRead.withValue({ read in
                    if read >= UInt64(IOChunk.size * 2) { withUnsafeCurrentTask { $0?.cancel() } }
                }) {
                    try SingleStreamCompressor.compress(file: source, to: output, format: format)
                }
            }
            do { try await task.value; XCTFail("cancelled compression succeeded") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source"])
        }
    }

    func testProgressCancellationAndRacingOutputCreation() throws {
        let directory = try TestSupport.directory("single-stream-atomic-race")
        let source = directory.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: source)
        for format in SingleStreamFormat.allCases {
            let output = directory.appendingPathComponent("output." + SingleStreamTestSupport.suffix(format))
            XCTAssertThrowsError(try SingleStreamWriter.$testingDidRead.withValue({ _ in
                try Data("racing output".utf8).write(to: output)
            }) {
                try SingleStreamCompressor.compress(file: source, to: output, format: format)
            }) { XCTAssertEqual($0 as? WriterError, .io(operation: "rename output", code: EEXIST)) }
            XCTAssertEqual(try Data(contentsOf: output), Data("racing output".utf8))
            try FileManager.default.removeItem(at: output)
            let progress = Progress(totalUnitCount: 0)
            XCTAssertThrowsError(try SingleStreamWriter.$testingDidRead.withValue({ _ in progress.cancel() }) {
                try SingleStreamCompressor.compress(file: source, to: output, format: format, progress: progress)
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source"])
        }
    }

    func testFailureAndChangedSourceRemoveTemporaryOutput() throws {
        let directory = try TestSupport.directory("single-stream-failure")
        let source = directory.appendingPathComponent("source")
        let original = Data([1, 2, 3])
        for format in SingleStreamFormat.allCases {
            try original.write(to: source)
            let output = directory.appendingPathComponent("output." + SingleStreamTestSupport.suffix(format))
            XCTAssertThrowsError(try SingleStreamWriter.$testingDidRead.withValue({ _ in
                throw WriterError.io(operation: "injected read failure", code: EIO)
            }) {
                try SingleStreamCompressor.compress(file: source, to: output, format: format)
            }) { XCTAssertEqual($0 as? WriterError, .io(operation: "injected read failure", code: EIO)) }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source"])
            XCTAssertThrowsError(try SingleStreamWriter.$testingDidRead.withValue({ _ in
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
            }) {
                try SingleStreamCompressor.compress(file: source, to: output, format: format)
            }) { XCTAssertEqual($0 as? WriterError, .sourceChanged(source.path)) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source"])
        }
    }

    func testGzipHeaderIsDeterministicAndLZMALevelsAndMemoryCap() throws {
        let directory = try TestSupport.directory("single-stream-levels")
        let source = directory.appendingPathComponent("input-with-name")
        let input = Data("level checks\n".utf8)
        try input.write(to: source)
        let gzip = directory.appendingPathComponent("output.gz")
        try SingleStreamCompressor.compress(file: source, to: gzip, format: .gzip)
        XCTAssertEqual(try Data(contentsOf: gzip).prefix(10), Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]))
        for format in [SingleStreamFormat.xz, .lzma, .lzip] {
            for level in [0, 6, 9] {
                let output = directory.appendingPathComponent("level-\(level)." + SingleStreamTestSupport.suffix(format))
                try SingleStreamCompressor.compress(file: source, to: output, format: format,
                    options: WriterOptions(lzmaLevel: level, lzmaExtreme: true, compressionThreads: 2))
                try SingleStreamTestSupport.assertCLI(output, format: format, input: input, in: directory, label: "\(format)-\(level)")
                try StreamEncoderTestSupport.assertKaito(output, equals: input)
            }
            let output = directory.appendingPathComponent("memory-\(format)")
            XCTAssertThrowsError(try SingleStreamCompressor.compress(file: source, to: output, format: format,
                options: WriterOptions(lzmaLevel: 6, memoryLimit: 1))) {
                XCTAssertEqual($0 as? WriterError, .invalidOption("memoryLimit"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        for format in [SingleStreamFormat.lzma, .lzip] {
            let output = directory.appendingPathComponent("nil-extreme." + SingleStreamTestSupport.suffix(format))
            try SingleStreamCompressor.compress(file: source, to: output, format: format,
                                                options: WriterOptions(lzmaExtreme: true))
            try SingleStreamTestSupport.assertCLI(output, format: format, input: input, in: directory, label: "nil-extreme-\(format)")
        }
    }
}
