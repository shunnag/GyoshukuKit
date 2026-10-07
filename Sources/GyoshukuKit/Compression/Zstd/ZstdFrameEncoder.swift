// Independent implementation from RFC 8878; no zstd source consulted.
// https://www.rfc-editor.org/rfc/rfc8878 (frame, literals, sequences, entropy coding)
import Foundation

/// 一つの独立した RFC 8878 frame を有界メモリで同期符号化する。
/// .zst / tar.zst は独立 frame の並列化、ZIP method 93 は単一 frame の逐次出力に使う。
final class ZstdFrameEncoder {
    static let blockSize = 128 << 10
    let properties: ZstdEncoderProperties
    private let contentSize: UInt64?
    private let parser: ZstdParser
    private let literalWorkspace = ZstdHuffmanEncoder.Workspace()
    private let sequenceWorkspace: ZstdSequences.Workspace
    private let storage: UnsafeMutablePointer<UInt8>
    private let literalStorage: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private var blockStart = 0
    private var pendingCount = 0
    private var position = 0
    private var received: UInt64 = 0
    private var repeats = ZstdRepeatOffsets()
    private var checksum = ZstdXXH64()
    private var started = false
    private var finished = false
    private let collectProfile: Bool
    private(set) var profile = ZstdEncoderProfile()
    var pendingInputBytes: UInt64 { UInt64(pendingCount) }
    var estimatedMemoryBytes: Int { properties.estimatedMemoryBytes }

    init(level: Int = 3, contentSize: UInt64? = nil, collectProfile: Bool = false) throws {
        properties = try .preset(level)
        self.contentSize = contentSize
        self.collectProfile = collectProfile
        parser = ZstdParser(properties: properties)
        sequenceWorkspace = ZstdSequences.Workspace(capacity: Self.blockSize / 3)
        capacity = 2 * properties.windowSize + Self.blockSize
        storage = .allocate(capacity: capacity)
        literalStorage = .allocate(capacity: Self.blockSize)
    }
    deinit { storage.deallocate(); literalStorage.deallocate() }

