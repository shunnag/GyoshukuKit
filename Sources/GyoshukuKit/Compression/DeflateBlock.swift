import Foundation
private import zlib
private import Darwin

struct DeflateBlock: Sendable {
    static let size = 1024 * 1024
    /// deflate の辞書（sliding window）長。windowBits=15 の 32 KiB で、gzip の橋・照合・計画が同じ窓幅を使う。
    static let windowSize = 32 * 1024
    typealias Encoder = @Sendable (DeflateBlock, Int) throws -> Data

    let input: Data
    let dictionary: Data
    let final: Bool

    private final class Stream {
        let pointer: UnsafeMutablePointer<z_stream>
        let level: Int
        init(level: Int) throws {
            // 初期化が失敗した pointer を self に所有させず、throw 時の二重解放を避ける。
            let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            stream.initialize(to: z_stream())
            let status = deflateInit2_(stream, Int32(level), Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                      ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else {
                stream.deinitialize(count: 1); stream.deallocate()
                throw WriterError.compression(status)
            }
            self.pointer = stream
            self.level = level
        }
        deinit { _ = deflateEnd(pointer); pointer.deinitialize(count: 1); pointer.deallocate() }
    }

    // Swift の thread dictionary に依存せず、worker 終了時に deflateEnd する。
    nonisolated(unsafe) private static var streamKey: pthread_key_t = {
        var key = pthread_key_t()
        precondition(pthread_key_create(&key, { value in
            Unmanaged<Stream>.fromOpaque(value).release()
        }) == 0)
        return key
    }()

    static func encode(_ block: DeflateBlock, level: Int) throws -> Data {
        let cached = pthread_getspecific(streamKey).map { Unmanaged<Stream>.fromOpaque($0).takeUnretainedValue() }
        let owner: Stream
        if let cached, cached.level == level {
            owner = cached
            let status = deflateReset(owner.pointer)
            guard status == Z_OK else { throw WriterError.compression(status) }
        } else {
            owner = try Stream(level: level)
            let retained = Unmanaged.passRetained(owner).toOpaque()
            let status = pthread_setspecific(streamKey, retained)
            guard status == 0 else {
                Unmanaged<Stream>.fromOpaque(retained).release()
                throw WriterError.compression(Int32(status))
            }
            if let cached { Unmanaged.passUnretained(cached).release() }
        }
        return try encode(block, stream: owner.pointer)
    }

    static func encodeFresh(_ block: DeflateBlock, level: Int) throws -> Data {
        let owner = try Stream(level: level)
        return try withExtendedLifetime(owner) { try encode(block, stream: owner.pointer) }
    }

    private static func encode(_ block: DeflateBlock, stream: UnsafeMutablePointer<z_stream>) throws -> Data {
        precondition(block.input.count <= size && block.dictionary.count <= windowSize)
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
        input.withUnsafeBytes { Data($0.suffix(windowSize)) }
    }
}
