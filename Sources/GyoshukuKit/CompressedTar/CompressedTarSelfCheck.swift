import Foundation
private import Darwin
private import zlib
private import Compression
private import CGyoshukuBzip2
@_spi(TarEditLayout) internal import KaitoKit

enum CompressedTarSelfCheck {
    typealias Metadata = CompressedTarSpliceOutput.Metadata
    typealias Part = CompressedTarSpliceOutput.WrittenPart
    static func failure(_ reason: String) -> TarUpdaterError { .outputVerificationFailed(reason: reason) }

    static func units(format: ArchiveFormat, metas: [Metadata], encoded: [Bool], tail: Int) -> UInt64 {
        var count: UInt64 = format == .tarGzip ? 18 : format == .tarXZ ? UInt64(12 + tail) : 0
        for (meta, isEncoded) in zip(metas, encoded) {
            if isEncoded { count += meta.length }
            if format == .tarBzip2 { count += min(10, meta.length) + min(11, meta.length) }
            if format == .tarXZ { count += meta.headerSize + (4 - meta.payloadSize % 4) % 4 + 4 }
        }
        return count
    }

    static func verify(writer: CompressedTarSpliceOutput, image: TarImageSource, plan: CompressedTarSplicePlan,
                       descriptor: Int32, meter: CommitProgressMeter) throws {
        try CompressedTarUpdater.testingStage?(.selfCheck)
        try ledger(writer: writer, image: image, plan: plan)
        let format = writer.format
        struct Input: Sendable {
            let compressed: Data
            let part: Part
        }
        let pipeline = OrderedChunkPipeline<Input, UInt64, Void>(threads: writer.threads) { input in
            do {
                let part = input.part
                let expected = try TarLayout.bytes(image, at: part.image.lowerBound, count: Int(part.image.byteLength))
                let decoded: Data
                switch format {
                case .tarGzip:
                    let window = min(UInt64(DeflateBlock.windowSize), part.image.lowerBound)
                    let dictionary = try TarLayout.bytes(image, at: part.image.lowerBound - window, count: Int(window))
                    decoded = try gzip(input.compressed, count: expected.count, dictionary: dictionary,
                                       final: part.image.upperBound == image.length)
                case .tarBzip2: decoded = try bzip2(input.compressed, count: expected.count)
                case .tarXZ:
                    var wrapped = XZFraming.streamHeader + input.compressed
                    let record = XZFraming.vli(part.meta.unpaddedSize) + XZFraming.vli(part.image.byteLength)
                    try XZFraming.emitIndexAndFooter(records: record, blockCount: 1) { wrapped.append($0) }
                    decoded = try xz(wrapped, count: expected.count)
                    guard input.compressed.zip32(input.compressed.count - 4) == updateCRC(0, expected) else { throw failure("V1 xz check") }
                default: throw failure("V1 codec")
                }
                guard decoded == expected else { throw failure("V1 image bytes") }
                return UInt64(input.compressed.count)
            } catch {
                if error is CancellationError { throw error }
                throw failure("V1: \(error)")
            }
        }
        let emit: (Void, UInt64?) throws -> Void = { _, count in if let count { try meter.advance(count) } }
        for part in writer.parts where part.baseIndex == nil {
            try Task.checkCancellation()
            try pipeline.waitForCapacity(emit: emit)
            let bytes = try SplicedArchiveOutput.read(descriptor, at: part.output.lowerBound, count: Int(part.output.byteLength), counted: true)
            try pipeline.submit(Input(compressed: bytes, part: part), tag: (), emit: emit)
        }
        try pipeline.finish(emit: emit)
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try Task.checkCancellation()
            let result = try SplicedArchiveOutput.read(descriptor, at: offset, count: count, counted: true)
            try meter.advance(UInt64(count))
            return result
        }
        if format == .tarGzip {
            guard try read(0, 10) == GzipFraming.header(level: writer.options.deflateLevel),
                  try read(writer.payloadEnd, 8) == writer.expectedTail else { throw failure("V2 gzip framing") }
        } else if format == .tarBzip2 {
            for part in writer.parts {
                let head = try read(part.output.lowerBound, Int(min(10, part.output.byteLength)))
                let tail = try read(part.output.upperBound - min(11, part.output.byteLength), Int(min(11, part.output.byteLength)))
                guard head.count == 10, head.prefix(3) == Data("BZh".utf8), (49...57).contains(head[3]),
                      [Data([0x31,0x41,0x59,0x26,0x53,0x59]), Data([0x17,0x72,0x45,0x38,0x50,0x90])].contains(Data(head.suffix(6))),
                      hasBzip2End(tail) else { throw failure("V2 bzip2 framing") }
            }
        } else {
            guard try read(0, 12) == XZFraming.streamHeader,
                  try read(writer.payloadEnd, writer.expectedTail.count) == writer.expectedTail,
                  writer.finalLength % 4 == 0 else { throw failure("V2 xz stream framing") }
            for part in writer.parts {
                let header = try read(part.output.lowerBound, Int(part.meta.headerSize))
                try xzHeader(header, meta: part.meta, imageLength: part.image.byteLength)
                let padding = Int((4 - part.meta.payloadSize % 4) % 4)
                let tail = try read(part.output.lowerBound + part.meta.headerSize + part.meta.payloadSize, padding + 4)
                guard tail.prefix(padding).allSatisfy({ $0 == 0 }) else { throw failure("V2 xz padding") }
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) == writer.finalLength,
              ArchiveOwnedFile.matches(url: writer.output, descriptor: descriptor) else { throw failure("V3 output identity/length") }
        guard writer.snapshot.archiveIsUnchanged() else { throw UpdaterError.sourceChanged }
    }

