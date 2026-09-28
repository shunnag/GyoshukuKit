import Foundation
internal import KaitoKit

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
    static func predictedEnd(source: ArchiveFileSource, directory: ZipValidatedDirectory,
                             removed: Set<Int>, renamed: [Int: String]) throws -> UInt64 {
        var position: UInt64 = 0
        for (index, record) in directory.records.enumerated() where !removed.contains(index) {
            let raw = record.layout
            var size = raw.recordRange.byteLength
            if let name = renamed[index] {
                let header = try LocalHeader(source: source, layout: raw)
                size = try checkedAdd(size - UInt64(header.name.count), UInt64(name.utf8.count))
            }
            position = try checkedAdd(position, size)
        }
        return position
    }

    private struct LocalPlan {
        let records: [PlannedRecord]
        let end: UInt64
        let bytes: UInt64
        let patchable: Bool
    }

    private struct CentralPlan {
        let actions: [CentralAction]
        let size: UInt64
        let patches: UInt64
        let trailer: Data
        let patchable: Bool
    }

    // 生き残る record の配置を決め、続けて CD と終端を組む。inPlace は両段階が patch だけで済むときに限る。
    static func plan(source: ArchiveFileSource, layout: ZipUpdateLayout, reader: ArchiveReader,
                     directory: ZipValidatedDirectory, removed: Set<Int>, renamed: [Int: String],
                     writtenRange: Range<UInt64>? = nil, appended: [ZipRecords.Entry] = [],
                     reencryption: ZipReencryption? = nil,
                     recordLayout: (Int) throws -> ZipRecordLayout?) throws -> Plan {
        let local = try planLocalRecords(source: source, reader: reader, directory: directory, removed: removed,
                                         renamed: renamed, writtenRange: writtenRange, reencryption: reencryption,
                                         recordLayout: recordLayout)
        let appendedSize = writtenRange?.byteLength ?? 0
        let centralOffset = try checkedAdd(local.end, appendedSize)
        let central = try planCentral(local, source: source, layout: layout, reader: reader, directory: directory,
                                      renamed: renamed, appended: appended, centralOffset: centralOffset)
        try Task.checkCancellation()
        let trailerSize = UInt64(central.trailer.count)
        let finalEnd = try checkedAdd(centralOffset, checkedAdd(central.size, trailerSize))
        let total = try checkedAdd(local.bytes, central.patchable ? central.patches : checkedAdd(central.size, trailerSize))
        return Plan(records: local.records, central: central.actions, end: local.end, centralOffset: centralOffset,
                    finalEnd: finalEnd, trailer: central.trailer, inPlace: central.patchable, totalBytes: total)
    }

    // 各 record を keep / patch / copy / convert に振り分け、新しい local 領域の終端を決める。
    private static func planLocalRecords(source: ArchiveFileSource, reader: ArchiveReader, directory: ZipValidatedDirectory,
                                         removed: Set<Int>, renamed: [Int: String], writtenRange: Range<UInt64>?,
                                         reencryption: ZipReencryption?,
                                         recordLayout: (Int) throws -> ZipRecordLayout?) throws -> LocalPlan {
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
                position = try checkedAdd(start, checkedAdd(UInt64(replacement.count), payload.byteLength))
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
                position = try checkedAdd(start, raw.recordRange.byteLength)
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
        return LocalPlan(records: records, end: position, bytes: localBytes, patchable: patchable)
    }

    // CD は canonical な record を原本から運び、それ以外は組み直す。終端が旧 EOCD と一致すれば in-place にできる。
    private static func planCentral(_ local: LocalPlan, source: ArchiveFileSource, layout: ZipUpdateLayout,
                                    reader: ArchiveReader, directory: ZipValidatedDirectory, renamed: [Int: String],
                                    appended: [ZipRecords.Entry], centralOffset: UInt64) throws -> CentralPlan {
        let records = local.records
        let localEnd = local.end
        var patchable = local.patchable && localEnd == layout.centralOffset && appended.isEmpty
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
        return CentralPlan(actions: central, size: centralSize, patches: centralPatches, trailer: trailer, patchable: patchable)
    }

    static func execute(_ plan: Plan, source: ArchiveFileSource, directory: ZipValidatedDirectory,
                        layout: ZipUpdateLayout, stagedSource: ArchiveFileSource?, writtenRange: Range<UInt64>?,
                        reencryption: ZipReencryption? = nil,
                        engine: inout ZipCopyEngine, progress: ((ArchiveUpdater.CommitProgress) throws -> Void)?) throws {
        try executeLocal(plan, source: source, reencryption: reencryption, engine: &engine, progress: progress)
        if let stagedSource, let writtenRange {
            try engine.copy(writtenRange, from: stagedSource, to: plan.end, progress: progress)
        }
        try executeCentral(plan, directory: directory, layout: layout, engine: &engine, progress: progress)
    }

    private static func executeLocal(_ plan: Plan, source: ArchiveFileSource, reencryption: ZipReencryption?, engine: inout ZipCopyEngine,
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
                   previous.offset + previous.range.byteLength == record.offset {
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
}

// record 単位の動作を保持し、後続の暗号化変換もこの計画に追加できる。
enum ZipPlannedAction {
    case keep
    case patchHeader(Data)
    case copy(Range<UInt64>)
    case headerThenCopy(Data, Range<UInt64>)
    case convert(ZipConversion)
}
