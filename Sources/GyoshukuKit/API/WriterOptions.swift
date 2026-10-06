import Foundation

/// ZIP の圧縮方式。
public enum CompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflate = 8
    /// system libbz2 による単一 bzip2 stream。展開には method 12 対応の reader が必要。
    case bzip2 = 12
    /// 自前 encoder の単一 raw LZMA1 stream。EOS を付け、展開には method 14 対応の reader が必要。
    case lzma = 14
    /// 完全な XZ stream。レベル未指定は Apple Compression、指定時は自前 LZMA2。
    case xz = 95
    /// 自前 encoder の単一 PPMd var.I rev.1 stream。展開には method 98 対応の reader が必要。
    case ppmd = 98
}

/// 7z の非空 folder に使う圧縮方式。既定は LZMA2。
public enum SevenZipCompressionMethod: Sendable {
    /// LZMA2。レベル未指定は Apple Compression、指定時は自前 encoder。
    case lzma2
    /// 自前 encoder の単一 raw LZMA1 stream。folder のサイズが既知なので EOS は付けない。
    case lzma
    /// system zlib の raw deflate。deflateLevel (0...9) を使う。
    case deflate
    /// system libbz2 の単一 stream。bzip2Level (1...9) を使う。
    case bzip2
    /// 自前 encoder の単一 PPMd var.H stream。ppmdLevel と order / memory の上書きを使う。
    case ppmd
    /// 入力 byte をそのまま保存する無圧縮方式。
    case copy
}

/// 7z の新規 folder のまとめ方。空ファイルと directory は block に数えない。
public enum SevenZipSolidMode: Sendable, Equatable {
    case off
    /// 入力順。nil のサイズは min(4 GiB, max(64 MiB, 辞書または PPMd model memory × 2))、件数は1,000,000。
    /// ファイルは分割せず、上限より大きいファイルは単独の folder にする。
    case on(blockSize: UInt64? = nil, filesPerBlock: Int? = nil)
}

