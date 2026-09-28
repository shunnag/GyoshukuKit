import Foundation
@_spi(ZipRawLayout) internal import KaitoKit

// 圧縮済み payload の同一性と、展開後の CRC は別々に検証する。
final class ZipConversion {
    let index: Int
    let name: String
    let raw: ZipRecordLayout
    let size: UInt64
    let target: ZipRawEncryption
    let storedLength: UInt64
    let compressedSize: UInt64
    let passA: Bool
    let v2: Bool
    var crc: UInt32
    var payloadCRC: UInt32 = 0
    var local = Data()
    var central = Data()
    var keySlot: Int?

    init(entry: ArchiveEntry, raw: ZipRecordLayout, target: ZipRawEncryption) throws {
        index = entry.index
        name = entry.name
        self.raw = raw
        self.target = target
        guard let size = entry.uncompressedSize,
              raw.payloadRange.byteLength >= raw.encryption.overhead else {
            throw UpdaterError.reencryptionFailed(index: entry.index, name: entry.name, reason: "保存データの長さが不正です")
        }
        self.size = size
        storedLength = raw.payloadRange.byteLength - raw.encryption.overhead
        compressedSize = try checkedAdd(storedLength, target.overhead)
        passA = raw.encryption.aesVersion == 2 && target.aesVersion == nil
        v2 = raw.encryption == .zipCrypto || passA || (raw.encryption == .none && target.aesVersion == 2)
        crc = target.aesVersion == 2 ? 0 : raw.storedCRC32
    }

    func failure(_ reason: String) -> UpdaterError {
        .reencryptionFailed(index: index, name: name, reason: reason)
    }

    func assemble(source: ArchiveFileSource, header: ZipRebuild.CentralHeader, offset: UInt64, name newName: String?) throws {
        let original = try ZipRebuild.LocalHeader(source: source, layout: raw)
        let aes = ZipRebuild.extraFields(header.extra).filter { $0.id == ZipRecords.ExtraID.winZipAES }
        if let version = raw.encryption.aesVersion {
            guard aes.count == 1,
                  header.extra.subdata(in: aes[0].range) == Self.aesExtra(version: version,
                    strength: raw.encryption.strength!, method: raw.compressionMethod) else {
                throw failure("中央ディレクトリの暗号情報が一致しません")
            }
        } else if !aes.isEmpty { throw failure("中央ディレクトリの暗号情報が一致しません") }
        let renamed = newName.map { Data($0.utf8) }
        let local64 = size >= ZipRecords.limit || compressedSize >= ZipRecords.limit
        let any64 = local64 || offset >= ZipRecords.limit
        var localSizes = Data()
        if local64 { localSizes.le(size); localSizes.le(compressedSize) }
        var centralSizes = Data()
        if size >= ZipRecords.limit { centralSizes.le(size) }
        if compressedSize >= ZipRecords.limit { centralSizes.le(compressedSize) }
        if offset >= ZipRecords.limit { centralSizes.le(offset) }
        let lx = try extras(original.extra, zip64: localSizes, renamed: renamed != nil)
        let cx = try extras(header.extra, zip64: centralSizes, renamed: renamed != nil)
        let ln = renamed ?? original.name, cn = renamed ?? header.name
        guard ln.count <= Int(UInt16.max), cn.count <= Int(UInt16.max) else { throw failure("名前が長すぎます") }
        local = original.fixed
        local.zipSet(version(original.fixed.zip16(4), zip64: any64), at: 4)
        local.zipSet(flags(original.fixed.zip16(6), renamed: renamed != nil), at: 6)
        local.zipSet(target.aesVersion == nil ? raw.compressionMethod : 99, at: 8)
        local.zipSet(crc, at: 14)
        local.zipSet(local64 ? UInt32.max : UInt32(compressedSize), at: 18)
        local.zipSet(local64 ? UInt32.max : UInt32(size), at: 22)
        local.zipSet(UInt16(ln.count), at: 26)
        local.zipSet(UInt16(lx.count), at: 28)
        local.append(ln)
        local.append(lx)
        central = header.fixed
        central.zipSet(version(header.fixed.zip16(6), zip64: any64), at: 6)
        central.zipSet(flags(header.fixed.zip16(8), renamed: renamed != nil), at: 8)
        central.zipSet(target.aesVersion == nil ? raw.compressionMethod : 99, at: 10)
        central.zipSet(crc, at: 16)
        central.zipSet(UInt32(min(compressedSize, ZipRecords.limit)), at: 20)
        central.zipSet(UInt32(min(size, ZipRecords.limit)), at: 24)
        central.zipSet(UInt16(cn.count), at: 28)
        central.zipSet(UInt16(cx.count), at: 30)
        central.zipSet(UInt16(0), at: 34)
        central.zipSet(UInt32(min(offset, ZipRecords.limit)), at: 42)
        central.append(cn)
        central.append(cx)
        central.append(header.comment)
    }

