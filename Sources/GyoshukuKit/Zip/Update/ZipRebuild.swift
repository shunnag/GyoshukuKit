import Foundation
public import KaitoKit

// entry の解釈と descriptor の終端は KaitoKit だけが決める。
// ここで読む CD の byte 表は、未知の extra / comment / 属性を保存して再出力するためのもの。
enum ZipRebuild {
    struct PlannedRecord {
        let index: Int
        let offset: UInt64
        let action: ZipPlannedAction
        let marker: Bool
    }

    enum CentralAction {
        case original(Range<Int>, UInt64)
        case rebuilt(Data)
        case converted(ZipConversion)
    }

    struct Plan {
        let records: [PlannedRecord]
        let central: [CentralAction]
        let end: UInt64
        let centralOffset: UInt64
        let finalEnd: UInt64
        let trailer: Data
        let inPlace: Bool
        let totalBytes: UInt64
    }

    // 予約時の予測では seam と改名拒否を使わず、header の長さだけを見る。
    static func predictedEnd(source: ZipUpdateSource, directory: ZipValidatedDirectory,
                             removed: Set<Int>, renamed: [Int: String]) throws -> UInt64 {
        var position: UInt64 = 0
        for (index, record) in directory.records.enumerated() where !removed.contains(index) {
            let raw = record.layout
            var size = raw.recordRange.upperBound - raw.recordRange.lowerBound
            if let name = renamed[index] {
                let header = try LocalHeader(source: source, layout: raw)
                size = try checkedAdd(size - UInt64(header.name.count), UInt64(name.utf8.count))
            }
            position = try checkedAdd(position, size)
        }
        return position
    }

