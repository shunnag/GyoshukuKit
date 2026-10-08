import Foundation

/// libbz2 1.0.8 bzlib.c の入力段だけを数える。圧縮済み bit の magic 検索には頼らない。
/// full の検査は次の byte の前。未確定 run の先頭が、直前の block を独立圧縮できる切断点。
struct Bzip2BlockScanner {
    let limit: Int
    private(set) var position = 0
    private(set) var blocks = 0
    private var nblock = 0
    private var character = 256
    private var runLength = 0
    private var runStart = 0

    init(level: Int) { limit = 100_000 * level - 19 }

    /// input はこの chunk の先頭から保持する。target 以上の最初の block 境界まで進める。
    mutating func scan(_ input: Data, target: Int) -> Int? {
        input.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = position, count = nblock, ch = character, length = runLength, start = runStart
            defer {
                position = index; nblock = count; character = ch; runLength = length; runStart = start
            }
            while index < bytes.count {
                if count >= limit {
                    count = 0
                    blocks += 1
                    if start >= target { return start }
                }
                let next = Int(bytes[index])
                if next != ch || length == 255 {
                    count += length < 4 ? length : 5
                    ch = next; length = 1; start = index
                } else { length += 1 }
                index += 1
            }
            return nil
        }
    }

    /// BZ_FINISH は残り入力が0なら full 判定より先に run をflushし、最後の block に含める。
    var finalBlockCount: Int { blocks + (position > 0 ? 1 : 0) }
}
