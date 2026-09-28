import Foundation
internal import KaitoKit

// KaitoKit の EntryStream から Data を取り出す二つの読み方。名前で「満たすまで読む」か「一度だけ読む」かを区別する。
extension EntryStream {
    /// count byte を満たすまで read を繰り返す。EOF で短くなり、空は終端。
    func readFully(upTo count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        let capacity = data.count
        try data.withUnsafeMutableBytes { storage in
            while filled < capacity {
                try Task.checkCancellation()
                let count = try read(into: UnsafeMutableRawBufferPointer(rebasing: storage[filled..<capacity]))
                if count == 0 { break }
                filled += count
            }
        }
        data.count = filled
        return data
    }

    /// 一度の read が返す分だけを返す。空は終端。count が 0 でも 1 byte は求め、終端の探りに使える。
    func readSome(upTo count: Int) throws -> Data {
        var data = Data(count: max(1, count))
        let count = try data.withUnsafeMutableBytes { try read(into: $0) }
        data.removeSubrange(count..<data.count)
        return data
    }
}