/// 圧縮前に適用する 7z filter。状態は同じ solid folder のファイル境界を越えて続く。
public enum SevenZipFilterMode: Sendable, Equatable {
    case none
    /// PE / 単一 Mach-O の x86・x86_64 は BCJ、PE / Mach-O / ELF の arm64 は ARM64。
    /// universal Mach-O と未判定の入力は none。solid は種別が変わるたびに block を区切る。
    case auto
    case bcjX86
    case arm64
    /// 元 byte の距離1〜256の差分を取る。範囲外は invalidOption("sevenZipFilter")。
    case delta(distance: Int)
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
    /// 7z の新規作成・追加・rewriter の solid 設定。既定は従来と同じ .off。
    public var sevenZipSolid: SevenZipSolidMode
    /// 新規 folder の filter。既存 folder の一部削除では元の filter を保持する。
    public var sevenZipFilter: SevenZipFilterMode
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
    /// PPMd の order / model memory preset (1...9)。既定の6は ZIP が order 8、7z が order 6、共に16 MiB。
    /// model memory は順に1・2・4・8・16・16・32・64・192 MiB。entry / folder ごとに同期符号化する。
    public var ppmdLevel: Int
    /// preset の order を上書きする。ZIP var.I は2...16、7z var.H は2...32。nil は preset。
    public var ppmdOrder: Int?
    /// preset の model memory を MiB 単位で上書きする。ZIP は1...256、7z は1...1024。nil は preset。
    /// 一つの entry / solid folder につき一つのモデルを確保し、memoryLimit や並列数による縮小は行わない。
    public var ppmdMemoryMiB: Int?
    /// tar.xz / 単独 XZ / 7z LZMA2 / ZIP XZ のレベル (0...9)。nil は従来の Apple preset-6 経路。
    /// ZIP LZMA / 7z LZMA / tar.lzma / tar.lz / 単独 LZMA・lzip は常に自前 encoder を使い、nil はレベル6。
    public var lzmaLevel: Int?
    /// 自前 LZMA の探索量を増やす。既定は false。tar.lzma / tar.lz / 単独 LZMA・lzip は nil でも使う。
    /// 他の形式は lzmaLevel を指定したときだけ使う。
    public var lzmaExtreme: Bool
    /// 自前 LZMA の圧縮作業メモリ上限（byte）。nil は物理メモリの50%。
    /// 物理メモリの50%との小さい方で並列数を抑える。一つも入らなければ invalidOption("memoryLimit")。
    /// 辞書を上限に合わせて縮小しない。レベル未指定の Apple 経路と他の codec には適用しない。
    public var memoryLimit: UInt64?
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
    /// ZIP deflate（ZipCrypto を除く）/ ZIP XZ / tar.gz / tar.bz2 / tar.lz / tar.lz4 / 7z LZMA2・Deflate / tar.xz / LHA の圧縮並列数（1...64）。
    /// 単独 gzip / bzip2 / XZ / lzip / LZ4 も同じ設定。LZMA_Alone / Brotli / compress は逐次。
    /// ZIP / 7z LZMA・bzip2・PPMd と 7z Copy は項目ごとに同期処理する。
    /// PPMd は入力を片に分けず、モデルの指定メモリと固定 I/O buffer を使う。
    /// ZIP updater の再暗号化では鍵導出の並列数にも使う。
    /// nil は CPU 数・物理メモリ GiB・8 の最小値（最低1）。未出力 chunk は最大でこの数
    /// （Apple 経路の tar.xz は2以上のとき64 KiB以下を数えず、合計2 × この数 + 1まで）。
    /// deflate / tar.bz2 は thread ごとに約2 × chunk size + codec state、Apple LZMA2 は約130 MiB。
    /// 自前 LZMA2 の辞書が16 MiBを超えると片は3 × 辞書。実際の並列数は
    /// t × (encoder memory + 2 × 片) <= min(memoryLimit, 物理メモリの50%) に制限する。
    /// 自前経路は小さい block も並列数に数える。Apple 経路の片は常に16 MiB。
    /// chunk 上限は deflate が1 MiB、tar.bz2 が5 × level × 100,000 byte。tar.xz の packing は4 MiB。
    /// gzip / bzip2 / XZ / lzip の圧縮 tar は member 境界で区切り、上限を超える header 群・本文を分割し、終端を独立させる。
    /// tar.bz2 level 9 は入力・出力約9 MB + codec state約7.6 MBで、thread ごとに約16.6 MB。
    /// lzip は片が max(16 MiB, 3 × 辞書)、raw LZMA1 と入力・出力二片をメモリ予算に含む。
    /// LZ4 は組立中を含め t 個の4 MiB block。Brotli は Apple 固定 level 2、LZ4 は単一 level。
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
        sevenZipSolid: SevenZipSolidMode = .off,
        sevenZipFilter: SevenZipFilterMode = .none,
        lhaMethod: LHACompressionMethod = .lh5,
        lhaLevel: Int = 6,
        deflateLevel: Int = 6,
        bzip2Level: Int = 9,
        ppmdLevel: Int = 6,
        ppmdOrder: Int? = nil,
        ppmdMemoryMiB: Int? = nil,
        lzmaLevel: Int? = nil,
        lzmaExtreme: Bool = false,
        memoryLimit: UInt64? = nil,
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
        self.sevenZipSolid = sevenZipSolid
        self.sevenZipFilter = sevenZipFilter
        self.lhaMethod = lhaMethod
        self.lhaLevel = lhaLevel
        self.deflateLevel = deflateLevel
        self.bzip2Level = bzip2Level
        self.ppmdLevel = ppmdLevel
        self.ppmdOrder = ppmdOrder
        self.ppmdMemoryMiB = ppmdMemoryMiB
        self.lzmaLevel = lzmaLevel
        self.lzmaExtreme = lzmaExtreme
        self.memoryLimit = memoryLimit
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
    /// tar.xz は通常枠と4 MiBの組立中 block を含み、Apple 経路だけ64 KiB以下の軽い block を別枠にする。
    /// ZIP / 7z LZMA・bzip2・PPMd と 7z Copy は同期処理なので 0。bzip2 の codec state は最大約7.6 MBと I/O buffer。
    /// PPMd のモデルは ppmdMemoryMiB または preset のメモリを entry / folder ごとに使い、この入力 byte には含まない。
    /// t は解決した並列数。7z Deflate は t 個の1 MiB block、LZMA2 は t 個の片を上界にする。
    /// ZIP XZ は通常枠 t 個と組立中1個の片を上界とし、項目の終了時には全て出力する。
    /// LHA は t 個の1 MiB入力と方式ごとの履歴を含む。逐次と forced store は0。
    /// codec state・出力と block 数に比例する XZ index はこの入力 byte に含まない。
    /// 7z solid は disk 上で待つ一つの block の上限。圧縮メモリの大きさとは独立する。
    public func maximumPendingInputBytes(for format: ArchiveFormat) -> UInt64 {
        let lzma = try? LZMAWriterConfiguration(options: self)
        let lzmaThreads = UInt64(max(1, min(64, lzma?.threads ?? 1)))
        let piece = UInt64(lzma?.pieceSize ?? ParallelXZCompressor.defaultBlockSize)
        let threads = UInt64(max(1, min(64, resolvedCompressionThreads)))
        switch format {
        case .zip:
            switch compressionMethod {
            case .stored, .bzip2, .lzma, .ppmd: return 0
            case .deflate:
                return password != nil && zipEncryption == .zipCrypto ? 0 : threads * UInt64(DeflateBlock.size)
            case .xz: return (lzmaThreads + 1) * piece
            }
        case .tar: return 0
        case .tarLZMA, .tarBrotli, .tarCompress: return 0
        case .tarLZ4: return threads * UInt64(LZ4FrameEncoder.blockSize)
        case .tarLzip:
            let configuration = try? LZMAWriterConfiguration.singleStream(options: self, lzip: true)
            let resolved = UInt64(max(1, min(64, configuration?.threads ?? 1)))
            return resolved * UInt64(configuration?.pieceSize ?? (16 << 20))
        case .tarGzip: return (threads + 1) * UInt64(DeflateBlock.size)
        case .tarBzip2: return (threads + 1) * UInt64(ParallelBzip2Compressor.chunkSize(level: max(1, min(9, bzip2Level))))
        case .tarXZ:
            // 未出力は通常枠 t 個、合計 2t + 1 個以下。member の終了時の組立中は packing 以下。
            let light = lzmaLevel == nil && lzmaThreads > 1 ? (lzmaThreads + 1) * UInt64(ParallelXZCompressor.lightChunkLimit) : 0
            return lzmaThreads * piece + light + UInt64(ParallelXZCompressor.memberPackingSize)
        case .sevenZip:
            // solid の未圧縮入力は disk 上の spool。最大一つの block を finishAdditions で出力する。
            if case .on = sevenZipSolid { return resolvedSevenZipBlockSize }
            switch sevenZipMethod {
            case .lzma2: return lzmaThreads * piece
            case .deflate: return threads * UInt64(DeflateBlock.size)
            case .lzma, .bzip2, .ppmd, .copy: return 0
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
        guard (1...9).contains(ppmdLevel) else { throw WriterError.invalidOption("ppmdLevel") }
        if let ppmdOrder, !(2...(format == .zip ? 16 : 32)).contains(ppmdOrder) {
            throw WriterError.invalidOption("ppmdOrder")
        }
        if let ppmdMemoryMiB, !(1...(format == .zip ? 256 : 1024)).contains(ppmdMemoryMiB) {
            throw WriterError.invalidOption("ppmdMemoryMiB")
        }
        guard (1...9).contains(lhaLevel) else { throw WriterError.invalidOption("lhaLevel") }
        if case let .on(blockSize, filesPerBlock) = sevenZipSolid {
            if blockSize == 0 || filesPerBlock.map({ $0 <= 0 }) == true {
                throw WriterError.invalidOption("sevenZipSolid")
            }
        }
        if case let .delta(distance) = sevenZipFilter, !(1...256).contains(distance) {
            throw WriterError.invalidOption("sevenZipFilter")
        }
        if let lzmaLevel, !(0...9).contains(lzmaLevel) { throw WriterError.invalidOption("lzmaLevel") }
        if let memoryLimit, memoryLimit == 0 { throw WriterError.invalidOption("memoryLimit") }
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
        switch format {
        case .tarXZ: _ = try LZMAWriterConfiguration(options: self)
        case .tarLZMA: _ = try LZMAWriterConfiguration.singleStream(options: self)
        case .tarLzip: _ = try LZMAWriterConfiguration.singleStream(options: self, lzip: true)
        case .zip where compressionMethod == .xz || compressionMethod == .lzma:
            _ = try LZMAWriterConfiguration(options: self, raw: compressionMethod == .lzma)
        case .sevenZip where sevenZipMethod == .lzma2 || sevenZipMethod == .lzma:
            _ = try LZMAWriterConfiguration(options: self, raw: sevenZipMethod == .lzma)
        default: break
        }
    }

    var resolvedSevenZipBlockSize: UInt64 {
        if case let .on(size?, _) = sevenZipSolid { return size }
        let dictionary = sevenZipMethod == .ppmd ? UInt64((try? ppmd7Properties().memorySize) ?? (16 << 20))
            : sevenZipMethod == .lzma || (sevenZipMethod == .lzma2 && lzmaLevel != nil)
            ? UInt64(LZMAEncoderProperties.preset(lzmaLevel ?? 6).dictSize) : 8 << 20
        return min(4 << 30, max(64 << 20, dictionary * 2))
    }

    func ppmd7Properties() throws -> PPMd7EncoderProperties {
        let preset = try PPMd7EncoderProperties.preset(ppmdLevel)
        if let ppmdMemoryMiB, !(1...1024).contains(ppmdMemoryMiB) {
            throw WriterError.invalidOption("ppmdMemoryMiB")
        }
        return try .init(order: ppmdOrder ?? preset.order, memorySize: ppmdMemoryMiB.map { $0 << 20 } ?? preset.memorySize)
    }

    func ppmd8Properties() throws -> PPMd8EncoderProperties {
        let preset = try PPMd8EncoderProperties.preset(ppmdLevel)
        if let ppmdMemoryMiB, !(1...256).contains(ppmdMemoryMiB) {
            throw WriterError.invalidOption("ppmdMemoryMiB")
        }
        return try .init(order: ppmdOrder ?? preset.order, memorySize: ppmdMemoryMiB.map { $0 << 20 } ?? preset.memorySize)
    }
}