    private func version(_ original: UInt16, zip64: Bool) -> UInt16 {
        let low: UInt16
        if target.aesVersion != nil { low = max(51, original & 255) }
        else if raw.encryption.aesVersion != nil {
            let methodVersion: UInt16
            switch raw.compressionMethod {
            case 9: methodVersion = 21
            case 12: methodVersion = 46
            case 14, 19, 20, 93, 95, 97, 98: methodVersion = 63
            default: methodVersion = 20
            }
            low = max(methodVersion, zip64 ? 45 : 20)
        } else { low = max(original & 255, target == .zipCrypto ? 20 : 0, zip64 ? 45 : 0) }
        return (original & 0xff00) | low
    }

    private func flags(_ original: UInt16, renamed: Bool) -> UInt16 {
        (original & ~UInt16(9)) | (target == .none ? 0 : 1) | (renamed ? ZipRecords.flags : 0)
    }

    private func extras(_ original: Data, zip64: Data, renamed: Bool) throws -> Data {
        var rest = Data()
        var consumed = 0
        for field in ZipRebuild.extraFields(original) {
            if field.id != ZipRecords.ExtraID.zip64 && field.id != ZipRecords.ExtraID.winZipAES { rest.append(original.subdata(in: field.range)) }
            consumed = field.range.upperBound
        }
        let tail = original.dropFirst(consumed)
        if renamed {
            // 不透明な末尾を含む extra の改名は renamedExtra と同じ規則で拒否する。
            rest.append(tail)
            rest = try ZipRebuild.renamedExtra(rest)
            rest.removeLast(tail.count)
        }
        var result = zip64.isEmpty ? Data() : ZipRecords.field(ZipRecords.ExtraID.zip64, zip64)
        result.append(rest)
        if let version = target.aesVersion {
            result.append(Self.aesExtra(version: version, strength: 3, method: raw.compressionMethod))
        }
        result.append(tail)
        guard result.count <= Int(UInt16.max) else { throw failure("拡張フィールドが長すぎます") }
        return result
    }

    static func aesExtra(version: UInt16, strength: UInt8, method: UInt16) -> Data {
        var body = Data()
        body.le(version)
        body.append(contentsOf: [0x41, 0x45, strength])
        body.le(method)
        return ZipRecords.field(ZipRecords.ExtraID.winZipAES, body)
    }

