import Foundation
private import zlib

// tar 全体を一つの gzip member にする。ZIP 用の raw deflate の設定は変更しない。
final class GzipCompressor {
    private var stream = z_stream()
    private var initialized = false
    private var finished = false
    private var output = [UInt8](repeating: 0, count: 256 * 1024)
    // deflateSetHeader は pointer を保持するので、一時的な inout の領域を渡さない。
    private let header: UnsafeMutablePointer<gz_header>

    init(level: Int) throws {
        header = .allocate(capacity: 1)
        header.initialize(to: gz_header())
        // gzip 側は再現可能な MTIME=0、OS=Unix。名前・comment・extra は持ち出さない。
        header.pointee.time = 0
        header.pointee.os = 3
        let status = deflateInit2_(
            &stream, Int32(level), Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw WriterError.compression(status) }
        initialized = true
        let headerStatus = deflateSetHeader(&stream, header)
        guard headerStatus == Z_OK else { throw WriterError.compression(headerStatus) }
    }

    deinit {
        if initialized { _ = deflateEnd(&stream) }
        header.deinitialize(count: 1)
        header.deallocate()
    }

    func write(_ input: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        if input.isEmpty && !finish { return }
        var offset = 0
        while true {
            try Task.checkCancellation()
            let available = min(input.count - offset, Int(uInt.max))
            let capacity = output.count
            let finalChunk = finish && available == input.count - offset
            let status = input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    stream.next_in = inputBytes.baseAddress.map {
                        UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self).advanced(by: offset))
                    }
                    stream.avail_in = uInt(available)
                    stream.next_out = outputBytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(capacity)
                    defer {
                        stream.next_in = nil
                        stream.next_out = nil
                    }
                    return deflate(&stream, finalChunk ? Z_FINISH : Z_NO_FLUSH)
                }
            }
            guard Int(stream.avail_in) <= available, Int(stream.avail_out) <= capacity else {
                throw WriterError.compression(Z_STREAM_ERROR)
            }
            let consumed = available - Int(stream.avail_in)
            let produced = capacity - Int(stream.avail_out)
            offset += consumed
            guard status == Z_OK || status == Z_STREAM_END else { throw WriterError.compression(status) }
            if produced > 0 { try emit(Data(output.prefix(produced))) }
            if status == Z_STREAM_END {
                finished = true
                return
            }
            if !finish && offset == input.count { return }
            guard consumed > 0 || produced > 0 else { throw WriterError.compression(Z_BUF_ERROR) }
        }
    }
}
