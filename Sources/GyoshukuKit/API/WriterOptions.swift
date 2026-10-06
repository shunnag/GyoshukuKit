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

/// 7z の非空 folder に使う圧縮方式。既定は LZMA2。
public enum SevenZipCompressionMethod: Sendable {
    /// Apple Compression の LZMA2。最大16 MiBの片と dictionary property を使う。
    case lzma2
    /// system zlib の raw deflate。deflateLevel (0...9) を使う。
    case deflate
    /// system libbz2 の単一 stream。bzip2Level (1...9) を使う。
    case bzip2
    /// 入力 byte をそのまま保存する無圧縮方式。
    case copy
}

/// LHA の新規 member に使う圧縮方式。ディレクトリは常に -lhd-。
public enum LHACompressionMethod: Sendable {
    /// 8 KiB 辞書の static Huffman。既定の方式。
    case lh5
    /// 32 KiB 辞書の static Huffman。
    case lh6
    /// 64 KiB 辞書の static Huffman。
    case lh7
    /// 圧縮を試さず、全ファイルを -lh0- で保存する。
    case stored

    var dictionaryBits: Int {
        switch self {
        case .lh5: 13
        case .lh6: 15
        case .lh7: 16
        case .stored: 0
        }
    }
    var windowSize: Int { self == .stored ? 0 : 1 << dictionaryBits }
    var headerMethod: String {
        switch self {
        case .lh5: LHARecords.Method.lh5
        case .lh6: LHARecords.Method.lh6
        case .lh7: LHARecords.Method.lh7
        case .stored: LHARecords.Method.lh0
        }
    }
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
    /// ZIP の member に使う圧縮方式。tar.gz は全体を deflate にする。
    public var compressionMethod: CompressionMethod
    /// 7z の新規 folder と updater が再圧縮する folder の方式。既定は LZMA2。
    /// rewriter の 7z 出力にも適用する。updater が運ぶ既存 folder の coder は保持する。
    public var sevenZipMethod: SevenZipCompressionMethod
    /// LHA の追加と LHA への rewriter に使う方式。既定は .lh5。縮まなければ -lh0-。
    /// updater が運ぶ既存 member の圧縮 byte と method は保持する。
    public var lhaMethod: LHACompressionMethod
    /// LHA の探索 level (1...9)。候補数は順に8・16・32・64・128・256・512・1024・2048。
    /// 最大一致長は全 level で256。8・9だけ次の1 byteの一致も調べる lazy matching を使う。
    /// 既定の6は従来の LH5 と同じ256候補・貪欲探索で、出力 byte を維持する。stored では使わない。
    public var lhaLevel: Int
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
    /// ZIP deflate（ZipCrypto を除く）/ ZIP XZ / tar.gz / tar.bz2 / 7z LZMA2・Deflate / tar.xz / LHA の圧縮並列数（1...64）。
    /// ZIP / 7z bzip2 と 7z Copy は項目ごとに同期処理する。ZIP XZ は最大16 MiBの block を使う。
    /// ZIP updater の再暗号化では鍵導出の並列数にも使う。
    /// nil は CPU 数・物理メモリ GiB・8 の最小値（最低1）。未出力 chunk は最大でこの数
    /// （tar.xz は2以上のとき64 KiB以下の block を数えず、合計2 × この数 + 1まで）。
    /// deflate / tar.bz2 は thread ごとに約2 × chunk size + codec state、LZMA2 は約130 MiB（16 MiB の片）。
    /// chunk 上限は deflate が1 MiB、tar.bz2 が5 × level × 100,000 byte、tar.xz が詰める block 4 MiB・片16 MiB（ZIP XZ / 7z は片のみ）。
    /// 圧縮 tar は member 境界で区切り、上限を超える header 群・本文はそれぞれ分割する。終端は独立させる。
    /// tar.bz2 level 9 は入力・出力約9 MB + codec state約7.6 MBで、thread ごとに約16.6 MB。
    /// LHA は thread ごとに入力1 MiB + 履歴8/32/64 KiB、hash 表512 KiB、chain 表64/256/512 KiB、
    /// command 表512 KiBと圧縮出力約1.1 MiB（64-bit Int）。stored は同期で codec 表を持たない。
    /// 1 は同期、2以上は出力が後続の add / finish まで遅れ得る。
    public var compressionThreads: Int?
    /// rewriter の追加位置。updater は末尾への追加を使う。
    public var additionPlacement: AdditionPlacement
    /// 運ぶ tar の uid/gid。ディスクからの追加には preserveOwnerIDs を使う。
    public var carriedTarOwnerIDs: CarriedOwnerIDs

    public init(
        compressionMethod: CompressionMethod = .deflate,
        sevenZipMethod: SevenZipCompressionMethod = .lzma2,
        lhaMethod: LHACompressionMethod = .lh5,
        lhaLevel: Int = 6,
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
        self.sevenZipMethod = sevenZipMethod
        self.lhaMethod = lhaMethod
        self.lhaLevel = lhaLevel
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
    /// ZIP / 7z bzip2 と 7z Copy は同期処理なので 0。bzip2 の codec state は最大約7.6 MBと I/O buffer。
    /// 7z Deflate は t 個の1 MiB block、LZMA2 は t 個の16 MiBの片を上界にする。
    /// ZIP XZ は通常枠 t 個と組立中1個の16 MiB block を上界とし、項目の終了時には全て出力する。
    /// LHA は t 個の1 MiB入力と方式ごとの履歴を含む。逐次と forced store は0。
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
        case .sevenZip:
            switch sevenZipMethod {
            case .lzma2: return threads * UInt64(LZMA2ChunkPipeline<Void>.chunkSize)
            case .deflate: return threads * UInt64(DeflateBlock.size)
            case .bzip2, .copy: return 0
            }
        case .lha:
            return threads == 1 || lhaMethod == .stored ? 0
                : threads * UInt64(LHAWriter.compressionChunkSize + lhaMethod.windowSize)
        }
    }

    // writer / updater / rewriter は出力や作業ファイルを作る前に同じ規則で検証する。
    func validate(for format: ArchiveFormat) throws {
        // ZIP bzip2 は同期、XZ は有界の block 並列なので、AES / ZipCrypto と全ての並列数を併用できる。
        guard (0...9).contains(deflateLevel) else { throw WriterError.invalidOption("deflateLevel") }
        guard (1...9).contains(bzip2Level) else { throw WriterError.invalidOption("bzip2Level") }
        guard (1...9).contains(lhaLevel) else { throw WriterError.invalidOption("lhaLevel") }
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
