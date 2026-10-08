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
    /// 自前 encoder の content checksum 付き単一 Zstandard frame。method 93 対応 reader が必要。
    /// macOS Archive Utility / unzip は非対応。抽出要求 version は6.3。
    case zstd = 93
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

/// 自動圧縮並列数に適用する電力方針。明示した compressionThreads には作用しない。
public enum CompressionPowerPolicy: Sendable, Hashable {
    /// Low Power Mode のときだけ並列数を減らす。
    case reduceInLowPowerMode
    /// Low Power Mode または serious / critical のとき並列数を減らす。
    case reduceInLowPowerModeOrThermalPressure
    /// 電力・温度による削減をしない。GiB と codec のメモリ制限は引き続き適用する。
    case alwaysUseAllCores
}

/// instance 間で共有できる書き込み設定。
public struct WriterOptions: Sendable {
    /// 明示的な圧縮並列数の受理範囲。codec のメモリ予算と項目窓の安全上限は別に適用する。
    public static let compressionThreadsRange = 1...1024
    @TaskLocal static var testingAutomaticThreads: (@Sendable (CompressionPowerPolicy) -> Int)?
    private var automaticThreadsSnapshot: Int?

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
    /// tar.zst / 単独 .zst / ZIP method 93 のレベル (1...19)。既定3、自前 encoder の探索 preset。
    public var zstdLevel: Int
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
    /// 自前 LZMA / Zstandard、ZIP / 7z BZip2の圧縮作業メモリ上限（byte）。nil は物理メモリの50%。
    /// 物理メモリの50%との小さい方で並列数を抑える。LZMA / Zstandardは一つも入らなければ invalidOption("memoryLimit")。
    /// 辞書を上限に合わせて縮小しない。Appleの既存block経路と上記以外のcodecには適用しない。
    /// 新規のLZMA/XZ項目・folder窓はAppleの見積りも含めこの予算で解決し、2枠未満なら従来経路へ戻す。
    /// Zstandard は encoder の見積りと入出力 buffer を数え、ZIP の逐次 frame も予算を検証する。
    /// ZIP / 7z BZip2はcodec・8 MiB capの入出力を予約して並列数を絞る。一枠未満は既存の逐次経路。
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
    /// ZIP / 圧縮tar / 7z / LHA の圧縮並列数（compressionThreadsRange: 1...1024）。
    /// tar.zst / 単独 Zstandard は max(4 MiB, level の window) の独立 frame を同じ並列数で処理する。
    /// 単独 gzip / bzip2 / XZ / lzip / LZ4 も同じ設定。LZMA_Alone / Brotli / compress は逐次。
    /// ZIP LZMA・XZ・Zstandard・PPMd と非solid 7z LZMA・PPMd は16 MiB以下の項目を並列化する。
    /// ZIP / 7z BZip2は約5 block分以下を項目間、それより大きい項目内はblockを並列化し単一streamへspliceする。
    /// 大項目と7z Copyは既存のstream経路。ZIP XZと7z LZMA2・Deflateは大項目内のblockも並列化する。
    /// 7z solid/filterはfolderごとのdisk spoolを並列圧縮する。非solidは16 MiB、solidはblock上限まで。
    /// LHAは1 MiB超〜16 MiBのmemberも項目間で並列化し、内部の1 MiB境界と履歴を保つ。
    /// PPMdは各entry/folderに独立した指定サイズのモデルを使う。モデルを片に分けない。
    /// ZIP updater の再暗号化では鍵導出の並列数にも使う。
    /// nil は有効 logical CPU 数と物理メモリ GiB の最小値（最低1）。powerPolicy に従い開始時に一度解決する。
    /// 項目 / folder 窓は GCD pool の安全上限とメモリ予算でさらに制限する。未出力 chunk は最大でこの数
    /// （Apple 経路の tar.xz は2以上のとき64 KiB以下を数えず、合計2 × この数 + 1まで）。
    /// deflate / tar.bz2 は thread ごとに約2 × chunk size + codec state、Apple LZMA2 は約130 MiB。
    /// 自前 LZMA2 の辞書が16 MiBを超えると片は3 × 辞書。実際の並列数は
    /// t × (encoder memory + 2 × 片) <= min(memoryLimit, 物理メモリの50%) に制限する。
    /// 自前経路は小さい block も並列数に数える。Apple 経路の片は常に16 MiB。
    /// chunk 上限は deflate が1 MiB、tar.bz2 が5 × level × 100,000 byte。tar.xz の packing は4 MiB。
    /// gzip / bzip2 / XZ / lzip の圧縮 tar は member 境界で区切り、上限を超える header 群・本文を分割し、終端を独立させる。
    /// tar.bz2 level 9 は入力・出力約9 MB + codec state約7.6 MBで、thread ごとに約16.6 MB。
    /// lzip は片が max(16 MiB, 3 × 辞書)、raw LZMA1 と入力・出力二片をメモリ予算に含む。
    /// Zstandard は組立中を含め t 個の frame。t × (encoder 見積り + 入出力二片 + framing) を予算内にする。
    /// LZ4 は組立中を含め t 個の4 MiB block。Brotli は Apple 固定 level 2、LZ4 は単一 level。
    /// LHA は thread ごとに入力1 MiB + 履歴8/32/64 KiB、hash 表512 KiB、chain 表64/256/512 KiB、
    /// command 表512 KiBと圧縮出力約1.1 MiB（64-bit Int）。stored は同期で codec 表を持たない。
    /// 1 は同期、2以上は出力が後続の add / finish まで遅れ得る。
    public var compressionThreads: Int?
    /// nil の compressionThreads にだけ適用する。既定は Low Power Mode で並列数を減らす。
    public var powerPolicy: CompressionPowerPolicy
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
        zstdLevel: Int = 3,
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
        powerPolicy: CompressionPowerPolicy = .reduceInLowPowerMode,
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
        self.zstdLevel = zstdLevel
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
        self.powerPolicy = powerPolicy
        self.additionPlacement = additionPlacement
        self.carriedTarOwnerIDs = carriedTarOwnerIDs
    }

    /// 現在の自動要求並列数。codec のメモリ制限と項目 / folder 窓の制限を適用する前の値。
    /// 表示時の snapshot であり、writer / updater は自身の開始時に一度解決する。
    public static func automaticCompressionThreads(powerPolicy: CompressionPowerPolicy = .reduceInLowPowerMode) -> Int {
        if let testingAutomaticThreads { return testingAutomaticThreads(powerPolicy) }
        let topology = CPUTopology.current
        let process = ProcessInfo.processInfo
        let memory = process.physicalMemory
        let lowPower = process.isLowPowerModeEnabled
        let thermal = process.thermalState
        return automaticCompressionThreads(topology: topology, physicalMemory: memory,
            lowPowerMode: lowPower, thermalState: thermal, policy: powerPolicy)
    }

    static func automaticCompressionThreads(topology: CPUTopology, physicalMemory: UInt64,
                                            lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState,
                                            policy: CompressionPowerPolicy) -> Int {
        let n = topology.activeLogicalCPUs
        let thermalPressure = thermalState == .serious || thermalState == .critical
        let reduced = policy != .alwaysUseAllCores && (lowPowerMode
            || (policy == .reduceInLowPowerModeOrThermalPressure && thermalPressure))
        let half = n / 2 + n % 2
        let lowest = topology.performanceLevels.count >= 2 ? topology.performanceLevels.last!.logicalCPUs : half
        let requested = reduced ? max(1, min(half, lowest)) : n
        return max(1, Int(min(UInt64(requested), max(1, physicalMemory / (1 << 30)))))
    }

    var resolvedCompressionThreads: Int {
        compressionThreads ?? automaticThreadsSnapshot ?? Self.automaticCompressionThreads(powerPolicy: powerPolicy)
    }

    /// 内部コピーに自動値を固定し、追加・commit・内側 worker も同じ値を共有する。
    func resolvingCompressionThreads() -> Self {
        var result = self
        if compressionThreads == nil, automaticThreadsSnapshot == nil {
            result.automaticThreadsSnapshot = Self.automaticCompressionThreads(powerPolicy: powerPolicy)
        }
        return result
    }

    func resolvedCompressionThreads(activeProcessorCount: Int, physicalMemory: UInt64) -> Int {
        compressionThreads ?? Self.automaticCompressionThreads(topology: .init(activeLogicalCPUs: activeProcessorCount),
            physicalMemory: physicalMemory, lowPowerMode: false, thermalState: .nominal, policy: powerPolicy)
    }

    /// 検証済み options の writer / updater が finishAdditions で報告する入力 byte の上界。
    /// ZIP Stored / Deflate（ZipCrypto以外）は解決した compressionThreads × 1 MiB。組立中 block も同じ窓に含む。
    /// tar.xz は通常枠と4 MiBの組立中 block を含み、Apple 経路だけ64 KiB以下の軽い block を別枠にする。
    /// ZIP LZMA・Zstandard・PPMd は t > 1 なら t × 16 MiB、逐次は0。
    /// 非solid 7z LZMA・PPMdの項目窓は (f + 1) × 16 MiB。追加の一枠は長いstream専用、逐次は0。
    /// ZIP の大項目を stream worker に渡す場合も一枠16 MiB以下を予約し、全入力は保持せず、結果はdisk spoolへ運ぶ。
    /// BZip2は項目窓と、内側(t+1) × 8 MiBの大きい方。t=1の大入力も同じ有界切断を使う。
    /// 項目窓の数は要求並列数・GCD poolの安全上限・メモリ予算で解決する。filterなし非solid 7z Copyは0。圧縮出力は1 MiBまでメモリ、超過時はdisk spoolで保持する。
    /// PPMd のモデルは ppmdMemoryMiB または preset のメモリを entry / folder ごとに使い、この入力 byte には含まない。
    /// t は解決した並列数。7z Deflate は t 個の1 MiB block、LZMA2 は t 個の片を上界にする。
    /// ZIP XZは項目窓の上界と、既存block窓の (t + 1) × 片の大きい方。大項目の終了時にはblockを全て出力する。
    /// tar.zst はメモリ予算で解決した t × max(4 MiB, level の window)。組立中の frame も枠に含む。
    /// LHAは項目窓の t × 16 MiBと、既存の t 個の1 MiB入力＋履歴の大きい方。逐次とforced storeは0。
    /// 自動値はこの呼出しでも一度解決する。ジョブ開始後の電力状態とは異なる場合がある。
    /// codec state・出力と block 数に比例する XZ index はこの入力 byte に含まない。
    /// 7z solidは (f + 1) × block上限、filter付き非solidは (f + 1) × 16 MiB。逐次は一枠、組立中も枠に数える。
    /// 上限を超えるstreamは一窓分の待ち入力予約で報告する。disk入力はそのfolderの確定長、出力spoolは最大256 × 入力長 + 1 MiB（UInt64で飽和）。
    /// 出力spoolの本数は通常f本と専用一本まで。空き容量から枠や上限を増減させない。
    /// rは要求並列数（自動解決後）。fは max(1, min(r, floor(GCD constrained pool / 4), floor((予算 - 専用予約) / (I/O + p × codec状態))))。
    /// I/Oは16 MiB + 1 MiB + 4 × 256 KiB。pはLZMA・PPMd・Copyが1、LZMA2・Deflateが min(r, ceil(folder上限 / 片サイズ))。
    /// LZMA・PPMd・Copyは予算内に二枠入る場合、一状態とI/Oを専用予約する。片並列も専用枠を含むf+1個のI/Oを先に差し引く。
    /// BZip2は1スレッドもsplice予約を使い、solid/filterでは(t+1+w) × 8 MiBも加える。wは並列時f+1、逐次は1。
    /// codec状態とdisk入力byteの上界は別に数える。
    public func maximumPendingInputBytes(for format: ArchiveFormat) -> UInt64 {
        maximumPendingInputBytes(for: format, physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    func maximumPendingInputBytes(for format: ArchiveFormat, physicalMemory: UInt64) -> UInt64 {
        resolvingCompressionThreads().pendingInputBound(for: format, physicalMemory: physicalMemory)
    }

    private func pendingInputBound(for format: ArchiveFormat, physicalMemory: UInt64) -> UInt64 {
        let lzma = try? LZMAWriterConfiguration(options: self, physicalMemory: physicalMemory)
        let lzmaThreads = UInt64(max(1, min(Self.compressionThreadsRange.upperBound, lzma?.threads ?? 1)))
        let piece = UInt64(lzma?.pieceSize ?? ParallelXZCompressor.defaultBlockSize)
        let threads = UInt64(max(1, min(Self.compressionThreadsRange.upperBound, resolvedCompressionThreads)))
        switch format {
        case .zip:
            switch compressionMethod {
            case .stored: return password != nil && zipEncryption == .zipCrypto ? 0 : threads * UInt64(DeflateBlock.size)
            case .bzip2:
                let inner = ParallelBzip2StreamEncoder.resolvedThreads(options: self, physicalMemory: physicalMemory)
                let chunks = UInt64(inner + 1) * UInt64(ParallelBzip2StreamEncoder.inputCap)
                return max(chunks, EntryCompressionConfiguration(options: self, physicalMemory: physicalMemory).maximumPendingInputBytes)
            case .lzma, .zstd, .ppmd:
                return EntryCompressionConfiguration(options: self, physicalMemory: physicalMemory).maximumPendingInputBytes
            case .deflate:
                return password != nil && zipEncryption == .zipCrypto ? 0 : threads * UInt64(DeflateBlock.size)
            case .xz: return max((lzmaThreads + 1) * piece, EntryCompressionConfiguration(options: self, physicalMemory: physicalMemory).maximumPendingInputBytes)
            }
        case .tar: return 0
        case .tarLZMA, .tarBrotli, .tarCompress: return 0
        case .tarZstd:
            let configuration = try? ZstdWriterConfiguration(options: self)
            return UInt64(max(1, min(Self.compressionThreadsRange.upperBound, configuration?.threads ?? 1))) * UInt64(configuration?.chunkSize ?? (4 << 20))
        case .tarLZ4: return threads * UInt64(LZ4FrameEncoder.blockSize)
        case .tarLzip:
            let configuration = try? LZMAWriterConfiguration.singleStream(options: self, lzip: true)
            let resolved = UInt64(max(1, min(Self.compressionThreadsRange.upperBound, configuration?.threads ?? 1)))
            return resolved * UInt64(configuration?.pieceSize ?? (16 << 20))
        case .tarGzip: return (threads + 1) * UInt64(DeflateBlock.size)
        case .tarBzip2: return (threads + 1) * UInt64(ParallelBzip2Compressor.chunkSize(level: max(1, min(9, bzip2Level))))
        case .tarXZ:
            // 未出力は通常枠 t 個、合計 2t + 1 個以下。member の終了時の組立中は packing 以下。
            let light = lzmaLevel == nil && lzmaThreads > 1 ? (lzmaThreads + 1) * UInt64(ParallelXZCompressor.lightChunkLimit) : 0
            return lzmaThreads * piece + light + UInt64(ParallelXZCompressor.memberPackingSize)
        case .sevenZip:
            // solid/filterの未圧縮入力はdisk上のspool。組立中もfolder窓の一枠に数える。
            if sevenZipSolid != .off || sevenZipFilter != .none {
                let count = UInt64(EntryCompressionConfiguration(options: self, method: sevenZipMethod,
                    physicalMemory: physicalMemory, innerParallelism: true).sevenZipWindowCount)
                let limit = sevenZipSolid == .off ? UInt64(EntryCompressionConfiguration.inputLimit) : resolvedSevenZipBlockSize
                let (bound, overflow) = limit.multipliedReportingOverflow(by: count)
                if sevenZipMethod == .bzip2 {
                    let inner = ParallelBzip2StreamEncoder.resolvedThreads(options: self, physicalMemory: physicalMemory)
                    let chunks = UInt64(inner + 1) * UInt64(ParallelBzip2StreamEncoder.inputCap)
                    // disk spoolと、複数folderの内側組立bufferを同時に数える。
                    let (total, totalOverflow) = bound.addingReportingOverflow(chunks + count * UInt64(ParallelBzip2StreamEncoder.inputCap))
                    return overflow || totalOverflow ? UInt64.max : total
                }
                return overflow ? UInt64.max : bound
            }
            switch sevenZipMethod {
            case .lzma2: return lzmaThreads * piece
            case .deflate: return threads * UInt64(DeflateBlock.size)
            case .bzip2:
                let inner = ParallelBzip2StreamEncoder.resolvedThreads(options: self, physicalMemory: physicalMemory)
                let chunks = UInt64(inner + 1) * UInt64(ParallelBzip2StreamEncoder.inputCap)
                return max(chunks, EntryCompressionConfiguration(options: self, method: sevenZipMethod, physicalMemory: physicalMemory).sevenZipMaximumPendingInputBytes)
            case .lzma, .ppmd:
                return EntryCompressionConfiguration(options: self, method: sevenZipMethod, physicalMemory: physicalMemory).sevenZipMaximumPendingInputBytes
            case .copy: return 0
            }
        case .lha:
            guard threads > 1, lhaMethod != .stored else { return 0 }
            let pieces = threads * UInt64(LHAWriter.compressionChunkSize + lhaMethod.windowSize)
            return max(pieces, EntryCompressionConfiguration(lhaThreads: resolvedCompressionThreads, physicalMemory: physicalMemory).maximumPendingInputBytes)
        }
    }

    // writer / updater / rewriter は出力や作業ファイルを作る前に同じ規則で検証する。
    func validate(for format: ArchiveFormat) throws {
        // 項目・block並列のどちらもAES / ZipCryptoと併用できる。
        guard (0...9).contains(deflateLevel) else { throw WriterError.invalidOption("deflateLevel") }
        guard (1...9).contains(bzip2Level) else { throw WriterError.invalidOption("bzip2Level") }
        guard (1...19).contains(zstdLevel) else { throw WriterError.invalidOption("zstdLevel") }
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
        if let compressionThreads, !Self.compressionThreadsRange.contains(compressionThreads) {
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
        case .tarZstd: _ = try ZstdWriterConfiguration(options: self)
        case .zip where compressionMethod == .zstd: _ = try ZstdWriterConfiguration(options: self, streaming: true)
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
