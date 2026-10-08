// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation
import XCTest
@testable import GyoshukuKit

/// 全位置の候補生成と raw encode を比較する opt-in probe。入力準備と報告は計測外。
final class LZMAMatchFinderProbeTests: XCTestCase {
    func testFinderFraction() throws {
        try OptInGate.flag("GYOSHUKU_LZMA_FINDER_PROBE")
        #if DEBUG
        XCTFail("Run LZMAMatchFinderProbeTests with -c release")
        return
        #else
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, OptInGate.integer("GYOSHUKU_LZMA_FINDER_PROBE_REPEATS", default: 3))
        let levels = environment["GYOSHUKU_LZMA_FINDER_PROBE_LEVELS"]?
            .split(separator: ",").compactMap { Int($0) } ?? [6]
        guard !levels.isEmpty, levels.allSatisfy({ [4, 6, 9].contains($0) }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        // 起動確認用だけに各 corpus を縮める。通常の測定では未設定にする。
        let maximumBytes: Int?
        if let value = environment["GYOSHUKU_LZMA_FINDER_PROBE_MAX_BYTES"] {
            guard let count = Int(value), count >= 4 else { throw CocoaError(.validationMissingMandatoryProperty) }
            maximumBytes = count
        } else { maximumBytes = nil }
        try report("text", source: "LZMAEncoderCorpus.text", input: LZMAEncoderCorpus.text(size: min(4 << 20, maximumBytes ?? .max)),
                   levels: levels, repeats: repeats, truncated: maximumBytes.map { $0 < 4 << 20 } ?? false)
        let binary = try binaryCorpus(maximumBytes: maximumBytes)
        try report("binary", source: binary.source, input: binary.input, levels: levels, repeats: repeats, truncated: binary.truncated)
        try report("random", source: "xorshift64star:D137923A6E259B41", input: TestCorpus.random(min(16 << 20, maximumBytes ?? .max)),
                   levels: levels, repeats: repeats, truncated: maximumBytes.map { $0 < 16 << 20 } ?? false)
        if let path = environment["GYOSHUKU_LZMA_FINDER_PROBE_FILE"] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            try report("file", source: path, input: Data(bytes.prefix(maximumBytes ?? bytes.count)),
                       levels: levels, repeats: repeats, truncated: maximumBytes.map { $0 < bytes.count } ?? false)
        }
        #endif
    }

    private func report(_ corpus: String, source: String, input: Data, levels: [Int], repeats: Int, truncated: Bool) throws {
        guard !input.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        for level in levels {
            let p = LZMAEncoderProperties.preset(level)
            // expectedSize を渡す raw encoder と同じ実効辞書で比較する。
            let dictionary = min(p.dictSize, max(4096, input.count))
            var finderSeconds = Double.infinity, fullSeconds = Double.infinity
            var checksum: UInt64 = 0, matchCount: UInt64 = 0, reference: Data?
            for _ in 0..<repeats {
                let finder = try measureFinder(input, properties: p, dictionary: dictionary)
                finderSeconds = min(finderSeconds, finder.seconds)
                checksum = finder.checksum; matchCount = finder.matches
                let start = DispatchTime.now().uptimeNanoseconds
                let encoded = try LZMAEncoder.encode(input, properties: p)
                fullSeconds = min(fullSeconds, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
                if let reference { XCTAssertEqual(encoded, reference) } else { reference = encoded }
            }
            let record: [String: Any] = [
                "corpus": corpus, "source": source, "level": level, "input_bytes": input.count,
                "dictionary_bytes": dictionary, "output_bytes": reference!.count, "repeats": repeats,
                "finder_seconds": finderSeconds, "full_seconds": fullSeconds, "f": finderSeconds / fullSeconds,
                "matches": matchCount, "checksum": String(checksum), "truncated": truncated,
            ]
            let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            TestSupport.report("LZMA-FINDER-PROBE\t" + String(decoding: json, as: UTF8.self))
        }
    }

    private func measureFinder(_ input: Data, properties: LZMAEncoderProperties, dictionary: Int) throws
        -> (seconds: Double, matches: UInt64, checksum: UInt64) {
        let matches = try lzmaAllocate(LZMAMatch.self, count: 274)
        defer { free(matches) }
        let start = DispatchTime.now().uptimeNanoseconds
        var finder = try LZMAMatchFinder(properties: properties, dictionary: dictionary)
        defer { finder.release() }
        var count: UInt64 = 0, checksum: UInt64 = 0
        input.withUnsafeBytes { bytes in
            let base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            // 全入力を一つの window として与え、終端の1〜3 byteも順に advance する。
            // parser の skip と異なり、全位置で record:true の候補を実際に読む。
            for position in 0..<bytes.count {
                let n = finder.matches(base + position, available: bytes.count - position, into: matches, record: true)
                count &+= UInt64(n)
                if n > 0 { checksum &+= UInt64(matches[n - 1].length) &+ UInt64(matches[n - 1].distance) }
            }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return (seconds, count, checksum)
    }

    private func binaryCorpus(maximumBytes: Int?) throws -> (source: String, input: Data, truncated: Bool) {
        let candidates = [Bundle(for: Self.self).executableURL, URL(fileURLWithPath: "/usr/bin/swift-frontend"),
                          URL(fileURLWithPath: CommandLine.arguments[0]), URL(fileURLWithPath: "/usr/lib/dyld")].compactMap { $0 }
        for url in candidates where FileManager.default.isReadableFile(atPath: url.path) {
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            // Mach-O の32 / 64 bitと fat、両 endianを受け付ける。file は読み取りだけ。
            let magic = Array(bytes.prefix(4))
            guard [[0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF],
                   [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA], [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA]]
                .contains(magic) else { continue }
            return (url.path, Data(bytes.prefix(maximumBytes ?? bytes.count)), maximumBytes.map { $0 < bytes.count } ?? false)
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
