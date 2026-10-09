import Foundation

/// SDK 26.03 Bra.c / Bra86.c / Delta.c と KaitoKit の逆変換に対応する前向き変換。
/// offset と履歴は folder 単位。命令の端数だけを次の I/O に持ち越す。
enum SevenZipWriteFilter: Equatable {
    case none, x86(UInt32), arm64(UInt32), delta(Int)

    var coder: SevenZipEditModel.Coder? {
        switch self {
        case .none: return nil
        case .x86(let start), .arm64(let start):
            var properties = Data()
            if start != 0 { properties.le(start) }
            return .init(methodID: self == .x86(start) ? [3, 3, 1, 3] : [0x0A],
                         properties: properties.isEmpty ? nil : Array(properties))
        case .delta(let distance): return .init(methodID: [3], properties: [UInt8(distance - 1)])
        }
    }

    static func select(_ mode: SevenZipFilterMode, prefix: Data) -> Self {
        switch mode {
        case .none: return .none
        case .bcjX86: return .x86(0)
        case .arm64: return .arm64(0)
        case .delta(let distance): return .delta(distance)
        case .auto: return detect(prefix)
        }
    }

    static func preserved(in folder: SevenZipEditModel.Folder) throws -> Self {
        for coder in folder.coders {
            if coder.methodID == [3] {
                guard let properties = coder.properties, properties.count == 1 else { throw WriterError.invalidState }
                return .delta(Int(properties[0]) + 1)
            }
            if coder.methodID == [3, 3, 1, 3] || coder.methodID == [0x0A] {
                let properties = coder.properties ?? []
                guard properties.isEmpty || properties.count == 4 else { throw WriterError.invalidState }
                let start = properties.isEmpty ? 0 : uint32(properties, 0)
                return coder.methodID == [0x0A] ? .arm64(start) : .x86(start)
            }
        }
        return .none
    }

    /// PE の e_lfanew を含む先頭64 KiBだけを読む。範囲外の header は推測しない。
    private static func detect(_ prefix: Data) -> Self {
        let b = Array(prefix)
        guard b.count >= 20 else { return .none }
        let magic = uint32(b, 0)
        if magic == 0xFEED_FACE || magic == 0xFEED_FACF || magic == 0xCEFA_EDFE || magic == 0xCFFA_EDFE {
            let cpu = magic == 0xFEED_FACE || magic == 0xFEED_FACF ? uint32(b, 4) : uint32BE(b, 4)
            if cpu == 7 || cpu == 0x0100_0007 { return .x86(0) }
            if cpu == 0x0100_000C { return .arm64(0) }
        } else if Array(b.prefix(4)) == [0x7F, 0x45, 0x4C, 0x46], b[4] == 2, b[5] == 1 || b[5] == 2 {
            let machine = b[5] == 1 ? UInt16(b[18]) | UInt16(b[19]) << 8 : UInt16(b[18]) << 8 | UInt16(b[19])
            if machine == 183 { return .arm64(0) }
        } else if b[0] == 0x4D, b[1] == 0x5A, b.count >= 64 {
            let offset = Int(uint32(b, 60))
            if offset <= b.count - 6, Array(b[offset..<(offset + 4)]) == [0x50, 0x45, 0, 0] {
                let machine = UInt16(b[offset + 4]) | UInt16(b[offset + 5]) << 8
                if machine == 0x14C || machine == 0x8664 { return .x86(0) }
                if machine == 0xAA64 { return .arm64(0) }
            }
        }
        return .none
    }

    fileprivate static func uint32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func uint32BE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

final class SevenZipFilterEncoder {
    private let filter: SevenZipWriteFilter
    // BCJ の未処理命令は最大4 byte。入力全体を配列へ往復させない。
    private var carry: UInt32 = 0
    private var carryCount = 0
    private var offset: UInt32 = 0
    private var x86State: UInt32 = 0
    private var history: [UInt8]