    private static func ledger(writer: CompressedTarSpliceOutput, image: TarImageSource, plan: CompressedTarSplicePlan) throws {
        var position: UInt64 = 0, compressed: UInt64 = writer.format == .tarGzip ? 10 : writer.format == .tarXZ ? 12 : 0
        for part in writer.parts {
            guard part.image.lowerBound == position, part.output.lowerBound == compressed,
                  part.output.byteLength == part.meta.length else { throw failure("V0 coverage") }
            if let index = part.baseIndex {
                guard plan.chunks.indices.contains(index) else { throw failure("V0 base index") }
                let chunk = plan.chunks[index]
                let window = writer.format == .tarGzip ? min(UInt64(DeflateBlock.windowSize), chunk.imageRange.lowerBound) : 0
                let spanIndex = image.spanIndex(at: part.image.lowerBound)
                guard spanIndex < image.spans.count else { throw failure("V0 source span") }
                let span = image.spans[spanIndex]
                guard part.image.byteLength == chunk.imageRange.byteLength, part.output.byteLength == chunk.compressedRange.byteLength,
                      writer.format != .tarGzip || index != plan.chunks.count - 1,
                          span.isOld && part.image.lowerBound >= span.range.lowerBound && part.image.upperBound <= span.range.upperBound
                          && part.image.lowerBound - span.range.lowerBound >= window
                          && span.offset + part.image.lowerBound - span.range.lowerBound == chunk.imageRange.lowerBound
                      else { throw failure("V0 source mapping/window") }
            }
            position = part.image.upperBound; compressed = part.output.upperBound
        }
        guard position == image.length, compressed == writer.payloadEnd,
              writer.payloadEnd + UInt64(writer.expectedTail.count) == writer.finalLength else { throw failure("V0 final coverage") }
        var cursor: UInt64 = writer.format == .tarGzip ? 10 : writer.format == .tarXZ ? 12 : 0
        var partIndex = 0
        for segment in writer.segments {
            let output: Range<UInt64>, base: Range<UInt64>?
            switch segment { case .encoded(let range): output = range; base = nil; case .reused(let range, let old): output = range; base = old }
            guard output.lowerBound == cursor, !output.isEmpty else { throw failure("V0 segments") }
            var oldCursor = base?.lowerBound
            while partIndex < writer.parts.count, writer.parts[partIndex].output.lowerBound < output.upperBound {
                let part = writer.parts[partIndex]
                guard part.output.upperBound <= output.upperBound else { throw failure("V0 segment boundary") }
                if let index = part.baseIndex {
                    guard oldCursor == plan.chunks[index].compressedRange.lowerBound else { throw failure("V0 reused segment") }
                    oldCursor = plan.chunks[index].compressedRange.upperBound
                } else if base != nil { throw failure("V0 encoded segment") }
                partIndex += 1
            }
            guard oldCursor == base?.upperBound else { throw failure("V0 base coverage") }
            cursor = output.upperBound
        }
        guard cursor == writer.payloadEnd, partIndex == writer.parts.count else { throw failure("V0 segment end") }
    }

