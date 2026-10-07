import Foundation

/// 項目の codec state を一つの呼出側または worker に閉じ込める。framing と読取境界は共通。
final class ZipEntryCompressor {
    private let options: WriterOptions
    private var deflateCompressor: DeflateCompressor?
    init(options: WriterOptions) { self.options = options }

    func compress(name: String, size: UInt64, method: CompressionMethod,
                               read: (Int) throws -> Data, emit: (Data) throws -> Void) throws -> UInt32 {
        // ZIP method 12 は一つの encoder を最後まで使い、tar.bz2 の連結 stream 経路は使わない。
        let bzip2 = method == .bzip2 ? try Bzip2StreamEncoder(level: options.bzip2Level) : nil
        // parameter word は encoder が一度だけ出力し、ZIP 暗号化の内側に含める。
        let ppmd = method == .ppmd ? try PPMd8StreamEncoder(properties: options.ppmd8Properties()) : nil
        // method 93 は一 entry に一 frame。AES / ZipCrypto の共通 sink の内側へ逐次出力する。
        let zstd = method == .zstd ? try ZstdFrameEncoder(level: options.zstdLevel, contentSize: size) : nil
        // APPNOTE §4.4.5 の method 95 は、7-Zip 26.03 の生成 ZIP で完全な .xz stream と確認した。
        // ParallelXZCompressor は stream header・blocks・index・footer を一組だけ出力する。
        let configuration = method == .xz || method == .lzma
            ? try LZMAWriterConfiguration(options: options, raw: method == .lzma) : nil
        let lzma = method == .lzma ? try configuration!.rawEncoder(size: size, endMarker: true) : nil
        if let lzma {
            // APPNOTE §5.8: SDK 26.03 と互換の properties、長さ5、lc/lp/pb + 辞書 LE32。
            var header = Data([26, 3, 5, 0])
            header.append(lzma.properties.bytes)
            try emit(header)
        }
        let xz = method == .xz ? try ParallelXZCompressor(threads: configuration!.threads,
            chunkSize: configuration!.pieceSize, allowsLightChunks: configuration!.properties == nil,
            encoder: configuration!.encoder) : nil
        let compressor: DeflateCompressor?
        if method == .deflate {
            if let deflateCompressor {
                try deflateCompressor.reset()
            } else {
                deflateCompressor = try DeflateCompressor(level: options.deflateLevel)
            }
            compressor = deflateCompressor
        } else {
            compressor = nil
        }
        var remaining = size
        var crc: UInt32 = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(IOChunk.size), remaining))
            let chunk = try read(requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw WriterError.sourceChanged(name) }
            crc = updateCRC(crc, chunk)
            remaining -= UInt64(chunk.count)
            if let compressor { try compressor.write(chunk, emit: emit) }
            else if let bzip2 { try bzip2.write(chunk, finish: false, emit: emit) }
            else if let ppmd { try ppmd.write(chunk, finish: false, emit: emit) }
            else if let zstd { try zstd.write(chunk, emit: emit) }
            else if let xz { try xz.write(chunk, finish: false, emit: emit) }
            else if let lzma { try emit(lzmaWriterOperation { try lzma.push(chunk) }) }
            else { try emit(chunk) }
        }
        guard try read(1).isEmpty else { throw WriterError.sourceChanged(name) }
        if let compressor { try compressor.write(Data(), finish: true, emit: emit) }
        if let bzip2 { try bzip2.write(Data(), finish: true, emit: emit) }
        if let ppmd { try ppmd.write(Data(), finish: true, emit: emit) }
        if let zstd { try zstd.write(Data(), finish: true, emit: emit) }
        if let xz { try xz.write(Data(), finish: true, emit: emit) }
        if let lzma { try emit(lzmaWriterOperation { try lzma.finish() }) }
        return crc
    }

}
