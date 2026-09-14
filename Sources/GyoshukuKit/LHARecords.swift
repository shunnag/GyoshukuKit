import Foundation

enum LHARecords {
    struct Entry {
        let mode: UInt16
        let size: UInt32
        let mtime: UInt32
        let filename: Data
        let directory: Data

        init(name: String, mode: UInt16, size: UInt64, date: Date) throws {
            let type = mode & 0xF000
            guard type == 0x8000 || type == 0x4000 else { throw WriterError.unsupportedFileType(name) }
            guard size <= UInt32.max else { throw WriterError.sizeOverflow }
            self.mode = mode
            self.size = UInt32(size)
            self.mtime = try LHARecords.timestamp(date)
            // Unicode の区切りで分けてから符号化する。CP932 の後続 byte 0x5C は名前の一部。
            let components = name.split(separator: "/")
            let directories = type == 0x4000 ? components[...] : components.dropLast()
            self.filename = type == 0x4000 ? Data() : try LHARecords.encodeName(String(components.last ?? ""))
            var directory = Data()
            for component in directories {
                directory.append(try LHARecords.encodeName(String(component)))
                directory.append(0xFF)
            }
            self.directory = directory
            // header 全体の 16 bit 上限も、入力の読み取りや出力より前に検証する。
            _ = try header(method: type == 0x4000 ? "-lhd-" : "-lh0-", packedSize: self.size, crc: 0)
        }

        func header(method: String, packedSize: UInt32, crc: UInt16) throws -> Data {
            var result = Data()
            result.le(UInt16(0))
            result.append(contentsOf: method.utf8)
            result.le(packedSize)
            result.le(size)
            result.le(mtime)
            result.append(contentsOf: [0x20, 2])
            result.le(crc)
            result.append(0x55) // Unix mode と Unix 秒を保存するので OS は 'U'。
            try LHARecords.extensionHeader(0x00, Data(count: 2), to: &result)
            try LHARecords.extensionHeader(0x01, filename, to: &result)
            if !directory.isEmpty { try LHARecords.extensionHeader(0x02, directory, to: &result) }
            var permissions = Data()
            permissions.le(mode)
            try LHARecords.extensionHeader(0x50, permissions, to: &result)
            var time = Data()
            time.le(mtime)
            try LHARecords.extensionHeader(0x54, time, to: &result)
            // size は次の type の直前に連なる。最後の 0 も総 header 長と CRC の対象。
            result.le(UInt16(0))
            // KaitoKit は先頭 byte 0 を終端と解釈する。一方 7zz は拡張列の終端を payload の
            // 開始とするので、padding は列の外ではなく common 拡張の CRC 後の予備領域へ置く。
            if result.count & 0xFF == 0 {
                result.insert(0, at: 29)
                result[24] = 6
            }
            guard result.count <= Int(UInt16.max) else { throw WriterError.sizeOverflow }
            let length = UInt16(result.count)
            result[0] = UInt8(truncatingIfNeeded: length)
            result[1] = UInt8(length >> 8)
            let headerCRC = LHACRC16.update(0, result)
            result[27] = UInt8(truncatingIfNeeded: headerCRC)
            result[28] = UInt8(headerCRC >> 8)
            return result
        }
    }

    static func timestamp(_ date: Date) throws -> UInt32 {
        let seconds = floor(date.timeIntervalSince1970)
        guard seconds.isFinite, seconds >= 0, seconds <= Double(UInt32.max) else { throw WriterError.invalidDate }
        return UInt32(seconds)
    }

    private static func encodeName(_ name: String) throws -> Data {
        // LHA に文字コード宣言はない。置換や非可逆な変換を通すと、別名で展開されてしまう。
        guard let bytes = name.data(using: .shiftJIS, allowLossyConversion: false),
              String(data: bytes, encoding: .shiftJIS) == name, !bytes.contains(0xFF) else {
            throw WriterError.invalidPath(name)
        }
        return bytes
    }

    private static func extensionHeader(_ type: UInt8, _ data: Data, to output: inout Data) throws {
        guard data.count <= Int(UInt16.max) - 3 else { throw WriterError.sizeOverflow }
        output.le(UInt16(data.count + 3))
        output.append(type)
        output.append(data)
    }
}
