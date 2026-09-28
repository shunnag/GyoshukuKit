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
