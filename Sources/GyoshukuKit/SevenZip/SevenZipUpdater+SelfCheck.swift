import Foundation
import Synchronization
@_spi(SevenZipEditLayout) internal import KaitoKit

extension SevenZipUpdater {
    static func verificationUnits(assembly: SevenZipEditPlan.Assembly, plan: SevenZipEditPlan,
                                  workset: SevenZipFolderWorkset) -> UInt64 {
        let model = assembly.model
        var units = model.plainHeaderLength
        for index in assembly.firstAddedFolder..<model.folders.count { units += model.folders[index].size }
        for work in plan.works {
            switch work {
            case .reencode(let index, _): units += model.folders[assembly.outputFolderIndices[index]!].size
            case .convert(let index, _): units += workset.conversions[index]!.plaintextLength
            default: break
            }
        }
        return units
    }

    /// 出力の自己照合。失敗理由の先頭の符号（design.md §9「P5-G: SevenZipUpdater」）:
    /// V0 計画・組み立ての帳簿（EditPlan.assemble / makePrefix / validLayout が出す）、
    /// V1 dup した descriptor 上で KaitoKit が解析した model と期待 model の一致、
    /// V2 共有出力の V5（動かした source 範囲の byte 比較。SegmentedArchiveOutput が行う）、
    /// V3 追加・再圧縮 folder の全 substream の復号、V3a 変換 folder の圧縮済み平文の長さと CRC。
    func selfCheck(fd: Int32, plan: SevenZipEditPlan, assembly: SevenZipEditPlan.Assembly, workset: SevenZipFolderWorkset,
                   advance: (UInt64) throws -> Void, statistics: inout SevenZipCommitStatistics) throws {
        let start = ProcessInfo.processInfo.systemUptime
        let source = try ArchiveFileSource(duplicating: fd)
        let descriptor = source.descriptor
        let bytesRead = Mutex<UInt64>(0)
        let previous = ArchiveFileSource.readObserver
        var stage = "V1", index = -1
        var progressError: Error?
        func advancing(_ count: UInt64) throws {
            do { try advance(count) } catch { progressError = error; throw error }
        }
        defer {
            statistics.selfCheckSeconds = ProcessInfo.processInfo.systemUptime - start
            statistics.verificationReadBytes += bytesRead.withLock { $0 }
        }
        do {
            try ArchiveFileSource.$readObserver.withValue({ fd, offset, count in
                previous?(fd, offset, count)
                if fd == descriptor { bytesRead.withLock { $0 += UInt64(count) } }
            }) {
                let v1 = ProcessInfo.processInfo.systemUptime
                let outputReader = try ArchiveReader.open(source: source, sourceURL: output,
                    options: SevenZipEditModel.readerOptions(password: options.password))
                guard let actual = SevenZipEditModel.read(outputReader) else { throw failure("V1 snapshot") }
                let expected = assembly.model
                guard actual.baseOffset == 0, actual.versionMajor == 0, actual.versionMinor == 4,
                      actual.packPosition == 0, actual.unrepresentedReason == nil,
                      actual.header == expected.header, actual.nextHeaderRange == expected.nextHeaderRange,
                      actual.plainHeaderLength == expected.plainHeaderLength,
                      actual.packs == expected.packs, actual.folders == expected.folders,
                      actual.substreams == expected.substreams, actual.files == expected.files,
                      actual.mainPackEnd == expected.mainPackEnd else { throw failure("V1 model") }
                try advancing(expected.plainHeaderLength)
                statistics.v1Seconds = ProcessInfo.processInfo.systemUptime - v1
                stage = "V3"
                let v3 = ProcessInfo.processInfo.systemUptime
                var decode = Set(assembly.firstAddedFolder..<expected.folders.count)
                for case let .reencode(original, _) in plan.works { decode.insert(assembly.outputFolderIndices[original]!) }
                for (file, value) in expected.files.enumerated() {
                    guard let stream = value.substreamIndex, decode.contains(expected.substreams[stream].folderIndex) else { continue }
                    index = file
                    try Task.checkCancellation()
                    let input = try outputReader.stream(outputReader.entries[file])
                    while true {
                        try Task.checkCancellation()
                        let bytes = try input.readSome(upTo: IOChunk.size)
                        try advancing(UInt64(bytes.count))
                        if bytes.isEmpty { break }
                    }
                }
                statistics.v3Seconds = ProcessInfo.processInfo.systemUptime - v3
                stage = "V3a"
                let v3a = ProcessInfo.processInfo.systemUptime
                for case let .convert(original, _) in plan.works {
                    try Task.checkCancellation()
                    index = assembly.outputFolderIndices[original]!
                    let folder = expected.folders[index]
                    let converted = workset.conversions[original]!
                    let pack = expected.packs[folder.packIndices.lowerBound].range
                    let input = folder.isEncrypted ? try outputReader.sevenZipDecryptedPackedStream(folder: index, packedInput: 0) : nil
                    var position: UInt64 = 0, crc: UInt32 = 0
                    while position < converted.plaintextLength {
                        try Task.checkCancellation()
                        let count = Int(min(4 * 1024 * 1024, converted.plaintextLength - position))
                        let bytes: Data
                        if let input { bytes = try input.readSome(upTo: count) }
                        else {
                            bytes = try SegmentedArchiveOutput.read(fd, at: pack.lowerBound + position, count: count, counted: true)
                            bytesRead.withLock { $0 += UInt64(count) }
                        }
                        guard !bytes.isEmpty else { throw failure("V3a length \(index)") }
                        crc = updateCRC(crc, bytes); position += UInt64(bytes.count)
                        try advancing(UInt64(bytes.count))
                    }
                    if let input, !(try input.readSome(upTo: 1)).isEmpty { throw failure("V3a length \(index)") }
                    guard position == converted.plaintextLength, crc == converted.plaintextCRC else { throw failure("V3a CRC \(index)") }
                }
                statistics.v3aSeconds = ProcessInfo.processInfo.systemUptime - v3a
            }
        } catch {
            if let progressError { throw progressError }
            if error is CancellationError { throw error }
            if let error = error as? UpdaterRouteError { throw error }
            throw failure("\(stage) folder/file \(index)")
        }
    }

    static func faultAction(plan: SevenZipEditPlan, assembly: SevenZipEditPlan.Assembly)
        -> (@Sendable (Int32) throws -> Void)? {
        guard let fault = testingFault else { return nil }
        var offset: UInt64?
        for work in plan.works {
            let folder = assembly.model.folders[assembly.outputFolderIndices[work.index]!]
            switch (fault, work) {
            case (.flipReencodedPackByte, .reencode), (.flipConvertedPackByte, .convert):
                offset = assembly.model.packs[folder.packIndices.lowerBound].range.lowerBound
            default: break
            }
            if offset != nil { break }
        }
        if fault == .flipMovedPackByte {
            // 試験側は先頭を削除して最初の生存 pack を動かす。
            offset = assembly.model.packs.first?.range.lowerBound
        }
        if fault == .flipAppendedPackByte, assembly.firstAddedFolder < assembly.model.folders.count {
            offset = assembly.model.packs[assembly.model.folders[assembly.firstAddedFolder].packIndices.lowerBound].range.lowerBound
        }
        guard let offset else { return nil }
        return { fd in
            var data = try SegmentedArchiveOutput.read(fd, at: offset, count: 1)
            data[0] ^= 1
            try data.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: offset) }
        }
    }
}
