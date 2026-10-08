import Foundation

/// MSB先行のsplice。payloadは一括copy / 64 bit単位でずらし、EOSだけ最大8候補のbitを読む。
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
        if !bytes.isEmpty { try emit(bytes); bytes = Data() }
        try stream.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            let fullEnd = end >> 3
            var index = 4
            while index < fullEnd {
                try Task.checkCancellation()
                let count = min(IOChunk.size, fullEnd - index)
                let output: Data
                if live == 0 {
                    output = Data(bytes: source.baseAddress! + index, count: count)
                } else {
                    var shifted = Data(count: count)
                    shifted.withUnsafeMutableBytes { destination in
                        var offset = 0
                        while offset + 8 <= count {
                            let word = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: index + offset, as: UInt64.self))
                            let value = (UInt64(pending) << 56) | (word >> live)
                            destination.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt64.self)
                            pending = UInt8(truncatingIfNeeded: word) << (8 - live)
                            offset += 8
                        }
                        // 64 bit未満の末尾だけをbyte単位で処理する。
                        while offset < count {
                            let byte = source[index + offset]
                            destination[offset] = pending | (byte >> live)
                            pending = byte << (8 - live)
                            offset += 1
                        }
                    }
                    output = shifted
                }
                try emit(output)
                index += count
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