    func validateHeaders(local: Data, central: Data) throws {
        let localExtraStart = ZipRecords.FixedLength.local + Int(local.zip16(26))
        let centralExtraStart = ZipRecords.FixedLength.central + Int(central.zip16(28))
        let lx = local.subdata(in: localExtraStart..<(localExtraStart + Int(local.zip16(28))))
        let cx = central.subdata(in: centralExtraStart..<(centralExtraStart + Int(central.zip16(30))))
        let lf = ZipRebuild.extraFields(lx), cf = ZipRebuild.extraFields(cx)
        var uncompressed = UInt64(local.zip32(22)), compressed = UInt64(local.zip32(18))
        if uncompressed == ZipRecords.limit || compressed == ZipRecords.limit {
            let fields = lf.filter { $0.id == ZipRecords.ExtraID.zip64 }
            guard uncompressed == ZipRecords.limit, compressed == ZipRecords.limit,
                  fields.count == 1, fields[0].range.count == 20 else {
                throw failure("出力 local の ZIP64 サイズを照合できません")
            }
            uncompressed = lx.zip64(fields[0].range.lowerBound + 4)
            compressed = lx.zip64(fields[0].range.lowerBound + 12)
        }
        let localAES = lf.filter { $0.id == ZipRecords.ExtraID.winZipAES }.map { lx.subdata(in: $0.range) }
        let centralAES = cf.filter { $0.id == ZipRecords.ExtraID.winZipAES }.map { cx.subdata(in: $0.range) }
        guard uncompressed == size, compressed == compressedSize, localAES == centralAES,
              local.zip16(6) & 0x809 == central.zip16(8) & 0x809,
              local.zip16(8) == central.zip16(10), local.zip32(14) == central.zip32(16) else {
            throw failure("出力 local と中央ディレクトリが一致しません")
        }
    }
}

final class ZipReencryption {
    enum Phase: Sendable { case deriveInput, deriveOutput, derivationWait, passA, convert, v0, v1, v2, v3 }
    struct Event: Sendable { let phase: Phase; let index: Int }
    @TaskLocal static var testingObserver: (@Sendable (Event) throws -> Void)?
    @TaskLocal static var testingKeyMaterial: (@Sendable (Int, inout Keys) throws -> Void)?
    struct KeyInput: Sendable { let password: Data; let salt: Data; let strength: UInt8 }
    struct Job: Sendable { let input: KeyInput?; let output: KeyInput? }
    struct Keys: Sendable { var input: ZipAESKeyMaterial?; var output: ZipAESKeyMaterial? }
    typealias Progress = ((ArchiveUpdater.CommitProgress) throws -> Void)?
    static let chunk = 1_048_576
    static let derivationWork: UInt64 = 65_536
    let conversions: [Int: ZipConversion]
    let samples: Set<Int>
    let work: UInt64
    let reader: ArchiveReader
    private let options: WriterOptions
    private let currentPassword: String?
    // 1 entry あたり材料 66 byte と salt 16 byte。検証が終わればまとめて解放する。
    private var outputKeys = Data()
    private var outputSalts = Data()

    static func plan(reader: ArchiveReader?, directory: ZipValidatedDirectory, removed: Set<Int>,
                     options: WriterOptions, currentPassword: String?) throws -> ZipReencryption? {
        guard let reader else { return nil }
        var conversions: [Int: ZipConversion] = [:]
        let samePassword = currentPassword.map { Data($0.utf8) } == options.password.map { Data($0.utf8) }
        for entry in reader.entries where !removed.contains(entry.index) {
            if entry.index % 4096 == 0 { try Task.checkCancellation() }
            let raw = directory.records[entry.index].layout
            let target: ZipRawEncryption
            if entry.kind != .file || options.password == nil { target = .none }
            else if options.zipEncryption == .zipCrypto { target = .zipCrypto }
            else { target = .winZipAES(strength: 3, vendorVersion: raw.encryption.aesVersion ?? ((entry.uncompressedSize ?? 0) < 20 ? 1 : 2)) }
            if raw.encryption == target && (target == .none || samePassword) { continue }
            conversions[entry.index] = try ZipConversion(entry: entry, raw: raw, target: target)
        }
        guard !conversions.isEmpty else { return nil }
        if currentPassword == nil, conversions.values.contains(where: { $0.raw.encryption != .none }) {
            throw KaitoError.passwordRequired
        }
        return try ZipReencryption(conversions: conversions, reader: reader, options: options, currentPassword: currentPassword)
    }

