import Foundation
private import Compression

/// Apple Compression's LZMA encoder emits the XZ container. Its compression
/// settings are fixed; input/output buffers remain bounded across members.
final class XZCompressor: TarCompressor {
    private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var initialized = false
    private var finished = false
    private var output = [UInt8](repeating: 0, count: 256 * 1_024)

    init() throws {
        let status = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZMA)
        guard status == COMPRESSION_STATUS_OK else { throw WriterError.compression(status.rawValue) }
        initialized = true
    }

    deinit { if initialized { compression_stream_destroy(&stream) } }

    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        if input.isEmpty && !finish { return }
        var offset = 0
        while true {
            try Task.checkCancellation()
            let available = input.count - offset, capacity = output.count
            let status = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    stream.src_ptr = source.baseAddress.map {
                        $0.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
                    } ?? UnsafePointer<UInt8>(bitPattern: 1)!
                    stream.src_size = available
                    stream.dst_ptr = destination.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    stream.dst_size = capacity
                    defer {
                        stream.src_ptr = UnsafePointer<UInt8>(bitPattern: 1)!
                        stream.dst_ptr = UnsafeMutablePointer<UInt8>(bitPattern: 1)!
                    }
                    return compression_stream_process(&stream, finish ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                }
            }
            try Task.checkCancellation()
            guard stream.src_size <= available, stream.dst_size <= capacity else {
                throw WriterError.compression(-1)
            }
            let consumed = available - stream.src_size, produced = capacity - stream.dst_size
            offset += consumed
            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                throw WriterError.compression(status.rawValue)
            }
            if produced > 0 { try emit(Data(output.prefix(produced))) }
            if status == COMPRESSION_STATUS_END {
                guard finish, offset == input.count else { throw WriterError.compression(-1) }
                finished = true
                return
            }
            if !finish && offset == input.count { return }
            guard consumed > 0 || produced > 0 else { throw WriterError.compression(-1) }
        }
    }
}
