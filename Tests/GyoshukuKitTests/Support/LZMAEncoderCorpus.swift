// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation
@testable import GyoshukuKit

/// 試験と benchmark が共有する corpus。機械の辞書や locale に依存しない。
enum LZMAEncoderCorpus {
    static func text(size: Int) -> Data {
        let words = "archive buffer branch byte cache change check chunk code compression context data decoder dictionary distance document encoder error file filter format header history index input integer length library literal match memory method model normal offset option output parser payload pointer position price probability property range reader record reset result size source state stream symbol table target test thread tree value window word writer".split(separator: " ")
        var random = TestCorpus.XorShift64(state: 0x1234_5678_9ABC_DEF1)
        var result = Data(); result.reserveCapacity(size)
        while result.count < size {
            var line = ""
            for _ in 0..<12 {
                let n = random.next()
                line += words[Int(n % UInt64(words.count))]
                line += n & 31 == 0 ? "\n" : " "
            }
            line += "\n"
            let bytes = Data(line.utf8)
            result.append(bytes.prefix(size - result.count))
        }
        return result
    }
    static func mixed(size: Int) -> Data {
        // 1 MiB 辞書の境界を越える距離、raw → compressed の state reset を含む。
        let random = TestCorpus.random(768 << 10)
        let words = text(size: 512 << 10)
        var result = Data(); result.reserveCapacity(size)
        while result.count < size {
            for data in [random, words, random, Data(repeating: 0, count: 128 << 10), words] {
                result.append(data.prefix(size - result.count))
                if result.count == size { break }
            }
        }
        return result
    }
    static func xz(_ payload: Data, input: Data, properties p: LZMAEncoderProperties) throws -> Data {
        var output = XZFraming.streamHeader
        let block = XZLZMA2(payload: payload, properties: LZMA2Encoder.dictionaryProperty(for: p.dictSize),
                           uncompressedSize: UInt64(input.count), payloadOffset: 0)
        let record = try XZFraming.emitBlock(block, crc: updateCRC(0, input)) { output.append($0) }
        try XZFraming.emitIndexAndFooter(records: record, blockCount: 1) { output.append($0) }
        return output
    }
}
