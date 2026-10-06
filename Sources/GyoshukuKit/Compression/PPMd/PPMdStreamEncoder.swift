// 出自: LZMA SDK 26.03 C/Ppmd7.c、C/Ppmd7Enc.c と 7-Zip 26.03 の公開ドメイン C/Ppmd8.c、C/Ppmd8Enc.c。
// Igor Pavlov、原作 Dmitry Shkarin、Subbotin range coder（全て公開ドメイン）。framing は APPNOTE §5.10。
import Foundation

/// 同期・逐次の一つの stream。入力の保持はせず、失敗した instance は再使用しない。
class PPMdStreamEncoder {
    private enum State { case ready, writing, finished, failed }
    private var state = State.ready
    private var header: Data
    private let coder: PPMdRangeEncoder
    let model: PPMdEncodingModel

    init(order: Int, memorySize: Int, variantI: Bool,
         restoration: PPMdRestorationMethod = .restart, header: Data = Data()) throws {
        model = try PPMdEncodingModel(order: order, memorySize: memorySize, variantI: variantI, restoration: restoration)
        coder = PPMdRangeEncoder(variantI: variantI)
        self.header = header
    }

    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard state == .ready else { throw WriterError.invalidState }
        if input.isEmpty && !finish { return }
        state = .writing
        var completed = false
        defer { if !completed { state = .failed } }
        try Task.checkCancellation()
        if !header.isEmpty { try emit(header); header.removeAll(keepingCapacity: false) }
        try input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in 0..<bytes.count {
                if i & 4095 == 0 { try Task.checkCancellation() }
                try model.encode(Int(bytes[i]), using: coder, emit: emit)
            }
        }
        try Task.checkCancellation()
        if finish {
            // ZIP は root からの escape を EOF として書き、4 byte flush する。
            // 7z は folder の展開サイズで終端を知るため、5 byte flush だけを書く。
            if coder.variantI { try model.encode(-1, using: coder, emit: emit) }
            try coder.finish(emit: emit)
        } else { try coder.drain(emit: emit) }
        state = finish ? .finished : .ready
        completed = true
    }
}

final class PPMd7StreamEncoder: PPMdStreamEncoder {
    let properties: PPMd7EncoderProperties

    init(properties: PPMd7EncoderProperties) throws {
        self.properties = properties
        try super.init(order: properties.order, memorySize: properties.memorySize, variantI: false)
    }

    convenience init(level: Int) throws { try self.init(properties: .preset(level)) }

    static func encode(_ input: Data, properties: PPMd7EncoderProperties) throws -> Data {
        var result = Data()
        try Self(properties: properties).write(input, finish: true) { result.append($0) }
        return result
    }
}

final class PPMd8StreamEncoder: PPMdStreamEncoder {
    let properties: PPMd8EncoderProperties

    init(properties: PPMd8EncoderProperties) throws {
        self.properties = properties
        try super.init(order: properties.order, memorySize: properties.memorySize, variantI: true,
                       restoration: properties.restoration, header: properties.header)
    }

    convenience init(level: Int, restoration: PPMdRestorationMethod = .restart) throws {
        try self.init(properties: .preset(level, restoration: restoration))
    }

    /// ZIP method 98 の payload 全体。2 byte parameter word を含む。
    static func encode(_ input: Data, properties: PPMd8EncoderProperties) throws -> Data {
        var result = Data()
        try Self(properties: properties).write(input, finish: true) { result.append($0) }
        return result
    }
}