    private init(conversions: [Int: ZipConversion], reader: ArchiveReader, options: WriterOptions, currentPassword: String?) throws {
        self.conversions = conversions
        self.reader = reader
        self.options = options
        self.currentPassword = currentPassword
        reader.password = currentPassword
        let aes = conversions.values.filter { $0.target.aesVersion != nil }.map(\.index).sorted()
        if aes.count <= 16 { samples = Set(aes) }
        else { samples = Set((0..<16).map { aes[$0 * (aes.count - 1) / 15] }) }
        var total: UInt64 = 0
        for conversion in conversions.values {
            let passes = 1 + (conversion.passA ? 1 : 0) + (conversion.v2 ? 1 : 0) + (samples.contains(conversion.index) ? 1 : 0)
            for _ in 0..<passes { total = try checkedAdd(total, conversion.storedLength) }
            if conversion.raw.encryption.aesVersion != nil { total = try checkedAdd(total, Self.derivationWork) }
            if conversion.target.aesVersion != nil { total = try checkedAdd(total, Self.derivationWork) }
            if samples.contains(conversion.index) { total = try checkedAdd(total, Self.derivationWork) }
        }
        work = total
        outputKeys.reserveCapacity(aes.count * 66)
        outputSalts.reserveCapacity(aes.count * 16)
    }

    static func observe(_ phase: Phase, _ index: Int) throws {
        try Task.checkCancellation()
        try testingObserver?(Event(phase: phase, index: index))
        try Task.checkCancellation()
    }

    func withKeys(records: [ZipRebuild.PlannedRecord], source: ArchiveFileSource,
                  emit: (ZipRebuild.PlannedRecord, Keys?) throws -> Void) throws {
        let pipeline = OrderedChunkPipeline<Job, Keys, (ZipRebuild.PlannedRecord, Job?)>(threads: options.resolvedCompressionThreads) { job in
            let input = try job.input.map { try ZipAESKeyMaterial.derive(passwordBytes: $0.password, salt: $0.salt, strength: $0.strength) }
            let output = try job.output.map {
                try ZipAESKeyMaterial(salt: $0.salt, strength: 3,
                    bytes: EncryptionPrimitives.zipKeyMaterial(passwordBytes: $0.password, salt: $0.salt))
            }
            return Keys(input: input, output: output)
        }
        defer { pipeline.abandon() }
        func receive(_ tag: (ZipRebuild.PlannedRecord, Job?), _ value: Keys?) throws {
            let (record, job) = tag
            var value = value
            if var keys = value {
                try Self.testingKeyMaterial?(record.index, &keys)
                value = keys
            }
            if let conversion = conversions[record.index] {
                guard value?.input?.salt == job?.input?.salt, value?.input?.strength == job?.input?.strength,
                      value?.output?.salt == job?.output?.salt, value?.output?.strength == job?.output?.strength else {
                    throw conversion.failure("鍵材料の順序または salt が一致しません")
                }
                if let output = value?.output {
                    conversion.keySlot = outputSalts.count / 16
                    outputSalts.append(output.salt)
                    outputKeys.append(output.bytes)
                }
            }
            try emit(record, value)
        }
        for record in records {
            try Self.observe(.derivationWait, record.index)
            try pipeline.waitForCapacity(emit: receive)
            var job: Job?
            if let conversion = conversions[record.index] {
                var input: KeyInput?, output: KeyInput?
                if let strength = conversion.raw.encryption.strength {
                    let salt = try source.bytes(at: conversion.raw.payloadRange.lowerBound, count: 4 * Int(strength) + 4)
                    input = KeyInput(password: Data(currentPassword!.utf8), salt: salt, strength: strength)
                    try Self.observe(.deriveInput, record.index)
                }
                if conversion.target.aesVersion != nil {
                    let salt = try EncryptionPrimitives.testingRandomBytes?(16) ?? EncryptionPrimitives.random(count: 16)
                    guard salt.count == 16 else { throw conversion.failure("salt の長さが一致しません") }
                    output = KeyInput(password: Data(options.password!.utf8), salt: salt, strength: 3)
                    try Self.observe(.deriveOutput, record.index)
                }
                if input != nil || output != nil { job = Job(input: input, output: output) }
            }
            try pipeline.submit(job, tag: (record, job), emit: receive)
        }
        try pipeline.finish(emit: receive)
    }

