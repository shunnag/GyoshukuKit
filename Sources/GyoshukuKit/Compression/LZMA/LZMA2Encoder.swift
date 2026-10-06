// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
// Chunk framing は同 SDK の Lzma2Enc.c と lzma-specification.txt に従う。
import Foundation

/// LZMA1 の確率 state と辞書を chunk 間で共有し、range coder だけを区切る。
final class LZMA2Encoder {
    static let unpackLimit = 2 << 20
    static let packLimit = 1 << 16
    let properties: LZMAEncoderProperties
    let dictionaryProperty: UInt8
    private var engine: LZMAEncodingEngine
    private let expectedSize: UInt64?
    private var received: UInt64 = 0
    private var finished = false
    private var first = true
    private var needsProperties = true

    init(properties: LZMAEncoderProperties = .preset(6), expectedSize: UInt64? = nil,
         memoryLimit: Int = 768 << 20) throws {
        try properties.validate(lzma2: true)
        self.properties = properties; self.expectedSize = expectedSize
        dictionaryProperty = Self.dictionaryProperty(for: properties.dictSize)
        engine = try LZMAEncodingEngine(properties: properties, sizeHint: expectedSize, memoryLimit: memoryLimit, chunked: true)
    }
    deinit { engine.release() }
    static func dictionaryProperty(for size: Int) -> UInt8 {
        precondition((4096...(3 << 29)).contains(size))
        for prop in 0...40 {
            let bound: UInt64 = prop == 40 ? UInt64(UInt32.max) : UInt64(2 | (prop & 1)) << (prop / 2 + 11)
            if UInt64(size) <= bound { return UInt8(prop) }
        }
        preconditionFailure()
    }
    func push(_ input: Data) throws -> Data {
        guard !finished else { throw LZMAEncodingError.finished }
        let (total, overflow) = received.addingReportingOverflow(UInt64(input.count))
        guard !overflow, expectedSize.map({ total <= $0 }) ?? true else { throw LZMAEncodingError.sizeMismatch }
        received = total
        var output = Data()
        try input.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                if engine.capacity - engine.end < min(bytes.count - offset, Self.unpackLimit - (engine.end - engine.cursor)) { engine.compact() }
                let n = min(bytes.count - offset, Self.unpackLimit - (engine.end - engine.cursor))
                engine.window.advanced(by: engine.end).update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: n)
                engine.end += n; offset += n
                if engine.end - engine.cursor == Self.unpackLimit { try drain(to: &output, final: false) }
            }
        }
        return output
    }
    func finish() throws -> Data {
        guard !finished else { throw LZMAEncodingError.finished }
        guard expectedSize.map({ received == $0 }) ?? true else { throw LZMAEncodingError.sizeMismatch }
        finished = true
        var output = Data()
        try drain(to: &output, final: true)
        output.append(0)
        return output
    }
    private func drain(to output: inout Data, final: Bool) throws {
        while engine.end > engine.cursor && (final || engine.end - engine.cursor >= Self.unpackLimit) {
            try Task.checkCancellation()
            let start = engine.cursor
            let resetState = engine.modelNeedsReset
            if resetState { engine.resetModel() }
            engine.rc.reset()
            // 最大 4096 byte の optimum 復元と carry flush 用に 8 KiB を残す。
            engine.process(limit: min(engine.end, start + Self.unpackLimit), reserve: 0, packedLimit: Self.packLimit - 8192)
            engine.rc.finish()
            if let error = engine.rc.error { finished = true; throw error }
            let compressed = engine.rc.take()
            let count = engine.cursor - start
            precondition(count > 0 && count <= Self.unpackLimit && engine.finderCursor == engine.cursor)
            if compressed.count + (needsProperties ? 6 : 5) < count + 3 && compressed.count <= Self.packLimit {
                let u = count - 1, c = compressed.count - 1
                let reset = first ? 0xE0 : needsProperties ? 0xC0 : resetState ? 0xA0 : 0x80
                output.append(UInt8(reset | (u >> 16)))
                output.append(contentsOf: [UInt8((u >> 8) & 255), UInt8(u & 255), UInt8(c >> 8), UInt8(c & 255)])
                if needsProperties { output.append(properties.packedByte) }
                output.append(compressed)
                needsProperties = false
            } else {
                var offset = start
                while offset < engine.cursor {
                    let n = min(Self.packLimit, engine.cursor - offset)
                    output.append(first ? 1 : 2)
                    output.append(contentsOf: [UInt8((n - 1) >> 8), UInt8((n - 1) & 255)])
                    output.append(engine.window + offset, count: n)
                    first = false; offset += n
                }
                // raw chunk に確率更新はない。次の compressed chunk に state reset を宣言する。
                engine.modelNeedsReset = true
            }
            first = false
        }
    }
    static func encode(_ input: Data, properties: LZMAEncoderProperties = .preset(6)) throws -> Data {
        let encoder = try Self(properties: properties, expectedSize: UInt64(input.count))
        return try encoder.push(input) + encoder.finish()
    }
}
