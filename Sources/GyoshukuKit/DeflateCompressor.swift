import Foundation
private import zlib

// RFC 1951 と zlib の公開 API に基づく raw deflate。作業領域は entry 長に依存しない。
final class DeflateCompressor {
    private var stream = z_stream()
    private var initialized = false
    private var output = [UInt8](repeating: 0, count: 256 * 1024)

    init(level: Int) throws {
        let status = deflateInit2_(
            &stream, Int32(level), Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw WriterError.compression(status) }
        initialized = true
    }

    deinit {
        if initialized { _ = deflateEnd(&stream) }
    }

    func write(_ input: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        var offset = 0
        while true {
            let available = input.count - offset
            let capacity = output.count
            let status = input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    stream.next_in = inputBytes.baseAddress.map {
                        UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self).advanced(by: offset))
                    }
                    stream.avail_in = uInt(available)
                    stream.next_out = outputBytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(capacity)
                    // KaitoKit と同じく、一時バッファのポインタを構造体へ残さない。
                    defer {
                        stream.next_in = nil
                        stream.next_out = nil
                    }
                    return deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
                }
            }
            guard Int(stream.avail_in) <= available, Int(stream.avail_out) <= capacity else {
                throw WriterError.compression(Z_STREAM_ERROR)
            }
            let consumed = available - Int(stream.avail_in)
            let produced = capacity - Int(stream.avail_out)
            offset += consumed
            guard status == Z_OK || status == Z_STREAM_END else {
                throw WriterError.compression(status)
            }
            if produced > 0 { try emit(Data(output.prefix(produced))) }
            if status == Z_STREAM_END || (!finish && offset == input.count) { return }
            guard consumed > 0 || produced > 0 else { throw WriterError.compression(Z_BUF_ERROR) }
        }
    }
}

func updateCRC(_ crc: UInt32, _ data: Data) -> UInt32 {
    data.withUnsafeBytes { bytes in
        UInt32(crc32(uLong(crc), bytes.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
    }
}
