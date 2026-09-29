import Foundation

// 出力の計画。形式側（tar / 7z / LHA の updater）が組み立て、SegmentedArchiveOutput が実行して照合する。
enum OutputSegment {
    case source(Range<UInt64>)
    case literal(length: UInt64, bytes: () throws -> Data)
    case generated(length: UInt64, write: (SegmentSink) throws -> Void)
    case scratch(ScratchFile, Range<UInt64>)

    var length: UInt64 {
        switch self {
        case .source(let range): range.byteLength
        case .scratch(_, let range): range.byteLength
        case .literal(let length, _), .generated(let length, _): length
        }
    }
}

struct SegmentCommitPlan {
    var prefix: [OutputSegment]
    var appended: Range<UInt64>?
    var terminal: Data
    var finalLength: UInt64
    var finalPatch: (offset: UInt64, bytes: Data)? = nil
    var formatVerificationUnits: UInt64
}

enum SegmentCommitStrategy { case unchanged, inPlacePatch, appendOnly, splice, sequential, relocatedAppend }
