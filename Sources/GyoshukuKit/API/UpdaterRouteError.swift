/// updater の経路選択と、計画した出力の照合失敗を区別する。
public enum UpdaterRouteError: Error, Sendable, Equatable {
    /// open でだけ返す。原本・出力・一時ファイルを残さず ArchiveRewriter へ戻す。
    case requiresRewrite(reason: String)
    /// commit の読み戻しが計画と一致しない。失敗した出力は削除する。
    case outputVerificationFailed(reason: String)
}

/// 既存の tar updater の呼出しと catch の source 互換性を保つ。
public typealias TarUpdaterError = UpdaterRouteError