    private static func gzip(_ bytes: Data, count: Int, dictionary: Data, final: Bool) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw failure("inflate init") }
        defer { inflateEnd(&stream) }
        if !dictionary.isEmpty {
            let status = dictionary.withUnsafeBytes { inflateSetDictionary(&stream, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            guard status == Z_OK else { throw failure("inflate dictionary") }
        }
        var result = Data(count: count + 1)
        try bytes.withUnsafeBytes { input in
            try result.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                defer { stream.next_in = nil; stream.next_out = nil }
                var previousStop: uLong = 0
                while true {
                    let beforeIn = stream.total_in, beforeOut = stream.total_out
                    let status = inflate(&stream, Z_BLOCK)
                    let stop = stream.data_type & 128 != 0
                    let empty = stop && stream.data_type & 64 == 0 && stream.data_type & 7 == 0 && stream.total_out == previousStop
                    if stop { previousStop = stream.total_out }
                    if status == Z_STREAM_END {
                        guard final, stream.avail_in == 0 else { throw failure("inflate final") }
                        break
                    }
                    guard status == Z_OK, stream.avail_out > 0 else { throw failure("inflate status \(status)") }
                    if stream.avail_in == 0 && empty {
                        guard !final else { throw failure("inflate missing final") }
                        break
                    }
                    guard stream.total_in != beforeIn || stream.total_out != beforeOut else { throw failure("inflate stalled") }
                }
                guard stream.total_out == count, stream.avail_in == 0 else { throw failure("inflate length") }
            }
        }
        result.removeLast()
        return result
    }

    private static func bzip2(_ bytes: Data, count: Int) throws -> Data {
        var stream = bz_stream()
        guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { throw failure("bzip2 init") }
        defer { BZ2_bzDecompressEnd(&stream) }
        var result = Data(count: count + 1)
        let status = bytes.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: CChar.self))
                stream.avail_in = UInt32(input.count)
                stream.next_out = output.baseAddress!.assumingMemoryBound(to: CChar.self)
                stream.avail_out = UInt32(output.count)
                defer { stream.next_in = nil; stream.next_out = nil }
                return BZ2_bzDecompress(&stream)
            }
        }
        guard status == BZ_STREAM_END, stream.avail_in == 0, stream.avail_out == 1 else { throw failure("bzip2 length/end") }
        result.removeLast()
        return result
    }

    private static func xz(_ bytes: Data, count: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_ERROR else { throw failure("xz init") }
        defer { compression_stream_destroy(stream) }
        var result = Data(count: count + 1)
        let status = bytes.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                stream.pointee.src_ptr = input.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.pointee.src_size = input.count
                stream.pointee.dst_ptr = output.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.pointee.dst_size = output.count
                return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            }
        }
        guard status == COMPRESSION_STATUS_END, stream.pointee.src_size == 0, stream.pointee.dst_size == 1 else { throw failure("xz length/end") }
        result.removeLast()
        return result
    }

    private static func hasBzip2End(_ bytes: Data) -> Bool {
        let bitCount = bytes.count * 8
        func bits(_ start: Int, _ count: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in start..<(start + count) { value = value << 1 | UInt64((bytes[index / 8] >> (7 - index % 8)) & 1) }
            return value
        }
        for padding in 0...7 where bitCount >= 80 + padding {
            if bits(bitCount - 80 - padding, 48) == 0x177245385090,
               padding == 0 || bits(bitCount - padding, padding) == 0 { return true }
        }
        return false
    }

    private static func xzHeader(_ bytes: Data, meta: Metadata, imageLength: UInt64) throws {
        guard bytes.count >= 8, (UInt64(bytes[0]) + 1) * 4 == meta.headerSize,
              updateCRC(0, bytes.prefix(bytes.count - 4)) == bytes.zip32(bytes.count - 4),
              bytes[1] & 0x3c == 0 else { throw failure("V2 xz header CRC/flags") }
        var cursor = 2
        func vli() throws -> UInt64 {
            do { return try XZFraming.readVLI(bytes, cursor: &cursor, end: bytes.count - 4) }
            catch XZFraming.VLIError.truncated { throw failure("V2 xz VLI") }
            catch XZFraming.VLIError.nonCanonical { throw failure("V2 xz VLI canonical") }
            catch XZFraming.VLIError.overflow { throw failure("V2 xz VLI overflow") }
        }
        if bytes[1] & 64 != 0, try vli() != meta.payloadSize { throw failure("V2 xz compressed size") }
        if bytes[1] & 128 != 0, try vli() != imageLength { throw failure("V2 xz image size") }
        for _ in 0...Int(bytes[1] & 3) {
            _ = try vli()
            let count = try vli()
            guard count <= UInt64(bytes.count - 4 - cursor) else { throw failure("V2 xz filter") }
            cursor += Int(count)
        }
        guard bytes[cursor..<(bytes.count - 4)].allSatisfy({ $0 == 0 }),
              meta.unpaddedSize == meta.headerSize + meta.payloadSize + 4 else { throw failure("V2 xz header padding/size") }
    }
}