    static func plan(source: ZipUpdateSource, layout: ZipUpdateLayout, reader: ArchiveReader,
                     directory: ZipValidatedDirectory, removed: Set<Int>, renamed: [Int: String],
                     writtenRange: Range<UInt64>? = nil, appended: [ZipRecords.Entry] = [],
                     reencryption: ZipReencryption? = nil,
                     recordLayout: (Int) throws -> ZipRecordLayout?) throws -> Plan {
        var position: UInt64 = 0
        var records: [PlannedRecord] = []
        records.reserveCapacity(reader.entries.count - removed.count)
        var localBytes: UInt64 = 0
        var patchable = writtenRange == nil && removed.isEmpty
        for entry in reader.entries where !removed.contains(entry.index) {
            if records.count % 4096 == 0 { try Task.checkCancellation() }
            guard let raw = try recordLayout(entry.index) else {
                throw UpdaterError.nonRelocatableEntry(index: entry.index, name: entry.name,
                    reason: "rawRecord が nil のため独立して移動できません。削除・改名による再構築を拒否します")
            }
            let start = position
            if let conversion = reencryption?.conversions[entry.index] {
                let header = try CentralHeader(bytes: directory.bytes, range: directory.records[entry.index].centralRange)
                try conversion.assemble(source: source, header: header, offset: start, name: renamed[entry.index])
                position = try checkedAdd(start, checkedAdd(UInt64(conversion.local.count), conversion.compressedSize))
                localBytes = try checkedAdd(localBytes, position - start)
                patchable = false
                records.append(PlannedRecord(index: entry.index, offset: start, action: .convert(conversion), marker: false))
                continue
            }
            if start >= ZipRecords.limit, raw.hasDataDescriptor, !raw.isZIP64 {
                throw UpdaterError.nonRelocatableEntry(index: entry.index, name: entry.name,
                    reason: "ZIP32 descriptor の移動先に ZIP64 offset が必要です。KaitoKit 0.4.0 の幅の解釈が変わるため再構築を拒否します")
            }
            let marker = raw.hasDataDescriptor && raw.isZIP64 && !raw.localHasZIP64Extra
            let clean = writtenRange.map { !raw.recordRange.overlaps($0) } ?? true
            let action: ZipPlannedAction
            if let name = renamed[entry.index] {
                let header = try LocalHeader(source: source, layout: raw)
                let replacement = try header.renamed(Data(name.utf8))
                let payload = raw.payloadRange.lowerBound..<raw.recordRange.upperBound
                position = try checkedAdd(start, checkedAdd(UInt64(replacement.count), payload.upperBound - payload.lowerBound))
                if replacement.count == Int(raw.payloadRange.lowerBound - raw.recordRange.lowerBound),
                   start == raw.recordRange.lowerBound, clean {
                    action = .patchHeader(replacement)
                    localBytes = try checkedAdd(localBytes, UInt64(replacement.count))
                } else {
                    action = .headerThenCopy(replacement, payload)
                    localBytes = try checkedAdd(localBytes, position - start)
                    patchable = false
                }
            } else {
                position = try checkedAdd(start, raw.recordRange.upperBound - raw.recordRange.lowerBound)
                if start == raw.recordRange.lowerBound, clean { action = .keep }
                else {
                    action = .copy(raw.recordRange)
                    localBytes = try checkedAdd(localBytes, position - start)
                    patchable = false
                }
            }
            records.append(PlannedRecord(index: entry.index, offset: start, action: action, marker: marker))
        }
        try Task.checkCancellation()
        let localEnd = position
        let appendedSize = writtenRange.map { $0.upperBound - $0.lowerBound } ?? 0
        let centralOffset = try checkedAdd(position, appendedSize)
        patchable = patchable && localEnd == layout.centralOffset && appended.isEmpty
        var central: [CentralAction] = []
        central.reserveCapacity(records.count + appended.count)
        var centralSize: UInt64 = 0
        var centralPatches: UInt64 = 0
        for (ordinal, record) in records.enumerated() {
            if ordinal % 4096 == 0 { try Task.checkCancellation() }
            let validated = directory.records[record.index]
            let entry = reader.entries[record.index]
            let newName = renamed[record.index]
            let action: CentralAction
            let count: Int
            if case .convert(let conversion) = record.action {
                action = .converted(conversion)
                count = conversion.central.count
            } else if validated.usesFastPath(offset: record.offset, renamed: newName != nil, marker: record.marker) {
                action = .original(validated.centralRange, record.offset)
                count = validated.centralRange.count
            } else {
                guard let size = entry.uncompressedSize, let compressed = entry.compressedSize else {
                    throw UpdaterError.invalidArchive("ZIP entry のサイズがありません")
                }
                let bytes = try CentralHeader(bytes: directory.bytes, range: validated.centralRange)
                    .rebuilt(offset: record.offset, size: size, compressedSize: compressed,
                             name: newName.map { Data($0.utf8) }, preserveDescriptorMarker: record.marker)
                action = .rebuilt(bytes)
                count = bytes.count
            }
            if !validated.canonical || (newName != nil && newName!.utf8.count != Int(directory.bytes.zip16(validated.centralRange.lowerBound + 28))) {
                patchable = false
            }
            if newName != nil { centralPatches = try checkedAdd(centralPatches, UInt64(count)) }
            centralSize = try checkedAdd(centralSize, UInt64(count))
            central.append(action)
        }
        for entry in appended {
            let offset = try checkedAdd(localEnd, entry.offset - layout.centralOffset)
            let bytes = try CentralHeader(bytes: entry.central()).rebuilt(offset: offset, size: entry.size,
                compressedSize: entry.compressedSize, name: nil, preserveDescriptorMarker: false)
            central.append(.rebuilt(bytes))
            centralSize = try checkedAdd(centralSize, UInt64(bytes.count))
        }
        let trailer = try ZipRecords.end(count: UInt64(records.count + appended.count), centralSize: centralSize,
                                         centralOffset: centralOffset, comment: layout.comment)
        if patchable {
            let oldEnd = try checkedAdd(layout.centralOffset, layout.centralSize)
            if source.length - oldEnd != UInt64(trailer.count) { patchable = false }
            else {
                let bytes = try layout.endBytes ?? source.bytes(at: oldEnd, count: trailer.count)
                patchable = bytes == trailer
            }
        }
        try Task.checkCancellation()
        let finalEnd = try checkedAdd(centralOffset, checkedAdd(centralSize, UInt64(trailer.count)))
        let total = try checkedAdd(localBytes, patchable ? centralPatches : checkedAdd(centralSize, UInt64(trailer.count)))
        return Plan(records: records, central: central, end: localEnd, centralOffset: centralOffset,
                    finalEnd: finalEnd, trailer: trailer, inPlace: patchable, totalBytes: total)
    }