    /// emit is called as each block becomes available. The caller owns emitted Data.
    /// Completion, cancellation or any error (including emit) makes this instance terminal.
    func write(_ data: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            let (size, overflow) = received.addingReportingOverflow(UInt64(data.count))
            guard !overflow else { throw WriterError.sizeOverflow }
            guard contentSize.map({ size <= $0 }) ?? true else { throw WriterError.sourceChanged("zstd content size") }
            if finish, let contentSize, size != contentSize { throw WriterError.sourceChanged("zstd content size") }
            if !started && (!data.isEmpty || finish) { try emit(header()); started = true }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    if pendingCount == Self.blockSize { try block(last: false, emit: emit) }
                    let n = min(Self.blockSize - pendingCount, bytes.count - offset)
                    let source = bytes.baseAddress!.advanced(by: offset)
                    let start = collectProfile ? ProcessInfo.processInfo.systemUptime : 0
                    // Destination lies in the allocated sliding buffer, exactly n bytes initialized.
                    UnsafeMutableRawPointer(storage + blockStart + pendingCount).copyMemory(from: source, byteCount: n)
                    checksum.update(UnsafeRawBufferPointer(start: source, count: n))
                    if collectProfile { profile.inputAndChecksum += ProcessInfo.processInfo.systemUptime - start }
                    pendingCount += n; offset += n
                }
            }
            received = size
            if finish {
                try block(last: true, emit: emit)
                var trailer = Data(); zstdAppendLE(UInt64(UInt32(truncatingIfNeeded: checksum.digest())), bytes: 4, to: &trailer)
                try emit(trailer); finished = true
            }
        } catch { finished = true; throw error }
    }

    /// A complete frame for a chunk. Independent instances are safe to run concurrently.
    static func encode(_ chunk: Data, level: Int = 3) throws -> Data {
        let encoder = try Self(level: level, contentSize: UInt64(chunk.count))
        var output = Data(); output.reserveCapacity(chunk.count)
        try encoder.write(chunk, finish: true) { output.append($0) }
        return output
    }

    private func header() -> Data {
        var result = Data([0x28,0xB5,0x2F,0xFD])
        let single = contentSize.map { $0 <= UInt64(properties.windowSize) } ?? false
        var flag = 0, fieldBytes = 0, storedSize: UInt64 = 0
        if let size = contentSize {
            if single && size < 256 { fieldBytes = 1; storedSize = size }
            else if (256...65791).contains(size) { flag = 1; fieldBytes = 2; storedSize = size - 256 }
            else if size <= UInt64(UInt32.max) { flag = 2; fieldBytes = 4; storedSize = size }
            else { flag = 3; fieldBytes = 8; storedSize = size }
        }
        result.append(UInt8((flag << 6) | (single ? 32 : 0) | 4))
        if !single { result.append(UInt8((properties.windowLog - 10) << 3)) }
        zstdAppendLE(storedSize, bytes: fieldBytes, to: &result)
        return result
    }
    private func block(last: Bool, emit: (Data) throws -> Void) throws {
        try Task.checkCancellation()
        let n = pendingCount, bytes = storage + blockStart
        if position >= 1 << 31 {
            parser.finder.rebase(by: 1 << 30); position -= 1 << 30
        }
        // Previous block's last three bytes become searchable now that their hash has lookahead.
        if blockStart > 0 {
            for back in stride(from: min(3, blockStart), through: 1, by: -1) where n + back >= 4 {
                parser.finder.insert(bytes - back, position: position - back, available: n + back)
            }
        }
        var type = 0, payload = Data()
        let rle = n > 0 && (1..<n).allSatisfy { bytes[$0] == bytes[0] }
        if rle {
            type = 1; payload.append(bytes[0])
            // RLE/raw blocks preserve repeat offsets and entropy state, but still enter the LZ history.
            for i in stride(from: 0, to: n, by: 4) { parser.finder.insert(bytes + i, position: position + i, available: n - i) }
        } else if n > 0 {
            var start = collectProfile ? ProcessInfo.processInfo.systemUptime : 0
            let sequences = parser.parse(UnsafePointer(bytes), count: n, position: position, repeats: repeats)
            if collectProfile { profile.matchAndParse += ProcessInfo.processInfo.systemUptime - start }
            start = collectProfile ? ProcessInfo.processInfo.systemUptime : 0
            var literalCount = 0
            let destination = UnsafeMutableRawPointer(literalStorage)
            sequences.withUnsafeBufferPointer { sequences in
                var cursor = 0
                for s in sequences {
                    assert(s.length >= 3)
                    if s.literals > 0 {
                        // 一致は3 byte以上。短い literal の広い copy も入力・予約内に収まる。
                        let target = destination.advanced(by: literalCount)
                        if s.literals <= 4 { target.copyMemory(from: bytes + cursor, byteCount: 4) }
                        else if s.literals <= 8 { target.copyMemory(from: bytes + cursor, byteCount: 8) }
                        else { target.copyMemory(from: bytes + cursor, byteCount: s.literals) }
                        literalCount += s.literals
                    }
                    cursor += s.literals + s.length
                }
                if cursor < n {
                    destination.advanced(by: literalCount).copyMemory(from: bytes + cursor, byteCount: n - cursor)
                    literalCount += n - cursor
                }
            }
            var proposedRepeats = repeats
            let literalTiming: ((Double, Double, Double) -> Void)? = collectProfile ? { [self] histogram, tables, bits in
                profile.literalHistogram += histogram; profile.literalTables += tables; profile.literalBits += bits
            } : nil
            var compressed = ZstdHuffmanEncoder.literals(UnsafeRawBufferPointer(start: literalStorage, count: literalCount), workspace: literalWorkspace, profile: literalTiming)
            if collectProfile { profile.literals += ProcessInfo.processInfo.systemUptime - start }
            start = collectProfile ? ProcessInfo.processInfo.systemUptime : 0
            let timing: ((Double, Double, Double) -> Void)? = collectProfile ? { [self] codes, tables, bits in
                profile.sequenceCodes += codes; profile.sequenceTables += tables; profile.sequenceBits += bits
            } : nil
            compressed.append(ZstdSequences.encode(sequences, repeats: &proposedRepeats, workspace: sequenceWorkspace, fast: properties.strategy == .fast, profile: timing))
            if collectProfile { profile.sequences += ProcessInfo.processInfo.systemUptime - start }
            if compressed.count < n && compressed.count <= Self.blockSize {
                type = 2; payload = compressed
                parser.updatePrices(sequences, repeats: repeats); repeats = proposedRepeats
            } else { payload.append(bytes, count: n) }
        }
        var output = Data()
        zstdAppendLE(UInt64(((type == 1 ? n : payload.count) << 3) | (type << 1) | (last ? 1 : 0)), bytes: 3, to: &output)
        output.append(payload)
        try Task.checkCancellation()
        try emit(output)
        position += n; blockStart += n; pendingCount = 0
        if blockStart + Self.blockSize > capacity {
            let retained = min(blockStart, properties.windowSize)
            // Source starts beyond the retained target. Only initialized history is copied.
            UnsafeMutableRawPointer(storage).copyMemory(from: storage + blockStart - retained, byteCount: retained)
            blockStart = retained
        }
    }
}

struct ZstdEncoderProfile {
    var inputAndChecksum = 0.0
    var matchAndParse = 0.0
    var literals = 0.0
    var literalHistogram = 0.0
    var literalTables = 0.0
    var literalBits = 0.0
    var sequences = 0.0
    var sequenceCodes = 0.0
    var sequenceTables = 0.0
    var sequenceBits = 0.0
    func report(corpus: String, level: Int) -> String {
        String(format: "ZSTD-PROFILE\t%@\t%d\tinput+xxh64=%.6f\tmatch+parse=%.6f\tliterals=%.6f\tsequences=%.6f\tcodes=%.6f\ttables=%.6f\tbits=%.6f\tliteral-histogram=%.6f\tliteral-tables=%.6f\tliteral-bits=%.6f",
               corpus, level, inputAndChecksum, matchAndParse, literals, sequences, sequenceCodes, sequenceTables, sequenceBits, literalHistogram, literalTables, literalBits)
    }
}
