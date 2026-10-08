// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

/// 後続の container writer が共有する設定。辞書の宣言と実際の確保量は区別する。
struct LZMAEncoderProperties: Sendable, Equatable {
    enum MatchFinder: Sendable { case bt4, hc4 }
    enum Mode: Sendable { case fast, normal }
    var lc = 3
    var lp = 0
    var pb = 2
    var dictSize = 8 << 20
    var niceLen = 64
    var matchFinder: MatchFinder = .bt4
    var mode: Mode = .normal
    /// 0 は SDK の自動値。xz は normal mode で 16 + niceLen / 2 を使う。
    var depth = 0
    var cutValue: Int { depth == 0 ? (16 + niceLen / 2) >> (matchFinder == .hc4 ? 1 : 0) : depth }
    var packedByte: UInt8 { UInt8((pb * 5 + lp) * 9 + lc) }
    var bytes: Data {
        var result = Data([packedByte])
        result.le(UInt32(dictSize))
        return result
    }

    // 出典: https://github.com/tukaani-project/xz/blob/v5.8.1/src/liblzma/lzma/lzma_encoder_presets.c
    // 設定値の表を照合した。この版の source は SPDX 0BSD。encoder の翻訳元は上記 SDK。
    // level 0 の xz は HC3。本 API は指定された二方式に絞り、同じ深さの HC4 を使う。
    static func preset(_ level: Int, extreme: Bool = false) -> Self {
        precondition((0...9).contains(level))
        let powers = [18, 20, 21, 22, 22, 23, 23, 24, 25, 26]
        var p = Self()
        p.dictSize = 1 << powers[level]
        if level <= 3 {
            p.mode = .fast
            p.matchFinder = .hc4
            p.niceLen = level <= 1 ? 128 : 273
            p.depth = [4, 8, 24, 48][level]
        } else {
            p.niceLen = level == 4 ? 16 : level == 5 ? 32 : 64
        }
        if extreme {
            p.mode = .normal
            p.matchFinder = .bt4
            p.niceLen = level == 3 || level == 5 ? 192 : 273
            p.depth = level == 3 || level == 5 ? 0 : 512
        }
        return p
    }

    func validate(lzma2: Bool = false) throws {
        guard (0...8).contains(lc), (0...4).contains(lp), (0...4).contains(pb),
              !lzma2 || lc + lp <= 4,
              (4096...(3 << 29)).contains(dictSize), (5...273).contains(niceLen),
              (0...(1 << 30)).contains(depth) else { throw LZMAEncodingError.invalidProperties }
    }
}

enum LZMAEncodingError: Error {
    case invalidProperties
    case memoryLimit(required: Int, limit: Int)
    case allocationFailed
    case finished
    case sizeMismatch
}

/// calloc の失敗を Swift の error にする。全領域は初期化済みで、確保前に総量を検査する。
func lzmaAllocate<T: BitwiseCopyable>(_ type: T.Type, count: Int) throws -> UnsafeMutablePointer<T> {
    guard let p = calloc(count, MemoryLayout<T>.stride) else { throw LZMAEncodingError.allocationFailed }
    return p.bindMemory(to: T.self, capacity: count)
}