    static func execute(_ plan: Plan, source: ZipUpdateSource, directory: ZipValidatedDirectory,
                        layout: ZipUpdateLayout, stagedSource: ZipUpdateSource?, writtenRange: Range<UInt64>?,
                        reencryption: ZipReencryption? = nil,
                        engine: inout ZipCopyEngine, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try executeLocal(plan, source: source, reencryption: reencryption, engine: &engine, progress: progress)
        if let stagedSource, let writtenRange {
            try engine.copy(writtenRange, from: stagedSource, to: plan.end, progress: progress)
        }
        try executeCentral(plan, directory: directory, layout: layout, engine: &engine, progress: progress)
    }

    private static func executeLocal(_ plan: Plan, source: ZipUpdateSource, reencryption: ZipReencryption?, engine: inout ZipCopyEngine,
                             progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try Task.checkCancellation()
        var pending: (range: Range<UInt64>, offset: UInt64)?
        func flushCopy(_ engine: inout ZipCopyEngine) throws {
            if let pending { try engine.copy(pending.range, from: source, to: pending.offset, progress: progress) }
            pending = nil
        }
        func emit(_ record: PlannedRecord, _ keys: ZipReencryption.Keys?) throws {
            if reencryption != nil { try Task.checkCancellation() }
            if case .copy(let range) = record.action {
                if let previous = pending, previous.range.upperBound == range.lowerBound,
                   previous.offset + (previous.range.upperBound - previous.range.lowerBound) == record.offset {
                    pending = (previous.range.lowerBound..<range.upperBound, previous.offset)
                } else {
                    try flushCopy(&engine)
                    pending = (range, record.offset)
                }
                return
            }
            try flushCopy(&engine)
            switch record.action {
            case .keep: break
            case .patchHeader(let bytes): try engine.patch(bytes, at: record.offset, progress: progress)
            case .headerThenCopy(let bytes, let range):
                try engine.append(bytes, at: record.offset, progress: progress)
                try engine.copy(range, from: source, to: record.offset + UInt64(bytes.count), progress: progress)
            case .copy: preconditionFailure()
            case .convert(let conversion):
                try reencryption!.convert(conversion, keys: keys, at: record.offset, engine: &engine, progress: progress)
            }
        }
        if let reencryption { try reencryption.withKeys(records: plan.records, source: source, emit: emit) }
        else { for record in plan.records { try emit(record, nil) } }
        try flushCopy(&engine)
    }

    private static func executeCentral(_ plan: Plan, directory: ZipValidatedDirectory, layout: ZipUpdateLayout,
                               engine: inout ZipCopyEngine, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        var position = plan.centralOffset
        for (ordinal, action) in plan.central.enumerated() {
            if ordinal % 4096 == 0 { try Task.checkCancellation() }
            if plan.inPlace {
                if case .patchHeader = plan.records[ordinal].action, case .rebuilt(let bytes) = action {
                    let range = directory.records[plan.records[ordinal].index].centralRange
                    try engine.patch(bytes, at: layout.centralOffset + UInt64(range.lowerBound), progress: progress)
                }
                continue
            }
            switch action {
            case .original(let range, let offset):
                try engine.appendCentral(directory.bytes, range: range, localOffset: offset, at: position, progress: progress)
                position += UInt64(range.count)
            case .rebuilt(let bytes):
                try engine.append(bytes, at: position, progress: progress)
                position += UInt64(bytes.count)
            case .converted(let conversion):
                try engine.append(conversion.central, at: position, progress: progress)
                position += UInt64(conversion.central.count)
            }
        }
        if !plan.inPlace { try engine.append(plan.trailer, at: position, progress: progress) }
        try engine.flush(progress: progress)
    }