    init(_ filter: SevenZipWriteFilter) {
        self.filter = filter
        if case .delta(let distance) = filter {
            precondition((1...256).contains(distance))
            history = [UInt8](repeating: 0, count: distance)
        } else { history = [] }
        switch filter { case .x86(let start), .arm64(let start): offset = start; default: break }
    }

    func push(_ data: Data, final: Bool) -> Data {
        switch filter {
        case .none: return data
        case .delta(let distance): return encodeDelta(data, distance: distance)
        case .x86, .arm64: break
        }
        let total = carryCount + data.count
        guard total > 0 else { return Data() }
        var output = Data(count: total)
        let count = output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
            let bytes = buffer.baseAddress!
            withUnsafeBytes(of: carry) { previous in
                bytes.copyMemory(from: previous.baseAddress!, byteCount: carryCount)
            }
            data.withUnsafeBytes { input in
                if !input.isEmpty { bytes.advanced(by: carryCount).copyMemory(from: input.baseAddress!, byteCount: input.count) }
            }
            let consumed: Int
            switch filter {
            case .x86: consumed = Self.encodeX86(buffer, offset: offset, state: &x86State)
            case .arm64: consumed = Self.encodeARM64(buffer, offset: offset)
            default: preconditionFailure()
            }
            let count = final ? total : consumed
            carryCount = total - count
            assert(carryCount <= 4)
            carry = 0
            withUnsafeMutableBytes(of: &carry) { previous in
                previous.baseAddress!.copyMemory(from: bytes.advanced(by: count), byteCount: carryCount)
            }
            return count
        }
        output.count = count
        offset &+= UInt32(truncatingIfNeeded: count)
        return output
    }

