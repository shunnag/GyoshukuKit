import Foundation
private import CGyoshukuBzip2

/// Uses the system libbz2 low-level streaming API, not an external process.
/// The bz_stream has a stable address for its entire native lifetime.
final class Bzip2Compressor: TarCompressor {
    private let stream: UnsafeMutablePointer<bz_stream>
    private var initialized = false
    private var finished = false
    private var output = [UInt8](repeating: 0, count: 256 * 1_024)

    init(level: Int) throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: bz_stream())
        guard (1...9).contains(level) else { throw WriterError.invalidOption("bzip2Level") }
        let status = BZ2_bzCompressInit(stream, Int32(level), 0, 30)
        guard status == BZ_OK else { throw WriterError.compression(status) }
        initialized = true
    }

    deinit {
        if initialized { BZ2_bzCompressEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func write(_ input: Data, finish: Bool, emit: (Data) throws -> Void) throws {
        guard !finished else { throw WriterError.invalidState }
        if input.isEmpty && !finish { return }
        var offset = 0
        while true {
            try Task.checkCancellation()
            let available = min(input.count - offset, Int(UInt32.max)), capacity = output.count
            let finalChunk = finish && available == input.count - offset
            let status = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    stream.pointee.next_in = source.baseAddress.map {
                        UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: CChar.self).advanced(by: offset))
                    }
                    stream.pointee.avail_in = UInt32(available)
                    stream.pointee.next_out = destination.baseAddress!.assumingMemoryBound(to: CChar.self)
                    stream.pointee.avail_out = UInt32(capacity)
                    defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                    return BZ2_bzCompress(stream, finalChunk ? BZ_FINISH : BZ_RUN)
                }
            }
            try Task.checkCancellation()
            guard stream.pointee.avail_in <= available, stream.pointee.avail_out <= capacity else {
                throw WriterError.compression(BZ_SEQUENCE_ERROR)
            }
            let consumed = available - Int(stream.pointee.avail_in)
            let produced = capacity - Int(stream.pointee.avail_out)
            offset += consumed
            guard status == (finalChunk ? BZ_FINISH_OK : BZ_RUN_OK) || status == BZ_STREAM_END else {
                throw WriterError.compression(status)
            }
            if produced > 0 { try emit(Data(output.prefix(produced))) }
            if status == BZ_STREAM_END {
                guard finish, offset == input.count else { throw WriterError.compression(BZ_SEQUENCE_ERROR) }
                finished = true
                return
            }
            if !finish && offset == input.count { return }
            guard consumed > 0 || produced > 0 else { throw WriterError.compression(BZ_SEQUENCE_ERROR) }
        }
    }
}
