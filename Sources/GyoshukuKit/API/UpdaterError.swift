import Foundation

/// 読み取り可能でも、安全な編集の条件を満たさない書庫を区別する。
public enum UpdateGatekeeper: String, Sendable {
    case sfxPrefix
    case trailingData
    case centralDirectoryOffset
    case ambiguousEndRecord

    public var reason: String {
        switch self {
        case .sfxPrefix: "SFX prefix があるため ZIP の offset 基準を保証できません"
        case .trailingData: "EOCD の後ろに trailing data があります"
        case .centralDirectoryOffset: "EOCD.cdOffset が PK\\x01\\x02 を指しません。ZIP64 なしの offset 切り詰めなどが疑われます"
        case .ambiguousEndRecord: "複数の EOCD 候補、または comment 内の EOCD があるため終端構造が曖昧です"
        }
    }
}

public enum UpdaterError: Error, Sendable, Equatable {
    case editingRefused(gatekeeper: UpdateGatekeeper, reason: String)
    case invalidArchive(String)
    case invalidEntryIndex(Int)
    case nonRelocatableEntry(index: Int, name: String, reason: String)
    case reencryptionFailed(index: Int, name: String, reason: String)
    case sourceChanged
    case invalidState
}
