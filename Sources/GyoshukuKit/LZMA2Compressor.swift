import Foundation
private import Compression

enum LZMA2Compressor {
    static func encode(_ input: Data) throws -> XZLZMA2 {
        let result = try XZLZMA2.extract(encodeXZ(input))
        guard result.uncompressedSize == UInt64(input.count) else { throw WriterError.compression(-1) }
        return result
    }

    static func encodeXZ(_ input: Data) throws -> Data {
        try Task.checkCancellation()
        guard !input.isEmpty else { throw WriterError.compression(-1) }
        let size = UInt64(input.count)
        let limit = try checkedAdd(checkedAdd(size, size), 65_536)
        guard limit <= UInt64(Int.max) else { throw WriterError.sizeOverflow }
        var capacity = Int(try checkedAdd(size, max(1024, size / 16)))
        while true {
            try Task.checkCancellation()
            var output = Data(count: capacity)
            let count = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    compression_encode_buffer(
                        destination.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                        source.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                        nil, COMPRESSION_LZMA
                    )
                }
            }
            // buffer API の呼出し中は中断できないので、返った直後にも確認して未完了出力を残さない。
            try Task.checkCancellation()
            if count > 0 {
                output.removeSubrange(count..<output.count)
                return output
            }
            // 0 は容量不足と encoder の失敗を区別しない。再試行で無制限に領域を増やさない。
            guard capacity < Int(limit) else { throw WriterError.compression(-1) }
            capacity = Int(min(UInt64(capacity) * 2, limit))
        }
    }
}
