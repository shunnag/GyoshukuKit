import Foundation
private import Darwin
internal import KaitoKit

/// 読み取り可能でも、安全な編集の条件を満たさない書庫を区別する。
public enum UpdateGatekeeper: String, Sendable {
    case sfxPrefix
    case trailingData
    case centralDirectoryOffset

    public var reason: String {
        switch self {
        case .sfxPrefix: "SFX prefix があるため ZIP の offset 基準を保証できません"
        case .trailingData: "EOCD の後ろに trailing data があります"
        case .centralDirectoryOffset: "EOCD.cdOffset が PK\\x01\\x02 を指しません。ZIP64 なしの offset 切り詰めなどが疑われます"
        }
    }
}

public enum UpdaterError: Error, Sendable, Equatable {
    case editingRefused(gatekeeper: UpdateGatekeeper, reason: String)
    case invalidArchive(String)
    case invalidEntryIndex(Int)
    case nonRelocatableEntry(index: Int, name: String, reason: String)
    case sourceChanged
    case invalidState
}

// 同じ descriptor を KaitoKit と CD コピーで共有する。pread のみなので cursor は共有しない。
final class ZipUpdateSource: ByteSource {
    let descriptor: Int32
    let length: UInt64
    private let snapshot: stat

    init(url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw WriterError.invalidPath(url.absoluteString) }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WriterError.io(operation: "open archive", code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            Darwin.close(fd)
            throw UpdaterError.invalidArchive("通常ファイルではありません")
        }
        descriptor = fd
        snapshot = info
        length = UInt64(info.st_size)
    }

    deinit { Darwin.close(descriptor) }

    var mode: UInt16 { UInt16(snapshot.st_mode & 0o7777) }

    func checkUnchanged(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_dev == snapshot.st_dev, info.st_ino == snapshot.st_ino,
              info.st_size == snapshot.st_size, info.st_mode == snapshot.st_mode,
              info.st_mtimespec.tv_sec == snapshot.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == snapshot.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == snapshot.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == snapshot.st_ctimespec.tv_nsec else {
            throw UpdaterError.sourceChanged
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length, !buffer.isEmpty else { return 0 }
        let count = Int(min(UInt64(buffer.count), length - offset))
        while true {
            let actual = pread(descriptor, buffer.baseAddress!, count, off_t(offset))
            if actual >= 0 { return actual }
            if errno != EINTR { throw WriterError.io(operation: "pread archive", code: errno) }
        }
    }

    func bytes(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= length, UInt64(count) <= length - offset else {
            throw UpdaterError.invalidArchive("終端構造がファイル範囲外です")
        }
        var result = Data(count: count)
        var filled = 0
        while filled < count {
            let actual = try result.withUnsafeMutableBytes {
                try read(into: UnsafeMutableRawBufferPointer(rebasing: $0[filled..<count]), at: offset + UInt64(filled))
            }
            guard actual > 0 else { throw UpdaterError.sourceChanged }
            filled += actual
        }
        return result
    }
}

// entry の parser は KaitoKit に任せる。ここでは更新に必要な終端の範囲と三門番だけを検査する。
struct ZipUpdateLayout {
    let centralOffset: UInt64
    let centralSize: UInt64
    let count: UInt64
    let comment: Data

