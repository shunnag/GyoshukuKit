import Foundation
private import Darwin
@_spi(ZipRawLayout) internal import KaitoKit

// 追加 block だけを独立した ZIP として提示し、既存 N 件の再解析をしない。
struct ZipAppendedRecordView: ByteSource {
    let descriptor: Int32
    let base: UInt64
    let blockLength: UInt64
    let trailer: Data
    let length: UInt64

    init(descriptor: Int32, base: UInt64, blockLength: UInt64, entries: [ZipRecords.Entry], recordBase: UInt64) throws {
        self.descriptor = descriptor
        self.base = base
        self.blockLength = blockLength
        var tail = Data()
        for var entry in entries {
            entry.offset -= recordBase
            tail.append(entry.central())
        }
        tail.append(try ZipRecords.end(count: UInt64(entries.count), centralSize: UInt64(tail.count), centralOffset: blockLength))
        trailer = tail
        length = try checkedAdd(blockLength, UInt64(tail.count))
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length, !buffer.isEmpty else { return 0 }
        if offset < blockLength {
            let count = Int(min(UInt64(buffer.count), blockLength - offset))
            while true {
                let result = pread(descriptor, buffer.baseAddress!, count, off_t(base + offset))
                if result >= 0 { return result }
                if errno != EINTR { throw WriterError.io(operation: "pread appended", code: errno) }
            }
        }
        let cursor = Int(offset - blockLength)
        let count = min(buffer.count, trailer.count - cursor)
        trailer.withUnsafeBytes { bytes in
            buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: cursor), byteCount: count)
        }
        return count
    }
}

enum ZipAppendedRecordCheck {
    @TaskLocal static var testingSkipHeaderEquality = false

    static func check(descriptor: Int32, entries: [ZipRecords.Entry], start: UInt64,
                      recordBase: UInt64, blockLength: UInt64, centralOffset: UInt64) throws {
        do {
            var end = start
            for entry in entries {
                let offset = try checkedAdd(start, entry.offset - recordBase)
                let header = entry.local()
                guard offset == end else { throw UpdaterError.invalidArchive("追加 record が連続していません") }
                let bytes = try read(descriptor, at: offset, count: header.count)
                if !testingSkipHeaderEquality, bytes != header {
                    throw UpdaterError.invalidArchive("追加 record の local header が一致しません")
                }
                end = try checkedAdd(offset, checkedAdd(UInt64(header.count), entry.compressedSize))
            }
            guard end == centralOffset, end == (try checkedAdd(start, blockLength)) else {
                throw UpdaterError.invalidArchive("追加 record の終端が一致しません")
            }
            let view = try ZipAppendedRecordView(descriptor: descriptor, base: start, blockLength: blockLength,
                                                entries: entries, recordBase: recordBase)
            let reader = try ArchiveReader.open(source: view, options: ArchiveUpdater.readerOptions)
            guard reader.format == .zip, reader.entries.count == entries.count else {
                throw UpdaterError.invalidArchive("追加 record の件数が一致しません")
            }
            for (index, entry) in entries.enumerated() {
                let parsed = reader.entries[index]
                let rel = entry.offset - recordBase
                guard parsed.rawName.bytes.elementsEqual(entry.name), parsed.compressedSize == entry.compressedSize,
                      parsed.uncompressedSize == entry.size,
                      let layout = try reader.zipRawRecordLayout(at: index),
                      layout.recordRange == rel..<(rel + UInt64(entry.local().count) + entry.compressedSize),
                      layout.payloadRange.lowerBound == rel + UInt64(entry.local().count),
                      !layout.hasDataDescriptor else {
                    throw UpdaterError.invalidArchive("追加 record の解釈が一致しません")
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw UpdaterError.invalidArchive("追加した record を KaitoKit で照合できません: \(error)") }
    }

    static func read(_ descriptor: Int32, at offset: UInt64, count: Int) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var filled = 0
            while filled < count {
                let actual = pread(descriptor, buffer.baseAddress!.advanced(by: filled), count - filled, off_t(offset + UInt64(filled)))
                if actual < 0 {
                    if errno == EINTR { continue }
                    throw WriterError.io(operation: "pread appended", code: errno)
                }
                guard actual > 0 else { throw UpdaterError.invalidArchive("追加 record が途中で終わっています") }
                filled += actual
            }
        }
        return bytes
    }
}
