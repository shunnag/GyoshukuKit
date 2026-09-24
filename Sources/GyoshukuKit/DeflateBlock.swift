import Foundation
private import zlib

struct DeflateBlock: Sendable {
    static let size = 1024 * 1024
    typealias Encoder = @Sendable (DeflateBlock, Int) throws -> Data

    let input: Data
    let dictionary: Data
    let final: Bool

    static func encode(_ block: DeflateBlock, level: Int) throws -> Data {
        precondition(block.input.count <= size && block.dictionary.count <= 32 * 1024)
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        let initialized = deflateInit2_(stream, Int32(level), Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw WriterError.compression(initialized) }
        defer { _ = deflateEnd(stream) }
        if !block.dictionary.isEmpty {
            let status = block.dictionary.withUnsafeBytes {
                deflateSetDictionary(stream, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count))
            }
            guard status == Z_OK else { throw WriterError.compression(status) }
        }
        // 一度の flush を全て収め、出力不足による追加の空 block を避ける。
        var output = Data(count: Int(try bound(UInt64(block.input.count))) + 1)
        let status = block.input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.pointee.next_in = source.baseAddress.map {
                    UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self))
                }
                stream.pointee.avail_in = uInt(source.count)
                stream.pointee.next_out = destination.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.pointee.avail_out = uInt(destination.count)
                defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                return deflate(stream, block.final ? Z_FINISH : Z_SYNC_FLUSH)
            }
        }
        guard status == (block.final ? Z_STREAM_END : Z_OK),
              stream.pointee.avail_in == 0, stream.pointee.avail_out > 0 else {
            throw WriterError.compression(status < 0 ? status : Z_BUF_ERROR)
        }
        output.removeLast(Int(stream.pointee.avail_out))
        return output
    }

    // windowBits=15 / memLevel=8 の compressBound に、SYNC_FLUSH の最大6 byte を加える。
    static func bound(_ size: UInt64) throws -> UInt64 {
        var result = size
        for extra in [size >> 12, size >> 14, size >> 25, 13, 6] {
            result = try checkedAdd(result, extra)
        }
        return result
    }

    static func bound(size: UInt64, blockSize: Int) throws -> UInt64 {
        precondition((1...Self.size).contains(blockSize))
        let full = size / UInt64(blockSize), tail = size % UInt64(blockSize)
        let (total, overflow) = try bound(UInt64(blockSize)).multipliedReportingOverflow(by: full)
        guard !overflow else { throw WriterError.sizeOverflow }
        return try checkedAdd(total, tail > 0 || size == 0 ? bound(tail) : 0)
    }

    static func dictionary(from input: Data) -> Data {
        // slice の backing storage に前 block 全体を残さない。
        input.withUnsafeBytes { Data($0.suffix(32 * 1024)) }
    }
}
