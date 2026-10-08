import Foundation

// CompressedTarUpdater の assess / commit が返す公開の結果と、@_spi(Testing) の統計。
public enum CompressedTarFullEncodeReason: Sendable, Equatable {
    case framing(String)
    case noReusableChunk
}

public enum CompressedTarStrategy: Sendable, Equatable {
    case unchanged
    case splice(carriedChunks: Int, reencodedChunks: Int)
    case fullEncode(CompressedTarFullEncodeReason)
}

public struct CompressedTarAssessment: Sendable, Equatable {
    public let format: ArchiveFormat
    public let framingReusable: Bool
    public let hasInteriorBoundaries: Bool
    public let imageLength: UInt64
    public let reason: CompressedTarFullEncodeReason?
    public var nextEditReencodesEverything: Bool {
        !framingReusable || (!hasInteriorBoundaries && imageLength > UInt64(CompressedTarSplicePlan.limits(format, options: WriterOptions(compressionThreads: 1)).piece))
    }
}

public enum CompressedTarOutputSegment: Sendable, Equatable {
    case reused(output: Range<UInt64>, base: Range<UInt64>)
    case encoded(output: Range<UInt64>)
}

public struct CompressedTarCommitResult: Sendable {
    public struct OutputIdentity: Sendable, Equatable {
        public let device: UInt64, inode: UInt64, size: UInt64
        public let modificationSeconds: Int64, modificationNanoseconds: Int64
    }
    public let strategy: CompressedTarStrategy
    public let output: OutputIdentity
    public let segments: [CompressedTarOutputSegment]
    public let reencodedImageBytes: UInt64, reencodedOldImageBytes: UInt64, carriedCompressedBytes: UInt64
}

@_spi(Testing) public struct CompressedTarCommitStatistics: Sendable {
    public let planningSeconds: Double, encodingSeconds: Double, copyingSeconds: Double, selfCheckSeconds: Double
    public let reencodedImageBytes: UInt64, reencodedOldImageBytes: UInt64, carriedCompressedBytes: UInt64
    public let carriedChunks: Int, reencodedChunks: Int, scratchBytes: UInt64
    public let strategy: CompressedTarStrategy
}
