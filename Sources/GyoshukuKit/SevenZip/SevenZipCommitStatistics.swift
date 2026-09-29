import Foundation

// SevenZipUpdater の assess が返す公開の判定と、@_spi(Testing) の commit 統計。
public struct SevenZipAssessment: Sendable, Equatable {
    public let updatable: Bool
    public let reason: String?
    public let hasSolidFolders: Bool
    public let canReencrypt: Bool
}

@_spi(Testing) public struct SevenZipCommitStatistics: Sendable {
    public internal(set) var strategy: SevenZipUpdater.CommitStrategy = .unchanged
    public internal(set) var writtenCarriedPackBytes: UInt64 = 0
    public internal(set) var appendedPackBytes: UInt64 = 0
    public internal(set) var convertedPackBytes: UInt64 = 0
    public internal(set) var reencodedFolderCount = 0
    public internal(set) var reencodedInputBytes: UInt64 = 0
    public internal(set) var reencodedPackBytes: UInt64 = 0
    public internal(set) var reencodeScratchWrittenBytes: UInt64 = 0
    public internal(set) var plainHeaderBytes: UInt64 = 0
    public internal(set) var storedHeaderBytes: UInt64 = 0
    public internal(set) var verificationReadBytes: UInt64 = 0
    public internal(set) var planSeconds = 0.0
    public internal(set) var reencodeScratchSeconds = 0.0
    public internal(set) var scratchCopySeconds = 0.0
    public internal(set) var passwordVerificationSeconds = 0.0
    public internal(set) var packsSeconds = 0.0
    public internal(set) var headerSeconds = 0.0
    public internal(set) var selfCheckSeconds = 0.0
    public internal(set) var v1Seconds = 0.0
    public internal(set) var v2Seconds = 0.0
    public internal(set) var v3Seconds = 0.0
    public internal(set) var v3aSeconds = 0.0
}

extension SevenZipCommitStatistics {
    /// 書き終えた後に、計画・組み立てた model・共有出力の結果から strategy と pack の byte 量を集計する。
    /// clone mode では動いた carry pack だけを書き、動かなかった pack は照合も読まない。
    /// 共有出力が relocatedAppend / sequential に落ちた場合はその strategy が優先する。
    mutating func summarize(plan: SevenZipEditPlan, assembly: SevenZipEditPlan.Assembly, original model: SevenZipEditModel,
                            shared: SegmentCommitStrategy, isCloneMode: Bool, appended: Range<UInt64>?, hasAdditions: Bool,
                            conversions: [Int: SevenZipFolderConversion], reencoded: [Int: SevenZipReencodedFolder],
                            scratchBefore: [Int: Double]) {
        var shifted = false, converted = false, reencodedAny = false
        for work in plan.works {
            let index = work.index, target = assembly.model.folders[assembly.outputFolderIndices[index]!]
            switch work {
            case .carry:
                for (old, new) in zip(model.packs[model.folders[index].packIndices], assembly.model.packs[target.packIndices]) {
                    let moved = old.range.lowerBound != new.range.lowerBound
                    shifted = shifted || moved
                    if (!isCloneMode && (appended == nil || shared == .relocatedAppend)) || (isCloneMode && moved) {
                        writtenCarriedPackBytes += old.length
                    }
                    if !isCloneMode || moved { verificationReadBytes += old.length * 2 }
                }
            case .convert:
                converted = true; convertedPackBytes += conversions[index]!.replacement.packs[0].length
            case .reencode:
                reencodedAny = true; reencodedFolderCount += 1
                scratchCopySeconds += reencoded[index]!.scratch.copySeconds - (scratchBefore[index] ?? 0)
                reencodedInputBytes += model.folders[index].size
                reencodedPackBytes += reencoded[index]!.scratch.length
                reencodeScratchWrittenBytes += reencoded[index]!.scratch.length
            }
        }
        strategy = plan.unchanged ? .unchanged : converted ? .reencrypted : reencodedAny ? .reencoded
            : shifted ? .compacted : hasAdditions ? .appendOnly : .headerOnly
        if shared == .relocatedAppend { strategy = .relocatedAppend }
        else if shared == .sequential { strategy = .sequential }
    }
}