    func convert(_ conversion: ZipConversion, keys: Keys?, at offset: UInt64,
                 engine: inout ZipCopyEngine, progress: Progress) throws {
        for key in [keys?.input, keys?.output] where key != nil {
            try engine.meter.wrote(Int(Self.derivationWork), progress: progress)
        }
        if conversion.passA {
            try Self.observe(.passA, conversion.index)
            let stream = try input(conversion) { try reader.zipStream(at: conversion.index, aesKey: keys!.input!) }
            let digest = try Self.digest(stream, length: conversion.size, work: conversion.storedLength,
                meter: &engine.meter, progress: progress, read: { buffer in try self.input(conversion) { try stream.read(into: buffer) } })
            conversion.crc = digest.crc
            conversion.local.zipSet(digest.crc, at: 14)
            conversion.central.zipSet(digest.crc, at: 16)
        }
        try Self.observe(.convert, conversion.index)
        let stream = try input(conversion) { try reader.zipStoredPayloadStream(at: conversion.index, aesKey: keys?.input) }
        let aes = try keys?.output.map { try ZipAESEncryptor(material: $0.bytes, salt: $0.salt) }
        var traditional = conversion.target == .zipCrypto ? ZipCryptoEncryptor(password: options.password!) : nil
        var prefix = Data()
        if let aes { prefix = aes.prefix }
        else if traditional != nil {
            prefix = try EncryptionPrimitives.testingRandomBytes?(11) ?? EncryptionPrimitives.random(count: 11)
            guard prefix.count == 11 else { throw conversion.failure("暗号ヘッダーの長さが一致しません") }
            prefix.append(UInt8(truncatingIfNeeded: conversion.crc >> 24))
            prefix = traditional!.encrypt(prefix)
        }
        let small = conversion.storedLength <= UInt64(Self.chunk)
        var assembled = conversion.local + prefix
        var position = offset
        if !small {
            try engine.append(assembled, at: position, progress: progress)
            position += UInt64(assembled.count)
            assembled.removeAll(keepingCapacity: false)
        }
        var buffer = Data(count: Int(min(UInt64(Self.chunk), max(1, conversion.storedLength))))
        var length: UInt64 = 0
        var crc: UInt32 = 0
        while true {
            try Task.checkCancellation()
            let count = try buffer.withUnsafeMutableBytes { bytes in try input(conversion) { try stream.read(into: bytes) } }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            crc = updateCRC(crc, chunk)
            length = try checkedAdd(length, UInt64(count))
            let encrypted = try aes?.encrypt(chunk) ?? traditional?.encrypt(chunk) ?? chunk
            if small { assembled.append(encrypted) }
            else {
                try engine.append(encrypted, at: position, progress: progress)
                position += UInt64(encrypted.count)
            }
        }
        guard length == conversion.storedLength else { throw conversion.failure("保存データの長さが一致しません") }
        conversion.payloadCRC = crc
        if let aes {
            let suffix = try aes.finish()
            if small { assembled.append(suffix) }
            else { try engine.append(suffix, at: position, progress: progress); position += UInt64(suffix.count) }
        }
        if small { try engine.append(assembled, at: position, progress: progress); position += UInt64(assembled.count) }
        guard position - offset == UInt64(conversion.local.count) + conversion.compressedSize else {
            throw conversion.failure("変換後の長さが計画と一致しません")
        }
    }

    private func input<T>(_ conversion: ZipConversion, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch is CancellationError { throw CancellationError() }
        catch KaitoError.wrongPassword { throw KaitoError.wrongPassword }
        catch KaitoError.passwordRequired { throw KaitoError.passwordRequired }
        catch let error as WriterError { if case .io = error { throw error }; throw conversion.failure("入力を復号・展開できません") }
        catch { throw conversion.failure("入力を復号・展開できません") }
    }

