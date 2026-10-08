// 出自: LZMA SDK 26.03 C/Ppmd7.h、7-Zip 26.03 の公開ドメイン C/Ppmd8.h（Igor Pavlov、原作 Dmitry Shkarin）。
// ZIP parameter word は PKWARE APPNOTE §5.10。preset 表は GyoshukuKit 独自の定義。
import Foundation

struct PPMd7EncoderProperties: Equatable, Sendable {
    let order: Int
    let memorySize: Int

    init(order: Int = 6, memorySize: Int = 16 << 20) throws {
        guard (2...32).contains(order) else { throw WriterError.invalidOption("ppmdOrder") }
        guard (1 << 20 ... 1 << 30).contains(memorySize) else {
            throw WriterError.invalidOption("ppmdMemorySize")
        }
        self.order = order
        self.memorySize = memorySize
    }

    /// 7z method 03 04 01 の coder properties。圧縮 stream 本体には含めない。
    var coderProperties: Data {
        let size = UInt32(memorySize)
        return Data([UInt8(order), UInt8(truncatingIfNeeded: size), UInt8(truncatingIfNeeded: size >> 8),
                     UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 24)])
    }

    static func preset(_ level: Int) throws -> Self {
        guard (1...9).contains(level) else { throw WriterError.invalidOption("ppmdLevel") }
        let orders = [3, 4, 4, 5, 6, 6, 8, 12, 16]
        let mebibytes = [1, 2, 4, 8, 16, 16, 32, 64, 192]
        return try Self(order: orders[level - 1], memorySize: mebibytes[level - 1] << 20)
    }
}

enum PPMdRestorationMethod: UInt16, CaseIterable, Sendable {
    case restart = 0
    case cutOff = 1
}

struct PPMd8EncoderProperties: Equatable, Sendable {
    let order: Int
    let memorySize: Int
    let restoration: PPMdRestorationMethod

    init(order: Int = 8, memorySize: Int = 16 << 20,
         restoration: PPMdRestorationMethod = .restart) throws {
        guard (2...16).contains(order) else { throw WriterError.invalidOption("ppmdOrder") }
        guard (1...256).contains(memorySize >> 20), memorySize & ((1 << 20) - 1) == 0 else {
            throw WriterError.invalidOption("ppmdMemorySize")
        }
        self.order = order
        self.memorySize = memorySize
        self.restoration = restoration
    }

    /// APPNOTE §5.10.4 の little endian word。freeze は rev.1 / rev.2 の非互換があるため提供しない。
    var parameterWord: UInt16 {
        UInt16(order - 1) | (UInt16((memorySize >> 20) - 1) << 4) | (restoration.rawValue << 12)
    }

    var header: Data {
        Data([UInt8(truncatingIfNeeded: parameterWord), UInt8(parameterWord >> 8)])
    }

    static func preset(_ level: Int, restoration: PPMdRestorationMethod = .restart) throws -> Self {
        guard (1...9).contains(level) else { throw WriterError.invalidOption("ppmdLevel") }
        let orders = [3, 4, 5, 6, 8, 8, 10, 12, 16]
        let mebibytes = [1, 2, 4, 8, 16, 16, 32, 64, 192]
        return try Self(order: orders[level - 1], memorySize: mebibytes[level - 1] << 20, restoration: restoration)
    }
}
