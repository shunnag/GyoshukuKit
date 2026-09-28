import Foundation
private import CGyoshukuBzip2

/// 外部 process ではなく system の libbz2 の低水準 streaming API で、一つの bzip2 stream を完結させる同期 codec。
/// ParallelBzip2Compressor は chunk ごとにこれを使う。bz_stream は native の寿命の間、同じ address に置く。
final class Bzip2StreamEncoder {
    private let stream: UnsafeMutablePointer<bz_stream>
    private var initialized = false
    private var finished = false
    private var output = [UInt8](repeating: 0, count: IOChunk.size)

    /// 入力全体を一つの stream に圧縮する。
    static func encode(_ input: Data, level: Int) throws -> Data {
        var result = Data()
        try Bzip2StreamEncoder(level: level).write(input, finish: true) { result.append($0) }
        return result
    }

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