    struct LocalHeader {
        var fixed: Data
        let name: Data
        let extra: Data
        var hasZIP64: Bool { extraFields(extra).contains { $0.id == 1 } }

        init(source: ZipUpdateSource, layout raw: ZipRecordLayout) throws {
            let length = raw.payloadRange.lowerBound - raw.recordRange.lowerBound
            guard length >= 30, length <= UInt64(Int.max) else {
                throw UpdaterError.invalidArchive("local header と rawRecord の payload 位置が一致しません")
            }
            let bytes = try source.bytes(at: raw.recordRange.lowerBound, count: Int(length))
            fixed = bytes.subdata(in: 0..<30)
            let nameLength = Int(fixed.zip16(26))
            let extraLength = Int(fixed.zip16(28))
            let variableOffset = try checkedAdd(raw.recordRange.lowerBound, 30)
            guard fixed.zip32(0) == 0x04034B50,
                  try checkedAdd(variableOffset, UInt64(nameLength + extraLength)) == raw.payloadRange.lowerBound else {
                throw UpdaterError.invalidArchive("local header と rawRecord の payload 位置が一致しません")
            }
            name = bytes.subdata(in: 30..<(30 + nameLength))
            extra = bytes.subdata(in: (30 + nameLength)..<bytes.count)
        }

        func renamed(_ name: Data) throws -> Data {
            guard name.count <= Int(UInt16.max) else { throw WriterError.sizeOverflow }
            var result = fixed
            result.zipSet(fixed.zip16(6) | ZipRecords.flags, at: 6)
            result.zipSet(UInt16(name.count), at: 26)
            result.append(name)
            result.append(try renamedExtra(extra))
            return result
        }
    }

    struct CentralHeader {
        let fixed: Data
        let name: Data
        let extra: Data
        let comment: Data
        var byteCount: Int { 46 + name.count + extra.count + comment.count }

        init(source: ZipUpdateSource, at offset: UInt64, end: UInt64) throws {
            guard offset <= end, end - offset >= 46 else { throw UpdaterError.invalidArchive("CD が途中で終わっています") }
            fixed = try source.bytes(at: offset, count: 46)
            guard fixed.zip32(0) == 0x02014B50 else { throw UpdaterError.invalidArchive("CD signature がありません") }
            let n = Int(fixed.zip16(28)), e = Int(fixed.zip16(30)), c = Int(fixed.zip16(32))
            guard UInt64(n + e + c) <= end - offset - 46 else { throw UpdaterError.invalidArchive("CD metadata が範囲外です") }
            name = try source.bytes(at: offset + 46, count: n)
            extra = try source.bytes(at: offset + 46 + UInt64(n), count: e)
            comment = try source.bytes(at: offset + 46 + UInt64(n + e), count: c)
        }

        init(bytes: Data, range: Range<Int>? = nil) throws {
            let range = range ?? bytes.startIndex..<bytes.endIndex
            let start = range.lowerBound
            guard range.count >= 46 else { throw UpdaterError.invalidArchive("CD が途中で終わっています") }
            guard bytes.zip32(start) == 0x02014B50 else { throw UpdaterError.invalidArchive("CD signature がありません") }
            let n = Int(bytes.zip16(start + 28)), e = Int(bytes.zip16(start + 30)), c = Int(bytes.zip16(start + 32))
            guard n + e + c <= range.count - 46 else { throw UpdaterError.invalidArchive("CD metadata が範囲外です") }
            fixed = bytes.subdata(in: start..<(start + 46))
            name = bytes.subdata(in: (start + 46)..<(start + 46 + n))
            extra = bytes.subdata(in: (start + 46 + n)..<(start + 46 + n + e))
            comment = bytes.subdata(in: (start + 46 + n + e)..<(start + 46 + n + e + c))
        }

