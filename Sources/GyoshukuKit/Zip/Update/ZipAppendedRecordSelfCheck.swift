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
            return try FileRead.pread(descriptor, into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
                                      at: base + offset, operation: "pread appended")
        }
        let cursor = Int(offset - blockLength)
        let count = min(buffer.count, trailer.count - cursor)
        trailer.withUnsafeBytes { bytes in
            buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: cursor), byteCount: count)
        }
        return count
    }
}

// commit 後の自己検査。追加した record を出力から読み直し、writer の計画と KaitoKit の解釈を照合する。
enum ZipAppendedRecordSelfCheck {
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
            try FileRead.preadExactly(descriptor, into: buffer, at: offset, operation: "pread appended") {
                UpdaterError.invalidArchive("追加 record が途中で終わっています")
            }
        }
        return bytes
    }
}

// 旧名。SplicedArchiveOutput.read の呼出しが FileRead へ置き換わるまで残す。
typealias ZipAppendedRecordCheck = ZipAppendedRecordSelfCheck