    init(source: ZipUpdateSource) throws {
        func refuse(_ gate: UpdateGatekeeper) throws -> Never {
            throw UpdaterError.editingRefused(gatekeeper: gate, reason: gate.reason)
        }
        // KaitoKit が読む trailing data の上限と同じ。攻撃者のサイズで確保しない。
        let tailSize = Int(min(source.length, 22 + 65_535 + 1_048_576))
        guard tailSize >= 22 else { throw UpdaterError.invalidArchive("EOCD がありません") }
        let tail = try source.bytes(at: source.length - UInt64(tailSize), count: tailSize)
        var found: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.zip32(index) == 0x06054B50,
               index + 22 + Int(tail.zip16(index + 20)) <= tail.count {
                found = index
                break
            }
        }
        guard let end = found else { throw UpdaterError.invalidArchive("EOCD がありません") }
        let first = try source.bytes(at: 0, count: 4).zip32(0)
        guard first == 0x04034B50 || first == 0x06054B50 || first == 0x06064B50 else {
            try refuse(.sfxPrefix)
        }
        let commentEnd = end + 22 + Int(tail.zip16(end + 20))
        guard commentEnd == tail.count else { try refuse(.trailingData) }
        let endOffset = source.length - UInt64(tailSize) + UInt64(end)
        guard tail.zip16(end + 4) == 0, tail.zip16(end + 6) == 0,
              tail.zip16(end + 8) == tail.zip16(end + 10) else {
            throw UpdaterError.invalidArchive("分割 ZIP は編集できません")
        }
        var count = UInt64(tail.zip16(end + 10))
        var size = UInt64(tail.zip32(end + 12))
        var offset = UInt64(tail.zip32(end + 16))
        var directoryEnd = endOffset
        let locator = endOffset >= 20 ? try source.bytes(at: endOffset - 20, count: 20) : Data()
        if locator.count == 20, locator.zip32(0) == 0x07064B50 {
            guard locator.zip32(4) == 0, locator.zip32(16) == 1 else {
                throw UpdaterError.invalidArchive("ZIP64 locator が単一 volume ではありません")
            }
            let position = locator.zip64(8)
            let record = try source.bytes(at: position, count: 56)
            guard record.zip32(0) == 0x06064B50, record.zip64(4) >= 44,
                  try checkedAdd(position, checkedAdd(12, record.zip64(4))) == endOffset - 20,
                  record.zip32(16) == 0, record.zip32(20) == 0,
                  record.zip64(24) == record.zip64(32),
                  count == 65_535 || count == record.zip64(32),
                  size == ZipRecords.limit || size == record.zip64(40),
                  offset == ZipRecords.limit || offset == record.zip64(48) else {
                throw UpdaterError.invalidArchive("ZIP64 終端が矛盾しています")
            }
            count = record.zip64(32)
            size = record.zip64(40)
            offset = record.zip64(48)
            directoryEnd = position
        } else if count == 65_535 || size == ZipRecords.limit || offset == ZipRecords.limit {
            throw UpdaterError.invalidArchive("ZIP64 終端が必要です")
        }
        // 空書庫には CD signature が存在しない。offset/size/count が全て 0 の正規形だけ許す。
        if count == 0 {
            guard offset == 0, size == 0, directoryEnd == 0 else {
                throw UpdaterError.invalidArchive("空 ZIP の終端が矛盾しています")
            }
        } else {
            guard offset <= source.length, source.length - offset >= 4,
                  try source.bytes(at: offset, count: 4).zip32(0) == 0x02014B50 else {
                try refuse(.centralDirectoryOffset)
            }
        }
        guard offset <= directoryEnd, size == directoryEnd - offset,
              count <= size / 46 else {
            throw UpdaterError.invalidArchive("CD の範囲または entry 数が矛盾しています")
        }
        centralOffset = offset
        centralSize = size
        self.count = count
        comment = tail.subdata(in: (end + 22)..<commentEnd)
    }
}

// 呼出箇所で固定長を検証した ZIP record 専用の little-endian 読み取り。
extension Data {
    func zip16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func zip32(_ at: Int) -> UInt32 { UInt32(zip16(at)) | UInt32(zip16(at + 2)) << 16 }
    func zip64(_ at: Int) -> UInt64 { UInt64(zip32(at)) | UInt64(zip32(at + 4)) << 32 }
    mutating func zipSet<T: FixedWidthInteger>(_ value: T, at: Int) {
        var encoded = Data()
        encoded.le(value)
        replaceSubrange(at..<(at + encoded.count), with: encoded)
    }
}