    private func encodeDelta(_ data: Data, distance: Int) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(count: data.count)
        data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                history.withUnsafeMutableBufferPointer { tail in
                    let source = input.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let result = destination.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let previous = tail.baseAddress!
                    let leading = min(distance, input.count)
                    for i in 0..<leading { result[i] = source[i] &- previous[i] }
                    // 同じ入力内の参照だけなので、剰余・履歴更新・配列検査なしで SIMD 化できる。
                    // 基点を先にずらし、添字の減算に付く溢れ検査も内側から除く。
                    let current = source.advanced(by: leading), body = result.advanced(by: leading)
                    for i in 0..<(input.count - leading) { body[i] = current[i] &- source[i] }
                    if input.count >= distance {
                        previous.update(from: source.advanced(by: input.count - distance), count: distance)
                    } else {
                        // 短い push は時系列順の履歴を詰め、末尾に今回の入力を継ぐ。
                        let nextTail = previous.advanced(by: input.count)
                        for i in 0..<(distance - input.count) { previous[i] = nextTail[i] }
                        previous.advanced(by: distance - input.count).update(from: source, count: input.count)
                    }
                }
            }
        }
        return output
    }

    @inline(__always)
    private static func signByte(_ value: UInt8) -> Bool { value == 0 || value == 0xFF }
    // mask を添字とする元の8要素の表を定数へ詰める。
    private static let x86Allowed: UInt32 = 0x17
    private static let x86Bits: UInt32 = 0x3333_2210
    @inline(__always)
    private static func bitNumber(_ mask: Int) -> Int { Int((x86Bits >> (mask * 4)) & 15) }

    private static func encodeX86(_ buffer: UnsafeMutableRawBufferPointer, offset: UInt32, state: inout UInt32) -> Int {
        guard buffer.count >= 5 else { return 0 }
        let pending = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let limit = buffer.count - 4
        let base = offset &+ 5
        var position = 0, previous = -1, mask = Int(state & 7)
        while true {
            while position < limit, pending[position] & 0xFE != 0xE8 { position += 1 }
            guard position < limit else { break }
            let distance = position - previous
            if distance > 3 { mask = 0 }
            else {
                mask = (mask << (distance - 1)) & 7
                if mask != 0, x86Allowed & (1 << mask) == 0 || signByte(pending[position + 4 - bitNumber(mask)]) {
                    previous = position; mask = ((mask << 1) | 1) & 7; position += 1
                    continue
                }
            }
            previous = position
            if signByte(pending[position + 4]) {
                var source = UInt32(littleEndian: buffer.baseAddress!.loadUnaligned(fromByteOffset: position + 1, as: UInt32.self))
                var destination: UInt32
                while true {
                    destination = source &+ (base &+ UInt32(truncatingIfNeeded: position))
                    guard mask != 0 else { break }
                    let shift = bitNumber(mask) * 8
                    guard signByte(UInt8(truncatingIfNeeded: destination >> (24 - shift))) else { break }
                    source = destination ^ ((UInt32(1) << (32 - shift)) &- 1)
                }
                // BCJ は25 bitの変位。bit 24を上位byteへ符号拡張する。
                destination = (destination & 0x00FF_FFFF) | (destination & 0x0100_0000 == 0 ? 0 : 0xFF00_0000)
                buffer.baseAddress!.storeBytes(of: destination.littleEndian, toByteOffset: position + 1, as: UInt32.self)
                position += 5
            } else { mask = ((mask << 1) | 1) & 7; position += 1 }
        }
        let distance = position - previous
        state = distance > 3 ? 0 : UInt32((mask << (distance - 1)) & 7)
        return position
    }

    private static func encodeARM64(_ buffer: UnsafeMutableRawBufferPointer, offset: UInt32) -> Int {
        let count = buffer.count & ~3
        guard count > 0 else { return 0 }
        let pending = buffer.baseAddress!
        for i in stride(from: 0, to: count, by: 4) {
            var instruction = UInt32(littleEndian: pending.loadUnaligned(fromByteOffset: i, as: UInt32.self))
            let pc = offset &+ UInt32(truncatingIfNeeded: i)
            if instruction & 0xFC00_0000 == 0x9400_0000 {
                instruction = 0x9400_0000 | ((instruction &+ (pc >> 2)) & 0x03FF_FFFF)
                pending.storeBytes(of: instruction.littleEndian, toByteOffset: i, as: UInt32.self)
            } else if instruction & 0x9F00_0000 == 0x9000_0000 {
                let immediate = ((instruction >> 29) & 3) | (((instruction >> 5) & 0x7_FFFF) << 2)
                guard immediate < 0x2_0000 || immediate >= 0x1E_0000 else { continue }
                var encoded = (immediate &+ (pc >> 12)) & 0x3_FFFF
                if encoded & 0x2_0000 != 0 { encoded |= 0x1C_0000 }
                instruction &= ~UInt32(0x60FF_FFE0)
                instruction |= (encoded & 3) << 29 | ((encoded >> 2) & 0x7_FFFF) << 5
                pending.storeBytes(of: instruction.littleEndian, toByteOffset: i, as: UInt32.self)
            }
        }
        return count
    }
}

/// filter の端数を吸収し、圧縮 pipeline には指定サイズの入力を渡す。
final class SevenZipFilteredInput {
    private let encoder: SevenZipFilterEncoder
    private var remaining: UInt64
    private var ready = Data()
    private var cursor = 0
    init(filter: SevenZipWriteFilter, size: UInt64) { encoder = .init(filter); remaining = size }

    func read(_ count: Int, source: (Int) throws -> Data) throws -> Data {
        while cursor == ready.count, remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(IOChunk.size), remaining))
            let bytes = try source(requested)
            guard !bytes.isEmpty, bytes.count <= requested else { throw WriterError.sourceChanged("7z filter") }
            remaining -= UInt64(bytes.count)
            ready = encoder.push(bytes, final: remaining == 0); cursor = 0
        }
        let end = min(ready.count, cursor + count)
        defer { cursor = end }
        return ready.subdata(in: cursor..<end)
    }
}
