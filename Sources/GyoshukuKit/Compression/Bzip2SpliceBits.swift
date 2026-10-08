import Foundation

/// MSB先行のsplice。payloadはbyte単位でずらし、EOSだけ最大8候補のbitを読む。
struct Bzip2SpliceBits {
    static let eosMagic: UInt64 = 0x177245385090
    private var bytes = Data()
    private var pending: UInt8 = 0
    private var live = 0

    static func read(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for bit in position..<(position + count) {
            value = (value << 1) | UInt64((bytes[bit >> 3] >> (7 - (bit & 7))) & 1)
        }
        return value
    }

    static func trailer(_ stream: Data, level: Int) throws -> (position: Int, crc: UInt32) {
        guard stream.count >= 14, stream.prefix(4) == Data([0x42, 0x5a, 0x68, UInt8(0x30 + level)]) else {
            throw WriterError.compression(-1)
        }
        return try stream.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var candidates: [(Int, UInt32)] = []
            for padding in 0...7 {
                let position = bytes.count * 8 - 80 - padding
                if position >= 32, read(bytes, at: position, count: 48) == eosMagic,
                   read(bytes, at: position + 80, count: padding) == 0 {
                    candidates.append((position, UInt32(read(bytes, at: position + 48, count: 32))))
                }
            }
            guard candidates.count == 1 else { throw WriterError.compression(-1) }
            return candidates[0]
        }
    }

    mutating func append(_ value: UInt64, count: Int) {
        for bit in (0..<count).reversed() {
            pending |= UInt8((value >> bit) & 1) << (7 - live)
            live += 1
            if live == 8 { bytes.append(pending); pending = 0; live = 0 }
        }
    }

    mutating func appendPayload(_ stream: Data, end: Int, emit: (Data) throws -> Void) throws {
        try stream.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            let fullEnd = end >> 3
            for index in 4..<fullEnd {
                let byte = source[index]
                if live == 0 { bytes.append(byte) }
                else {
                    bytes.append(pending | (byte >> live))
                    pending = byte << (8 - live)
                }
                if bytes.count >= IOChunk.size {
                    try Task.checkCancellation()
                    try emit(bytes); bytes = Data()
                }
            }
            append(Self.read(source, at: fullEnd * 8, count: end & 7), count: end & 7)
        }
        // 下位bitだけを次のchunkへ持ち越し、完了結果のDataを保持しない。
        if !bytes.isEmpty { try emit(bytes); bytes = Data() }
    }

    mutating func finish(emit: (Data) throws -> Void) throws {
        if live > 0 { bytes.append(pending) }
        if !bytes.isEmpty { try emit(bytes) }
        self = Self()
    }
}