    private func outputKey(_ conversion: ZipConversion) throws -> ZipAESKeyMaterial? {
        guard let slot = conversion.keySlot else { return nil }
        return try ZipAESKeyMaterial(salt: outputSalts.subdata(in: (slot * 16)..<(slot * 16 + 16)), strength: 3,
                                     bytes: outputKeys.subdata(in: (slot * 66)..<(slot * 66 + 66)))
    }

    static func digest(_ stream: EntryStream, length: UInt64, work: UInt64, meter: inout ZipCommitMeter,
                       progress: Progress, read: ((UnsafeMutableRawBufferPointer) throws -> Int)? = nil) throws -> (crc: UInt32, length: UInt64) {
        var buffer = Data(count: Int(min(UInt64(chunk), max(1, length))))
        var crc: UInt32 = 0, produced: UInt64 = 0, credited: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let count = try buffer.withUnsafeMutableBytes { try read?($0) ?? stream.read(into: $0) }
            if count == 0 { break }
            crc = buffer.withUnsafeBytes { updateCRC(crc, UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            produced = try checkedAdd(produced, UInt64(count))
            guard produced <= length else { throw KaitoError.malformed("entry length") }
            let next = length == 0 ? work : length.dividingFullWidth(work.multipliedFullWidth(by: produced)).quotient
            try meter.wrote(Int(next - credited), progress: progress)
            credited = next
        }
        guard produced == length else { throw KaitoError.truncated }
        try meter.wrote(Int(work - credited), progress: progress)
        return (crc, produced)
    }

    func verify(url: URL, plan: ZipRebuild.Plan, directory: ZipValidatedDirectory,
                renamed: [Int: String], appended: [ZipRecords.Entry], meter: inout ZipCommitMeter, progress: Progress) throws {
        defer { outputKeys = Data(); outputSalts = Data() }
        var active: ZipConversion?
        do {
            try Self.observe(.v0, -1)
            let source = try ArchiveFileSource(url: url)
            let layout = try ZipUpdateLayout(source: source)
            var settings = ArchiveUpdater.readerOptions
            settings.password = options.password
            settings.lazyLocalHeaders = false
            let output = try ArchiveReader.open(source: source, options: settings)
            let validated = try ZipCentralDirectory.validate(source: source, reader: output,
                centralOffset: layout.centralOffset, centralSize: layout.centralSize)
            guard output.format == .zip, layout.count == UInt64(plan.records.count + appended.count),
                  output.entries.count == plan.records.count + appended.count,
                  layout.centralOffset == plan.centralOffset, source.length == plan.finalEnd,
                  try source.bytes(at: plan.finalEnd - UInt64(plan.trailer.count), count: plan.trailer.count) == plan.trailer else {
                throw KaitoError.malformed("output layout")
            }
            for (ordinal, record) in plan.records.enumerated() {
                try Task.checkCancellation()
                active = conversions[record.index]
                let original = reader.entries[record.index], entry = output.entries[ordinal]
                let raw = validated.records[ordinal].layout
                let expected = active?.target ?? directory.records[record.index].layout.encryption
                let crc = active?.crc ?? directory.records[record.index].layout.storedCRC32
                guard entry.name == (renamed[record.index] ?? original.name), entry.kind == original.kind,
                      entry.uncompressedSize == original.uncompressedSize,
                      entry.compressedSize == (active?.compressedSize ?? original.compressedSize),
                      entry.crc32 == (expected.aesVersion == 2 ? nil : crc), raw.storedCRC32 == crc,
                      raw.encryption == expected, raw.compressionMethod == directory.records[record.index].layout.compressionMethod,
                      raw.recordRange.lowerBound == record.offset else { throw KaitoError.malformed("output entry") }
                if let conversion = active {
                    guard !raw.hasDataDescriptor else { throw KaitoError.malformed("output descriptor") }
                    // KaitoKit が照合しない local の方式・CRC・AES extra も byte 表から照合する。
                    let local = try source.bytes(at: raw.recordRange.lowerBound, count: conversion.local.count)
                    let central = validated.bytes.subdata(in: validated.records[ordinal].centralRange)
                    guard local == conversion.local, central == conversion.central else {
                        throw conversion.failure("出力ヘッダーの照合に失敗しました")
                    }
                    try conversion.validateHeaders(local: local, central: central)
                }
            }
            active = nil
            for ordinal in appended.indices {
                let index = plan.records.count + ordinal
                // 追記 CD は plan が offset を確定済み。追加 record の local は ZipAppendedRecordSelfCheck が照合する。
                guard case .rebuilt(let bytes) = plan.central[index],
                      validated.bytes.subdata(in: validated.records[index].centralRange) == bytes else {
                    throw KaitoError.malformed("appended entry")
                }
            }
            for (ordinal, record) in plan.records.enumerated() {
                guard let conversion = conversions[record.index] else { continue }
                active = conversion
                let key = try outputKey(conversion)
                try Self.observe(.v1, conversion.index)
                let stored = try output.zipStoredPayloadStream(at: ordinal, aesKey: key)
                let digest = try Self.digest(stored, length: conversion.storedLength, work: conversion.storedLength, meter: &meter, progress: progress)
                guard digest.crc == conversion.payloadCRC else { throw conversion.failure("保存データの照合に失敗しました") }
                if conversion.v2 {
                    do {
                        try Self.observe(.v2, conversion.index)
                        let stream = try key.map { try output.zipStream(at: ordinal, aesKey: $0) } ?? output.stream(output.entries[ordinal])
                        let expanded = try Self.digest(stream, length: conversion.size, work: conversion.storedLength, meter: &meter, progress: progress)
                        if conversion.target.aesVersion == 2, expanded.crc != conversion.raw.storedCRC32 {
                            throw conversion.failure("展開データの照合に失敗しました")
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if conversion.raw.encryption == .zipCrypto {
                            // 照合 byte を偶然通る入力だけ、通常の reader で原因を確定する。
                            do {
                                var discarded = ZipCommitMeter(totalBytes: 0)
                                let input = try reader.stream(reader.entries[conversion.index])
                                _ = try Self.digest(input, length: conversion.size, work: 0, meter: &discarded, progress: nil)
                            } catch KaitoError.wrongPassword { throw InputPasswordFailure() }
                            catch is CancellationError { throw CancellationError() }
                            catch { }
                        }
                        throw conversion.failure("展開データの照合に失敗しました")
                    }
                }
            }
            // 材料経由では検出できない AE-2 の encryption key の取り違えを、password 導出で検出する。
            for (ordinal, record) in plan.records.enumerated() where samples.contains(record.index) {
                let conversion = conversions[record.index]!
                active = conversion
                try Self.observe(.v3, conversion.index)
                let stream = try output.zipStoredPayloadStream(at: ordinal)
                try meter.wrote(Int(Self.derivationWork), progress: progress)
                let digest = try Self.digest(stream, length: conversion.storedLength, work: conversion.storedLength, meter: &meter, progress: progress)
                guard digest.crc == conversion.payloadCRC else { throw conversion.failure("鍵導出の照合に失敗しました") }
            }
        } catch is CancellationError { throw CancellationError() }
        catch is InputPasswordFailure { throw KaitoError.wrongPassword }
        catch { throw active?.failure("出力の再暗号化検証に失敗しました") ?? UpdaterError.reencryptionFailed(index: -1, name: "", reason: "出力構造の照合に失敗しました") }
    }

    private struct InputPasswordFailure: Error { }
}


extension ZipRawEncryption {
    var aesVersion: UInt16? { if case .winZipAES(_, let version) = self { version } else { nil } }
    var strength: UInt8? { if case .winZipAES(let strength, _) = self { strength } else { nil } }
    var overhead: UInt64 {
        switch self {
        case .none: 0
        case .zipCrypto: 12
        case .winZipAES(let strength, _): UInt64(4 * strength + 16)
        }
    }
}
