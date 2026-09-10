import Foundation

/// 作成できる書庫形式。ZIP / ZIP64 の追加・削除・改名は ArchiveUpdater が扱う。
public enum ArchiveFormat: Sendable {
    case zip
    /// 非圧縮の restricted pax tar。
    case tar
    /// restricted pax tar 全体を gzip で包む。
    /// gzip header は時刻 0、OS=Unix、ファイル名・comment なし。
    case tarGzip
}

/// ZIP の圧縮方式。
public enum CompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflate = 8
}

/// instance 間で共有できる書き込み設定。
public struct WriterOptions: Sendable {
    /// ZIP の member に使う圧縮方式。tar.gz は常に書庫全体を deflate する。
    public var compressionMethod: CompressionMethod
    /// zlib の level (0...9)。既定は Info-ZIP と同じ 6。
    public var deflateLevel: Int
    /// ZIP で既知の圧縮済み拡張子は stored にする。false なら指定方式を使う。
    /// 空ファイル、ディレクトリ、symlink は常に stored。
    public var useCompressionHeuristic: Bool
    /// ディスク由来の uid/gid を保存する。ZIP は Info-ZIP 0x7875、tar は数値欄を使う。
    /// 既定の ZIP は省略、tar は 0。tar の uname / gname は常に空。
    public var preserveOwnerIDs: Bool
    /// この段階では true を指定すると unsupportedOption を返す。
    public var preserveMacOSMetadata: Bool

    public init(
        compressionMethod: CompressionMethod = .deflate,
        deflateLevel: Int = 6,
        useCompressionHeuristic: Bool = true,
        preserveOwnerIDs: Bool = false,
        preserveMacOSMetadata: Bool = false
    ) {
        self.compressionMethod = compressionMethod
        self.deflateLevel = deflateLevel
        self.useCompressionHeuristic = useCompressionHeuristic
        self.preserveOwnerIDs = preserveOwnerIDs
        self.preserveMacOSMetadata = preserveMacOSMetadata
    }
}

/// 書き込み失敗。失敗した writer は破棄する。ZIP の未完成出力は呼出側で削除する。
public enum WriterError: Error, Sendable, Equatable {
    case invalidOption(String)
    case unsupportedOption(String)
    case invalidPath(String)
    case duplicatePath(String)
    case unsupportedFileType(String)
    case sourceChanged(String)
    case invalidDate
    case invalidState
    case io(operation: String, code: Int32)
    case compression(Int32)
    case sizeOverflow
}
