import Foundation
private import Compression

// 出典: Brotli RFC 7932（形式）と Apple Compression streaming API（圧縮は OS に委譲）。
// https://www.rfc-editor.org/rfc/rfc7932
// https://developer.apple.com/documentation/compression/compression_brotli
// Xcode SDK usr/include/compression.h は COMPRESSION_BROTLI を macOS 12.0 以降、
// encoder は固定 level 2 と記載する。Package.swift の macOS 26.0 はこの条件を満たす。
// Brotli stream は連結できないため、全入力を一つの逐次 stream とし level は公開しない。
final class BrotliStreamEncoder {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let empty: UnsafeMutablePointer<UInt8>
    private var initialized = false
    private var finished = false
    private var output = [UInt8](repeating: 0, count: IOChunk.size)

    init() throws {
        empty = .allocate(capacity: 1)
        empty.initialize(to: 0)
        stream = .allocate(capacity: 1)
        stream.initialize(to: compression_stream(dst_ptr: empty, dst_size: 0,
                                                 src_ptr: UnsafePointer(empty), src_size: 0, state: nil))
        let status = compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_BROTLI)
        guard status == COMPRESSION_STATUS_OK else { throw WriterError.compression(status.rawValue) }
        initialized = true
    }

    deinit {
        if initialized { compression_stream_destroy(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
        empty.deinitialize(count: 1)
        empty.deallocate()
    }

    func write(_ input: Data, finish: Bool = false, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        do {
            try Task.checkCancellation()
            if input.isEmpty && !finish { return }
            var offset = 0
            while true {
                try Task.checkCancellation()
                let available = input.count - offset, capacity = output.count
                let status = input.withUnsafeBytes { source in
                    output.withUnsafeMutableBytes { destination in
                        stream.pointee.src_ptr = source.baseAddress.map {
                            $0.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
                        } ?? UnsafePointer(empty)
                        stream.pointee.src_size = available
                        stream.pointee.dst_ptr = destination.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        stream.pointee.dst_size = capacity
                        // native state の寿命中も、Swift buffer の pointer を closure 外に残さない。
                        defer { stream.pointee.src_ptr = UnsafePointer(empty); stream.pointee.dst_ptr = empty }
                        return compression_stream_process(stream, finish ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    }
                }
                try Task.checkCancellation()
                guard status != COMPRESSION_STATUS_ERROR,
                      stream.pointee.src_size <= available, stream.pointee.dst_size <= capacity else {
                    throw WriterError.compression(COMPRESSION_STATUS_ERROR.rawValue)
                }
                let consumed = available - stream.pointee.src_size
                let produced = capacity - stream.pointee.dst_size
                offset += consumed
                if produced > 0 { try emit(Data(output.prefix(produced))) }
                if status == COMPRESSION_STATUS_END {
                    guard finish, offset == input.count else { throw WriterError.compression(-1) }
                    finished = true
                    return
                }
                if !finish && offset == input.count { return }
                guard consumed > 0 || produced > 0 else { throw WriterError.compression(-1) }
            }
        } catch {
            finished = true
            throw error
        }
    }
}
