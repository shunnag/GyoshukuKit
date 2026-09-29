import Foundation
private import Darwin
internal import KaitoKit

/// 非圧縮 tar の commit 後の自己照合。SegmentedArchiveOutput.commit の verify callback として、
/// fsync 後・公開前の出力 descriptor に対して走る。失敗は全て TarUpdaterError.outputVerificationFailed。
/// - V4 length: fstat の長さが計画の finalLength
/// - V1 header group: 変更した header 群を原本から独立に再生成して byte と checksum を比較
/// - V2 boundary header: source segment 境界の header block を原本と比較（boundaryUnits ずつ進捗に数える）
/// - V3 added name / bounds: 追加群を独立に walk し、名前と終端を writer の記録と比較
/// - V4 EOF: 終端の空 block と record fill
/// V5（書いた source 範囲の byte 比較）は SegmentedArchiveOutput.verifySources が行う。
enum TarSelfCheck {
    /// V2 は境界ごとに原本と出力の header を 1 block ずつ読む。commit の total と advance が同じ値を使う。
    static let boundaryUnits = UInt64(2 * TarRecords.blockSize)

    static func verify(plan: TarEditPlan, appendedPaths: [(String, Bool)], additionLength: UInt64, finalLength: UInt64,
                       descriptor: Int32, source: ArchiveFileSource, layout: TarLayout,
                       advance: (UInt64) throws -> Void) throws {
        var progressError: Error?
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, UInt64(info.st_size) == finalLength else {
                throw TarUpdaterError.outputVerificationFailed(reason: "V4 length")
            }
            guard plan.isChanged else { return }
            for change in plan.changed {
                let expected = try TarHeaderRewrite.rewrite(source: source, unit: layout.member(change.index),
                    name: change.name, link: change.link, materializedSize: change.materializedTarget.map { layout.member($0).storedSize })
                let actual = try SegmentedArchiveOutput.read(descriptor, at: change.outputOffset, count: Int(change.headerLength))
                guard actual == expected else { throw TarUpdaterError.outputVerificationFailed(reason: "V1 header group") }
                try TarLayout.validateChecksum(Data(actual.suffix(TarRecords.blockSize)))
            }
            for boundary in plan.boundaries {
                try Task.checkCancellation()
                let original = try SegmentedArchiveOutput.read(source.descriptor, at: boundary.source, count: TarRecords.blockSize, counted: true)
                let output = try SegmentedArchiveOutput.read(descriptor, at: boundary.output, count: TarRecords.blockSize, counted: true)
                do { try advance(boundaryUnits) } catch { progressError = error; throw error }
                guard original == output else { throw TarUpdaterError.outputVerificationFailed(reason: "V2 boundary header") }
            }
            if additionLength > 0 {
                let view = OutputView(descriptor: descriptor, length: finalLength)
                var count = 0
                let walk = try TarLayout.walk(source: view, range: plan.membersEnd..<(plan.membersEnd + additionLength)) { index, _, group in
                    guard index < appendedPaths.count, group.name == Data(appendedPaths[index].0.utf8) else {
                        throw TarUpdaterError.outputVerificationFailed(reason: "V3 added name")
                    }
                    count += 1
                }
                guard count == appendedPaths.count, walk.membersEnd == plan.membersEnd + additionLength else {
                    throw TarUpdaterError.outputVerificationFailed(reason: "V3 added bounds")
                }
            }
            let terminal = try SegmentedArchiveOutput.read(descriptor, at: plan.membersEnd + additionLength, count: plan.terminal.count)
            guard terminal == plan.terminal, terminal.count >= TarRecords.endOfArchiveSize else {
                throw TarUpdaterError.outputVerificationFailed(reason: "V4 EOF")
            }
        } catch {
            if let progressError { throw progressError }
            if error is CancellationError { throw error }
            if let failure = error as? TarUpdaterError, case .outputVerificationFailed = failure { throw failure }
            throw TarUpdaterError.outputVerificationFailed(reason: "tar verification: \(error)")
        }
    }

    /// 試験用。fsync 直前の出力を壊し、上の照合が拒否することを確かめる。closure は plan を捕まえず、座標だけを持つ。
    static func faultAction(_ fault: TarUpdater.Fault, plan: TarEditPlan, finalLength: UInt64) -> @Sendable (Int32) throws -> Void {
        let changedOffset = plan.changed.first?.outputOffset ?? plan.membersEnd
        let moved = plan.boundaries.first(where: { $0.source != $0.output })?.output ?? 0
        let block = UInt64(TarRecords.blockSize)
        return { fd in
            let offset: UInt64
            switch fault {
            case .flipWrittenByte(let value): offset = value
            case .shiftSourceSegment:
                let bytes = try SegmentedArchiveOutput.read(fd, at: moved + block, count: TarRecords.blockSize)
                try bytes.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: moved) }
                return
            case .corruptWrittenHeader: offset = changedOffset
            case .dropTerminatorBlock:
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).truncate(atOffset: finalLength - block)
                return
            }
            var byte = try SegmentedArchiveOutput.read(fd, at: offset, count: 1)
            byte[0] ^= 1
            try byte.withUnsafeBytes { try ZipCopyEngine.pwrite(fd, bytes: $0, at: offset) }
        }
    }

    /// V3 の独立 walk が読む、書いた出力の range 限定 view。
    private struct OutputView: ByteSource {
        let descriptor: Int32
        let length: UInt64
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length, !buffer.isEmpty else { return 0 }
            let bytes = try SegmentedArchiveOutput.read(descriptor, at: offset, count: Int(min(UInt64(buffer.count), length - offset)))
            bytes.withUnsafeBytes { buffer.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            return bytes.count
        }
    }
}
