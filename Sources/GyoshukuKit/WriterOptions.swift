import Foundation

/// 作成できる書庫形式。ZIP / ZIP64 の追加・削除・改名は ArchiveUpdater が扱う。
public enum ArchiveFormat: Sendable {
    case zip
    /// 非圧縮の restricted pax tar。
    case tar
    /// restricted pax tar 全体を gzip で包む。
    /// gzip header は時刻 0、OS=Unix、ファイル名・comment なし。
    /// member 境界で最大 1 MiB に区切り、大きい member は header 群と本文を分ける。終端は独立させる。
    case tarGzip
    /// restricted pax tar を member 境界で最大 5 × level × 100,000 byte の bzip2 stream に区切る。
    /// 大きい member は header 群と本文を分け、tar 終端は独立した stream にする。
    case tarBzip2
    /// restricted pax tar を member 境界で最大 16 MiB の LZMA2 block に区切り、単一 XZ stream で包む。
    /// 大きい member は header 群と本文を分け、tar 終端は独立した block にする。
    case tarXZ
    /// ファイルごとに Apple LZMA2 を使う non-solid 7z。AES-256 と header 暗号化を選択できる。
    case sevenZip
    /// CP932 名の level-2 LHA。各ファイルは -lh5-、縮まなければ -lh0-。
    /// 1 MiB 以下は member ごと、それ以上は 1 MiB と 8 KiB の履歴で並列に符号化する。出力は並列数によらず同一。
    case lha

    var isTar: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXZ: true
        default: false
        }
    }
}

/// ZIP の圧縮方式。
public enum CompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflate = 8
}

/// ZIP のパスワード暗号化方式。
public enum ZipEncryption: Sendable {
    case aes256
    case zipCrypto
}

/// rewriter が既存項目に対して追加を置く位置。
public enum AdditionPlacement: Sendable, Equatable { case end, beginning }

/// 既存 tar 項目を rewriter で運ぶ際の所有者 ID。
public enum CarriedOwnerIDs: Sendable, Equatable { case keep, reset }

/// instance 間で共有できる書き込み設定。
public struct WriterOptions: Sendable {
    /// ZIP の member に使う圧縮方式。tar.gz は全体を deflate、7z は LZMA2、LHA は LH5 にする。
    public var compressionMethod: CompressionMethod
    /// zlib の level (0...9)。既定は Info-ZIP と同じ 6。
    public var deflateLevel: Int
    /// bzip2 の block size level (1...9)。既定は9（900,000 byte block）。
    public var bzip2Level: Int
    /// ZIP で既知の圧縮済み拡張子は stored にする。false なら指定方式を使う。
    /// 空ファイル、ディレクトリ、symlink は常に stored。
    public var useCompressionHeuristic: Bool
    /// ディスク由来の uid/gid を保存する。ZIP は Info-ZIP 0x7875、tar は数値欄を使う。
    /// 既定の ZIP は省略、tar は 0。tar の uname / gname は常に空。7z / LHA は true を拒否する。
    public var preserveOwnerIDs: Bool
    /// この段階では true を指定すると unsupportedOption を返す。
    public var preserveMacOSMetadata: Bool
    /// nil は非暗号。ZIP は UTF-8、7z は UTF-16LE のパスワードを使う。空文字列は拒否する。
    public var password: String?
    /// パスワード指定時の ZIP 暗号化方式。通常ファイルだけに適用する。
    public var zipEncryption: ZipEncryption
    /// 7z の header（ファイル名を含む）も暗号化する。パスワードが必要。
    public var encryptsSevenZipHeaders: Bool
    /// ZIP deflate（ZipCrypto を除く）/ tar.gz / tar.bz2 / 7z / tar.xz / LHA の圧縮並列数（1...64）。
    /// ZIP updater の再暗号化では鍵導出の並列数にも使う。
    /// nil は CPU 数・物理メモリ GiB・8 の最小値（最低1）。未出力 chunk は最大でこの数。
    /// deflate / bzip2 は thread ごとに約2 × chunk size + codec state、LZMA2 は約130 MiB。
    /// chunk 上限は deflate が1 MiB、bzip2 が5 × level × 100,000 byte、LZMA2 が16 MiB。
    /// 圧縮 tar は member 境界で区切り、上限を超える header 群・本文はそれぞれ分割する。終端は独立させる。
    /// bzip2 level 9 は入力・出力約9 MB + codec state約7.6 MBで、thread ごとに約16.6 MB。
    /// LHA は thread ごとに入力1 MiB + 履歴8 KiB + 出力と表約1.1 MiB。1 は同期、2以上は出力が後続の add / finish まで遅れ得る。
    public var compressionThreads: Int?
    /// rewriter の追加位置。updater は末尾への追加を使う。
    public var additionPlacement: AdditionPlacement
    /// 運ぶ tar の uid/gid。ディスクからの追加には preserveOwnerIDs を使う。
    public var carriedTarOwnerIDs: CarriedOwnerIDs

    public init(
        compressionMethod: CompressionMethod = .deflate,
        deflateLevel: Int = 6,
        bzip2Level: Int = 9,
        useCompressionHeuristic: Bool = true,
        preserveOwnerIDs: Bool = false,
        preserveMacOSMetadata: Bool = false,
        password: String? = nil,
        zipEncryption: ZipEncryption = .aes256,
        encryptsSevenZipHeaders: Bool = false,
        compressionThreads: Int? = nil,
        additionPlacement: AdditionPlacement = .end,
        carriedTarOwnerIDs: CarriedOwnerIDs = .keep
    ) {
        self.compressionMethod = compressionMethod
        self.deflateLevel = deflateLevel
        self.bzip2Level = bzip2Level
        self.useCompressionHeuristic = useCompressionHeuristic
        self.preserveOwnerIDs = preserveOwnerIDs
        self.preserveMacOSMetadata = preserveMacOSMetadata
        self.password = password
        self.zipEncryption = zipEncryption
        self.encryptsSevenZipHeaders = encryptsSevenZipHeaders
        self.compressionThreads = compressionThreads
        self.additionPlacement = additionPlacement
        self.carriedTarOwnerIDs = carriedTarOwnerIDs
    }

    var resolvedCompressionThreads: Int {
        compressionThreads ?? max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8,
                                        Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))))
    }

    // writer / updater / rewriter は出力や作業ファイルを作る前に同じ規則で検証する。
    func validate(for format: ArchiveFormat) throws {
        guard (0...9).contains(deflateLevel) else { throw WriterError.invalidOption("deflateLevel") }
        guard (1...9).contains(bzip2Level) else { throw WriterError.invalidOption("bzip2Level") }
        if let compressionThreads, !(1...64).contains(compressionThreads) {
            throw WriterError.invalidOption("compressionThreads")
        }
        guard !preserveMacOSMetadata else { throw WriterError.unsupportedOption("preserveMacOSMetadata") }
        if format == .sevenZip || format == .lha, preserveOwnerIDs {
            throw WriterError.unsupportedOption("preserveOwnerIDs")
        }
        if let password {
            guard !password.isEmpty else { throw WriterError.invalidOption("password") }
            guard format == .zip || format == .sevenZip else { throw WriterError.unsupportedOption("password") }
        }
        if encryptsSevenZipHeaders, password == nil {
            throw WriterError.invalidOption("encryptsSevenZipHeaders")
        }
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
