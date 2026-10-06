import Foundation

/// ZIP の圧縮方式。
public enum CompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflate = 8
    /// system libbz2 による単一 bzip2 stream。展開には method 12 対応の reader が必要。
    case bzip2 = 12
    /// Apple Compression による完全な XZ stream。展開には method 95 対応の reader が必要。
    case xz = 95
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
    /// ZIP deflate（ZipCrypto を除く）/ ZIP XZ / tar.gz / tar.bz2 / 7z / tar.xz / LHA の圧縮並列数（1...64）。
    /// ZIP bzip2 は項目ごとに同期処理する。ZIP XZ は最大16 MiBの block を使う。
    /// ZIP updater の再暗号化では鍵導出の並列数にも使う。
    /// nil は CPU 数・物理メモリ GiB・8 の最小値（最低1）。未出力 chunk は最大でこの数
    /// （tar.xz は2以上のとき64 KiB以下の block を数えず、合計2 × この数 + 1まで）。
    /// deflate / tar.bz2 は thread ごとに約2 × chunk size + codec state、LZMA2 は約130 MiB（16 MiB の片）。
    /// chunk 上限は deflate が1 MiB、tar.bz2 が5 × level × 100,000 byte、tar.xz が詰める block 4 MiB・片16 MiB（ZIP XZ / 7z は片のみ）。
    /// 圧縮 tar は member 境界で区切り、上限を超える header 群・本文はそれぞれ分割する。終端は独立させる。
    /// tar.bz2 level 9 は入力・出力約9 MB + codec state約7.6 MBで、thread ごとに約16.6 MB。
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

    /// 検証済み options の writer / updater が finishAdditions で報告する入力 byte の上界。
    /// tar.xz は 16 MiB の通常枠、64 KiB 以下の軽い block と、4 MiB の組立中 block を含む。
    /// ZIP bzip2 は同期処理なので 0。codec state は最大約7.6 MBと I/O buffer で、入力長に依存しない。
    /// ZIP XZ は通常枠 t 個と組立中1個の16 MiB block を上界とし、項目の終了時には全て出力する。
    /// XZ の codec state・出力（thread ごとに約130 MiB）と block 数に比例する index はこの入力 byte に含まない。
    public func maximumPendingInputBytes(for format: ArchiveFormat) -> UInt64 {
        let threads = UInt64(max(1, min(64, resolvedCompressionThreads)))
        switch format {
        case .zip:
            switch compressionMethod {
            case .stored, .bzip2: return 0
            case .deflate:
                return password != nil && zipEncryption == .zipCrypto ? 0 : threads * UInt64(DeflateBlock.size)
            case .xz: return (threads + 1) * UInt64(ParallelXZCompressor.defaultBlockSize)
            }
        case .tar: return 0
        case .tarGzip: return (threads + 1) * UInt64(DeflateBlock.size)
        case .tarBzip2: return (threads + 1) * UInt64(ParallelBzip2Compressor.chunkSize(level: max(1, min(9, bzip2Level))))
        case .tarXZ:
            // 未出力は通常枠 t 個、合計 2t + 1 個以下。member の終了時の組立中は packing 以下。
            let light = threads > 1 ? (threads + 1) * UInt64(ParallelXZCompressor.lightChunkLimit) : 0
            return threads * UInt64(ParallelXZCompressor.defaultBlockSize) + light + UInt64(ParallelXZCompressor.memberPackingSize)
        case .sevenZip: return threads * UInt64(LZMA2ChunkPipeline<Void>.chunkSize)
        case .lha: return threads == 1 ? 0 : threads * UInt64(LHAWriter.compressionChunkSize)
        }
    }

    // writer / updater / rewriter は出力や作業ファイルを作る前に同じ規則で検証する。
    func validate(for format: ArchiveFormat) throws {
        // ZIP bzip2 は同期、XZ は有界の block 並列なので、AES / ZipCrypto と全ての並列数を併用できる。
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