        func rebuilt(offset: UInt64, size: UInt64, compressedSize: UInt64, name newName: Data?,
                     preserveDescriptorMarker: Bool = false) throws -> Data {
            var zip64 = Data()
            if size >= ZipRecords.limit { zip64.le(size) }
            if compressedSize >= ZipRecords.limit { zip64.le(compressedSize) }
            if offset >= ZipRecords.limit { zip64.le(offset) }
            var extras = Data()
            if !zip64.isEmpty || preserveDescriptorMarker { extras.append(ZipRecords.field(1, zip64)) }
            // central だけの ZIP64 extra で幅が決まる descriptor もある。サイズの sentinel を
            // 不要に残す代わりに空の marker を保ち、KaitoKit が解決した幅を変えない。
            let fields = extraFields(extra)
            var consumed = 0
            for field in fields {
                if field.id != 1 { extras.append(extra.subdata(in: field.range)) }
                consumed = field.range.upperBound
            }
            // KaitoKit が許した末尾 padding も残す。新しい ZIP64 field は必ずその前に置く。
            extras.append(extra.dropFirst(consumed))
            if newName != nil { extras = try renamedExtra(extras) }
            let name = newName ?? name
            guard name.count <= Int(UInt16.max), extras.count <= Int(UInt16.max) else { throw WriterError.sizeOverflow }
            var result = fixed
            if !zip64.isEmpty || preserveDescriptorMarker { result.zipSet(max(fixed.zip16(6), 45), at: 6) }
            if newName != nil { result.zipSet(fixed.zip16(8) | ZipRecords.flags, at: 8) }
            result.zipSet(UInt32(min(compressedSize, ZipRecords.limit)), at: 20)
            result.zipSet(UInt32(min(size, ZipRecords.limit)), at: 24)
            result.zipSet(UInt16(name.count), at: 28)
            result.zipSet(UInt16(extras.count), at: 30)
            result.zipSet(UInt16(0), at: 34)
            result.zipSet(UInt32(min(offset, ZipRecords.limit)), at: 42)
            result.append(name)
            result.append(extras)
            result.append(comment)
            return result
        }
    }

    static func extraFields(_ data: Data) -> [(id: UInt16, range: Range<Int>)] {
        var fields: [(UInt16, Range<Int>)] = []
        var cursor = 0
        while data.count - cursor >= 4 {
            let length = Int(data.zip16(cursor + 2))
            guard length <= data.count - cursor - 4 else { break }
            let end = cursor + 4 + length
            fields.append((data.zip16(cursor), cursor..<end))
            cursor = end
        }
        return fields
    }

    static func renamedExtra(_ extra: Data) throws -> Data {
        var result = extra
        var consumed = 0
        for field in extraFields(extra) {
            switch field.id {
            case 0x7075:
                // 長さを保って旧名と CRC を消し、同長改名の payload 位置を維持する。
                result.zipSet(UInt16(0xFFFF), at: field.range.lowerBound)
                result.resetBytes(in: (field.range.lowerBound + 4)..<field.range.upperBound)
            case 0x0008, 0x2605, 0x334D, 0x4F4C, 0x554E:
                // 名前と他の metadata が混在し得る拡張は、黙って捨てず改名を拒否する。
                throw UpdaterError.invalidArchive(String(format:
                    "名前を含む ZIP extra field 0x%04X を安全に更新できないため改名できません", field.id))
            default: break
            }
            consumed = field.range.upperBound
        }
        // CD では未解析の末尾も許されるが、旧名を含まないとは保証できない。
        guard extra.dropFirst(consumed).allSatisfy({ $0 == 0 }) else {
            throw UpdaterError.invalidArchive("ZIP extra field の末尾を解析できないため改名できません")
        }
        return result
    }
}

// record 単位の動作を保持し、後続の暗号化変換もこの計画に追加できる。
enum ZipPlannedAction {
    case keep
    case patchHeader(Data)
    case copy(Range<UInt64>)
    case headerThenCopy(Data, Range<UInt64>)
    case convert(ZipConversion)
}
