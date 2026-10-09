# GyoshukuKit 設計書(2026-09-10 初版)

導入は [README](../README.md)、利用時の API・保証は[使用ガイド](usage.md)、方式と制限は[形式リファレンス](formats.md)、設定とメモリは [WriterOptions](options.md)、検証手順は[開発ガイド](testing.md)を参照する。

## 1. 位置づけ

解凍(KaitoKit)と凝縮(GyoshukuKit)を対にする。KaitoKit が読み取り専用で
あることは意図的な設計であり、書き込みをそこへ足すと、読み取りしか必要としない
利用者(cooViewer など)にまで writer の byte が届いてしまう。別リポジトリに
することで、その影響を文言ではなく構造として断つ。

KaitoKit と同じ性格を引き継ぐ。

- 純 Swift。追加の外部依存なし。zlib、libbz2、Apple Compression、CommonCrypto / CryptoKit / Security をサポートされた
  形で使う。システムの libarchive は使わない —— SDK に `archive.h` が無く
  (実測)、prototype を手書きして依存するのは性格に合わない。加えて libarchive
  には in-place update が無く、書庫内編集のためにどのみち自前の updater が要る。
- 攻撃者が制御する値は読んだ場所で検証する。書く側でも同じで、宣言サイズや
  entry 数を信用して確保しない。
- 実装の正しさは**参照実装との差分テスト**で担保する。書いたものを `unzip -t`、
  `7zz t`、`bsdtar` で読み、さらに **KaitoKit で読み直す往復**を必ず行う。
  解凍と凝縮が対である以上、この往復が最も素直な回帰テストになる。

## 2. 依存の向き

```
GyoshukuKit ──依存──> KaitoKit
```

一方向だけ。KaitoKit は GyoshukuKit を知らない。

書庫の**更新**(追加・削除・改名)は、生き残る entry を再圧縮せずに運ぶために
既存書庫を読む必要がある。その堅い parser は KaitoKit が既に持っているので、
二つ目の ZIP parser は書かない。開発中は `.package(path: "../KaitoKit")`、
release では `.upToNextMinor(from: "0.12.0")` の tag 参照を使う。
GyoshukuKit 0.8.0 は KaitoKit 0.12.x に依存する。`@_spi` は SemVer の保証外で、
`public import KaitoKit` により公開 API にも KaitoKit の型を含むため、次の minor は再検証が必要。
隣接 checkout の自動選択と、SwiftPM / Xcode の `checkouts/` 内では tag を使う規則は維持する。

### CI と toolchain（2026-10-08）

ビルドには Xcode 27 / Swift 6.4 以上を使い、成果物の実行環境は macOS 26 以上を維持する。
Swift 6.3.3 の `-O` は Optional な関数型の `TaskLocal.withValue` を誤コンパイルする。
独立 probe で全 Optional 関数型について valueType metadata が nil になり、EXC_BAD_ACCESS を確認した。
Swift 6.4 で build した release binary は macOS 26 で動くため、Xcode 26 / Swift 6.3 での
コンパイル差の検査は廃止し、古い compiler に合わせた source の回避策は加えない。

CI の `build-and-test` は `xcode-27` で debug 全 suite と release FullSize 16件（BZip2追加後）を実行する。
並行する `build-for-macos-26` も `xcode-27` で debug / release test を build し、test bundle と
隣接 resource bundle、`otool` で調べた非 system の依存 dylib / framework、Xcode 27 の xctest を tar で運ぶ。
`macos-26-runtime` は同じ checkout path に展開し、`#filePath` の fixture と `Bundle.module` の path を保つ。
`macos-26` 上で Swift の build / test は行わず、artifact に同梱した Xcode 27 の xctest runner と
framework / dylib で debug 全 suite と release FullSize を実行する。Xcode 26 の system xctest は
XCTestCore の interop symbol が不足し、Xcode 27 の test bundle を load できない。
製品コードは macOS 26 の OS Swift runtime 上で動かし、OS の差を検査する。
実際の test failure と実行件数0は失敗にする。両実行 job に同じ必須 oracle を導入し、
KaitoKit は利用側と同じ tag から解決する。

### 2.1 ソースの配置(2026-09-28)

`Sources/GyoshukuKit/` は役割ごとの階層にする。SwiftPM は階層を見ないので `Package.swift` は変えない。
file 名は中の主な型の名前に合わせ、`Records` / `Layout` / `EditPlan` / `Updater` / `Writer` / `SelfCheck` の
語を形式をまたいで同じ意味で使う。

| directory | 内容 |
| --- | --- |
| `API/` | 公開の形式・設定・error(`ArchiveEditing`、`ArchiveFormat`、`SingleStreamFormat`、`SingleStreamCompressor`、`WriterOptions`、`WriterError`、`UpdaterError`、`UpdaterRouteError`) |
| `Writer/` | 新規作成の facade `ArchiveWriter`(形式ごとの writer への振り分け)、`SingleStreamWriter`の原子的公開と、ディスク側の先読み・署名 |
| `Editing/` | 全 updater と rewriter が共有する層(`ArchiveRewriter`、`ArchiveRepresentability`、`EntryEditLedger`、`EditPathReservations`、`ArchiveFileSource`、`CommitProgressMeter`、`EntryStream` の読取) |
| `SegmentedOutput/` | 形式中立の出力 engine(`SegmentedArchiveOutput`、`SegmentCommitPlan` / `OutputSegment`、`ScratchFile`、`OwnedOutputFile`、`ArchiveSourceSnapshot`、`ArchiveOwnedFile` / `FileIdentity`)。圧縮 tar の splice(`CompressedTarSpliceOutput`)は別の engine なので語を分ける |
| `Zip/`、`Zip/Update/` | ZIP の record 表・`ZipWriter`・暗号化と、`ArchiveUpdater` の編集経路(layout の門番、中央 directory、rebuild、再暗号化、copy engine、自己照合) |
| `Tar/`、`CompressedTar/`、`SevenZip/`、`LHA/` | 形式ごとの Records / Layout / EditPlan / Updater / Writer / SelfCheck |
| `Compression/` | byte を圧縮 byte にする codec と framing(`DeflateBlock`、`OrderedChunkPipeline`、`GzipFraming`、`XZFraming`、`LH5Encoder`、…)。hot path。命名・comment・定数以外は触らない |
| `Support/` | 書庫を知らない補助(`checkedAdd`、`Range<UInt64>.byteLength`、`updateCRC`、little-endian の `Data` 拡張、`IOChunk.size`、`FileMode`、`FileRead`、`EncryptionPrimitives`) |

圧縮 tar の経路(`TarEditPlan → TarImageSource(+ScratchFile)→ CompressedTarSplicePlan →
CompressedTarSpliceOutput.commit → CompressedTarSelfCheck.verify`)は `SegmentedArchiveOutput` を使わず、
出力 inode の所有だけを `OwnedOutputFile` で共有する。

試験の継ぎ目は `@TaskLocal static var testing*`(試験だけが設定する)と `*Observer`(本番も設定しうる観測点)で
名前を分ける。`CommitStrategy` と `lastCommitStrategy` は四つの updater で同じ `@_spi(Testing)` の形にする。

## 3. API の形

KaitoKit の `ArchiveReader` と対称にする。

```swift
// 新規作成
let writer = try ArchiveWriter.create(url: destination, format: .zip, options: WriterOptions())
try writer.add(contentsOf: sourceURL, as: "docs/readme.txt")
try writer.addDirectory("docs/")
try writer.finish()

// 既存 ZIP への追加(段階 1 後半)
let updater = try ArchiveUpdater.open(url: archive)   // 内部で KaitoKit の reader を使う
try updater.add(contentsOf: fileURL, as: "new.txt")
try updater.add(data: Data("追加".utf8), as: "memo.txt", modificationDate: nil, permissions: nil)
try updater.addDirectory("empty/")
try updater.commit()        // clone を完成させて atomic replace

// 既存 ZIP の削除・改名(段階 3、0.3.0)
let editing = try ArchiveUpdater.open(url: archive)
try editing.remove(entriesAt: [0, 2])
try editing.rename(entryAt: 1, to: "docs/新しい名前.txt")
try editing.commit()        // index は open 時の値。削除予約で詰め直さない

// 非圧縮 tar は原本を保ち、指定した新規 output へ必要な範囲だけ書く。
let tar = try TarUpdater.open(url: archive, output: destination)
try tar.rename(entryAt: 0, to: "renamed.txt")
try tar.add(contentsOf: fileURL, as: "new.txt", ownerIDs: ArchiveOwnerIDs(user: 501, group: 20))
try tar.commit(progress: { progress in /* completedBytes / totalBytes */ })
```

`ArchiveEditing` は日付・所有者指定の `addDirectory(_:modificationDate:ownerIDs:)` と
`add(contentsOf:as:ownerIDs:)` も要求する。従来の conformer 向けの既定実装は、指定値が
あれば `unsupportedOption` を返す。ZIP / tar は明示 ID を全子孫へ適用し、7z / LHA は拒否する。
`ArchiveRewriter` の既定は既存項目の後ろへ追加する `.end`。add は名前と追加元の署名を予約し、
出力を作らず commit で運んでから追加する。追加元の最上位 inode・mode・size・mtime を再検査し、
directory の子孫は commit で探索する。`.beginning` は従来の add 時に書く動作を保つ。

`ArchiveWriter` / `ArchiveUpdater` は thread-safe にしない。KaitoKit と同じく、
一つの instance の操作は呼出側が直列化する。値型の設定は `Sendable` にする。

`WriterOptions` は圧縮方式と level、暗号化、名前の encoding、timestamp の
粒度、macOS metadata を書くかどうかをまとめる。既定値は「相手が Windows でも
困らない」側に倒す(§5)。

## 4. 形式ごとの段階

| 段階 | 形式 | 作成 | 追加 | 削除・改名 |
|---|---|---|---|---|
| 1 | ZIP / ZIP64 | ○ | ○(旧 CD の byte をそのまま運ぶ) | ○(段階 3、KaitoKit 0.4.0 の rawRecord を使用) |
| 2 | tar | ○ | ○(TarUpdater、終端の手前へ) | ○(TarUpdater、変更 header と位置の動く範囲だけ) |
| 2 | tar.gz / .bz2 / .xz | ○ | ○(CompressedTarUpdater) | ○(変更を含む区切りだけ再符号化) |
| 2 | tar.zst / .lzma / .lz / .lz4 / .br / .Z | ○ | ○(ArchiveRewriter) | ○(全体再符号化) |
| 2 | 単独 gzip / bzip2 / XZ / Zstandard / LZMA / lzip / LZ4 / Brotli / compress | ○(SingleStreamCompressor) | 対象外 | 対象外 |
| 3 | 7z | ○(solid・BCJ / ARM64 / Delta・AES-256 / header 暗号化を選択可能) | ○(SevenZipUpdater、末尾へ) | ○(header・移動 pack、solid の一部削除はその folder だけ再圧縮) |
| 4 | LHA / LZH | ○(`-lh5-` / `-lh6-` / `-lh7-` / `-lh0-`) | ○(LHAUpdater、末尾へ) | ○(header と位置の動く member だけ) |
| — | RAR | × license が禁じる | × | × |
| — | CAB / RPM / ISO / xar | × | × | × |

圧縮 tar は session reader の復号済み image と区切りの地図から編集する。
継げる区切りが無い入力は最初の変更で全体を G1 の配置に符号化する。
従来の追加位置・所有者設定と open 時に拒否される入力は ArchiveRewriter を使う。
UI 側は進捗と取り消しを必ず出す。

### ZIP の圧縮方式

`CompressionMethod` は stored（0）、Deflate（8）、BZip2（12）、LZMA（14）、Zstandard（93）、XZ（95）、PPMd（98）を持ち、既定は Deflate。
writer と updater の新規追加、ZIP への ArchiveRewriter は同じ ZipWriter を使う。
method 93 の Zstandard は下の「Zstandard の writer 接続」節に framing・version・メモリの規則を記す。
updater の既存 local record・圧縮 byte・central directory は追加時にそのまま運ぶ。
空ファイル・directory・symlink と、heuristic が選ぶ圧縮済み拡張子は stored。

method 12 は `ParallelBzip2StreamEncoder` で一組のheader・EOSを持つstreamを作る（下のsplice節）。
並列数1は従来の `Bzip2StreamEncoder` を使う。codec stateはlevel 9で約7.6 MBとI/O buffer。
method 14 は自前 `LZMAEncoder` を entry ごとに一つ作り、同期符号化する。
[APPNOTE §5.8](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) に従い、
SDK version `[26, 3]`、properties size `[5, 0]`、lc/lp/pb byte と辞書 LE32 の5 byte、
raw LZMA1 stream の順に置く。EOS を書き、両 header の general purpose bit 1 を立てる。
展開要求 version は6.3。`lzmaLevel == nil` は6、extreme はレベル指定時だけ有効。
AES / ZipCrypto は properties header を含む圧縮結果全体を暗号化し、ZIP64 の予約と updater / rewriter は既存経路を使う。
7-Zip 26.03 の ZIP listing は辞書を省略し `LZMA:eos` と表示するので、辞書は properties byte でも検査する。

method 98 は `PPMd8StreamEncoder` の PPMd var.I rev.1 を entry ごとに一つ作る。
[APPNOTE §5.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) の2 byte parameter word を
little endian で stream の直前に置く。下位4 bitは order−1、続く8 bitはメモリ MiB−1、上位4 bitは restoration。
writer は restoration 0（restart）を選び、EOF と4 byte flush を一度だけ書く。
order は2...16、メモリは1...256 MiB。両 header の展開要求 version は6.3、LZMA 用 bit 1 は立てない。
parameter word も AES / ZipCrypto の暗号化対象で、AES の0x9901には実 method 98を記録する。
ZIP64 は最大 order の suffix escape と range 正規化を覆う保守的な出力上界で local の余白を予約する。
updater の追加・rewriter も同じ経路を使う。7zz の ZIP 一覧は order / memory を省略するため parameter word を直接検査する。

method 95 は `ParallelXZCompressor` と `XZFraming` を使い、既定は最大16 MiBの block を
`compressionThreads` で並列化する。hint の無い固定幅を使い、stream header・blocks・index・footer を
一組だけ書く。レベル指定時は自前 `LZMA2Encoder` の結果を `XZLZMA2` として同じ framing に渡す。
block header の filter properties も preset の辞書から作る。片サイズと並列数は自前 encoder 節の予算を使う。
通常枠 t 個と組立中1個の入力は `(t + 1) × 片サイズ` 以下で、Apple の codec と出力は
thread ごとに約130 MiB。index は block 数に比例する。
16 MiB以下の項目は下の項目窓で並列化し、一括disk追加も同じ窓を使う。
大きい項目は従来のblock pipelineを使い、addの終了時に出力を完了する。
全ての並列数と AES / ZipCrypto を併用でき、追加の unsupportedOption はない。

[APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) §4.4.3・§4.4.5 は
BZip2 の展開要求 version を4.6とする。XZ の要求 version は明記されていないので、
[7-Zip 26.03 の公開定義](https://github.com/ip7z/7zip/blob/main/CPP/7zip/Archive/Zip/ZipHeader.h) と
生成した ZIP の2.0を使う。LZMA（method 14）の6.3は流用しない。
method 95 の file data が完全な .xz stream であることは、7zz が作った ZIP の stream 単独復号と
KaitoKit の往復で確認する。圧縮方式、ZIP64、暗号化の要求 version の最大値を両 header に書く。
CRC32・確定サイズ・ZIP64 の事前予約・seek による local header patch は既存の経路を使い、descriptor は書かない。
XZ の予約長は選択した片サイズで Apple encoder の容量上限と framing の上界を使い、自前 LZMA2 の raw chunk 膨張も覆う。
LZMA1 は最悪 literal 膨張の上界として16 × 入力長 + 1,024 byteを予約する。

macOS Archive Utility / ditto と `/usr/bin/unzip` は method 12 / 14 / 95 / 98 を展開できない。
Deflate を互換性の既定とし、BZip2 / LZMA / XZ / PPMd は KaitoKit や 7-Zip を使う場合の opt-in とする。

### ZIP / 7z BZip2 / 単独.bz2 の単一stream並列圧縮

`Bzip2BlockScanner` はsystem libbz2のRLE1入力段をSwiftでO(n)走査する。
照合元はbzip2 1.0.8のBSD形式ライセンスの
[bzlib.c](https://raw.githubusercontent.com/libarchive/bzip2/bzip2-1.0.8/bzlib.c)
（`copy_input_until_stop` / `ADD_CHAR_TO_BLOCK` / `add_pair_to_block` / `handle_compress`）と
[compress.c](https://raw.githubusercontent.com/libarchive/bzip2/bzip2-1.0.8/compress.c)。Cの同梱はしない。
`nblockMAX = 100000 × level - 19`、run 1〜3はその長さ、4〜255は5 byteとして数える。
次の入力byteを消費する前の満杯判定では未確定runをflushしない。そのrunの入力先頭で切ると、
独立した `BZ2_bzCompressInit(level, 0, 30)` でも同じblock内容・block CRCになる。
`BZ_FINISH` は残り入力0の処理を満杯判定より優先するので、末尾のrunは最後のblockに数える。

chunkの目標幅はlevelと入力サイズだけで決め、並列数・CPU topology・メモリ予算には依存させない。
`B = 100000 × level - 19`、既知サイズS>0の推定block数を `N = ceil(S / B)` とし、
目標幅を `W = B × min(5, max(1, floor(N / 32)))` とする。
2 block以上は推定で `min(N, 32)` 片以上を確保し、巨大入力では5 block幅を上限にする。
level 9の10 MiBはW=Bで12片、64 MiBはW=2Bで38片、1 GiBはW=5Bで239片。
level 1では同じ入力がそれぞれW=3Bで35片、W=5Bで135片、W=5Bで2148片になる。
サイズ不明（S=0）のstreamingは固定W=Bとし、中程度の入力も早く並列codecへ渡す。
完全なblock境界まで走査するため、RLEによって一片の実block数・入力長・実片数は変わる。
予約用の `estimatedChunkCount` は同じWによる `ceil(S / W)` を公開範囲 `compressionThreadsRange` の1024まで数え、S=0は1とする。
入力capは各chunk 8 MiB。長い同値runでcapに達したときは強制切断し、その位置からscannerを初期化する。
並列数1の大入力も同じscanner・切断・spliceを使い、workerは inline 実行し、結果を直ちに出力する。
cap未満の既知入力の1 thread処理と一block以下の入力は既存codecを使う。
既知入力の逐次経路は最後の1 byteをfinishまで保持し、末尾の満杯blockをBZ_RUNで先に確定させない。
入力とfinishを別writeで渡しても、片をBZ_FINISHで圧縮するsplice経路と同じblock境界を保つ。
capちょうどの既知入力もspliceを使い、最後の入力とfinishを別writeで渡した場合の強制切断を揃える。
強制切断の有無にかかわらず並列数1/2/7/12/36/64でbyte一致する。強制切断時のbyteは従来の逐次libbz2とは異なるが、標準の単一streamを維持する。
1スレッドもspliceのbuffer予約に含め、公開の入力上界は `(t + 1) × 8 MiB`（最低16 MiB）にする。

`OrderedChunkPipeline` がchunkを並列符号化し、入力順にbitをspliceする。
byte境界が揃うpayloadは一括copyし、揃わないpayloadは64 bit単位でshiftする。
出力bufferは `IOChunk.size` 以下とし、端数bitだけを次のchunkへ持ち越す。
各結果の32 bit headerを除き、末尾の `totalBits - 80 - pad`（pad 0〜7）の8候補から
EOS magic `0x177245385090` と零paddingを満たす位置がちょうど一つであることを検査する。
block数mのchunk CRCをCとして全体CRCを `rotl(crc, m) XOR C` で結合し、
最後にEOS・全体CRC・零paddingを一度だけ書く。block数はscannerで数え、byte一致試験で照合する。
Mac miniの事前probeでは連結streamをZIP / 7zに入れると7zzが最初のstreamだけを展開し
rc=2・切詰め、Python zipfileはBad CRC-32、bsdtarも失敗したため、このspliceを採る。
tar.bz2の `ParallelBzip2Compressor` は従来の連結streamと固定幅 `5 × level × 100000` を保つ。
単独.bz2は `SingleStreamWriter` が通常fileの既知サイズを `ParallelBzip2StreamEncoder` へ渡す。

ZIP（一括disk追加も含む）と非solid/filterなし7zの項目窓上限は `5 × B` とし、levelだけで固定する。
上限以下は項目窓で各workerをthreads=1にし、複数項目を並列に圧縮する。
ZIPの一括disk追加も同じ上限で先読みし、先行項目を窓に保持する。
上限を超える項目は項目窓をdrainし、入力サイズ別のchunk幅で内側threadsを使う。
項目窓の上限は全levelで8 MiB cap未満なので強制切断されず、逐次libbz2とspliceのbyteは一致する。
level 1 / 9の上限直前・ちょうど・直後でthreads 1 / 7 / 36の通常追加と一括追加のbyte一致を検査する。
solid/filterの7zは推定片数を予約し、`assignedThreads` の合計を予算内に保つ。
filter付きsolidに次folderがあるときは、内側の予約を `max(1, 予算threads / min(4, folder窓threads))`
以下に分配する。filterはfolder内で逐次なので、先頭folderが全予約を取ると他folderのfilterも待たされる。
BZip2 solidの確定folderは次入力またはflushまで保持し、単独folderのflushでは全予算を使う。
filterの後に圧縮し、spliceしたbyteを従来のAES / ZipCrypto層へ渡す。
取消しは `abandon()` で結果を捨て、chunk codecの終了を待たない。
solidのworkerは共有取消しを内部の容量待ちでも観測し、source descriptorの回収だけを待つ。

C=8 MiB、O=C+floor(C/100)+601、E=400000+800000×level、I=256 KiBとすると、
内側t>=1のメモリ予約は `(t+2)C + t(O+E+I)`。入力(t+1)片に加え切断copy、
圧縮結果、codecとI/Oを含める。Oは[libbz2 manual §3.5.1](https://sourceware.org/bzip2/manual/manual.html#bzbufftobuffcompress)
の出力上界を使い、結果bufferを先に予約して成長時の余剰容量を抑える。
threadsは物理メモリの半分と `memoryLimit` の小さい方で絞る。一枠も入らない指定では
従来どおりthreads=1へ戻し、既存のoptionを拒否しない。
項目窓の逐次codec予約も上のt=1の予約を使い、solid窓は内側の全予約を各枠に数える。幅・片数・メモリ予約の固定表は `Bzip2SpliceTests` に置く。

Mac mini M4でのbase 9d46fe2とda08ba6の交互比較は
[BZip2 splice検証記録](verification/2026-10-08-bzip2-splice-mini-ab.md)に記載する。
全26入力 / 方式・690 sampleで逐次経路と出力が一致し、単一10 MiBのZIP BZip2 / 7z BZip2はt=12で約5倍、
256 MiB corpusの同2方式は約2.3倍。filter付きsolidのtree退行も解消した。

### LHA の方式・探索 level と並列圧縮（P4-G-a）

`ArchiveWriter.create` は `options.lhaMethod`・`lhaLevel`・`resolvedCompressionThreads` を LHAWriter に渡す。
既定は `.lh5`・level6。既存の `LH5Encoder` は `Configuration` で辞書と位置木を選び、Huffman の
serializer を共有する。最大一致長は256 byte、blockは32,768 commandのままにする。

| 方式 | 辞書 bit / 履歴 | position symbol数（NP） | pt-count欄 |
|---|---|---|---|
| `.lh5` | 13 / 8 KiB | 14 | 4 bit |
| `.lh6` | 15 / 32 KiB | 16 | 5 bit |
| `.lh7` | 16 / 64 KiB | 17 | 5 bit |
| `.stored` | なし | なし | なし |

辞書と最大一致長の一次資料は [LHa for UNIX header.doc](https://github.com/jca02266/lha/blob/master/header.doc.md)。
[Lhasa 利用者文書](https://github.com/fragglet/lhasa/blob/master/doc/lha.1) は各methodが同じstatic-Huffman系列であること、
`t`・`xw=<dir>`・`p` の使い方を確認する。Lhasa文書の窓表示（16 / 64 / 128 KiB）はheader.docの値の2倍なので、
writerの辞書値にはheader.docを採用する。NP = 辞書bit + 1 とpt-count欄はtaskの指定と、read-onlyの
KaitoKit `Codecs/LHA/LHAStaticHuffmanDecoder.swift` のparameter表を照合した。Lhasa・LHa for UNIX・7zzの
黒箱でCRC・method表示・展開byteを確認し、LHa for UNIX `-ao62` / `-ao72` の逆方向も読む。
7zz 26.03の `l -slt` はmethodを `LH5` 等でなく `-lh5-` / `-lh6-` / `-lh7-` と表示するため、その表記を照合する。

| level | chainの最大候補数 | 一致の選択 |
|---|---|---|
| 1 / 2 / 3 | 8 / 16 / 32 | 貪欲 |
| 4 / 5 / 6（既定） | 64 / 128 / 256 | 貪欲 |
| 7 | 512 | 貪欲 |
| 8 / 9 | 1024 / 2048 | 次の1 byteで長い一致を見つけたときliteralを先に出すlazy matching |

level6の候補順・同長一致の選び方・block境界・bit列は従来と同じ。既存入力の凍結byteを
`Tests/Fixtures/lha-methods`、大きいmemberの凍結hashを `LHAWriterStreamedMemberIdentityTests` で固定する。
`lhaLevel` は他のlevelと同じく出力作成前に1...9を検証する。storedでも不正なlevelは拒否する。
`.stored` はspool・encoder・parallel pipelineを作らず、I/O chunkで本文とCRCを進めてheaderを確定する。
通常の圧縮もmember全体が縮まなければ `-lh0-` に落とし、directoryは常に `-lhd-` にする。

rewriter もこの経路を使う。1 は従来の同期処理、2 以上では 1 MiB 以下の member を
`OrderedChunkPipeline` に渡し、CRC と入力の読み切りは呼出側で行う。directory も投入順を保つ。
1 MiB超〜16 MiBのmemberも別の有界項目窓へ渡し、worker内の既存writerで一つの完成recordをdisk spoolへ作る。
worker内は1 threadにし、既存の1 MiB区切り・履歴・bit列・raw fallbackを保つ。完成header/bodyとmember記録は投入順に運ぶ。
入力を確保する前に容量を待ち、同時に保持する入力を並列数までに抑える。

大きい member は 1 MiB と方式ごとの直前8 / 32 / 64 KiBの履歴に分ける。各 worker が返す完全な byte と
端数 bit を投入順に padding なしで継ぐ。各方式の辞書・Huffman block の区切りは一定で、
どの並列数でも直列時の byte と一致する。raw を先に出力し、縮めば spool から置き換える。
完成 byte の累計が原本サイズ以上になった区切りで残りの符号化を破棄し、raw の保存を続ける。

`add` の後に符号化が残る場合、失敗・取消しは後続の add / finish / internal の endMembers で通知し、
従来の abort で出力を削除する。小項目窓と中項目窓の切替、16 MiB超のmemberの前にpendingをdrainする。
16 MiB超のmember内は従来の片並列。中項目の取消しはreadごとのlatchで伝え、abortでworkerを待つ。
internal の `endAppendedMembers()`（tar と共通）は終端・fsync・close なしで追加の終わりを返す。
init の `recordsMembers` を有効にしたとき（updater が使う `ArchiveWriter.lhaAppend` は常に有効）だけ、実際の出力時点の header 絶対位置・header/data 長・method と
canonical な名前の byte（directory の 0xFF を `/` に変換し filename を連結）を保存する。
LHAUpdater はこの追加 writer を既存の `SegmentedArchiveOutput` と組み合わせる。
新規追加には選んだmethod・levelを適用し、運ぶmemberの圧縮byteとmethodは変えない。
LHAへのrewriterでは既存memberも再符号化するので、追加と同じmethod・levelを使う。

64-bit Int環境のthreadごとの主要buffer（Huffmanの一時領域・Foundationのコピーを除く）:

| 方式 | 入力 + 履歴 | hash表 | chain表 | command表 | 圧縮出力の目安 | 合計の目安 |
|---|---|---|---|---|---|---|
| LH5 | 1 MiB + 8 KiB | 512 KiB | 64 KiB | 512 KiB | 約1.1 MiB | 約3.2 MiB |
| LH6 | 1 MiB + 32 KiB | 512 KiB | 256 KiB | 512 KiB | 約1.1 MiB | 約3.4 MiB |
| LH7 | 1 MiB + 64 KiB | 512 KiB | 512 KiB | 512 KiB | 約1.1 MiB | 約3.7 MiB |

storedはI/O bufferだけを使う。levelは探索時間を変え、これらの表の大きさは変えない。
この合計はpeak RSSの保証ではなく、圧縮出力のbyte配列とDataが一時的に同時に存在する場合もある。

2026-10-06の参照incident: 形式文書の確認中にLhasaの `lib/lh_new_decoder.c` と
`lib/lh5_decoder.c`・`lh6_decoder.c`・`lh7_decoder.c` を誤って開いた。
以後は上記の許可された形式・利用者文書に限定し、追加実装は既存LH5、taskのparameter、KaitoKitの
既存parameter表から導いた。Lhasaのコードは転記・vendoringせず、互換性は実行ファイルの黒箱出力で検証する。

### LHA の更新（P4-G-b）

`LHAUpdater.open(url:output:options:)` は原本を readonly で開き、descriptor から clone した snapshot を
KaitoKit で読む。clone 非対応時は原本を直接読み、新規 output を先頭から書く。公開・属性の復元は呼出側が行う。
KaitoKit の全件解析、共有 `validateRepresentability`、独立した level 0/1/2 の header walk と
`LHARawLayout` SPI の照合、原本の identity 検査を行う。walk は 4 KiB の窓で読み、payload を読み切らずに飛ばす。
境界の表を二重に保持せず、照合後の計画では SPI を使う。取消しは 1,024 member ごとに検査する。

| 条件 | open の経路 |
|---|---|
| R0 `.beginning` | `requiresRewrite("additionPlacement")`。LHA は `carriedTarOwnerIDs` を見ない |
| R7 分割巻名 | `requiresRewrite("split volume name")` |
| R8 SPI 不在、walk 不可（OS-9 `K` の不足宣言長を含む）、SPI/公開 entry との不一致 | `requiresRewrite` |
| R10(a) nameEncoding が nil/shiftJIS 以外 | `requiresRewrite` |
| R10(b) nameEncoding が nil で rawName に非 ASCII byte がある（宣言付きも含む） | `requiresRewrite` |
| L1 SFX、L2 0 byte 以外の終端 | `requiresRewrite` |
| L3 終端の後ろに非 0 byte、または後続が 64 KiB 超 | `requiresRewrite` |
| L4 非公開 member、L5 level 3、L6 incomplete entry | `requiresRewrite` |
| L7 directory が lhd 以外、packed/original size が 0 以外 | `requiresRewrite` |
| L8 lh7 + OS 0x20（LHArk）、L9 packed size が UInt32 超 | `requiresRewrite` |

`rewriteReason(reader:)` は SPI と公開値による構造判定だけを共有し、設定・分割巻名・独立した walk は判定しない。
MacBinary envelope のある `m` member、symlink、pm2、表せない名前などの門番は rewriter と同じで、
`RewriterError.unrepresentable` のまま返す。KaitoError と非 LHA の `UpdaterError.invalidArchive` も経路変更に使わない。
`UpdaterRouteError` は `requiresRewrite` と `outputVerificationFailed` の二つだけを持ち、
`TarUpdaterError` はその typealias として既存の catch を保つ。

削除・改名と名前の予約は `EntryEditLedger`（内部で `EditPathReservations`）を使い、tar・圧縮 tar・7z の updater と
`ArchiveRewriter` も同じ台帳を使う。index と entryNames は open 時のままで、削除後に同名の追加ができる。
root `.` は予約名が空でも運び、正規化後に同じ名前へ改名した member の byte は保つ。
違う名前への改名時点で `LHARecords.Entry` の header を作り、失敗は transaction 全体を失敗にする。
改名しない member は header・payload・名前の raw byte・時刻・拡張をそのまま運ぶ。

改名した member は level 2、OS `U`、attribute 0x20、拡張 0x00/01/02/50/54 になる。
comment、DOS 属性、Windows 時刻、64 bit size、code page、uid/gid、所有者名、未知の拡張は落ちる。
時刻は KaitoKit が解いた modificationDate の Unix 秒へ切り捨て、欠ければ現在時刻を使う。
level 0/1 の DOS 時刻は現在 timezone の解釈、0x41 の秒未満は失う。
permission は OS `U` の値、その他は 0644/0755。method・payload・data CRC16・元サイズは保つ。

追加・改名は宣言なし CP932 で書く。R10(b) は、追加した名前だけが文字コード推定の入力となる場合を避ける。
`SP/p4rev/enc` の実験では、単独の第 2 水準漢字名 12 件のうち 9 件が別 encoding と推定された。
既存の CP932 名があれば同じ 12 件は正しく読めた。宣言付き非 ASCII 名も R10(b) の対象になる。
既存 CP932 名の削除によって、編集後の書庫が次回 R10(b) に当たる場合はある。

変更時は生存 member、追加 block、0 の 1 byte の順に並べ、後続の 0 も落とす。全削除は `[0]`。
KaitoKit がこの空書庫を識別するには、読取 URL の拡張子を `.lha` / `.lzh` にする。
無変更 commit は後続の 0 も含め全 byte を保つ。位置が同じ source segment は clone のままにし、
移動範囲だけ copy する。追加後の予約で位置が変われば共有部品の scratch へ退避して再配置する。
出力、spool、dup descriptor の所有と削除は既存の FAT/exFAT の fresh fstat/lstat 規則を使う。

commit の照合は V1（改名 header の byte・CRC・解釈）、V2（source segment 境界の header）、
V3（追加 block の独立 walk と記録、dup descriptor 上の KaitoKit 全復号/CRC16）、V4（長さと終端）、
V5（共有部品による、書いた source 範囲の 4 MiB ごとの memcmp）。追加だけでは既存 prefix を読み戻さない。
運んだ payload は復号しない。呼出側の公開前の全 header 解析・projection 照合は別に残す。
進捗 total は書込み（再配置の往復を含む）+ V2/V5 読取 + 追加 block 長で、計画後は固定する。
V2/V5 は `SegmentedArchiveOutput.verificationReadObserver` 一つに報告する。V1/V4 と V3 の実読取量は足さない。
callback の throw・取消し・再入は失敗とし、自分の出力だけを削除する。

tl-S11 の危険は残る。level 2 の長さの下位 byte が 0 だと KaitoKit は終端と見る。
非 0 の後続を L3 で拒否できるが、rewriter も見えなかった後ろの member は復元しない。
新しい header は `LHARecords` の既存の padding 規則でこの形を作らない。

## 5. 既定値の方針

- ZIP は general purpose **bit 11** を立てて UTF-8 名を書き、NFC へ正規化する。
  既存の CP932 書庫を更新するときは、既存 entry の名前バイトと flag を
  **そのまま**運ぶ(混在は正当)。
- ZIP の `version made by` は host 3 (UNIX)。でないと POSIX mode と symlink が
  尊重されない。
- data descriptor は**書かない**(seek して local header を patch する)。ただし
  **読む側は必須** —— `ditto` は deflate entry すべてに bit 3 を立てる。
- tar は macOS metadata(`._` AppleDouble、`SCHILY.xattr`)を**既定で書かない**。
  Apple の bsdtar は既定で書き、それが Mac 製書庫が Windows で嫌われる主因。
- 新規 tar とディスク追加の uid/gid は既定 0、uname/gname は空。`preserveOwnerIDs` はディスク追加だけに効く。
  運ぶ tar の ID は `carriedTarOwnerIDs: .keep` で数値を維持する。rewriter の `.reset` は 0 にする。
  TarUpdater は header の ID・uname/gname・pax・sparse 表現を byte 単位で運び、名前も正規化しない。
  追加・改名と衝突判定には従来の NFC 正規化を使う。`additionPlacement` の既定は `.end`。
- 圧縮は zlib の deflate、既定 level 6(Info-ZIP と同じ)。Apple の Compression
  framework は `COMPRESSION_ZLIB` が level 5 相当に固定で選べない(実測)。

## 6. 更新の安全性

### 圧縮 tar の区切り単位の更新（P3-G G2）

`CompressedTarUpdater.open(reader:output:format:options:)` は KaitoKit の
`recordsTarEditLayout` を立てた session reader を受け取り、原本の URL は受け取らない。
`assess(reader:)` は snapshot と地図だけを見て初回の全体符号化の見込みを返す。
open は P2 の `TarLayout` と K1 の member/header/global/EOF 境界を照合し、
従来の設定と R0–R8・R10 を拒否する。ここでは出力も一時ファイルも作らない。

変更の意味は `TarEditPlan` と追加用 factory を共有する。hard link の付け替え・実体化、
pax/sparse header 群の変更、comment の global header、所有者と未変更名の byte を保つ。
変更 commit は新しい EOF と record fill を作り、変更なしは圧縮 byte もそのまま複写する。
`TarImageSource` は旧 image と追加/literal の区間を二分探索し、image 全体を複写しない。
追加/literal だけの保存領域は形式共通の `ScratchFile`（出力の隣に O_EXCL・0600 で作り、inode の一致を確かめて直ちに unlink し、fd だけを持つ。2026-09-29 に再配置の scratch・7z folder の scratch・LHA の圧縮 spool も同じ型に統一）で、
固定の予備容量や空き容量の事前検査は設けず、実際の書込みエラーを伝えて後始末する。
出力 volume 上で追加と literal だけを保存するため、出力本体と同じ容量方針にする。

運ぶ chunk は新 image の一つの連続する source 区間に収まるものだけとする。
gzip はさらに直前 32 KiB も同じ source 区間に収め、BFINAL を途中へ運ばない。
残りの橋を `TarChunkCutter(limits:)` で切る。`TarChunkLimits` は詰める上限 packing と片の上限 piece を持つ。
gzip は両方1 MiB、bzip2 は両方5 × level × 100,000 B。xz は packing が
`ParallelXZCompressor.memberPackingSize`（4 MiB）、piece が `defaultBlockSize`（16 MiBの片）。
header 群・本文・詰め物を合わせて packing を越える member は header 群と本文を分け、
それぞれ piece ごとに切る。小さな member は packing まで詰め、終端は独立する。
橋が member の途中から始まる場合は残りの長さで判定する。橋に隣接する packing/16 未満の
chunk を片側一つ吸収し、間が小さい chunk だけの橋同士も併合する。
xz の吸収のしきい値は256 KiB。`nextEditReencodesEverything` の判定は piece のまま保つ。
gzip の CRC は libz の `crc32_combine`、xz の block/Index/footer は G1 の `XZFraming` を使う。
bzip2 は運ぶ stream の元の level を維持する。CRC64 の xz、地図の無い容器、
運べる chunk の無い計画は fullEncode になる。

進捗の total は橋の image byte、運ぶ圧縮 byte、自己照合の圧縮/framing 読取 byte の合計。
圧縮長を先に求めて total を固定し、その後に出力を作る。並列数 × piece × 2 の
cache に符号化結果を残し、収まらない fullEncode の chunk は書出し時に再符号化する。
xz の cache 上限は片が16 MiBなら8 threadsで256 MiB、明示16 threadsなら512 MiB（自動値に固定上限はない）。事前符号化と書出しの両方に下記の軽い block の枠を使う。
追加の圧縮 spool は作らない。この事前符号化中も Task の取消しを確認するが、
最初の進捗通知は total が確定した後になる。callback の throw・再入も失敗として扱う。

自己照合は V0（区間・座標・gzip 窓）、V1（橋だけを並列に復号して新 image と比較）、
V2（header/trailer、bzip2 EOS、xz block/Index/footer）、V3（出力と原本の同一性）を行う。
V4 は copy engine が読んだ圧縮 byte の CRC32 を open 時の digest と比較し、
mtime を戻した同一 inode の変更も `sourceChanged` にする。読取りは一回で、
出力の運んだ payload は自己照合で読み直さない。検証読取は既存の
`SegmentedArchiveOutput.verificationReadObserver` に報告する。

`commit(progress:)` は戦略、自己照合後の出力 identity、統計、
`.reused(output:base:)` / `.encoded(output:)` の segment 列を返す。
呼出側はこれを一対一で KaitoKit の `CompressedTarSplice` へ写し、**公開前に K5
`openSplicedCompressedTar` を呼ぶこと**。全体の open で検証し直してよいのは
K5 の `.baseNotSpliceable` の場合だけで、それ以外の失敗は公開しない。
K5 は運んだ出力の digest・gzip 窓・橋の復号・容器の終端を独立に検証する。
GK の自己照合だけでは、書いた後の運ぶ payload の破損を検出しない。

原本は snapshot の descriptor の同一性を open・commit 開始・fsync 後に検査する。
原本のパスが別 inode へ置換されたかは呼出側の責任で、GK は保持した inode を読む。
作った output は `ArchiveOwnedFile` の fresh fstat/lstat 照合で所有を確認し、
失敗時も別の inode は消さない。FAT/exFAT の空 file の仮 inode を保存しない。
成功した出力は 0600・fsync・close 済みで、公開・属性復元は呼出側が行う。
圧縮率の極端に高い小さな書庫では、数十 byte の区切り差でも相対サイズ差が 1% を
超える場合がある。検証記録では byte 差と比率を両方示す。

試験・互換性・AC9 の TSV は [G2 検証記録](verification/2026-09-26-p3g2-compressed-tar-updater.md) に記す。

### tar.xz の並列圧縮（P14-G）

writer と updater は同じ二つの上限で区切る。packing は4 MiB、片は nil レベルなら16 MiB、
自前 encoder では辞書が16 MiBを超えると3 × 辞書にする。hint の無い入力と組立の予約は片サイズの固定幅を使う。
hint の無い経路に packing を使うと固定幅へ届かず停止する。
`OrderedChunkPipeline` の `weight` は入力 byte 数。`lightWeightLimit > 0` かつ
`0 < weight <= lightWeightLimit` の item だけを軽いものとする。
未出力の重い item が threads 以上、または全 item が `2 × threads + 1` 以上の間、
先頭を順に書き出してから次を投入する。次の item の重みは待機条件に使わない。
既定の limit と weight は0で、従来の枠を保つ。取消し・失敗・abandon の扱いも共通。

Apple 経路の tar.xz だけが threads > 1 のとき `lightChunkLimit`（64 KiB）を指定する。
writer は block の入力長、updater の事前符号化と書出しは part の image 長を weight にする。
運ぶ part と cache 済みの part は入力が無いので weight 0。threads == 1 は同時に一つだけを符号化する。
待機中の入力と組立中の入力の上界は `(threads + 1) × (piece + lightChunkLimit)`。
自前経路は小さい block も並列枠に数え、解決した並列数 t に対する入力上界は `t × 片 + 4 MiB`。
`CompressedTarSplicePlan` / `CompressedTarSpliceOutput` も同じ片・encoder・並列数を使い、運ぶ block は変えない。
codec state と圧縮出力は別で、P9 の `30 + 135 × t` MiB は実測に合わせた見積りであり上界ではない。
試験と計測の引継ぎは [P14 検証記録](verification/2026-09-26-p14-xz-packing.md) に記す。

### 非圧縮 tar の最小書き換え（P2-G）

TarUpdater は P1-G の `ArchiveSourceSnapshot` を共有し、原本を O_RDONLY で開く。
immutable / append flags を拒否し、descriptor clone が ENOTSUP / EXDEV のときだけ sequential に戻す。
KaitoKit の open と全件の表現可能性検査に加え、`TarLayout` が独立して tar を走査し、
member の名前・種別・保存長を照合する。走査は任意の ByteSource と座標だけで動き、
4 KiB の header cache と拡張 payload の範囲読取を使う。旧 GNU sparse・非 comment 大域 pax・
hdrcharset・不安定な名前 encoding・sparse hard link などは open で `requiresRewrite` になる。
`.beginning` と `.reset` も open で拒否し、rewriter へ戻す判断を mutate 前に確定できる。

`TarEditPlan` は生存 member 順の source / literal 区間を作る。変更しない header/body と comment の
大域 pax はそのまま、改名では必要な name / prefix / link / checksum と pax record だけを変える。
削除された hard link の参照先は生存 holder へ付け替え、holder が無ければ最初の link を実体化する。
変更した commit は 1,024 B の EOF と 10,240 B record までの fill を新しく書く。変更 0 件は尾部も含め原本と一致する。

形式共通の `SegmentedArchiveOutput` が clone、新規 output、4 MiB copy、追加 block の再配置、scratch、
truncate、fsync、close、inode に限定した cleanup を所有する。TarUpdater は計画と終端・形式照合を渡す。
同じ位置の source は clone 上で書かない。sequential の初回 add は先に prefix を埋め、予約の変更で
追加位置や prefix が変わった場合だけ同じ directory の scratch（`ScratchFile`。名前は作成直後に unlink され、commit 中も名前では見えない）へ追加を退避する。
generated 区間と最初の fsync 後の finalPatch も形式共通の契約として用意し、後続の updater が再利用する。

V1 は変更 header、V2 は source 境界 header、V3 は追加群、V4 は終端と長さ、V5 は書いた source と
出力の全 byte を照合する。V5 は 4 MiB ごとの直接 pread 比較で、未移動の clone 範囲は読まない。
V2/V5 の読取を一つの `SegmentedArchiveOutput.verificationReadObserver` に報告する。
共通 `CommitProgress` の total は計画後に固定し、commit 中の書込み（再配置の往復を含む）と
V2/V5 の読取を数える。初回 add の書込みは含めない。単調に通知し、最後は 0 を含め completed == total。
callback の throw・再入・取消しは失敗として、自分の inode の output / snapshot を削除し、scratch は fd を閉じて解放する。

試験・互換性・計測値は [P2-G 検証記録](verification/2026-09-25-p2g-tar-updater.md) に記す。

### 段階 1 の追加

1. 同一ボリュームの `.itemReplacementDirectory` へ **APFS clone** する
   (`FileManager.copyItem`。実測 300 MB で 0.002 s)。最初の add まで遅延する。
2. clone の旧 CD offset から新しい local record を書く。既存の local record は
   元の位置のままであり、再圧縮も descriptor の探索も行わない。
3. open で検証して保持した **旧 CD の byte をそのまま**コピーし、新しい CD を
   続ける。旧 local offset が動かないので、旧 CD の再符号化や部分修正は不要。
   旧 entry 数・CD size・CD offset を合算した EOCD を作り、必要なら ZIP64 EOCD と
   locator を新たに書く。旧 ZIP コメントも保持し、末尾を truncate・同期する。
4. `FileManager.replaceItemAt` で差し替え、**直後に POSIX permission を復元**する
   (実測:replacement 側の mode が勝つ)。`replaceItemAt` は Finder tag と
   xattr と作成日は保つが `com.apple.quarantine` は落とすので、付いていれば戻す。

原本は一度も in-place 編集しない。commit 前の失敗・破棄では clone を削除する。
成功後の commit は no-op。失敗後の instance は再利用できない。原本の inode・size・
mtime・mode が open 時と変わった場合は置換を拒否する。device も比較する。
Finder tag や LaunchServices の `com.apple.lastuseddate#PS` 更新でも変わるため ctime は除外する。
通常ファイルの読取前後と tar hard link の内容 signature も同じ方針にする。ただし排他 lock は取らず、
同一書庫への他プロセスの操作も呼出側で直列化する。
置換後の metadata 復元が失敗した場合はエラーを返すが、内容の置換は既に完了している。

### 段階 3 の削除・改名(0.3.0)

生き残る local record 全体を新しい位置へ運ぶには、KaitoKit が検証した範囲が必要になる。
open で `@_spi(ZipRawLayout) zipRawRecordLayout(at:)` を使い、CD を一括で読み、独立した
walk の offset・件数・終端と ZIP64 extra の解釈を照合する。CD の bytes と検証済み範囲を保持し、
commit は同じ record を再解析しない。nil の生存 entry は理由付きで拒否する。
CD の一括確保は KaitoKit と同じ metadata 上限以内に限定する。validate 自体は取消しを検査しないが、
KaitoKit の解析は取消し済みの Task で CancellationError を投げる。
local と central の extra field 長は異なるので local を CD から再構成しない。
この場合は offset が動き、ZIP64 extra も増減するため CD 全体を再出力する。
追加だけにこの再構成や descriptor 探索を持ち込まない。

削除・改名は open 時の index で予約する。削除の重複は無害、同じ index の再改名は最後の
予約名を使う。削除済み entry の改名は拒否し、削除予約した名前は後の追加・改名で再利用できる。
子孫の削除・改名、symlink target の変更は暗黙に行わない。

先に local、次に CD の順で出力を計画する。生存 record は CD 順に、source と出力がともに
厳密に連続する copy だけを併合し、4 MiB の buffer で運ぶ。隙間と未移動の payload は読まない。
改名する local header は一度だけ読み、同長かつ未移動なら header を patch、他は header の後に
payload から `recordRange.upperBound` までをコピーする。descriptor の長さは算出しない。
ZIP64 extra・sentinel・disk start が不要で、reader とサイズが一致する canonical な CD は、
元の byte をコピーして local offset だけを patch する。他は従来の再符号化を行う。
同長改名だけで、全 record が未移動、CD の手前に隙間がなく、全 CD が canonical、
改名後も CD の名前の byte 長が同じ、かつ終端が従来の再生成結果と完全一致するときは、
local と CD の改名箇所だけを patch して同期する。CD 全体の再出力と truncate は行わない。
改名時だけ UTF-8 / NFC / bit 11 を使い、旧 Unicode Path extra は長さを保った padding にする。
その本文は CRC・旧名を含めてゼロで埋める。重複・未知 version の field も同様に扱う。
他の名前を持つ既知の extra（0x0008 / 0x2605 / 0x334D / 0x4F4C / 0x554E）や
非ゼロの未解析末尾がある場合、metadata を黙って捨てず改名を拒否する。
CD の各 ZIP64 size / offset は独立判定する。central だけで wide descriptor を宣言していた
entry は、値が小さくなっても空の ZIP64 marker を残して KaitoKit の幅の解釈を維持する。
逆に ZIP32 descriptor に offset 用 ZIP64 extra が初めて必要になる移動は拒否する。
KaitoKit 0.4.0 がこの extra も wide 判定に使うためで、descriptor の独自変換はしない。

削除だけでは名前予約表を作らない。ZIP の open 時の entry が 2,048 件以上なら、追加・改名の
名前検査を合計 4 回まで `LiveNameCheck` の走査で行う。最初の走査で元の名前を UTF-8 の平らな
snapshot に一度だけ写し、削除・改名した index の除外配列、改名後の名前、追加済みの名前を
別に照合する。ASCII で空成分のない名前は byte と `/` の境界で比較し、それ以外だけ NFC の
比較 key を持つ。改名の予約表は空成分を残し、writer の必要 directory は空成分を除くという
従来の違いも保つ。改名は祖先 file、同名、子孫の順、追加は同名、子孫、祖先 file の順に拒否する。
5 回目以降は必要な側の既存の表を作り、改名は `EditPathReservations` を差分更新する。
削除がないときの生存名一覧は元の順で作り、改名した index だけを差し替える。
少数の改名の後に表へ切り替えても、全件に対する改名辞書の検索を加えない。
2,048 件未満では初回から従来の表を使う。TarUpdater・CompressedTarUpdater には適用しない。

writer の正規化・名前の予約は internal `reserveEntryName(_:directory:)` 一か所に置き、
`addEntry` が呼ぶ。ZIP updater だけが internal `existingPathCheck` を設定し、走査中は元の名前を
writer の集合に入れない。budget を使い切った次の追加で既存名を補い、hook を外す。
後続の一括追加も同じ関数を同じ順に呼び、budget・例外・集合の更新順を共有する。

追加が混在するときは、最初の add の前に詰めた位置を予測して、その位置へ追加 record を書く。
writer の仮想 offset は旧 CD offset を基準にし、従来の local header の version も保つ。
commit で追加 pipeline を drain し、生存 record を移動してから CD と終端を一度だけ書く。
writer が上書きした範囲 W と交差する生存 record は、同じ位置に残る場合も source から復元する。
追加の後に予約を変えて予測位置が変わった場合だけ、出力の段階 snapshot を作り、追加 block を
そこから最終位置へコピーする。全 N 件の段階 reader と二度目の raw walk は不要になる。
追加 M 件は出力 descriptor で header の完全一致と連続性を確認し、その block と仮想の CD・終端を
提示する ByteSource を KaitoKit で開いて raw name・サイズ・local/payload 範囲・descriptor 不在を照合する。
追加 payload の CRC は従来どおりここでは展開検証しない。

計画は 4,096 件ごとと計画直後、実行直前、コピー・書込み chunk ごと、公開直前に取消しを確認する。
CD 側の改名拒否は実行中の I/O エラーより先に判定する。混在時も既存 N 件と追加 M 件を別々に検査するため、
従来の段階 reader が N+M 件に課していた entry 数・metadata の上限による拒否はなくなる。
呼出側による公開前の全体検証は維持する。今日 commit が成功する入力の出力 byte は変えない。

### 作業ファイルへの直接出力と進捗

`ArchiveUpdater.open(url:output:options:)` の output は既存であってはならず、親は呼出側が用意する。
省略時の原本置換は従来どおり。指定時は原本を O_RDONLY | O_NOFOLLOW で開き、immutable / append の
UF/SF flags があれば何も作らず EPERM を返す。開いた descriptor から `fclonefileat` で output の隣に
source snapshot を作り、flags を 0 にする。以後の門番・reader・validate・rebuild・CD 読取はこの descriptor
だけを使う。ENOTSUP / EXDEV だけは原本への直接読取へ戻り、他の clone エラーは失敗にする。
この処理は形式に依存しない internal の `ArchiveSourceSnapshot` で、拡張子を指定できる（後続の tar 用）。

最初の add または commit で snapshot の descriptor から output を clone し、snapshot がない場合は
原本を copyItem する。変更がなくても output は作る。作成前後と commit の開始・終了直前に原本の
同一性を確認し、snapshot があればその同一性も確認する。output は flags 0、mode 0600 にして開き、
fstat と lstat の dev/ino を照合する。成功時は fsync・close 済みで返す。xattr・quarantine・作成日は
clone のまま保持し、mode・属性の復元と公開の rename は呼出側が行う。output mode では
replaceItemAt と itemReplacementDirectory を使わない。取消し・失敗・破棄時は、自分が作った output と
snapshot の dev/ino が一致する場合だけ消す。成功時も snapshot を消す。ZipCrypto spool は隣に作り直後に unlink する。

`commit(progress:)` は同期的に `CommitProgress(completedBytes:totalBytes:)` を通知する。
追加 pipeline の drain 後に計画から total を決め、実行前の 0、4 MiB 以上進んだ時、最後の完了値を通知する。
この段階では total は commit 中の移動・patch・CD・終端の書込み byte であり、drain 中の追加 data は含まない。
callback を呼出しの外に保持せず、throw は取消しと同じく原本を保って作業ファイルを片付ける。

### 追加・書き直しと圧縮待ちの byte 進捗（P6-G）

`ArchiveEditing.add(contentsOf:as:ownerIDs:progress:)` と writer の `add(contentsOf:as:progress:)` は、
一回の呼出しで読む通常ファイルの byte を数える。通常ファイルの total は lstat の size、symlink は 0。
directory は progress があるときだけ、追加と同じ名前順・symlink を辿らない lstat の事前走査で合計する。
元の lstat / 出力との同一性、O_NOFOLLOW と fstat、読後の fstat の順序は維持する。
事前走査後の子孫の変更は既存の検査で扱い、観測値は total へ clamp する。progress が nil のときは
事前走査・meter・追加の read wrapper を作らない。数える時点は writer へ渡した時なので、圧縮完了前に最終通知が来る。

新しい session は既存の `ArchiveUpdater.CommitProgress` と `CommitProgressMeter` を使い、最初の
`(0, total)` で total を固定する。completed は単調で total 以下、成功時の最終通知は一度だけ
`(total, total)`（total が 0 なら開始と完了の二回）。通知は 4 MiB 以上の前進時と開始・完了で、
回数は `ceil(total / 4 MiB) + 2` 以下。callback は呼出側の thread で同期実行し、保持しない。
throw は元の error のまま失敗し、既存の cleanup 契約に従う（単体 ZIP writer の部分出力は呼出側が削除する）。

`ArchiveAddition` の配列を `add(_:events:)` に渡すと、小さな通常ファイルを並列に先読みする。
項目別 API の同期性は変えず、同じ項目・日時・乱数を使う列と出力 byte を一致させる。
空配列は writer、全 updater、rewriter、protocol の既定実装のいずれでも完全な no-op。
状態・取消しの検査より前に戻り、writer や一時出力を準備せず、待ち入力を drain せず、events も通知しない。
追加を閉じた後や commit / finish・失敗の後も同じで、追加口や失敗状態を変えない。
`finishAdditions` / `commit` / `finish` の動作・commit strategy・出力 byte は呼ばなかった場合と一致する。
`ArchiveAdditionEvent` は呼出しの thread だけで同期通知し、保持しない。`willStart(index:)` は
その項目の lstat より前、progress の session と `didFinish(index:)` は index の昇順になる。
先読みした項目は受取時に (0, T) と (T, T) を通知する。directory の再帰と大きなファイルは
既存の読取経路へ戻り、tar の圧縮 buffer は途中で drain しない。

窓は `resolvedCompressionThreads` 件以下。open から close の並列数は Step 0-P7 で採った
`min(threads, 4)` とし、ZIP deflate は `deflateBlockSize`、他は 1 MiB 以下だけを先読みする。
ZIP bzip2 / XZ の通常ファイルは大きさにかかわらず項目別の streaming 経路を使う。
worker は O_NOFOLLOW の open、dev/ino/mode/size/mtime の fstat 照合、厳密な長さと EOF、
読後の fstat を経てから内容を返す。hook は仕事の作成時に capture する。取消し・失敗では
未着手の仕事を放棄し、着手済みの仕事が descriptor を閉じるまで合流してから戻る。
ZIP は block と file を同じ順序付き pipeline に入れ、完成した単一 block の local header と
payload を一度に書く。deflate の stream は pthread ごとに reset して使い、destructor で解放する。

名前の検査は `reserveEntryName` 一か所のまま、一括では open の前に予約する。
同じ項目に名前と読取の二つの問題がある場合、項目別 API と原因の優先順が変わりうる。
ZIP updater の走査 budget と回数は保ち、表への切替え時には窓内の予約名も取り込む。
`ArchiveAdditionError` は最小の失敗 index、path、sourceURL（再帰では失敗した子孫）、underlying を持つ。
呼出側の準備で失敗しても先行する結果を順に確かめ、より小さい index の失敗を優先する。
取消しと events の throw は包まず返し、writer/editor を failed にする。
rewriter の `.end` は add では記録して二つの (0, 0) を通知し、commit で期待 signature 付きの
内部 batch に渡す。commit の byte meter と既存の error は保つ。

`finishAdditions(progress:)` は受取済みで未出力の入力を drain し、追加口を閉じる。終端は finish / commit が書く。
total は開始時の組立中 buffer と pipeline の未出力重みの和。tar の入力重みには header と padding も含む。
出力ごとに重みを進め、tar の組立中 buffer は終端前と同じ境界で送る。gzip の辞書も維持するので、
呼ぶ場合と呼ばない場合で出力 byte は一致する。二度目は `(0, 0)` を二回通知する。
閉じた後の add（空配列を除く）・add(data:)・addDirectory は perform の catch の外で invalidState を返し、instance を失敗にしない。
writer の addEntry も単一の `reserveEntryName` / `existingPathCheck` より前に閉鎖を検査する。
削除・改名・commit は引き続き可能。既存 updater の commit の total・通知・strategy は変えない。

検証済み options の `maximumPendingInputBytes(for:)` は、並列数 `t = resolvedCompressionThreads` と
以下の形式別定数から決まる。tar.xz は P14 の配置を使う。

| 形式 | 上界（byte） |
|---|---|
| ZIP stored | 0 |
| ZIP LZMA / Zstandard / PPMd | `t > 1 ? t × 16 MiB : 0`（tは項目窓の予算で解決） |
| ZIP / 非solid/filterなし7z BZip2 | `max(項目窓の上界, (t+1) × 8 MiB)` |
| ZIP Deflate | `t × DeflateBlock.size`（ZipCrypto は 0） |
| ZIP XZ | `max((t + 1) × 片, 項目窓の上界)`（大項目は終了時にblockを全て出力） |
| tar | 0 |
| tar.gz | `(t + 1) × DeflateBlock.size` |
| tar.bz2 | `(t + 1) × (5 × bzip2Level × 100,000)` |
| tar.zst | `t × max(4 MiB, level の window)`（t はメモリ予算で解決） |
| tar.xz | `t × 16 MiB + 4 MiB + (t > 1 ? (t + 1) × 64 KiB : 0)` |
| 7z LZMA2 | `t × 16 MiB` |
| 7z Deflate | `t × 1 MiB` |
| 非solid/filterなし7z LZMA / PPMd | `t > 1 ? t × 16 MiB : 0` |
| 非solid/filterなし7z Copy | 0 |
| 7z solid / filter | `f × (solidならblockSize、非solidなら16 MiB)`（disk上の入力。fはfolder窓）BZip2はさらに`(t+1+f) × 8 MiB` |
| LHA LH5 / LH6 / LH7 | `t > 1 ? max(項目窓の上界, t × (1 MiB + 8 / 32 / 64 KiB)) : 0` |
| LHA stored | 0（同期処理） |

tar.xz は通常 block が最大 t 個、軽量 block と合わせて最大 `2t + 1` 個。最大 byte は通常 t 個と
軽量 `t + 1` 個で得られる。add から戻ると大きな member の header 群と本文は既に送信済みで、
組立中は小さな member の packing 上限 4 MiB 以下。t = 1 は 20 MiB、t = 8 は 132.5625 MiB。
drain の加算は item 単位で、packed block は 4 MiB 以下、大きな piece は 16 MiB 以下、軽量 block は 64 KiB 以下。
4 MiB は中間通知の最小間隔であり、16 MiB piece を一度に加算する場合は未通知分と合わせて 20 MiB 未満の前進になる。
rewriter の最後の finish は、実際の待ちより大きかった D の予算の残りも完了にする。

rewriter の `.end` は add 時には記録して `(0, 0)` を二回通知し、`readsAdditionsDuringCommit` が true。
`.beginning` は writer の追加 session を使う。rewriter の finishAdditions は自身の入口だけを閉じて
`(0, 0)` を二回通知する。carry との間に圧縮境界を作らない。
commit の total は `C + A + D`。C は生存 entry と hard link 実体化に伴う退避・再読取、A は記録した
追加の通常ファイル・data・directory 子孫の byte（beginning は 0）、
`D = min(C + A + 開始時の待ち, maximumPendingInputBytes)`。
directory・tar hard link・linkPath symlink・不明サイズ entry の読取は C に数えない。
carry と追加の後に writer を drain し、finish 後、原本の置換前に最終通知する。didCarry の回数と引数は維持する。

観測だけの既定実装は `(0, 0)` の前後で、ownerIDs が nil なら従来の二引数 add、指定時は ownerIDs 付き add を呼ぶ。
既定の finishAdditions は `(0, 0)` を二回、readsAdditionsDuringCommit は false。
open、非 clone volume で最初の追加に必要な prefix のコピー・再符号化、reader adoption、公開前の
verification open / output probe / entry comparison、公開・再読込には新しい callback を足さない。
これらの区間は呼出側が別に扱う。従来の ZIP commit では最終通知の total が変わり得るため、共通の利用側は通知ごとの比を使う。

### 編集を断る三つの門番

読み取りは従来どおり行い、**編集だけ**を断る。理由を呼出側へ返す。

- **SFX prefix 付き ZIP** —— prefix があると central directory の offset 基準がずれる。
- **EOCD の後ろに trailing data がある ZIP**。
- **`EOCD.cdOffset` が `PK\x01\x02` を指さない ZIP** —— 実測で見つけた実在の罠。
  `ditto`(Finder の「圧縮」)は 4 GiB 超の entry を ZIP64 なしで書き、
  uncompressed size / compressed size / EOCD の CD offset を mod 2^32 で切る。
  その状態で data descriptor を算術で探すと deflate stream の途中を指し、
  編集が静かに壊す。詳細は KaitoFinder の
  `Documentation/verification/2026-09-10-ditto-zip64.md`。

## 7. KaitoKit の raw record API と ZIP layout SPI

ZIP updater は `@_spi(ZipRawLayout) internal import KaitoKit` で `ZipRawRecordLayout` と
`ArchiveReader.zipRawRecordLayout(at:)` を使う。公開の rawRecord と同じ local・descriptor 検査を保ち、
String 辞書と entry 全体の等値比較を作らず、範囲 2 つと descriptor・central/local ZIP64 の有無を受け取る。
この型は KaitoKit 側の public init を必要とせず、GK 内では internal な検証済み layout に写す。

試験用 `@_spi(Testing)` は `ArchiveUpdater.CommitStrategy`（unchanged / appendOnly / inPlacePatch /
rebuild / rebuildThenAppend / stagedRebuild）と `lastCommitStrategy` だけを公開する。
KaitoKit 0.11.0 以降が SPI を提供するため、GyoshukuKit 0.8.0 の URL 依存は
`.upToNextMinor(from: "0.12.0")` とする。開発中は sibling の KaitoKit を使い、manifest の自動選択規則は変えない。

従来の public rawRecord API（0.4.0）は引き続き利用できる。

削除・改名で生き残る entry を再圧縮せずに運ぶには、生 record の範囲が要る。
`ZipReader` は `localHeaderOffset` / `dataOffset` / `compressedSize` を private に
持っているため、追加の公開 API を KaitoKit 0.4.0 で提供する。

```swift
public struct RawEntryRecord: Sendable {
    public let recordRange: Range<UInt64>   // そのまま運ぶ範囲(data descriptor 含む)
    public let payloadRange: Range<UInt64>  // 検証用。圧縮データ本体だけ
    public let formatSpecific: [String: String]
}
public func rawRecord(of entry: ArchiveEntry) throws -> RawEntryRecord?
```

**終端の算出は KaitoKit にやらせる**のが要点。ZIP の data descriptor は
signature の有無と ZIP64 かどうかで 0 / 12 / 16 / 20 / 24 byte と変わる。
呼ぶ側にこの算術をやらせると writer と reader で解釈がずれる。

これは段階 1 の**追加**では不要で、**削除・改名**に入るときに必要になる。
GyoshukuKit 側でこの accessor を利用し、KaitoKit の source は変更しない。

## 8. 暗号化出力（2026-09-15）

`WriterOptions.password` は nil なら平文。空文字列は `invalidOption("password")`、
tar / tar.gz / LHA の指定は `unsupportedOption("password")` にする。
`encryptsSevenZipHeaders` の既定は false、パスワードなしの true は invalidOption。
ZIP の既定は `ZipEncryption.aes256`、互換性のため `.zipCrypto` も選択可能。
writer / updater / rewriter は同じ検証関数を使い、出力作成前に検証する。

### ZIP WinZip AES-256

通常ファイルだけ（空ファイルを含む）を暗号化する。directory / symlink は平文の stored。
圧縮方式は既存の拡張子 heuristic と stored / deflate / bzip2 / lzma / zstd / xz / ppmd 設定を使い、両 header の method を 99、
version needed は方式との最大値（LZMA / Zstandard / PPMd は63、それ以外は51）、flag は bit 0 + bit 11（LZMA はさらに bit 1）にする。0x9901 の 7 byte 本体は、vendor version、
`AE`、strength 3、実際の圧縮 method。20 byte 未満を AE-1 と実 CRC、以上を AE-2 と CRC 0 にする。
これはこの writer の選択方針で、AE-1 / AE-2 の wire format は公開仕様に従う。

UTF-8 パスワード + 16 byte のランダム salt を PBKDF2-HMAC-SHA1（1000 回）へ渡す。
66 byte の結果を AES key 32 byte、HMAC key 32 byte、password verifier 2 byte に分割する。
payload は salt / verifier / ciphertext / HMAC-SHA1 の先頭 10 byte の順。compressed size は全体
（圧縮結果 + 28 byte）。CTR は 1 始まりの 128 bit little-endian counter を CommonCrypto の
ECB で暗号化し、chunk 境界の鍵流の端数を次回へ持ち越す。HMAC の対象は ciphertext のみ。
ZIP64 予約長の計算にも暗号化 overhead を含め、local header は seek して patch する。

### ZIP ZipCrypto

PKWARE traditional encryption の 3 個の UInt32 鍵を UTF-8 パスワードで初期化する。
bit 3 がない場合、12 byte の encryption header の末尾は CRC の最上位 byte なので、
データを書き始める前に CRC が必要になる。圧縮 / store と CRC 計算を先に行い、圧縮結果だけを
出力の隣の `mkstemp`（mode 0600）へ保存する。CRC と packed size の確定後に local header、
11 byte の乱数 + CRC 上位 byte を暗号化した header、spool を暗号化した payload の順に出力する。
compressed size は spool + 12 byte。deinit による失敗時の削除と、成功時の明示的な close / unlink
を持ち、一時ファイルの I/O エラーは `WriterError.io` にする。

両 ZIP 方式とも **data descriptor は書かない**。既存の seek / patch と updater の layout 契約を
維持するためで、ZipCrypto の spool はそのために必要になる。AES は spool を使わない。

### 7z の圧縮方式・AES-256 と header

既定は非空 stream ごとに non-solid folder を作る。`WriterOptions.sevenZipMethod` は `SevenZipCompressionMethod` の
LZMA2（既定）/ LZMA / Deflate / BZip2 / PPMd / Copy を選ぶ。ZIP の `compressionMethod` と拡張子 heuristic から独立させる。

| 方式 | method ID | properties | level と stream |
|---|---|---|---|
| LZMA2 | `21` | dictionary size の1 byte | nil は従来の Apple、レベル指定時は自前 encoder |
| LZMA | `03 01 01` | lc/lp/pb + 辞書 LE32 の5 byte | 自前 raw LZMA1、一つの同期 stream、EOS 無し |
| Deflate | `04 01 08` | 無し | `deflateLevel`（0...9）、一つの raw deflate stream |
| BZip2 | `04 02 02` | 無し | `bzip2Level`（1...9）、folder ごとに単一 bzip2 stream |
| PPMd | `03 04 01` | order byte + memory LE32 の5 byte | `ppmdLevel`（1...9）、自前 var.H、folder ごとに単一 stream |
| Copy | `00` | 無し | 入力をそのまま保存。無圧縮 level 用 |

method ID と coder の flags は `inbox/lzma-sdk-26.03/DOC/Methods.txt` と `DOC/7zFormat.txt` で照合する。
`SevenZipEditModel.Coder` は method ID の byte 列・任意の properties・入出力数を持ち、writer と updater は
`SevenZipHeaderSerializer.coder` で共通に直列化する。LZMA・PPMd・BCJ / ARM64 / Delta も同じ表現で記録する。
`SevenZipChunkPipeline` は既存の `OrderedChunkPipeline` 上で LZMA2 と Deflate を並列化する。
Deflate は `DeflateBlock` の最大1 MiB入力と直前の末尾32 KiBを辞書に使い、最後だけ Z_FINISH、
中間は Z_SYNC_FLUSH で一つの byte-aligned raw stream に連結する。7zz の検査・展開で受理を確認する。
LZMA は `LZMAEncoder` を folder ごとに保持し、size を expectedSize に渡して EOS 無しで一度だけ finish する。
solid folder の再圧縮と追加も WriterOptions 全体を FolderEncoder に渡すので方式・level・extreme が揃う。
header の再圧縮は従来の Apple LZMA2 の設定を保つ。
BZip2 は `ParallelBzip2StreamEncoder` をfolderごとに持ち、blockを並列圧縮して単一streamへspliceする。
PPMd は `PPMd7StreamEncoder` の状態を folder ごとに持つ。properties は stream の外側の coder に書き、
folder の展開サイズで終端を知るため EOF を書かず5 byte flush を一度だけ出力する。
order は2...32、encoder の対応メモリは1...1024 MiB。solid は block 全体を一つのモデルで符号化する。
BCJ / ARM64 / Delta の出力を PPMd に渡し、その圧縮 byte に AES を適用する。header 暗号化は従来の経路を使う。
updater の新規追加と solid の一部削除の再圧縮、rewriter は同じ properties を渡す。
7zz は `PPMD:o6:mem24`（16 MiB）、`PPMD:o16:mem192m`（192 MiB）のように表示する。
Copy は同じ I/O 境界で同期出力する。LZMA2 の既定 byte 列は凍結済み hash と既存試験で固定する。

`ppmdLevel` の preset は GyoshukuKit の定義で、既定の6は encoder の既定 order / memory と一致する。
`ppmdOrder` / `ppmdMemoryMiB` はそれぞれ独立に preset を上書きし、出力を作る前に形式ごとの範囲を検証する。

| level | ZIP var.I order | 7z var.H order | model memory（MiB） |
|---|---|---|---|
| 1 | 3 | 3 | 1 |
| 2 | 4 | 4 | 2 |
| 3 | 5 | 4 | 4 |
| 4 | 6 | 5 | 8 |
| 5 | 8 | 6 | 16 |
| 6（既定） | 8 | 6 | 16 |
| 7 | 10 | 8 | 32 |
| 8 | 12 | 12 | 64 |
| 9 | 16 | 16 | 192 |

モデルは ZIP の entry / 7z の folder につき一つ。指定 model memory と固定の頻度表・64 KiB出力 buffer・
256 KiB I/O buffer を使い、入力全体を保持しない。メモリ不足時はモデルを restart する。
一つのモデル内では片を並列化せず、`compressionThreads` / LZMA用`memoryLimit`はモデルサイズに作用しない。
16 MiB以下の非solid項目とsolid/filter folderは独立モデルで並列化する。モデルのメモリはpending inputに含めない。
同時モデル数はモデルメモリと項目入力の予約で物理メモリの50%以下に抑える。

実測した `7zz a -p... -mhe=off -mhc=off` と
同じ decoder 順で AES（06 F1 07 01）を coder 0、選択方式を coder 1 に置く。Copy も同じ chain を使う。
bind pair は input 1 ← output 0、packed input は暗黙の 0。unpack sizes は AES 出力である
圧縮結果の真の長さ、選択方式の出力であるファイル長の順で、substream CRC は元ファイルの CRC。

AES property は `53 0F` + 16 byte IV（NumCyclesPower 19、salt なし）。UTF-16LE パスワードと
8 byte little-endian counter を 0 から 2^19 - 1 まで連結して SHA-256 へ入力し、鍵を得る。
同じ鍵は書庫内で再利用できるが IV は毎回乱数で生成する。AES-256-CBC は PKCS#7 を使わず、
最後の block の不足だけを zero pad する。真の圧縮長を AES の unpack size に記録する。
空ファイル・directory は従来の EmptyStream / EmptyFile 表現を使う。

nil レベルの LZMA2 の `SevenZipChunkPipeline.chunkSize` は **16 MiB**、I/O 用の `IOChunk.size` は **256 KiB** と分離する。
短い read が返っても最大 16 MiB まで入力を集めてから Apple の LZMA buffer API を一度呼ぶ。
各片の LZMA2 辞書 reset を残して終端 byte だけを取り除き、最後に一度だけ終端を書く。
圧縮出力も 256 KiB ごとに分割して暗号化・書込を行う。一つの folder 内で decoder が reset する
正当な stream であり、既定の non-solid・filter 無しの平文・暗号出力は spool 不要。

自前 LZMA2 は選んだ辞書 property を保持し、辞書が16 MiBより大きいと片を3倍にする。
encoder closure は片ごとに新しい encoder を作り、辞書 reset を残して連結する。
並列数と memoryLimit は自前 encoder 節で解決し、`maximumPendingInputBytes` は t × 片。
raw LZMA の単一streamは256 KiBずつ同期入力する。非solidの項目窓を使う場合はその保持入力を数え、
solid/filterでは下記のfolder窓のdisk入力を数える。単一stream内のchunk並列化は行わない。

`sevenZipSolid: .off` と `sevenZipFilter: .none` は従来の writer 経路を保持する。
それ以外は `SevenZipBlockWriter` が入力順に非空 file を集め、`ScratchFile` に256 KiBずつ流す。
solid の上限は `blockSize` と `filesPerBlock`。nil のサイズは
`min(4 GiB, max(64 MiB, dictionary × 2))`、件数は1,000,000とする。
Apple LZMA2 と他の方式の基準辞書は8 MiB、自前 LZMA / LZMA2 は指定 level の辞書、PPMd は model memory。
次の file が上限を越える前に folder を閉じ、file 自体は分割しない。上限超過 file は単独にする。
空 file / directory は EmptyStream のままで、件数とサイズには数えない。拡張子による並べ替えは行わない。
folder の全サイズ確定後に `SevenZipFolderEncoder` を使うので raw LZMA の expectedSize も既知となる。
圧縮前と圧縮後のfolderをunlink済みspoolで保持し、投入順に出力する。
未出力folderと組立中folderを合わせt枠以下（tは要求数・GCD poolの安全上限・メモリ予算で解決）。並列投入する各入力はsolidならblockSize、非solid/filterなら16 MiB以下。
blockSizeが256 MiBを超える場合とfilterなしCopyはfolder間の並列化を使わず、従来の同期経路へ戻す。
従って並列入力spoolの一時disk上界はt × blockSize（非solid/filterはt × 16 MiB）。tは要求数・GCD poolの安全上限・メモリ予算で解決する。
圧縮出力は各folderの最初の1 MiBをメモリに保持し、超過時だけspoolへ移す。
通常の作業disk合計はこの入力上界と、未出力folderの圧縮長の合計（AESのpaddingを含む）。
fileを分割しないため、組立中の単一fileが入力上限Lを超える場合だけ、入力disk上界にmax(0, fileSize - L)を加える。
圧縮長に入力長の定数倍という仮定は置かない。同期経路の上限超過単一fileは入力spool一つと有界codec状態を使う。
最終folderのflush時に他のfolderが無ければ同期経路で全threadsを使う。
workerの内部並列数は実際の片数と未割当数でも制限し、未出力jobの割当合計を要求threadsと予算内codec数の小さい方以下に保つ。出力開始時に予約を返す。各枠のcodec状態はfolder上限に入る最大片数分だけ予約する（単一stream codecは一つ、BZip2は既存splice予約）。
上限を超える単一fileは前のfolderを出力し、既存の有界stream経路を使う。
`pendingInputBytes` / `maximumPendingInputBytes`はdisk spoolの未圧縮byteも数える。
`finishAdditions`は残るblockを閉じ、順に出力した入力byteを呼出側の進捗へ通知する。finishだけの場合と出力byteは同じ。

folder 一つに pack 一つ、非空 file ごとに substream 一つを対応させる。
`SevenZipHeaderSerializer` は `NumUnpackStream (0D)` と、各 folder の最後以外の substream size (09)、
元 file の CRC (0A) を `SubStreamsInfo` に書く。folder CRC は省略する。
updater の追加帳簿にも folder 定義と folder 内の substream 添字を渡し、元 folder には結合しない。

`SevenZipFilterEncoder` は public domain SDK 26.03 の `C/Bra86.c`・`C/Bra.c`・`C/Delta.c` と
KaitoKit `Codecs/SevenZipFilters` の逆変換を基準に、Swift で前向き変換する。
BCJ x86 は `03 03 01 03`、ARM64 は新しい `DOC/Methods.txt` の `0A`、Delta は `03`。
x86 は E8/E9 候補 mask と25 bit符号拡張を持ち、ARM64 は BL と範囲を限定した ADRP を変換する。
Delta は元 byte の履歴から距離1〜256の差分を取る。properties は距離−1の1 byte。
branch filter の開始位置が0なら properties を省略し、既存の4 byte開始位置は再圧縮でも保つ。
7zz の BCJ coder は properties を受け付けないため、新規 BCJ は開始位置0とし、開始位置保持の実ツール試験は ARM64 で行う。
命令の端数は次の I/O へ持ち越し、folder 末尾だけ無変換で出す。状態・位置は file 境界で reset しない。
decoder 順は packed → [AES] → method → filter → file、単入力・単出力の coder をこの順に置く。
bind は `input i ← output i−1`、packed input は暗黙の0。
unpack sizes は [圧縮結果の真の長さ]・folder サイズ・filter 出力の folder サイズ。
AES は folder に一つで、header の暗号化経路は本文の filter から独立する。

`.auto` は先頭64 KiB内の PE header / 単一 Mach-O / ELF64 の CPU を読む。
x86・x86_64 PE / Mach-O は BCJ、arm64 PE / Mach-O / ELF は ARM64、universal Mach-O と未判定は none。
non-solid は file ごと、solid は filter class が変わったら block を閉じる。
削除による solid の再圧縮は元の filter と開始位置を使い、指定方式だけを変更する。carry の coder・pack は保持する。
新規作成、updater の追加、7z への rewriter は同じ options と block writer を使う。

試験は全方式、Apple / 自前 LZMA2、AES / header 暗号化、複数のサイズ・件数上限、空 file / directory、
10,000小ファイル、短い read、filter をまたぐ auto block、BCJ / ARM64 / Delta の固有状態と開始位置を扱う。
必須の7zz `t / l -slt / x` と KaitoKit の byte 照合、7zz `-ms=on -mf=BCJ/ARM64/Delta:4` の逆方向、
filter + Copy の packed byte の7zzとの直接比較、実在 arm64 binary corpus の圧縮サイズ比較、既定の凍結済みhashを用いる。
2026-10-06 の `/usr/lib/dyld`・`/usr/bin/ditto`・`/usr/bin/git` の arm64 slice を入力順にまとめた
Apple LZMA2 の packed サイズは、filter 無し348,699 byte、ARM64付き329,089 byteだった。

Apple の encoder は 8 MiB の辞書を使う。16 MiB 以下のファイルは従来の whole-file buffer API と
同じ一回の圧縮なので、圧縮 payload と圧縮率は変わらない。16 MiB を超えるファイルだけ境界で
辞書の蓄積が失われる。256 KiB ごとに辞書を捨てる初期案はソースコードで出力が約倍増したため撤回した。
主な作業メモリの上限は一ファイルにつき **約 16 MiB の入力 + その圧縮出力**。別途 encoder の辞書・
framing の一時領域・256 KiB の I/O buffer があるが、いずれもファイル全体の長さに比例して増えない。
header metadata のメモリは entry 数と名前長に比例する。

header 暗号化を指定したときは通常の Header を AES-only folder に通し、その ciphertext を
全ファイルの packed data の後ろへ置く。NextHeader は `kEncodedHeader`（17）の StreamsInfo とし、
PackPos は署名の 32 byte 後を起点にした暗号化 header の位置、folder unpack size / CRC は平文 header。
StartHeader と NextHeader の CRC / offset / size は最後に確定する。名前の UTF-16LE byte は平文では残らない。

乱数は `SecRandomCopyBytes`、失敗は `WriterError.io(operation: "random", code: status)`。
AES / PBKDF2 / HMAC は CommonCrypto、7z KDF の SHA-256 は CryptoKit。依存は追加しない。
KaitoKit の内部暗号型を公開・共有せず、公開パラメータに従って GyoshukuKit 内で実装する。

### 編集と検証

updater の `options.password` は通常は追加分だけに適用し、既存 record は byte のまま運ぶ。
削除・改名だけなら ciphertext と既存 password を維持する。ZIP 全体をそろえる場合は
`reencryptExistingEntries(currentPassword:)` を一度予約する。圧縮データを作り直す必要はない。
他形式の rewriter は `password` で入力を復号し、`options.password` で出力を暗号化する。

XCTest は KaitoKit、ZIP AES / 7z AES の 7zz、ZipCrypto の unzip を oracle にする。
header byte・AE-1/AE-2 境界・誤パスワード・HMAC 改変・spool の成功/失敗時 cleanup・
更新前後の record・再暗号化・300 MiB の chunk 読取・xattr 更新を検査する。
40 MiB の固定 seed の擬似ソースコードを平文・暗号 7z の両方で KaitoKit / 7zz に往復させ、
同じ入力を Compression framework の `compression_encode_buffer` で一括圧縮した結果に対して
packed size が ±5% に収まることを確認する。参照圧縮は製品 compressor を呼ばない。
7z の5 / 16 MiBの片では short read を混ぜても一括圧縮と payload が byte 単位で一致することを確認する。
実行済みの範囲と sandbox 制限は[検証記録](verification/2026-09-15-encryption.md)へ分けて記録する。

参照: [WinZip AES 仕様](https://www.winzip.com/en/support/aes-encryption/)、
[7z format](https://github.com/ip7z/7zip/blob/main/DOC/7zFormat.txt)、
[XZ の LZMA2 decoder の reset 処理](https://github.com/tukaani-project/xz/blob/master/src/liblzma/lzma/lzma2_decoder.c)。

### ZIP の再暗号化（P1b）

予約は `adding` 状態で一度だけ受け付け、remove / rename / add との順序に依存しない。
commit の `checkUnchanged` 後、生存する既存 entry だけを計画する。通常ファイルは options の
plain / ZipCrypto / AES-256、directory と symlink は平文にする。同じ方式・同じ UTF-8 byte の
password なら運ぶだけで、実際の password は検証しない。入力の全件検証は呼出側が行う。
空書庫や変換 0 件の予約は P1-G の経路・出力 byte・strategy・進捗を変えない。

`ZipRecordLayout` は KaitoKit SPI の encryption / storedCRC32 / compressionMethod も保持する。
`ZipPlannedAction.convert` は keep・canonical CD・同長改名 patch・descriptor marker の対象外。
変換 entry は descriptor を捨てるため ZIP32 descriptor の offset 越境拒否も不要になる。
運ぶ entry には従来の拒否を残す。追加分は writer が暗号化し、変換しない。追加位置の予測が
変換でずれたときは stagedRebuild、一致すれば rebuildThenAppend、追加なしは rebuild になる。

`OrderedChunkPipeline` は `WriterOptions.resolvedCompressionThreads` 件の窓で導出だけを並列化する。
入力は KaitoKit の `ZipAESKeyMaterial.derive`、出力は GK の PBKDF2-HMAC-SHA1（1,000 回）。
reader・出力・salt の乱数・TaskLocal observer は commit の thread だけで扱う。
乱数の試験注入は P1-G と同じ `testingRandomBytes`（AES salt 16 byte、ZipCrypto header 11 byte）。
出力の材料 66 byte / salt 16 byte は連続した Data に保存し、検証後に解放する。

AES の AE-2 から平文 / ZipCrypto へ変える場合だけ、pass A で展開 CRC を先に計算する。
payload は `zipStoredPayloadStream(at:aesKey:)` から最大 1 MiB ずつ復号し、既存の encryptor へ渡す。
圧縮器や ZipCrypto spool は呼ばない。小さい record は header から認証 tag まで一度に組み立てる。
local / CD の元の名前・時刻・属性・comment・未知 extra を保ち、暗号欄とサイズだけを組み直す。
0x0001 は先頭、0x9901 は既知 field の末尾、解析できない末尾は最後に置く。改名時は既存の
Unicode 名の無効化と不透明 extra の拒否を適用する。AES → AES は AE の版を保つ。

fsync・close 後、公開前に出力を読み直す。V0 は門番・entry 数・名前・種別・方式・サイズ・CRC・
暗号状態と、GK による local / CD の照合。P1-G の追加 record 検査も残す。V1 は全変換 entry の
復号した保存 payload の長さと CRC。V2 は ZipCrypto 入力・AE-2 の pass A 対象・平文 → AE-2 で
展開を検証し、CRC のない AE-2 は入力 CD の CRC と照合する。V3 は AES 出力の先頭・末尾を含む
等間隔の最大 16 件を password から導き直して保存 byte を照合する。AE-2 の encryption key だけが
誤っても HMAC / verifier が正しければ材料経由の読取は成功するため、V3 は省略しない。

入力の wrongPassword / passwordRequired だけはそのまま返す。V2 が失敗した ZipCrypto 入力は
通常の stream で読み直し、照合 byte が偶然合った誤 password を区別する。出力検証の失敗は
`reencryptionFailed` に包み、取消しは `CancellationError` のまま返す。変換中の I/O は従来どおり。
`CommitProgress` は書込み + pass A / V1 / V2 / V3 の保存長 + 導出 1 回 65,536 の仕事量。
total は計画時に固定し、完了時の一致を確認してから公開する。失敗と取消しは作業ファイルを削除する。

実測と A2–A10 の範囲は [P1b 検証記録](verification/2026-09-25-p1b-reencryption.md) を参照。

## 9. やらないこと

- **RAR の作成**。license が
  「cannot be used to develop RAR (WinRAR) compatible archiver」と明示している。
- **SFX の作成**。macOS では成立しない —— data を追記した Mach-O は正しく署名
  できず、ad-hoc 署名の実行ファイルは Gatekeeper に拒否され、quarantine が付けば
  Apple Silicon では SIGKILL される。作っても相手の Mac で動かない。
- **sparse file の検出**。bsdtar は自動で行うが、結果は改名された entry と
  GNU.sparse.* pax record で、規約を知らない reader を混乱させる。GUI 利用者が
  踏むことはまず無い割に writer の複雑さがほぼ倍になる。

> **GyoshukuKit design (2026-09-10, first edition)**
>
> GyoshukuKit is the compression half of a pair whose extraction half is KaitoKit.
> KaitoKit is read-only by design, and adding writing to it would push writer code
> into consumers that only ever read; a separate repository makes that separation
> structural rather than asserted. It inherits KaitoKit's character: pure Swift,
> no additional external dependencies, only OS-bundled zlib, libbz2, Apple Compression
> and CommonCrypto / CryptoKit / Security
> through supported APIs — deliberately not the system libarchive, which ships no
> `archive.h` in the SDK and has no in-place update anyway.
>
> The dependency runs one way only, GyoshukuKit to KaitoKit, because updating an
> archive means reading the existing one to carry surviving entries across without
> recompressing them, and KaitoKit already has the hardened parser for that.
>
> The API mirrors `ArchiveReader`: an `ArchiveWriter` for creation and an
> `ArchiveUpdater` for add, remove and rename, committed through a temporary file
> and an atomic replace. Neither is thread-safe, matching KaitoKit's contract.
>
> Formats arrive in four stages — ZIP, then tar and the compressed tars, then 7z,
> then LHA. `CompressedTarUpdater` edits gzip, bzip2 and xz tar archives from a
> session reader's decoded image and chunk map. It carries reusable compressed
> chunks unchanged and encodes the changed regions. Inputs without usable framing
> receive a full encode into the member-aligned layout on their first edit.
> The caller must verify the output with KaitoKit's K5 before publication; a full
> verification open is the fallback only when K5 reports `baseNotSpliceable`.
>
> Defaults are chosen so a recipient on Windows is not inconvenienced: UTF-8 names
> with bit 11 and NFC normalization, UNIX host byte so POSIX modes and symlinks
> survive, no data descriptors written but always parsed because `ditto` emits
> them, no macOS metadata in tar by default, and no owner names leaked.
>
> Stage-one append clones the archive with APFS, leaves old local records at
> their original offsets, writes new local records at the old CD offset, then
> copies the old CD bytes verbatim and emits the new CD and combined end records.
> ZIP64 appears whenever the combined values require it. No descriptor scanning
> or existing-name re-encoding is needed. Commit uses `replaceItemAt`, immediately
> restores POSIX permissions and restores quarantine when originally present.
> Stage three (0.3.0) uses KaitoKit 0.4.0 raw records for deletion and renaming,
> rebuilding the complete CD with new offsets and independent ZIP64 fields.
> Indices remain stable from open, and subtree policy belongs to the caller.
> Equal-length local renames patch headers; different lengths re-emit headers
> while copying stored payloads and descriptors. Only authored names gain UTF-8/NFC.
> Mixed additions are completed in the clone and read from a separate snapshot
> during rebuilding. Cancellation and failure discard the working copies.
> A ZIP32 descriptor gaining an offset-only ZIP64 extra is refused because
> KaitoKit 0.4.0 would reinterpret the descriptor width; the original remains intact.
> Editing is refused — while reading still works — for SFX-prefixed ZIPs, ZIPs
> with trailing data after the EOCD, and ZIPs whose declared central-directory
> offset does not point at a `PK\x01\x02` signature, the last being a measured
> trap: `ditto` writes entries above 4 GiB with no ZIP64 at all and truncates
> three separate values mod 2^32.
>
> Remove and rename use the KaitoKit 0.4.0 accessor, `rawRecord(of:)`,
> exposing the byte range of an entry's stored record with the data-descriptor
> arithmetic done on KaitoKit's side so writer and reader cannot disagree. Stage
> one does not need it. GyoshukuKit does not change KaitoKit's source.
>
> Password output supports ZIP WinZip AES-256 or ZipCrypto, plus 7z
> AES-256-CBC and optional encrypted headers. ZIP still writes no descriptors;
> ZipCrypto spools compressed bytes to learn the CRC first, while AES streams.
> 7z bounds its LZMA2 input to 16 MiB while I/O and encryption stay at 256 KiB.
> Files up to 16 MiB retain the whole-buffer compression ratio; larger files reset
> the dictionary at chunk boundaries. A 40 MiB corpus guards packed size within
> 5% of whole-buffer Apple compression. Updaters encrypt additions by default and can explicitly
> re-encrypt existing ZIP payloads without recompression. Rewriters separate input and output
> passwords. File-change checks exclude ctime to allow Finder tag and xattr updates.
>
> Three things are deliberately never done: writing RAR, whose licence forbids it;
> creating self-extracting archives, which cannot be validly signed on macOS and
> would be killed by Gatekeeper on the recipient's Mac; and sparse-file detection,
> which roughly doubles writer complexity for a case a GUI archiver's users
> essentially never hit.

### P5-G: 共有出力の scratch segment（S24-c1）

2026-09-26 のオーケストレータ修正により、`OutputSegment.scratch(ScratchFile, Range<UInt64>)`（当時の名は `SplicedSegment.scratch(SplicedScratchFile, …)`）を追加する。
`makeScratch` の append-only な同じ object（`===`）と同じ範囲は同じ byte を表す。
sequential mode の `beginAppend` が既に書いた prefix は、その組が同じなら commit で再利用する。
範囲外・別の出力部品に属する scratch は `outputVerificationFailed`。scratch は snapshot の範囲ではないので
clone による省略や V5 の対象ではなく、形式側の検証が担う。`generated` の closure は比較できないため、従来どおり
変更ありとして保守的に再配置する。tar / LHA の source・literal の意味は変えない。

### P5-G: SevenZipUpdater

`SevenZipUpdater.open(url:password:output:options:)` は `ArchiveReencrypting` に適合する。
この protocol は `ArchiveEditing` と `reencryptExistingEntries(currentPassword:)` の契約をまとめる。
ZIP の `ArchiveUpdater` は既存のメソッドで適合し、処理は変えない。7z の ownerIDs は nil だけを受け付ける。
公開する前の KaitoKit による全体の検査・計画との照合、原本の mode / xattr / 作成日の復元、公開は呼出側の責務。

open は P1-G の descriptor 起点の `ArchiveSourceSnapshot` を使い、KaitoKit の
`@_spi(SevenZipEditLayout)` を有効にして同じ snapshot を解析する。共有の表現可能性検査に加え、
追加位置 `.beginning`、分割巻名、SPI snapshot 不在、SFX、表現できない header property、
非 0 の main packPosition、entry / file / folder / substream / pack の不一致を、変更前に
`UpdaterRouteError.requiresRewrite` で返す。`assess(reader:)` は既存 reader の構造だけを判定する。
KaitoKit 0.11.0 の P5-K SPI が必要。Package.swift の tag 依存は
`.upToNextMinor(from: "0.12.0")` とし、リリース順は KaitoKit 0.12.x → GyoshukuKit 0.8.0 → KaitoFinder 0.6.0 とする。
KaitoKit は既存の0.12.xを使う。製品ソースは v0.12.1 以降変わっていないため、今回再リリースしない。

生存 file は元の順、追加は呼出し順で末尾へ置く。運ぶ folder の圧縮 byte、coder と props、bind、
packed input、unpack size、CRC、AES の IV を保ち、file の UTF-16LE の生の名前、FILETIME、属性、
empty / anti / StartPos も保つ。改名だけは NFC と directory の末尾 `/` を適用し、同じ正規化名への
改名は元の byte のままにする。予約と衝突判定は既存の共通部品を使う。

全部を削除した folder は落とし、solid の一部だけを削除した場合は、その folder 全体を順に復号して
CRC を照合し、生存 file を元の順の一つの `options.sevenZipMethod` の folder に作り直す。他の folder は復号しない。
AES の folder は暗号化の予約が無ければ AES のまま。作り直しの出力は `makeScratch` に先に書いて長さを
確定し、S24-c1 の `.scratch` で写す。後続 pack は新しい位置へ写す。生存 stream が 0 byte だけの場合も
選択方式の空 stream と各 substream の CRC を持つ folder を書く（LZMA2 は `00`、Copy の packed size は0）。
folder ごとの作り直し・AES 変換・password 検証の状態と encryptor は `SevenZipFolderWorkset` が持ち、`SevenZipUpdater` は
追加・commit・自己照合のライフサイクルと出力だけを担う（2026-09-29）。
`SevenZipFolderEncoder` は writer と同じ方式・level・AES の出力規則を使う。新規追加と 7z への rewriter も
`options.sevenZipMethod` に従う。圧縮 header は従来の LZMA2 の1 MiBの片を使い、本文の選択方式から独立させる。
既定 LZMA2 の writer の出力 byte は変えない。

最初の add は共有部品の `beginAppend` の dup descriptor へ直接書く。追加専用 writer は
`endEntries` で記録を返し、header を書いたり output を閉じたりしない。sequential の場合は先に prefix を
書く。予約が変わらなければ同じ scratch object / range を再利用する。後から予約が変わった場合は、
共有部品が追加済み pack を spool に退避して再配置する。output の作成、clone、copy、fsync、開始 header
の finalPatch、切詰め、進捗、V5、cleanup は `SegmentedArchiveOutput` だけが行う。空 file の仮 inode は記録せず、
FAT32 / exFAT でも現在の fd と path の同一性で自分のファイルだけを消す。

暗号化の予約では圧縮済み stream に AES を付与・解除・掛け直しし、再圧縮しない。packed input が 1 本で、
AES があればそれを直接読む 1 入力 / 1 出力である folder に対応する。複数 pack の BCJ2 は運べるが変換できず、
`assess.canReencrypt` で分かる。暗号化の予約が無ければ部分的な暗号化はそのまま保つ。
入力の header は open の password、その後の変換・solid 再圧縮は予約の currentPassword、出力は options.password を使う。
変換する AES folder はそれぞれ先頭 64 KiB まで復号して password を確かめる。
7z AES は認証を持たず、64 KiB を越える AES + Copy の entry では誤った currentPassword をこの確認だけでは検出できない。
短い entry は最後まで読むので CRC が照合される。同じ UTF-16 password の carry は復号しない。
呼出側の全件検査を省略してよいという意味ではない。

header は元が平文 / Copy なら平文、元が圧縮されていれば LZMA2 にし、AES の有無は
`encryptsSevenZipHeaders` に従う。ただし暗号化の予約なしに元の暗号化 header を平文にする設定は
`invalidOption("encryptsSevenZipHeaders")` で失敗する。property の相対順、元に kDummy がある場合の整列、
定義されている digest の bit を維持する。平文 header は 16 MiB まで。開始 header は version 0.4。
file 0 件の平文 header は `01 05 00 00 00`（7zz / bsdtar / KaitoKit が受理）。既存 writer / rewriter の
空出力 `01 00` を bsdtar が拒否すること、7zz の 32 B 空出力を KaitoKit が拒否することは、この変更では直さない。

属性の追加規則は 2026-09-26 のオーケストレータ追補に従う。元の file が 1 件以上あり、全件の WinAttributes
（0x15）が未定義なら、追加・置換 entry も属性を未定義にする。判定は削除前の元の file vector に対して行う。
元が空、または 1 件でも属性が定義されていれば、追加には従来の mode 由来の属性を付ける。運ぶ file の属性は
未定義のものもそのまま。directory は属性が無くても emptyStream / emptyFile で表す。
7-Zip 26.03 の参照実行では、属性・mtime が無い `solid_zero.7z` の一部削除後の追加、および `zero_lzma2.7z`
への追加は、0755 の file でも Attributes と Modified が無い。空の `empty_7zz.7z` への追加では両方がある。
この updater は属性の規則だけを合わせ、追加の mtime は保持する（7zz との意図した違い）。
libarchive 3.7.4 は一部だけが定義された 0x15 を "Damaged 7-Zip archive" として拒否する。この規則により、
bsdtar が読める属性無しの元から、その形を新たに作らない。元が既に一部定義なら、その形は保持する。
P5 前の全体の書き直しは `SevenZipRecords.swift` で mode から全件定義の属性を合成していた。
その writer / rewriter は変更しない。属性無しの元に追加する file の Unix mode は、7zz と同様に保存されなくなる。

自己照合は V0 の帳簿、V1 の保持中 descriptor を dup した KaitoKit の独立した構造解析、V2 = 共通部品の
V5（動かした source 範囲の byte 比較）、V3 の追加・再圧縮 folder の全 substream 復号、V3a の変換した
圧縮済み平文の長さと CRC を行う。失敗は `outputVerificationFailed` で後始末する。
進捗の total は固定し、再圧縮があれば入力・出力と header の上界を使い、最後の finish で残りを完了にする。
再圧縮も再配置も無ければ共有部品の正確な units を使う。変更しない clone commit の total は 0。

S24 の AC-G13 について、オーケストレータは frozen `startpos.7z` だけの基準非互換を承認した。
7-Zip 26.03 は編集前から `7zz t` を受理し、`7zz x` は exit 2 / Unsupported Method になる。
StartPos を持つ entry が残る間だけ同じ失敗を求め、StartPos の生値・byte、KaitoKit の全件の内容と CRC、
bsdtar の展開、7zz t を検査する。該当 entry の削除後は 7zz x も成功しなければならない。
他の fixture にこの例外は適用しない。

未検証の実用範囲は、実際に使われる anti / StartPos の書庫（合成 fixture は検査）、4 GiB 超の圧縮 entry
（大きな offset の probe は Copy の sparse folder）、SFX stub の保持、BCJ2 の暗号化変換、古い 7-Zip と
Archive Utility による LZMA2 header。試験と計測、sandbox で実行できなかった項目は
[検証記録](verification/2026-09-26-p5g-sevenzip-updater.md) に記載する。

### 自前 LZMA encoder（2026-10-07）

`Compression/LZMA/` は internal の raw LZMA1 encoder と、その上の LZMA2 chunker。
`LZMAEncoderProperties`、`LZMAEncoder`、`LZMA2Encoder` は ZIP method 14 / 7z LZMA と
tar.xz / 7z LZMA2 / ZIP XZ のレベル選択を共有する。`lzmaLevel: Int?` は nil なら従来の Apple preset-6、
0...9 なら自前の `preset(level, extreme:)`。`lzmaExtreme` は既定 false、レベル指定時だけ有効。
ZIP / 7z LZMA は常に自前で、nil は6。nil の既存三形式は片16 MiB・圧縮 byte を変えない。
`Tests/Fixtures/lzma-writers` は接続前の出力を凍結し、並列数1・4で byte 比較する。
`push(Data)` の戻り値を順に出力し、`finish()` の戻り値を最後に出力する。instance は直列に使い、設定だけを
`Sendable` にする。LZMA1 は EOS の有無と既知サイズを独立に指定でき、`alone(_:properties:knownSize:)` は
13 byte header（未知サイズは all-ones と EOS）を付ける。

range coder は low / range / cache の carry 処理、確率 bit、direct bit、逆順 bit tree を持つ。
HC4 は hash chain、BT4 は binary tree と短い一致用の 2 / 3 byte hash を使う。normal parser は SDK の
GetOptimum の価格最小化を Swift の predecessor と到達 state / rep distance に置き換え、literal、short rep、
match / rep の各長さ、literal + rep0、match / rep + literal + rep0 の複合遷移を比較する。
fast parser は GetOptimumFast の rep 優先と次位置の一致による遅延選択を使う。
window、hash、tree / chain、確率、価格、parser node は unsafe buffer で確保し、入力全体を別途保持しない。
window は辞書と先読み、入力 staging 分で、空きが足りなくなったときにだけ履歴を移す。
raw の slack は実効辞書 D に対して `min(4 MiB, max(64 KiB, D / 2))`。
旧64 KiBから増やし、8 MiB辞書では約8 MiBの履歴移動を数 MiBごとにまとめる。
`push` の64 KiBごとの追加入力と `process(limit:)` の分割は維持するので、圧縮byteは変わらない。
LZMA2 の slack は従来の2 MiBのまま。`memorySize` と writer の予約は実際の window 容量を共有する。
位置参照は UInt32 で正規化して 4 GiB を越える stream でも wrap しない。
一致長の延長と rep の比較は limit 内の未整列 UInt64 比較を使う。HC4 の skip は hash と chain の
リンクだけを更新し、候補を走査しない。長さ価格は niceLen 以下の葉を親の価格から展開し、
posState 共通の high tree を再利用する。node / action / match は32 / 8 / 8 byteに収め、
以前の88 / 16 / 16 byteから探索 buffer を縮めた。rep 距離は UInt32、state と tail は一つの UInt16 に保持する。
normal parser は posState の価格行と長さ5以上の距離価格を再利用し、複合遷移は長さの loop の後で一度だけ調べる。
BT4 の2 / 3 byte hash は SDK と同じ選択で延長を一度にまとめ、HC4 は二候補から best を先に得て chain を除外する。
通常の advance は inline 化し、大きな表の正規化だけを別関数に分ける。bit 価格は0 / 1 の各2048確率を UInt8 の4 KiB表に展開し、
lookup の shift / xor を省いた。symbol の入力位置・state・rep は pointer の書込みにまたがる local 値で保持する。
`memorySize` の予約量は以前より encoder ごとに261,264 byte（約0.249 MiB）減った。
LZMA2のMiB切上げの予算表は変わらないが、raw level 0の同期予算は20から19 MiBになり、
byte単位で解決する並列数と入力上界は予算境界で増える（下の統合時照合表を参照）。

LZMA2 は最大 2 MiB の入力、64 KiB 以下の圧縮 byte に区切る。range coder を chunk ごとに flush し、
辞書と確率 state は継続する。先頭 compressed chunk は辞書 / state / property を reset する。
縮まない chunk は最大 64 KiB の raw chunk に分け、次の compressed chunk で state を reset する。
先頭 raw chunk は辞書 reset を指定し、property は最初の compressed chunk で送る。最後は `0x00`。
2 MiB の staging と parser の復元余地を含む pack limit の予約により、chunk の形式上限を越えない。
LZMA2 では `lc + lp <= 4` を検査する。

翻訳の出自は Igor Pavlov が public domain に置いた LZMA SDK 26.03 の `C/LzmaEnc.c`、`C/LzFind.c`、
`C/LzHash.h`、`C/Lzma2Enc.c` と `lzma-specification.txt`。`DOC/lzma-sdk.txt` の public domain の宣言を確認した。
各追加 Swift file の冒頭にも出自を書く。C の同梱・compile はせず、純 Swift と OS library の規則を維持する。
preset の数値は [xz の lzma_encoder_presets.c](https://github.com/tukaani-project/xz/blob/v5.8.1/src/liblzma/lzma/lzma_encoder_presets.c)
と照合した（この版の source 表示は 0BSD）。xz の level 0 は HC3 だが、本 API は指定された HC4 を使う。
それ以外の通常 preset の辞書、mode、nice length、depth と extreme の値は同表に合わせる。

| level | 辞書 MiB | finder / mode | niceLen | depth（自動値解決後） | hash MiB | tree / chain MiB | 辞書 + 表 MiB |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 0.25 | HC4 / fast | 128 | 4 | 0.754 | 1 | 2.004 |
| 1 | 1 | HC4 / fast | 128 | 8 | 2.254 | 4 | 7.254 |
| 2 | 2 | HC4 / fast | 273 | 24 | 4.254 | 8 | 14.254 |
| 3 | 4 | HC4 / fast | 273 | 48 | 8.254 | 16 | 28.254 |
| 4 | 4 | BT4 / normal | 16 | 24 | 8.254 | 32 | 44.254 |
| 5 | 8 | BT4 / normal | 32 | 32 | 16.254 | 64 | 88.254 |
| 6 | 8 | BT4 / normal | 64 | 48 | 16.254 | 64 | 88.254 |
| 7 | 16 | BT4 / normal | 64 | 48 | 32.254 | 128 | 176.254 |
| 8 | 32 | BT4 / normal | 64 | 48 | 64.254 | 256 | 352.254 |
| 9 | 64 | BT4 / normal | 64 | 48 | 64.254 | 512 | 640.254 |

表は入力サイズ未知のときの確保量。これに probability / price / optimum / 初期 range buffer などの
約0.5 MiBと、raw LZMA1 の slack 64 KiB〜4 MiB、または LZMA2 の slack 2 MiBを加える。
`expectedSize` が小さければ宣言辞書を保ったまま実効辞書と
match finder の表を縮める。API は辞書 1.5 GiB まで受け付けるが、確保前に総量と `memoryLimit` を照合する。
既定の上限は 768 MiB で、上限超過や allocation 失敗は error にする。黙って小さい辞書へ変更しない。
range 出力 buffer は初期 128 KiB で、確率の偏りによる膨張時だけ残りの memory budget 内で最大 16 MiB まで増やす。
extreme は BT4 / normal、level 3 / 5 が niceLen 192・自動 depth 112、それ以外は niceLen 273・depth 512。

`LZMAWriterConfiguration` は encoder closure とメモリ解決を writer / updater 間で共有する。
自前 encoder を `LZMA2ChunkPipeline` / `ParallelXZCompressor` / `SevenZipChunkPipeline` の
`(Data) throws -> XZLZMA2` に接続する。片ごとの encoder は独立で、property は宣言辞書から作る。
辞書が16 MiBを超えたときの片は `max(16 MiB, 3 × 辞書)`（xz の既定 block size 規則）。
レベル8は96 MiB、9は192 MiB、それ以下は16 MiB。

自前 LZMA2 の実際の並列数 t は `t × (encoder memory + 2 × 片サイズ)` が
`min(memoryLimit（nil は物理メモリの50%）, 物理メモリの50%)` 以下になる最大数に制限します。
要求した並列数を上限とし、1個分も入らなければ書庫を作る前に `WriterError.invalidOption("memoryLimit")` を返します。
メモリ不足で宣言辞書を縮小しません。自前 tar.xz は小さい block も t 個の枠に数えます。
入力の上界は tar.xz が `t × 片 + 4 MiB`、7z が `t × 片`、ZIP XZ が `(t + 1) × 片` です。

| `lzmaLevel` | 辞書 MiB | LZMA2 encoder MiB | 片 MiB | LZMA2 1 thread の予算 MiB | raw LZMA1 の同期予算 MiB |
|---|---:|---:|---:|---:|---:|
| 0 | 0.25 | 5 | 16 | 37 | 19 |
| 1 | 1 | 10 | 16 | 42 | 25 |
| 2 | 2 | 17 | 16 | 49 | 33 |
| 3 | 4 | 31 | 16 | 63 | 48 |
| 4 | 4 | 47 | 16 | 79 | 64 |
| 5 / 6 | 8 | 91 | 16 | 123 | 110 |
| 7 | 16 | 179 | 16 | 211 | 198 |
| 8 | 32 | 355 | 96 | 547 | 374 |
| 9 | 64 | 643 | 192 | 1027 | 662 |

64-bit の通常 preset を MiB 単位で切り上げた値です。extreme のレベル0〜3は BT4 に替わり、
それぞれ1 / 4 / 8 / 16 MiB増えます。raw LZMA1 の予算は range buffer の最大16 MiBと I/O を含みます。
短い入力では encoder の実確保が減りますが、検証・並列数解決は表の完全な辞書で行います。
Appleのnilレベルの既存block経路は従来のbyteと16 MiB境界を維持し、この予算で内部並列数を変えません。
新規のwriter項目/folder窓は、下の見積りと予算で別に並列数を解決します。

2026-10-08の`speed/integrate`統合時に、base `f273d34`とHEAD `4d327a5`の式と64-bitの
`MemoryLayout.stride`を照合した。通常preset、入力サイズ未知、LZMA2（`chunked: true`）、
`memoryLimit = 3 GiB`、物理メモリ8 GiB、要求64 threadの結果は次のとおり。
Eは`LZMAEncodingEngine.memorySize`、Mは`memoryPerThread = E + 2 × 片`（いずれもbyte）。
この表は明示threads=64の測定なのでtは`min(64, floor(3 GiB / M))`（64は既定上限ではない）。右二列はHEADのZIP XZ / 非solid・filterなし7z LZMA2の入力上界。

| level | E: base → HEAD byte | M: base → HEAD byte | t: base → HEAD | ZIP MiB | 7z MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 4,923,681 → 4,662,417 | 38,478,113 → 38,216,849 | 64 → 64 | 1040 | 1024 |
| 1 | 10,428,705 → 10,167,441 | 43,983,137 → 43,721,873 | 64 → 64 | 1040 | 1024 |
| 2 | 17,768,737 → 17,507,473 | 51,323,169 → 51,061,905 | 62 → 63 | 1024 | 1008 |
| 3 | 32,448,801 → 32,187,537 | 66,003,233 → 65,741,969 | 48 → 48 | 784 | 768 |
| 4 | 49,226,021 → 48,964,757 | 82,780,453 → 82,519,189 | 38 → 39 | 640 | 624 |
| 5 | 95,363,365 → 95,102,101 | 128,917,797 → 128,656,533 | 24 → 25 | 416 | 400 |
| 6 | 95,363,365 → 95,102,101 | 128,917,797 → 128,656,533 | 24 → 25 | 416 | 400 |
| 7 | 187,638,053 → 187,376,789 | 221,192,485 → 220,931,221 | 14 → 14 | 240 | 224 |
| 8 | 372,187,429 → 371,926,165 | 573,514,021 → 573,252,757 | 5 → 5 | 576 | 480 |
| 9 | 674,177,317 → 673,916,053 | 1,076,830,501 → 1,076,569,237 | 2 → 2 | 576 | 384 |

減少の内訳はoptimum / actionが`4096 × ((88 + 16) - (32 + 8)) = 262,144 byte`、
matchが`274 × (16 - 8) = 2,192 byte`、bit価格表の増加が`4096 - 128 × 8 = 3,072 byte`。
合計は`262,144 + 2,192 - 3,072 = 261,264 byte`。
`LZMAMatchFinder.memorySize`のhash / son / CRCの式はbaseと同じで、match候補の縮小はengine側に計上する。
辞書、片サイズ、probability、その他の価格表、range出力の初期容量も変わらない。

現行の`init`が`calloc(count, stride)`で確保するbufferと見積りの対応は次のとおり。
Dは実効辞書、Hは`mask(for: D)`、Sは`min(4 MiB, max(64 KiB, D / 2))`、lc / lpはproperties。
各項は確保byte数と一致し、過少計上はない。

| buffer | `memorySize`の項と確保byte数 |
| --- | ---: |
| window | `D + (chunked ? 2 MiB : S) + 4369 + 64 KiB` |
| finder.hash | `(H + 1 + 1024 + 65536) × 4` |
| finder.son | `(D + 1) × (BT4 ? 8 : 4)` |
| finder.crc | `256 × 4 = 1024` |
| probs | `(1846 + (768 << (lc + lp))) × 2` |
| bitPrices | `4096 × 1` |
| lengthPrices / repLengthPrices | `2 × 16 × 272 × 8` |
| distancePrices / slotPrices / alignPrices | `(4 × 128 + 4 × 64 + 16) × 8` |
| matches | `274 × 8` |
| opt / actions | `4096 × (32 + 8)` |
| rc.outputの初期容量 | `131072` |

range出力の伸長は`memoryLimit - required + 131072`以下（最大16 MiB）に制限する。
writerのraw予約は初期容量との差`16 MiB - 131072`を追加し、LZMA2は64 KiBのpack limitで区切る。
小さい`expectedSize`による実効辞書の縮小も、完全な辞書で算出したwriter予約の範囲内。
ここで数えるのはcodec bufferのbyte数であり、allocatorの管理領域やプロセス全体のRSSではない。
`EntryCompressionConfiguration`はMに入力16 MiB・spool 1 MiB・I/O 1 MiBを追加し、要求数・GCD poolの1/4・メモリ予算で項目窓を制限する。
この条件ではZIP XZのblock上界`(t + 1) × 片`が項目窓の上界以上になる。
`Tests/`のraw / lzip / level-9の並列数、`MulticoreWriterTests`の項目窓の期待値、
`WriterOptions`の式とその他の固定上界も照合し、更新が必要なのは上の固定表とraw level 0の切上げ値だった。

2026-10-09のraw slack拡大では、`encoderMemory`、`memoryPerThread`を通じてlzipのmember数と
ZIP / 7zの項目窓・pending入力上界にも新しい予約量を反映する。各解決側の式は共有計算を参照するため変更しない。
`LZMAWriterConfigurationTests`は全levelのraw予約byte数とlzipの並列数・入力上界を固定値で検査し、
level 6の新予約の三枠に1 byte足りない予算ではZIP / 7zの入力上界が32 MiBになることを確認する。
`LZMAEncoderTests`は旧64 KiB slackをTaskLocalの試験用hookで強制し、256 KiB辞書より2倍以上大きい入力を
幅1 / 7 / 65537 / 262144でpushしてHC4 / BT4の出力をbyte比較する。大辞書のlevel 4 / 6 / 9もサイズ未知で照合する。

試験は KaitoKit の公開 `LZMADecoder` / `LZMA2Decoder`、xz の復号と byte 比較、`xz -t` と `7zz t` の
独立 oracle を使う。writer は tar.xz の xz / tar 展開、7z と ZIP の `7zz t / l -slt / x`、
暗号化、updater の追加・solid 再圧縮、既定4 MiB + 512 byte入力の level-9 並列数制限も照合する。
元の128 MiB入力は `TarXZLZMALevelTests` の `…FullSize` に残し、`GYOSHUKU_LARGE_ENCODER_TESTS=1` で実行する。
encoder は既定の random / text 各65,537 byte、mixed 2.625 MiB + 17 byteをlevel 0 / 1 / 3 / 5 / 6 / 9で照合する。
元の1 / 4 / 20 MiB入力と2 MiB + 777 byteの全分割幅は `LZMAEncoderTests` の `…FullSize` に残す。
7z の listing は LZMA2:18/20/23/26 と LZMA:18/20/23/26、ZIP 14 は LZMA:eos。
外部ツール不在は Tests/README.md の規則どおり失敗する。
benchmark は通常の試験で skip し、固定 seed の 4 MiB 辞書単語 text と `/usr/lib/dyld` から始める
Framework の実在 Mach-O（path 順、最大 32 MiB）を使う。corpus の path と長さも表示する。
単一 thread の Swift raw LZMA2、`xz -<level> -T1 --format=raw -c`、現行 Apple 経路の raw LZMA2 size と MB/s を出す。
Apple に level 指定はなく、各行は同じ OS encoder の比較値。MB/s は 1,000,000 byte/s。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build -c release --disable-sandbox --build-system native
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox --build-system native --filter LZMAEncoder
GYOSHUKU_LZMA_BENCHMARK=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift test -c release --disable-sandbox --build-system native --filter LZMAEncoderBenchmarkTests
```

Xcode build system の dSYM 生成が制限される環境では `--build-system native` を指定する。
benchmark の速度閾値は通常の test failure にせず、size gap、対 xz 速度、level 1 / 6 比を実測して報告する。

2026-10-06 の開発機計測（arm64、Swift 6.4、xz / liblzma 5.8.4、release XCTest / `-enable-testing`、単一 thread）での実測。
text は 4,194,304 byte、binary は dyld 4,129,088 byte と CreateML 16,559,504 byte の連結（合計 20,688,592 byte）。
比較の size は全て raw LZMA2 で、container overhead を含まない。速度には encoder の確保と終了処理を含み、
xz は process 起動と file I/O も含む。入力生成と Swift 出力の検証は計測区間外で行う。
Apple の値は現行 `LZMA2Compressor.encode` 呼出し全体なので framing 抽出も含む。

| corpus | level | Swift byte | xz byte | Apple byte | Swift MB/s | xz MB/s | Apple MB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| text | 1 | 1,024,529 | 1,024,519 | 695,024 | 21.825 | 30.578 | 3.262 |
| text | 6 | 694,823 | 695,024 | 695,024 | 3.077 | 3.307 | 3.318 |
| text | 9 | 694,823 | 695,024 | 695,024 | 2.824 | 3.147 | 3.359 |
| binary | 1 | 6,453,276 | 6,451,638 | 4,623,756 | 18.137 | 28.015 | 5.582 |
| binary | 6 | 4,615,940 | 4,623,756 | 4,623,756 | 4.677 | 5.965 | 5.624 |
| binary | 9 | 4,612,054 | 4,620,542 | 4,623,756 | 4.749 | 5.540 | 5.617 |

level 6 / 9 の size 差は text が各 -0.029%、binary が -0.169% / -0.184% で、1.5% 以内。
text の level 6 速度は xz の 93.1%（目標 40% 以上）、level 1 / 6 は 7.093 倍（目標 2 倍以上）。
この時点の目標を満たした。2026-10-07 の速度改善は同じ corpus を使い、以下の別計測で比較する。

release build、release の 7 tests（131 秒）、debug の通常 suite 5 tests と追加 2 tests、release benchmark を検証済み。
通常の debug suite は約 18 分、同じ大入力の release suite は約 2 分だった。KaitoKit の往復と全 level の xz / 7zz oracle は全て成功。
再検証は上の `LZMAEncoder` filter を使い、元の大入力には `GYOSHUKU_LARGE_ENCODER_TESTS=1` を指定する。
oracle の書庫と log は試験が生成する（保存先は Tests/README.md を参照）。

2026-10-07 の単一thread速度改善を非XCTestハーネスで再計測した（Apple M4 Max / 128 GB、Swift 6.4、xz / liblzma 5.8.4）。
基準版 `f273d34` と改善版 `926d828` の source をそれぞれ取り出し、同じ
`swiftc -O -wmo -swift-version 6 -module-cache-path "$PWD/.build/clang-module-cache"` でコンパイルした。
`-enable-testing` は使わない。上と同じtext / binaryの保存済みcorpusを使い、level 1 / 3 / 6 / 9を
同じloop内で基準版・改善版・xzの順序を6通りに入れ替えて7巡し、各条件の最速（best-of-7）を選んだ。
各sampleは別processで実行し、追加のwarmupはしない。Swiftはraw LZMA2の確保・符号化・解放を計時し、入力読込と出力保存は除く。
xzは `xz -k -T1 -<level> --format=xz <input>` のwall timeで、process起動・file I/O・XZ framingとchecksumを含む。
Swift は process 内の計時、xz は process 全体の wall timeなので、ほぼ同等の行ではこの差がSwiftに数%有利に働く。
表の速度は MB/s（1,000,000 byte/s）、Swift byteはraw、xz byteはXZ container全体なのでsizeの直接比較には使わない。
負荷平均（1 / 5 / 15分）は開始3.99 / 3.79 / 4.50、終了4.59 / 4.29 / 4.54、sample前の範囲は
3.55〜5.64 / 3.78〜4.46 / 4.48〜4.63だった。共有機の負荷による揺れを含む。

| corpus | level | 基準 MB/s | 改善 MB/s | xz MB/s | Swift raw byte（両版） | xz container byte |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| text | 1 | 23.216 | 56.104 | 45.394 | 1,024,529 | 1,024,580 |
| text | 3 | 4.850 | 19.900 | 19.956 | 939,624 | 939,672 |
| text | 6 | 3.304 | 4.116 | 3.898 | 694,823 | 695,084 |
| text | 9 | 3.416 | 4.146 | 4.045 | 694,823 | 695,084 |
| binary | 1 | 19.863 | 37.680 | 33.689 | 6,453,276 | 6,451,700 |
| binary | 3 | 6.585 | 19.817 | 18.685 | 5,995,056 | 5,993,544 |
| binary | 6 | 5.413 | 6.548 | 6.647 | 4,615,940 | 4,623,816 |
| binary | 9 | 5.384 | 6.403 | 6.256 | 4,612,054 | 4,620,604 |

level 9の基準版比は最速値でtext 1.214倍 / binary 1.189倍、中央値ではtext 1.171倍 / binary 1.211倍。
両corpusとも約1.2倍で、1.2倍以上という達成判定は負荷と採用する統計量に依存する。
対xzの速度超過はlevel 1の両corpus（1.236倍 / 1.118倍）で達成し、level 3はbinaryの今回の最速値で1.061倍（小差で負荷依存）だった。
level 3のtextはxzの99.7%でほぼ同等・負荷依存。level 2は今回未計測で、levels 1〜3全体の達成とはしない。
level 6の対xzはtext 105.6% / binary 98.5%、level 9は102.5% / 102.3%。約5%の小差はほぼ同等・負荷依存と扱う。
測定した8条件のSwift出力は両版・全7回でbyte一致し、基準版からのsize増加0%を達成した。
計測後に両版のrawとxzの計24出力を独立xzで復号し、corpusの全byteに一致した。
現行版の計測・oracle 照合は上の `GYOSHUKU_LZMA_BENCHMARK=1` で再実行できる。
表と同じ非XCTest比較を再生成するには、両commitの `Compression/LZMA/` のSwift sourceを別々に上記commandでビルドし、
`LZMAEncoderCorpus.text` と同じtext・記載したMach-O連結を保存して、`LZMA2Encoder.encode` の計時とxzを上記の順序で7巡する。
全sample・source / corpusのSHA-256・負荷を記録し、最速値と中央値を分けて集計する。
速度比較はこの同一 `-O -wmo` 条件を使い、round 1のrelease XCTest / `-enable-testing`計測とは混ぜない。

2026-10-07 の LZMA1 並列 finder 試作は public-domain の `C/LzFindMt.c` の block 受渡しを参考に、
`Thread` と semaphore、4096位置の二つの block で実装した。raw LZMA1 level 6のbest-of-5は
textが3.424 → 4.494 MB/s（1.312倍）、binaryが5.648 → 7.200 MB/s（1.275倍）だった。
当時の採用条件には届かなかったが、many-core Macの長い単一streamが未使用coreを残すため、
2026-10-09に二段pipelineを採用する方針へ変更した。現在の実装と試験はこのworktreeで新規作成したSwiftであり、
新たな外部reference sourceの読取り・Cの取り込みはない。

`LZMAMatchFinderPipeline`はcaller/parserと専用finder `Thread`の二段。callerの`qos_class_self()`に合わせたQoSを使う。
各blockは4096位置、候補を詰めた配列と位置ごとのoffsetを持ち、二つのblockを`NSCondition`で所有権移譲する。
finderのhash/sonと位置stateは専用Threadだけが更新し、parserは候補を消費し、選択したmatch内の候補を読み飛ばす。
BTでは全位置の木の走査結果と2/3 byte hash headの距離を保存する。短いhash候補の比較と
273 byteまでの最後の候補の延長は表を変更しないので、parserが実際に読む位置だけで行う。
短いhashで得たbest以下のBT候補を除けば、候補順・同長の距離優先も逐次と同一になる。
HCではchainの走査結果を記録し、延長だけを読取時に行う。これは逐次の`ReadMatchDistances`相当の最終化であり、
parserへ渡す候補列の長さ・距離は逐次と同一。skip位置の不要な比較・延長を省き、反復が多い長いstreamの費用を抑える。
BT4の枝更新は`record`・候補の`best/count`を参照しない。HC4のskipはhashとchainのheadを保存するだけで、
record時のchain走査はその表を変更しない。したがって全位置で候補を記録しても、後続位置の表と候補は逐次と一致する。
`LZMAMultithreadedFinderTests`は全preset/extremeで可変skipを混ぜ、候補とhash/sonの全byteを直接比較する。

pushの64 KiB処理境界と`process(limit:reserve:)`を保つ。投機的な先読みは`available >= 273`の位置までとし、
最後の272位置はparserが要求した範囲だけ、その時点の`limit`で生成する。短いpushでまだ確定しない長さを記録しない。
sizeMismatchはThreadをjoinしつつ表・未消費候補を保持し、再試行時に同じ状態からThreadを再開する。
processから戻る前にfinderをpauseし、入力追記と`compact()`はworkerの読取り完了後に行う。
compactでは未消費候補の距離を保ち、workerのwindow位置だけdrop分ずらす。finishの小さいlimitにも同じ規則を適用する。
取消しはcallerが4096位置ごとにも検査し、error・finish・abandon・deinitでThreadをjoinしてからwindow/hashを解放する。
候補二組とoffset、512 KiBのThread stack、管理余裕を合わせた追加予約は18,518,024 byte（約17.66 MiB）。
`memorySize`・`encoderMemory`・`memoryPerThread`へ計上し、追加予約が収まらない任意高速化はfinder=1へ戻す。

raw設定の内部`finderThreads`は1/2。単独`.lzma`と`tar.lzma`、inlineの単一ZIP項目/7z folder、
ZIPのstreamed大項目、7zのlong-poleだけ、解決済みcompressionThreadsが2以上なら2を選ぶ。
通常項目窓は1。7zはlong-poleのparser+finderに要求core数の内側から二枠を予約し、通常窓には残りを渡す。
要求2では専用long-pole枠を作らず、通常jobをdrainして二枠を貸す。folderのメモリと入力窓は二重に予約しない。
ZIPは通常窓を要求数−1以下にしてfinder用一core・buffer一組を別予約し、非待機の貸出しで同時に一つの大項目だけMTにする。
他のstreamed項目は1で進める。LZMA2のchunk境界・finder並列数とlzipのmember並列は従来通り。

`GYOSHUKU_LZMA_MT_BENCHMARK=1 swift test -c release --disable-sandbox -debug-info-format none
-Xswiftc -enable-testing --filter LZMAMultithreadedBenchmarkTests`でtext/Mach-O/randomを各3回測る。
`GYOSHUKU_LZMA_MT_BENCHMARK_FILE`で任意の入力を加える。level 6、初期化・compact・joinを含むraw streamingで、
全sample・best秒・MB/s・speedup・出力byte数を`LZMA-MT-BENCH` + tab + JSONで報告し、出力を逐次と照合する。
2026-10-09、16-core M4 Maxのrelease buildで各3回の最良値を採った。通常の試験と他worktreeの作業が
同じMacで並行しており、writer sampleの1分loadは2.41〜6.48。Mac miniは使用していない。

| raw LZMA1 level 6 | 逐次 MB/s | MT MB/s | 逐次秒 | MT秒 | speedup |
|---|---:|---:|---:|---:|---:|
| text 4 MiB | 4.041 | 6.534 | 1.038050 | 0.641943 | 1.617× |
| Mach-O試験実行file 20,517,408 byte | 6.776 | 11.467 | 3.027832 | 1.789330 | 1.692× |
| random 16 MiB | 7.480 | 17.324 | 2.243050 | 0.968456 | 2.316× |
| mixed z-large.dat 64 MiB | 13.696 | 15.110 | 4.899742 | 4.441325 | 1.103× |

text / binaryの1.25倍目標は達成。mixedの改善は1.103倍に留まる。finderの表更新は一つのThreadで逐次実行する。
HC4 presetの速度比較は今回のlevel 6測定の対象外。byte identityは全level / extremeで検査する。

writer harnessは `swift build -c release --package-path Benchmarks --scratch-path "$PWD/.build/bench-release"
--product gyoshuku-multicore --disable-sandbox -debug-info-format none` でbuildし、指定corpusに対して
`gyoshuku-multicore <corpus> <sample.jsonl> <case> 16 <label> corpus batch` を各3回実行した。
共通の`result-new.archive`の競合を避けるためlabelだけ`lzma-mt-new-<round>-<case>`へ変えた。
入力は各case 268,435,456 byte、同じcaseの3回の出力サイズ・SHA-256は一致した。

| writer case | 秒（3 sample） | best秒 | 出力byte |
|---|---|---:|---:|
| zip-lzma | 6.027600 / 6.081846 / 6.052139 | 6.027600 | 83,874,740 |
| 7z-lzma-solid | 5.300184 / 5.359229 / 5.337895 | 5.300184 | 70,176,846 |
| tar.lzma | 17.784104 / 17.766333 / 17.740243 | 17.740243 | 68,215,836 |

変更前に提示されたZIP約6.24秒 / 7z solid約5.48秒に対して、それぞれ約1.035 / 1.034倍。
実writerの改善幅はraw text / binaryより小さい。tar.lzmaの変更前baselineはこの比較に含めていない。
全sampleは `.build/lzma-mt-results/{raw-final-samples,writer-final-samples}.jsonl` に保存した。

専用試験は全preset 0〜9 / extreme、小辞書4 KiB・大辞書1 MiB、空・1 byte・text・Mach-O・random・
反復・mixed、push幅1 / 7 / 4096 / 65537 / 262144、available=1〜273、reserve / 64 KiB境界、
2×windowを超える入力、サイズ未知、最終pushとfinishの組合せを検査する。全presetでcompactを通し、
BT4 / HC4の候補列とhash/sonを直接照合する。全writer preset / extremeも1 / 2 / 16 / 36 threadsで一致した。
取消しのjoinは2秒未満をassertし、保持したencoderのerror、サイズ検査からの再試行、read / sink error、
abandon / deinitでworkerの開始・終了数を照合する。LZMA2の既定finderと出力は維持する。

最終sourceの対象試験はdebug 19 tests / 0 failures（409.216秒）、release 21 tests / 0 failures（30.571秒）。
writerの全preset / extremeは400条件を含む。取消し試験全体はrelease 0.057秒で成功し、取消し後joinを2秒未満で検査した。
ZIPのfile入力は読取りでatimeが変わるため、byte比較前にatime / mtimeを毎回固定する。
7zの通常窓を二core分減らした結果、flush前に返る先頭folderの予約をprogress試験の期待値にも反映した。
指定の広いfilterは233 tests / 16 skipped / 4 assertion failures（1988.489秒）。失敗caseは上記fixtureの二つだけだった。
実行中にfixtureを修正したため、この旧binaryの結果と最終sourceの再検証は区別する。
修正後の広いfilter一括再実行はしていないが、両失敗caseを含む最終sourceのdebug / release対象試験はすべて成功した。

`LZMAMatchFinderProbeTests`は並列finderを再検討するためのrelease専用probe。
`GYOSHUKU_LZMA_FINDER_PROBE=1 swift test -c release -Xswiftc -enable-testing --filter LZMAMatchFinderProbeTests`
で、既存の4 MiB text corpus、実在するMach-O（試験bundleの実行fileを優先）、固定seedの16 MiB randomを測る。
`GYOSHUKU_LZMA_FINDER_PROBE_FILE`で任意の読み取り用fileを追加する。
levelは既定6、`GYOSHUKU_LZMA_FINDER_PROBE_LEVELS=4,6,9`で増やせる。
`GYOSHUKU_LZMA_FINDER_PROBE_REPEATS`は既定3、各計測の最良値を使う。
`GYOSHUKU_LZMA_FINDER_PROBE_MAX_BYTES`は各入力を短くする起動確認専用で、通常の性能判断では未設定にする。
corpus / levelごとに `LZMA-FINDER-PROBE` + tab + JSONの一行を出し、
入力・実効辞書・出力byte数、秒、`f = finder_seconds / full_seconds`、候補数・checksum・縮小の有無を記録する。
入力準備・checksumの報告・反復間の出力照合は計測外。finderとraw encoderの初期化はそれぞれの時間に含める。
finderは全入力を一つのwindowで与え、各位置で `matches(..., record: true)`を呼ぶ。
encoderの `record: false` skipや64 KiB入力境界とは異なるため、fは並列候補生成の費用を調べる目安であり、
実際のencode時間の厳密な割合ではない。小さいfならfinder以外の改善を優先し、大きいfなら同期・候補受渡し込みの試作で再検証する。

2026-10-07（round 3、改善版 `926d828`）の release targeted suite は52 tests / 0 failures、115.680秒。debug の短い通常試験は
14 tests / 0 failures、2.836秒。両方 `--disable-sandbox --build-system native -debug-info-format none` を指定した。
価格表、bit価格の量子化、未整列の一致長、position正規化、独立xz / 7zz oracle、
writer / updater、並列LZMA2、nilレベルの凍結出力を検証した。全suiteは実行していない。
現行版の再検証は `LZMA|TarXZ|TarLZMA|Lzip|SevenZip.*LZMA|Zip.*LZMA|XZPackingLayout` をfilterにし、
大入力を含める場合は `GYOSHUKU_LARGE_ENCODER_TESTS=1` とreleaseを指定する。過去版の件数・秒数は当時の試験構成による。

### LZ4 frame encoder（2026-10-06）

`LZ4FrameEncoder` は [LZ4 Frame Format v1.6.4](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md)
から独立に実装した internal codec。magic `0x184D2204`、version 01、独立 block、BD=7（4 MiB）、
content checksum 有効の一つの frame を書く。既知の `contentSize` は header に載せ、入力長も照合する。
block checksum は既定 off で指定可能。header / block / content の XXH32 は
[公開 xxHash 仕様](https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md)から自前実装し、末尾は最大 15 byte。
block 本体だけを Apple の `compression_encode_buffer(..., COMPRESSION_LZ4_RAW)` に委ねる。
SDK `usr/include/compression.h` は RAW を buffer API 専用と記載する。`COMPRESSION_LZ4` の
Apple 独自 wrapper は使わない。縮まない block は長さの最上位 bit を立ててそのまま格納する。

frame の連結ではなく、`OrderedChunkPipeline` で同じ frame の独立 block を並列化し順序どおり出す。
組立中を含め最大 `threads` block の枠、各 block は入力 4 MiB、圧縮試行 4 MiB 未満、framing 済み結果
4 MiB + 8 byte 以下なので、Swift 側の上限は概ね `threads × 12 MiB`（呼出元の入力・emit の保持分を除く）。
これに各 native 呼出しの固定 scratch が加わる。stream 全体の index / 入力を保持しない。
空、1 byte、64 KiB zeros、9 MiB random の stored block、4 MiB 境界を越える 12 MiB text を
content size / block checksum の全組み合わせで試験し、KaitoKit と `lz4 -t` / `lz4 -dc` で検証する。

### Brotli stream encoder（2026-10-06）

`BrotliStreamEncoder` は [RFC 7932](https://www.rfc-editor.org/rfc/rfc7932) の stream を、Apple の
`compression_stream_init(..., COMPRESSION_STREAM_ENCODE, COMPRESSION_BROTLI)` と
`compression_stream_process` / `COMPRESSION_STREAM_FINALIZE` で書く。圧縮本体・framing は OS が提供し、
Swift は入力供給・出力排出・native state の寿命と失敗を管理する。stream は連結できないので、全 write を
一つの逐次 stream に渡す。Apple は固定 level 2 の encoder を提供するため、level 設定は公開しない。
[Apple の API 文書](https://developer.apple.com/documentation/compression/compression_brotli)と、検証した
MacOSX27.0.sdk の `usr/include/compression.h:114-126` に固定 level 2 と macOS 12.0 以降の記載がある。
stream API 自体は同 header の macOS 10.11 以降。Package.swift の最低 macOS 26.0 は双方を満たす。

Swift が保持するのは 256 KiB の出力 buffer と空入力用 1 byte、native state だけで、入力を全量収集しない。
native の辞書・作業領域は固定 encoder の window に従う（具体的な確保量は Apple API の保証にない）。
LZ4 と同じ五つの入力を不揃いな chunk に分け、別呼出しの finish、byte ごとの write、入力付き finish も試験する。
KaitoKit と `brotli -t` / `brotli -dc` が同じ内容を復元することを確認する。

### UNIX compress / LZW stream encoder（2026-10-06）

`LZWStreamEncoder` は [公開 LZC 形式説明](https://ciderpress2.com/formatdoc/LZC-notes.html)と
[compress(1) の辞書規則](https://man.openbsd.org/compress.1)からの独立した純 Swift 実装。Apple の圧縮 API は
使わない。header は `1F 9D` と block mode `0x80 | maxbits`、maxbits は 12...16（既定 16）。
形式の範囲は 9...16 だが、macOS の gzip / uncompress が 12 未満を拒否するため 9...11 は
`WriterError.invalidOption("compressMaxbits")` とする。tool 固有の CLEAR 回避策は入れない。
prefix code と次の byte の辞書を使い、9 bit から最大幅まで LSB first の 8-code group に詰める。
幅を増やすのは旧幅の code を出した直後、次の辞書 entry を登録する前。幅変更と CLEAR=256 の後は
旧幅の group を `width` byte まで埋め、EOF だけは byte 境界まで詰める。CLEAR 後は 9 bit literal から再開する。
KaitoKit の `LZWDecoder` が幅変更 / CLEAR 時に旧 group の残りを破棄することも読み、実ツールで互換性を検査する。

辞書が満杯になった後、10,000 入力 byte ごと（次の code 出力時）に累積圧縮率を比較する。
悪化したら CLEAR を出し辞書と最高比を reset する。評価時点の違いで `compress(1)` との byte 一致は要求しない。
保持量は最大 `2^maxbits - 257` 辞書 entry（16 bit で 65,279）、256 KiB + 最大 15 byte の出力、
16 byte の group、現在の prefix とカウンター。入力長に比例する保存領域はない。
maxbits 12 / 16の既定は小入力とtext 128 KiB → random 256 KiB → text 128 KiBを扱い、CLEAR count > 0も検査する。
元の7 MiB混合入力・9 MiB random・12 MiB textは `…FullSize` に残し、`GYOSHUKU_LARGE_ENCODER_TESTS=1` で実行する。
KaitoKit と `/usr/bin/uncompress -c`、OS の `/usr/bin/gzip -dc`、`/opt/homebrew/bin/7zz x -so` で byte を照合し、
`/usr/bin/compress -c -b <maxbits>` のサイズから 25% を越えて離れないことを確認する。
空の `.Z` は EOF code がなく header のみで、BSD gzip / uncompress は拒否するため、
その特定の終了値・診断と空の出力も試験に明記する。KaitoKit と 7zz は空を正常に復元する。
制限付き環境で `compress -c` が `/dev/stdout` の再 open を拒否された場合だけ、同じ OS codec を
`compress -f -b <maxbits> <一時入力>` の file 出力で呼ぶ。`uncompress -c` も同じ再 open を行うため、
`uncompress -c` が同じ診断を返した場合だけ `uncompress -f <一時コピー.Z>` で全 byte を照合する。
gzip と 7zz の stdout 復号も常に試験する。必須の実ツール照合は維持する。

新 codec の外部ツール不在は Tests/README.md の規則どおり失敗とする。製品の外部依存には加えない。
検証コマンド（CLI 復号 byte の照合は XCTest 内で行う）:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --disable-sandbox
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox --filter "LZ4|Brotli|LZW|Compress|XXH32"
/opt/homebrew/bin/lz4 -t output.lz4
/opt/homebrew/bin/lz4 -dc output.lz4 > restored
/opt/homebrew/bin/brotli -t output.br
/opt/homebrew/bin/brotli -dc output.br > restored
/usr/bin/uncompress -c output.Z > restored
/usr/bin/compress -c -b 16 input > reference.Z
/opt/homebrew/bin/7zz x -so output.Z > restored
git diff --stat
```


### 新しい圧縮 tar と lzip framing（2026-10-06）

`ArchiveFormat.tarLZMA / tarLzip / tarLZ4 / tarBrotli / tarCompress` は `isTar` に含め、
名前・日時・所有者・リンク・record は既存の `TarWriter` を共有する。拡張子は呼出側が決める。
`StreamCompressor` が tar と単独 file の共通sinkを作る。既存tarのgzip / bzip2 / XZの区切り・byteは維持する。
単独.bz2は `SingleStreamWriter` から入力サイズを渡し、上の単一stream splice経路を使う。

LZMA_Alone は自前 LZMA1 の逐次単一 stream。properties 1 byte、dictionary LE32、
未知サイズ `UInt64.max` の13 byte headerを出し、EOSで閉じる。`lzmaLevel` の nil は6で、
extreme は nil にも適用する。従来の ZIP / 7z の nil と extreme の解決は変えない。
LZ4 は content checksum 付き単一 frame、4 MiBの独立blockを並列化する。レベルは一つ。
`finishAdditions` は組立中blockを区切ってdrainし、frameは `finish` まで閉じない。
Brotli は Apple の固定level 2、逐次単一stream。compressはblock modeのLZW、maxbits 16で逐次処理する。

lzip は [manual の File format](https://www.nongnu.org/lzip/manual/lzip_manual.html#File-format)
に従う独立framingで、lzip / lzlib / tarlzのGPL sourceを参照・移植しない。
各memberは `LZIP` + VN=1 + DSの6 byte header、自前LZMA1（lc=3 / lp=0 / pb=2、EOSあり）、
CRC32 LE32 + data size LE64 + member size LE64の20 byte trailerを持つ。
DSの下位5 bitをn、上位3 bitをfとして辞書は `2^n - (2^n / 16) × f`。
encoder presetの辞書は2の冪なのでf=0を使う。辞書を入力長やメモリ不足に合わせて宣言上縮めない。

`ParallelLzipCompressor` は `TarChunkCutter` と `OrderedChunkPipeline` を使い、member境界を優先する。
上限は `max(16 MiB, 3 × 辞書)`。大きいtar memberはheader群と本文を分け、それぞれ上限で分割する。
終端は独立member。level 0 / 6 / 9の上限は16 / 24 / 192 MiB。
入力全体を集めず、組立中を含め未出力はt個の枠に収め、独立memberを並列符号化して順序どおり出す。
`finishAdditions` は残りの入力をmemberとして出してdrainする。

`LZMAWriterConfiguration` の raw予算に入力・出力二片を加え、
`t × (encoder memory + 2 × member上限) <= min(memoryLimit, 物理メモリの50%)` を満たすよう並列数を制限する。
nilのmemoryLimitは物理メモリの50%、一つも入らなければ出力作成前に `invalidOption("memoryLimit")`。
raw encoderの予算は完全な辞書とrange buffer最大16 MiBを含む。pushは256 KiBずつdrainする。
入力byteの上界はlzipが `t × member上限`、LZ4が `t × 4 MiB`、逐次3形式が0。
codecの内部buffer・辞書・出力はpending inputの集計に含めない。

KaitoKitのsplice地図がある形式は引き続きgzip / bzip2 / XZだけ。
新しい5形式の `CompressedTarUpdater.assess` はnil、`open` は `UpdaterRouteError.requiresRewrite`。
`ArchiveRewriter` は各形式を出力でき、既存項目の削除・改名と追加はTarWriter経由の全体再符号化に戻す。
入力が別形式でも同じ経路を使い、KaitoKitは変更しない。

### 単独ファイルの圧縮 API（2026-10-06）

`SingleStreamFormat: Sendable, CaseIterable` はgzip / bzip2 / xz / zstd / lzma / lzip / lz4 / brotli / compress。
`SingleStreamCompressor.compress(file:to:format:options:progress:)` は通常ファイル一つから圧縮ファイル一つを新規作成する。
編集・複数source・メタデータ保存は扱わず、複数sourceは呼出側がtar.Xを作る。
公開の型は `API/SingleStreamCompressor.swift`、fileの寿命と公開は `Writer/SingleStreamWriter.swift`。

sourceをlstatし、通常ファイル以外（directory / symlinkを含む）は `WriterError.unsupportedFileType`。
`O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` で開いてdevice / inode / mode / size / mtimeを照合し、
既知サイズを256 KiBずつ読む。EOFと終了時のfd・pathのstatを照合し、変更時は `sourceChanged`。
`Progress` は入力長をtotal、実際に読んだbyteをcompletedへ設定する。圧縮の終了とは独立する。

出力の隣にUUID名の `.gyoshuku-stream-*.tmp` を `O_CREAT | O_EXCL` で作り、
圧縮終了・synchronize・取消し検査・pathとfdの所有照合後に `renamex_np(..., RENAME_EXCL)` で公開する。
先に出力存在を検査するが、最終renameも排他的なので読取中に現れたfileを上書きしない。
失敗・Task cancellation・Progress.cancelでは `ArchiveOwnedFile` のpath/fd照合で自分のinodeだけを削除する。

gzipは決定的header（FNAMEなし、MTIME 0、OS=3）と1 MiBの並列deflate block。
bzip2は上の入力サイズ別chunk幅でblockを並列圧縮し、単一streamへspliceする。tar.bz2の独立stream連結とは経路を分ける。
XZは単一stream内の独立blockで、nilはApple、指定levelは自前LZMA2。
LZMA / lzipのnilは自前level 6、extreme対応。LZ4は単一level、BrotliはApple固定level 2、compressはmaxbits 16。
既存の `WriterOptions` のvalidationとLZMAメモリ予算を出力作成前に適用する。

試験は `CompressedTarNewFormatTests` / `ArchiveRewriterNewTarFormatTests` / `SingleStreamCompressorTests`。
新tarはfile・空file・directory・symlink・日本語名・20 MiB混合入力を各独立decoderからbsdtarへpipeして
一覧・抽出・全byteを照合し、KaitoKitでも照合する。lzip level 0 / 6 / 9と複数memberはtrailerから数え `lzip -t` も使う。
ZIPとの相互変換とtar.lz4 / tar.lzの編集、単独9形式の既定の空・1 byte・128 KiB text・1 MiB + 17 byte乱数の全byte復号、
読取進捗・種別拒否・既存出力とrename競合・取消しcleanupを検査する。
乱数はbzip2 level 9の二つのblockを越える。元の1 MiB text・9 MiB乱数は `…FullSize` に残し、
`GYOSHUKU_LARGE_ENCODER_TESTS=1` で実行する。
空.Zと制限されたstdout再openは上記LZW節の実ツール方針を共有する。

### PPMd var.H / var.I encoder（2026-10-07）

`Compression/PPMd/` の internal `PPMd7StreamEncoder` は 7z method `03 04 01` の var.H、
`PPMd8StreamEncoder` は ZIP method 98 の var.I revision 1 を純 Swift で書く。
ZIP / 7z の writer と `WriterOptions.ppmdLevel` に接続し、updater の追加・7z solid 再圧縮・rewriter でも使う。
方式・framing・preset とメモリの契約は上の ZIP / 7z 節を参照する。
同期 API は `write(_:finish:emit:)`。呼出しをまたいで同じ model と range coder を更新し、入力全体を保存しない。
finish でない空 write は何も出さず、入力付き finish と別呼出しの finish をともに扱う。
finish、emit の失敗、キャンセルの後は instance を再使用できない。

出自は inbox の LZMA SDK 26.03 `C/Ppmd.h`、`Ppmd7.h`、`Ppmd7.c`、`Ppmd7Enc.c` と、
7-Zip 26.03 から同じ inbox に置いた `Ppmd8.h`、`Ppmd8.c`、`Ppmd8Enc.c`。
各原典は Igor Pavlov の公開ドメイン宣言を持ち、Dmitry Shkarin の公開ドメイン PPMd var.H（2001）/
var.I（2002）、Dmitry Subbotin の公開ドメイン carryless range coder（1999）に基づく。
SDK の `DOC/lzma-sdk.txt` と `inbox/7zip-License.txt` の明示された公開ドメイン条項を確認した。
Swift へ移植したもので、C を同梱・コンパイルしない。7-Zip の LGPL C++ encoder / ZIP wrapper は参照しない。
ZIP の parameter word は [PKWARE APPNOTE §5.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
による。KaitoKit の decoder は終了条件と公開 reader 経由の往復を確認するために読んだ。

heap は一つの allocation に置き、6 byte STATE と 12 byte CONTEXT / free unit を SDK と同じ配置で管理する。
永続 successor / suffix / stats は UInt32 offset。model 内の byte を文脈に昇格する処理、頻度の rescale、
free block の結合も Swift が行う。heap のサイズは指定の memorySize + 最大 3 byte の整列領域。
これに固定の確率表・mask・order 最大 32 の successor stack と 64 KiB 出力 buffer が加わる。
emit 用 Data のコピーも最大 64 KiB で、追加保持量は概ね 192 KiB 以下。呼出元が保持する入力・出力は含めない。
7z の carry 保留は byte 列ではなく UInt64 件数として保持し、排出時にも固定 buffer を使う。

2026-10-07 の高速化では model / arena / range coder を所有権付きの noncopyable struct にし、
入力 block の `withUnsafeBytes` 内で一度だけ `inout` を借りる。記号ごとの class 排他アクセスと
参照更新を減らし、固定の allocator / NS 表を pointer、SEE を SDK と同じ 4 byte にした。
SDK の first-state fast path、suffix の一回探索と 2 state ずつの mask 合計、rescale の安定な state 移動、
H の最大 2 回の正規化（binary success は 1 回）を反映した。round 2 では H / I を block の入口で
固定し、記号選択・binary 表・range coder を定数で特殊化した。single-state の symbol / freq は
明示した LE UInt16 で一度だけ読み、確率表と頻度更新で使い回す。H の UpdateModel で見つけた
suffix state を CreateSuccessors に渡して再探索を省き、更新・allocator の hot な加減乗算は
既存の範囲に基づく wrapping 算術にした。SDK の exponential escape 表は二つの UInt64 に詰め、
Array の bounds check を除いた。heap offset は最大 1 GiB 内、頻度は 16 bit、中間の積は 2^25 未満。
取消しを 4096 byte ごとの内側 loop の入口で確認し、記号ごとの判定を省く。
model の計算式・復元方法・framing は変えない。
追加保持量の 192 KiB 上限、per-worker reservation、4096 byte ごとのキャンセル確認、64 KiB の排出は維持する。
記号 loop 内の retain と class の動的な排他アクセスの範囲は、
`-O -wmo` の特殊化された encode 関数の SIL では未検証。

7z の order は 2...32、memorySize は 1 MiB...1 GiB（byte 単位）。5 byte coder properties は
order byte と memorySize の LE32。raw stream に properties や EOF marker は入れず、7z range coder を
5 byte flush する。展開サイズは folder に持たせる。メモリ不足時は model を restart する。
ZIP の order は 2...16、memorySize は整数 MiB の 1...256 MiB。
payload の先頭に `(order - 1) | ((memoryMiB - 1) << 4) | (restoration << 12)` の LE16 を置く。
restoration は restart=0 と cut-off=1。freeze は rev.1 / rev.2 の非互換のため実装しない。
Subbotin coder は各 escape の後と最終区間で正規化し、最後に root escape（symbol=-1）と 4 byte flush を書く。
cut-off は失敗までの部分更新を戻し、高次文脈を削り、使用量が heap の 3/4 以下になるまで解放する。

以下は GyoshukuKit 独自の level 1...9 表で、7-Zip C++ の default 計算からは導出していない。
level 5 / 6 は 16 MiB を基準にし、高 level は文脈と heap を増やす。明示 properties で表以外の値も指定できる。
ZIP の preset は既定 restart、指定した restoration も保持する。

| level | 7z order | 7z heap | ZIP order | ZIP heap |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3 | 1 MiB | 3 | 1 MiB |
| 2 | 4 | 2 MiB | 4 | 2 MiB |
| 3 | 4 | 4 MiB | 5 | 4 MiB |
| 4 | 5 | 8 MiB | 6 | 8 MiB |
| 5 | 6 | 16 MiB | 8 | 16 MiB |
| 6 | 6 | 16 MiB | 8 | 16 MiB |
| 7 | 8 | 32 MiB | 10 | 32 MiB |
| 8 | 12 | 64 MiB | 12 | 64 MiB |
| 9 | 16 | 192 MiB | 16 | 192 MiB |

encoder 単独試験は製品の serializer に頼らず、PPMd coder 一つの folder を持つ最小 7z と method 98 の最小 ZIP を作る。
KaitoKit の PPMd decoder は internal なので、公開 `ArchiveReader` の stream で全 byte を照合する。
独立 oracle は必須の `7zz t`、`7zz x -so`、`7zz l -slt`。
7zz 26.03 の表示は 7z が `PPMD:o6:mem24`（16 MiB は log2=24）、ZIP が `PPMd`。
既定は空、1 byte、64 KiB zeros、128 KiB text、256 KiB randomを扱う。
1 MiB heap の256 KiB + 17 byte textと256 KiBの全256値乱数（各byteを二度置く）で、H / I restartとI cut-offのcount > 0、
復旧後の7z / ZIP oracleとKaitoKit全byte復号を検査する。元の1 MiB text・8 MiB random・20 MiB textは
`…FullSize` に残し、`GYOSHUKU_LARGE_ENCODER_TESTS=1` で実行する。
byte ごと、不揃い chunk、非ゼロ startIndex の Data slice、終了後と emit 失敗後の拒否を検査する。
固定 seed の英文風 corpus では order 6 / 16 MiB の両 variant が `xz -6` より小さいことを要求する。
1 MiB の corpus の実測は H が 41,930 byte、I が 41,967 byte、xz -6 が 72,628 byte。
round 2 の対象 XCTest は release（`-Xswiftc -enable-testing`、debug 情報なし）で、
encoder 6 件 46.862 秒、writer options 1 件 0.001 秒、7z writer 5 件 24.715 秒、ZIP writer 5 件 16.674 秒が成功した。
凍結 fixture の `LZMAWriterDefaultOutputTests` / `LHADefaultOutputTests` /
`SevenZipHeaderSerializerTests` / `ZipModernMethodEditingTests` も 6 件成功。
全体は 23 件成功 + benchmark の門 1 件 skip、89.408 秒、build 81.00 秒。full suite は実行していない。
この XCTest の秒数は検証所要時間で、encoder の旧比を算出する計測ではない。
旧 encoder は f273d34 の PPMd source を Git から読出し、製品 tree 外の比較用 build に置く。
round 1 の比較は試験 corpus の 84 出力と benchmark の 12 出力、計 96 組で全 byte が一致した。
round 2 の再実行可能な比較は `Benchmarks/PPMd/run.py` に置き、製品 target / XCTest に旧版を依存させない。
最終版は dyld / zsh / 8 MiB mixed / 小入力、H order 2 / 4 / 8 / 16 / 32、
I order 2 / 4 / 8 / 16、heap 1 / 3 / 64 MiB、両 restoration の全組合せを比較した。
I の order 32 は形式・properties の契約外なので扱わない。text / dyld の全 level 1...9（I は両 restoration）と
分割 write も含めて **300 組全てで全 byte が一致**し、比較は178.139秒。全 level の自前サイズ増加は0%。
比較 payload、build command、全試行、load average、hash と oracle の書庫は指定した出力 directory に記録する。

encoder の旧比は非 XCTest の `Benchmarks/PPMd/run.py` で測る。
f273d34 と作業 tree の source を **両方 `swiftc -O -wmo -swift-version 6`** でビルドし、
`-enable-testing` を使わない。固定 seed の英文風 text 8,388,608 byte と `/usr/lib/dyld` 4,129,088 byte を使う。
round 3 の再計測は2026-10-07、Apple M4 Max / Swift 6.4、導入済みの 7zz は **26.04**。
旧→新→7zz の順で各11回を交互実行する best-of-11。参照書庫は各反復の前に削除し、
`7zz t` / `7zz x -so` / properties の確認は loop 後に一度だけ行う。MB/s は 1,000,000 byte/s。
測定中にこの作業の build / test は重ねていないが、Mac の他の負荷はある。
load average（1 / 5 / 15 分）は開始 3.99 / 3.79 / 4.50 → 終了 4.94 / 4.15 / 4.57。
12条件の計測・照合は82.146秒。build・全試行・参照propertiesの記録は、下の `Benchmarks/PPMd/run.py --runs 11` で再生成できる。
Swift は model allocation / payload 生成 / finish、7zz は起動 / file I/O / archive 作成を含む wall time。
Swift は process 内、7zz は process 全体の計時なので、ほぼ同等の行では起動・file I/Oの差がSwiftに数%有利に働く。
入力準備、CRC / container の組立、復号 oracle は計測外。SDK の内部 loop だけの速度比較ではない。
round 1 の XCTest `-enable-testing` baseline は旧版を不均等に遅くしたため、その速度表と倍率を撤回した。
`GYOSHUKU_PPMD_BENCHMARK=1` の XCTest は参照との照合用として残すが、旧版との倍率には使わない。

参照は H が `7zz a -t7z -m0=PPMd:o=<order>:mem=<MiB>m -mmt=1`、
I が `7zz a -tzip -mm=PPMd:o=<order>:mem=<MiB>m:a=0 -mx=<level> -mmt=1`。
H の order は 3 / 6 / 16、I は 3 / 8 / 16、heap は両方 1 / 16 / 192 MiB、I は restart を指定する。
`a=0` が無い高 level の ZIP は cut-off になる。7zz は入力サイズで heap を減らすため、
**level 9 の参照実値は text 128 MiB / binary 64 MiB**（Swift は 192 MiB）。
7z の `l -slt` / ZIP の parameter word で order / heap / restoration を確認し、JSON に実値も出す。
表の byte は payload サイズ（ZIP は 2 byte parameter word 込み）。level 9 の binary サイズ差は heap 条件が異なる。

| corpus | var. | level | 旧 MB/s | 新 MB/s | 7zz MB/s | 旧=新 byte | 7zz byte |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| text | H | 1 | 77.88 | 142.18 | 125.09 | 703,855 | 703,855 |
| text | H | 6 | 95.69 | 195.54 | 162.02 | 328,737 | 328,737 |
| text | H | 9 | 89.21 | 135.30 | 115.66 | 293,408 | 293,408 |
| text | I | 1 | 70.60 | 128.57 | 113.79 | 704,541 | 704,541 |
| text | I | 6 | 81.36 | 176.49 | 141.15 | 297,284 | 297,284 |
| text | I | 9 | 77.59 | 126.88 | 107.21 | 294,144 | 294,144 |
| binary | H | 1 | 10.95 | 23.54 | 23.38 | 1,286,117 | 1,286,117 |
| binary | H | 6 | 9.17 | 18.68 | 18.47 | 1,110,799 | 1,110,799 |
| binary | H | 9 | 8.58 | 15.74 | 15.13 | 903,351 | 1,057,380 |
| binary | I | 1 | 10.52 | 22.95 | 22.90 | 1,282,687 | 1,282,687 |
| binary | I | 6 | 8.14 | 17.19 | 17.44 | 1,134,452 | 1,134,452 |
| binary | I | 9 | 8.35 | 15.57 | 14.87 | 900,741 | 1,053,497 |

level 6 の旧比は H が text 2.044 倍 / binary 2.038 倍、
I が text 2.169 倍 / binary 2.113 倍。
H level 6 の新 / 7zz 比は text **120.7%** / binary **101.1%**（丸める前の速度から算出）。
binary は 7zz とほぼ同等で負荷に依存する。
I level 6 の binary 比は98.6%。他の環境での速度の下限を保証する値ではない。
表の出力は全て旧版と同一。参照と同じ heap の level 1 / 6 は 7zz のサイズにも一致した。

残る時間は診断用の別 build で 1024 回ごとの `mach_absolute_time` を20回分集計した。
計測 overhead・sampling の偏りがあるため概算で、上の速度表には使わない。
binary の model update は H 2,051,159 回 / I 2,387,554 回、suffix escape は H 827,690 回 / I 895,793 回。
記号処理内の model update は H 約49% / I 約39%、CreateSuccessors は約17% / 約15%、rescale は約5% / 約3%。
suffix escape 全体は約77% / 約59% で、探索・mask 合計・range coder・選択後の update を含む。
CreateSuccessors は update の内数、update の一部は suffix の内数なので、これらの割合は加算しない。
text の model update は H 5,279 回 / I 7,812 回（約0.2% / 約0.4%）に留まり、binary / first-state の経路が中心。

導入時のrelease 6件は55.7秒で成功し、元の大入力と両復元方法を全て照合した。
導入時のdebug大入力2件も成功した（約26分）。大きなcorpusの照合にはreleaseを推奨する。
encoder 高速化の round 1 の debug 記録は **前後の実行が重なり、他の oracle も同時実行された参考値**。
逐次実行の速度比較として扱わない。encoder 単体（`-Onone` harness、8 MiB random、order 6 / 16 MiB、1 回）は
H 239.118 → 43.602 秒、I 250.084 → 57.227 秒、出力はそれぞれ 8,580,567 / 8,591,123 byte で一致した。
`PPMdEncoderTests` は旧版 6 件成功 1941.041 秒 → round 1 の 6 件成功 1586.002 秒。
`testLargeTextAndRandom` は 1243.960 → 983.561 秒、20 MiB restoration 試験は 681.143 → 590.132 秒だった。
KaitoKit の復号・CRC / container の準備を含み、同時負荷も異なるため改善率は算出しない。
この debug の 36 書庫も旧版と全 byte 一致した。前後の生成書庫は別 directory に保存して照合した。
encoder 高速化の round 2 の debug は旧版との速度比較を行わず、properties / 小入力・order 上下限 / 分割 write・失敗後の拒否 /
writer options の4件を逐次実行し、7.227秒で全件成功した（`-Onone`、`-enable-testing`、debug情報なし）。

別の試験側の高速化は、encoder sourceを基準版のまま保ち、既定入力の縮小とoracle処理の共有を行った。
そのround 1のDEBUG実測は、PPMd以外も含む対象classのbest-of-5合計5,421.581 s → 974.804 s（82.0%短縮、5.56倍）。
5並列のXCTest class時間の合計で、全suiteの壁時計やPPMd単独のthroughputではない。
既定coverage・試験側のround 2 / 3の再検証・再計測用runnerは [検証記録](verification/2026-10-07-encoder-debug-speed.md) を参照する。
PPMd のoracle書庫とlogは下のfilterで再生成する。8 classのFullSize 14件はCIでもXcode 27でbuildし、macOS 27 / 26でrelease実行する。

```sh
swift build
swift test --filter PPMd
git diff --stat
# cache が sandbox 外になる環境の検証用。製品の実行条件ではない。
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --disable-sandbox
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox --filter PPMd
# 元の大きな corpus を照合する場合
GYOSHUKU_LARGE_ENCODER_TESTS=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift test --disable-sandbox -c release --filter PPMd
# Swift 6.4 の swiftbuild が dSYM 作成を禁止される環境では debug 情報を省略できる。
GYOSHUKU_LARGE_ENCODER_TESTS=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift test --disable-sandbox -c release -debug-info-format none --filter PPMd
# XCTest の参照比較（-enable-testing。旧版との速度倍率には使わない）
GYOSHUKU_PPMD_BENCHMARK=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift test --disable-sandbox -c release -Xswiftc -enable-testing -debug-info-format none \
  --filter PPMdEncoderBenchmarkTests
# 非 XCTest、同一 -O -wmo の release。build / bench / identity を逐次実行する。
python3 Benchmarks/PPMd/run.py --runs 11
# overhead を含む stage 診断（速度の表には使わない）
python3 Benchmarks/PPMd/run.py --mode profile
```

### 自前 Zstandard frame encoder（2026-10-07）

`Compression/Zstd/ZstdFrameEncoder.swift` の internal `ZstdFrameEncoder` は、RFC 8878 の frame を純 Swift で書く。
同期 API は `write(_:finish:emit:)`、独立 frame を作る helper は `encode(_:level:)`。
`contentSize` が既知なら header に保存し、受取長の過不足を `sourceChanged` として拒否する。
空の非 finish write は出力しない。finish、emit の失敗、取消しの後は `invalidState` で再利用を拒否する。
writer 接続と独立 frame の並列化は下の節を参照する。

frame は magic、dictionary ID なしの header、最大 128 KiB の block、XXH64(seed=0) の下位 32 bit checksum。
checksum flag は常に有効。既知サイズが window 以下なら single segment、それ以外は window descriptor を書く。
既知サイズの 1 / 2 / 4 / 8 byte 表現（2 byte の +256 を含む）、未知サイズ、空 frame、連結 frame に対応する。
raw / RLE / compressed block を選び、圧縮して縮まらない block は raw に戻す。
literals は raw / RLE / Huffman の完全な section サイズで選択し、Huffman は小入力で 1 stream、大入力で 4 streams。
Huffman の深さは最大 11 bit。重みは最大 symbol が 128 以下なら直接 nibble、それ以外は 2 状態 FSE で記述する。
sequence は LL / OF / ML の predefined / RLE / 独自に正規化した FSE table を、header と推定遷移 bit 数の費用で選ぶ。
FSE log は LL / ML が 5...9、OF が 5...8。RFC の復号 table の各遷移区間を反転して符号化 table を得る。
repeat offset の初期値 1 / 4 / 8、LL=0 の規則、rep1-1、compressed block 間の引継ぎを扱う。
raw / RLE block は repeat offset を変更しない。treeless Huffman、sequence Repeat_Mode、dictionary、ultra は生成しない。

以下は GyoshukuKit 独自の level 表で、参照実装の preset を転記していない。
fast は8 byte loadから5 byteをhashする主表とprefix tag、直近のrepeatを調べる専用解析。
double hash は unaligned 8 byte load の主 hash と4 byteの補助 hash を一回ずつ調べる greedy 解析。
不一致区間は適応サンプリングし、一致内の辞書更新は低 level ほど間引く。
lazy / lazy2 は8 byte / 4 byteの循環 row table と1 / 2 byte先読みを使う。
row は16 / 32 / 64 / 128候補、tag は `SIMD16<UInt8>` / `SIMD32<UInt8>` で比較し、新しい候補から調べる。
4 byte row は8 byte以上の候補がない場合に短い一致を補う。深さ96以上では一致内も全位置を挿入する。
lazy2 は1 byte先で nice / 8以上の改善一致を得た場合、2 byte先を辞書挿入だけにして探索を省く。
一致内のサンプリング位置は従来の先読み2と同じに保つ。
optimal は 3 / 4 byte hash と binary tree を使い、
byte ごとの最小推定費用・literal run・repeat 履歴を保持する近似最短路解析。
各位置で一つの履歴に併合し、短い match の全長、長さ code 境界と最長 match を比較する。
nice 長以上の一致は終端へ進むため、完全な最適解析ではない。前 block の sequence 頻度で費用を更新する。
block 末尾の短い key は木の子を引き継がず、未知の後続 byte に依存した順序を持ち越さない。

| level | strategy | window | hash log | depth | nice length | 概算 memory 上限 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | fast | 1 MiB | 17 | 1 | 32 | 7.75 MiB |
| 2 | fast | 1 MiB | 18 | 1 | 48 | 8.25 MiB |
| 3 | double hash | 2 MiB | 18 | 2 | 64 | 10.25 MiB |
| 4 | double hash | 2 MiB | 19 | 2 | 80 | 11.25 MiB |
| 5 | double hash | 2 MiB | 19 | 2 | 96 | 11.25 MiB |
| 6 | lazy | 2 MiB | 19 | 16 | 64 | 19.25 MiB |
| 7 | lazy | 2 MiB | 19 | 24 | 80 | 19.25 MiB |
| 8 | lazy | 4 MiB | 19 | 32 | 96 | 31.25 MiB |
| 9 | lazy2 | 4 MiB | 20 | 48 | 128 | 33.25 MiB |
| 10 | lazy2 | 4 MiB | 20 | 64 | 160 | 33.25 MiB |
| 11 | lazy2 | 4 MiB | 20 | 96 | 192 | 33.25 MiB |
| 12 | lazy2 | 4 MiB | 20 | 128 | 256 | 33.25 MiB |
| 13 | optimal | 8 MiB | 20 | 64 | 128 | 100.25 MiB |
| 14 | optimal | 8 MiB | 20 | 96 | 160 | 100.25 MiB |
| 15 | optimal | 8 MiB | 20 | 128 | 192 | 100.25 MiB |
| 16 | optimal | 8 MiB | 21 | 192 | 256 | 104.25 MiB |
| 17 | optimal | 8 MiB | 21 | 256 | 384 | 104.25 MiB |
| 18 | optimal | 8 MiB | 21 | 384 | 512 | 104.25 MiB |
| 19 | optimal | 8 MiB | 21 | 512 | 768 | 104.25 MiB |

memory は `estimatedMemoryBytes` の保守的な見積り。二つ分の window、UInt32 hash head、chain または tree のリンク、
block / entropy / parser scratch の予算を含み、呼出元が保持する入力・出力と allocator の管理領域は含めない。
level 6...12の上表は、従来からコードが予約していた値に訂正した（以前の表は UInt32 link の byte 数を過少記載）。
row table の実確保は従来の chain 予算以下。optimal の永続 node と長さ別価格表は既存16 MiB scratch 内に収める。
round 3の level 1 / 2は4 byte補助 headを省き、1 byteのtag表（128 / 256 KiB）に置き換える。
見積りは従来の256 KiB補助 head予算を残すため保守的な上界を保つ。window・pending input・worker予約は変わらない。
連続 buffer は window ごとに compact し、入力全体を保存しない。未処理入力は 128 KiB 以下。
長い stream の table position は 2 GiB ごとに番号を縮め、live window を保つ。
比較・table 反転・符号化の hot loop は検証済み範囲の unsafe buffer を使い、unaligned load は初期化済み入力だけを読む。

出自は [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878) と
[公開 xxHash specification の XXH64](https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md) からの独立実装。
各新規 Swift file の先頭に `Independent implementation from RFC 8878; no zstd source consulted` を記す。
facebook/zstd の `lib/*` その他の参照実装 source は読んでおらず、移植・翻訳・vendor code はない。
KaitoKit の MIT decoder の frame / Huffman / FSE / sequence の復号規則を相互運用の確認に読んだ。
match finder も独自に実装し、LZMA SDK 由来の既存 finder の code を取り込まない。製品に外部 codec library を加えない。

試験は `Tests/GyoshukuKitTests/Compression/Zstd/`。必須の `/opt/homebrew/bin/zstd` で `-t` と `-dc`、
公開 KaitoKit readerで全byteを照合する。level 1 / 3 / 9 / 19の既定は空・1 byte・64 KiB zeros・
128 KiB + 17 byte text・256 KiB + 17 byte randomと、不揃いchunk、非ゼロData startIndex、未知content size、連結frame。
混合入力は各levelの2 × window + blockSizeを越え、window + 4096 byte先の乱数とcompact後のwindow内text再出現、
raw / RLE / compressedを検査する。元の1 / 8 MiBと20 MiB text/binaryは `…FullSize` に残し、`GYOSHUKU_LARGE_ENCODER_TESTS=1` で実行する。
全 19 level の短い周期列、Huffman の 1 / 4 streams と両 tree 表現、sequence 長さ code の境界と repeat 規則も扱う。
木のblock末尾は既定256 KiB + 17 byte text、元の4 MiBは `…FullSize` に残す。
XXH64は既知vector、stripeをまたぐchunk、seedと非破壊digestを検査する。
外部ツールが無い場合は Tests/README.md の方針どおり失敗する。

benchmark は `GYOSHUKU_ZSTD_BENCHMARK=1` の release 限定。
text は `LZMAEncoderCorpus.text` の固定 seed の英文風単語列 4,194,304 byte。
binary は `/usr/lib/dyld` 4,129,088 byte と実在する
`/System/Library/Frameworks/CreateML.framework/Versions/A/CreateML` 16,559,504 byte の連結、計 20,688,592 byte。
Swift は instance 確保・checksum を含む `encode` の最良時間（最低5回、累積0.3秒以上、最大20回）を使う。
`GYOSHUKU_ZSTD_ALL_LEVELS=1` は全19 levelを測る。
サイズは `zstd -<level> -T1 -c` の出力、参照速度は同じ corpus の `zstd -b<level> -e<level> -i1 -T1` の内部計測。
後者は process 起動と file I/O の時間を除く。MB/s は 1,000,000 byte/秒。
目標未達は `ZSTD-BENCH-MISS` に記録し、計測試験の失敗条件にせず、実測値と profile をここに報告する。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --disable-sandbox -c release
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox --filter Zstd
GYOSHUKU_ZSTD_BENCHMARK=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift test --disable-sandbox -c release -debug-info-format none --filter ZstdEncoderBenchmarkTests
git diff --stat
```

#### Zstandard 高速化 round 1（2026-10-07）

実測（Apple M4 Max / 128 GB、macOS 27.2、Apple Swift 6.4、Zstandard CLI 1.5.7）。
基準は `f273d34` の変更前 source。最初に既存 `ZstdEncoderBenchmarkTests` を基準版の release で計測し、
最低5回のベンチマーク、変更版の targeted test と連続比較も行った。並行 workstream の負荷で CLI の値も変動するため、
下表は追加の同一 process 計測を使う。基準版は型名だけを `BaselineZstd...` に変更して同じ program に組み込み、
両 source を `swiftc -O -whole-module-optimization` で build。入力を一度読み、条件ごとに両 encoder を交互に5回実行した最良値。
CLI は同じ corpus の `-b<level> -e<level> -i1 -T1` を5回実行した最良値。bytes は checksum 込みの完全な frame。
追加 program の16 frameも `zstd -t` に成功し、製品版の benchmark は zstd と KaitoKit の全 byte 照合に成功した。

| corpus | level | 基準 MB/s | 変更 MB/s | CLI MB/s | 基準 bytes | 変更 bytes | CLI bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| text | 1 | 151.059 | 283.704 | 561.100 | 1,008,821 | 974,556 | 1,022,409 |
| text | 3 | 163.713 | 223.468 | 520.000 | 933,816 | 933,781 | 970,449 |
| text | 9 | 15.881 | 37.587 | 83.200 | 916,309 | 786,451 | 944,619 |
| text | 19 | 2.072 | 3.685 | 4.020 | 704,190 | 704,190 | 692,480 |
| binary | 1 | 95.909 | 152.702 | 734.500 | 7,997,811 | 7,880,014 | 9,037,641 |
| binary | 3 | 97.473 | 143.753 | 458.300 | 7,371,581 | 7,369,211 | 7,570,180 |
| binary | 9 | 13.523 | 31.918 | 111.800 | 6,920,557 | 6,935,984 | 6,898,131 |
| binary | 19 | 3.258 | 5.794 | 6.310 | 5,339,170 | 5,339,170 | 5,204,544 |

text: level 9は基準の2.367倍、level 19は1.778倍。各2倍 / 1.3倍の目標を達成。

binary: level 9は基準の2.360倍、level 19は1.778倍。各2倍 / 1.3倍の目標を達成。

level 1 / 3の CLI 速度比は次の通り。両 corpus で50%という目標は未達で、70%の stretch も未達。
level 1: text は負荷により約50%±1〜2ポイント、binary 20.8%。
level 3: text 43.0%、binary 31.4%。

全19 level・両 corpusの38条件で、変更後のサイズ増加は最大 +0.222916%（binary level 9）。
level 3の CLI サイズ +10%以内、level 19の +8%以内も達成。level 13...19の frame サイズは基準と同じ。
サイズ・速度は、両commitのSwift sourceを上記の同一programに組み込み、全19 levelを交互に実行して再生成する。

最適化は fast の8 / 4 byte hash 専用経路、repeat の3 byte一括判定、row の SIMD tag 比較と lazy2 の探索省略、
optimal の node / 長さ価格表の再利用と候補ごとの配列生成廃止。sequence code は確保済み buffer に書き、
FSE遷移とextra bitをまとめて64 bit accumulatorへ追加する。Huffmanの4 streamを交互に進め、
literal集約は確保済み Dataへの一括copyに変えた。window・checksum・frame/blockの仕様は維持する。

以下の公開 writer の並列測定は XCTest release（`-enable-testing`）で、level 3、4 MiB text + 上記Mach-Oを繰り返した268,435,456 byte。
`.zst` は `SingleStreamCompressor.compress`、`tar.zst` は一つのfileを `ArchiveWriter` に追加してfinish。
file I/O・checksum・frame組立・公開処理を含む5回の最良値を、基準版→変更版の順に連続測定した。
出力は各実装・各形式内で1 / 4 / 8 / 12 thread間のbyte一致、全出力のzstd検査に成功。

| format | threads | 基準 MB/s | 変更 MB/s | 基準 bytes | 変更 bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| .zst | 1 | 99.453 | 143.923 | 91,115,521 | 91,127,531 |
| .zst | 4 | 368.017 | 547.302 | 91,115,521 | 91,127,531 |
| .zst | 8 | 460.064 | 832.759 | 91,115,521 | 91,127,531 |
| .zst | 12 | 652.075 | 942.108 | 91,115,521 | 91,127,531 |
| tar.zst | 1 | 99.347 | 142.500 | 91,115,621 | 91,127,631 |
| tar.zst | 4 | 331.825 | 537.067 | 91,115,621 | 91,127,631 |
| tar.zst | 8 | 500.033 | 819.919 | 91,115,621 | 91,127,631 |
| tar.zst | 12 | 610.604 | 913.015 | 91,115,621 | 91,127,631 |

変更版の12 threadは1 thread比で `.zst` 6.546倍、`tar.zst` 6.407倍。線形ではないが並列数で伸びる。
XXH64とencoder内の入力copyは元からworkerで実行される。producerには片の組立copyがあるが、
今回明らかなserial checksumは見つからず、`ParallelZstdCompressor` / 共通pipelineは変更していない。
並列測定は `GYOSHUKU_ZSTD_PARALLEL_BENCHMARK=1` とreleaseの `ZstdParallelBenchmarkTests` filterで再実行する。
tarのsource timestampは各runで生成されるfileのmtimeを使う。

round 1 の release は `ZstdEncoderTests` / `ZstdXXH64Tests` / `ZstdWriterConfigurationTests` /
`CompressedTarZstdTests` / `ZipZstdWriterTests` / `ZstdEncoderBenchmarkTests` / `ZstdParallelBenchmarkTests` の
26件成功・失敗0・117.727秒。debugの高速testは13件成功・失敗0・13.947秒。
その後の並列benchmarkは基準1件50.144秒、変更1件33.007秒で成功。
再検証は上記classのfilterを使い、大入力を含める場合は `GYOSHUKU_LARGE_ENCODER_TESTS=1` を指定する。全test suiteは走らせていない。
fixtureは再生成・変更せず、public APIと取消し・進捗・error処理の経路を変えていない。
測定はこのMacの二つのcorpusのみで、別入力の速度・比率、Intel Macは未測定。並行負荷による揺れは残る。
当時の `git diff --check` は成功。

#### Zstandard 高速化 round 2（2026-10-07）

基準 `f273d34`、round 1 `74492a9`、round 2 を一つの非 XCTest harness に組み込み、
全て同一の `swiftc -O -wmo` で buildした。`-enable-testing` は使わない。
過去版は型名と helper 名だけを変更し、元の commit と照合した。corpus は上記と同じで入力を一度だけ読む。
各条件で基準→round 1→round 2→CLI、次回は逆順に交互実行し、各7回の最良値を採る。
CLI は `-b<level> -e<level> -i1 -T1`、Swift は instance・checksum・frame 組立を含む。
Apple M4 Max、macOS 27.2（26B5101f）、Apple Swift 6.4、CLI 1.5.7。
測定中の1分 load average は5.78〜7.40。負荷による変動を含み、CLI 比は各最良値の比である。

| corpus | level | 基準 MB/s | round 1 MB/s | round 2 MB/s | CLI MB/s | round 2 / CLI |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| text | 1 | 155.478 | 288.009 | 339.775 | 575.300 | 59.1% |
| text | 3 | 165.820 | 232.413 | 287.624 | 531.600 | 54.1% |
| binary | 1 | 98.662 | 158.110 | 233.704 | 752.300 | 31.1% |
| binary | 3 | 99.695 | 149.228 | 192.111 | 475.500 | 40.4% |

text の50%と binary level 3の40%は達成。binary level 1の40%は未達で、あと約29%の速度向上が必要。
60%の stretch は全条件で未達。round 1比では text 1 / 3が1.180 / 1.238倍、binary 1 / 3が1.478 / 1.287倍。
binary level 3の達成幅は小さく、別の負荷・corpus で40%を保証する値ではない。
同じ比較は基準・round 1・round 2のsourceを上記の非XCTest条件でビルドし、全sampleと負荷を記録して再生成する。

| corpus | level | 基準 bytes | round 1 bytes | round 2 bytes | CLI bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| text | 1 | 1,008,821 | 974,556 | 993,183 | 1,022,409 |
| text | 3 | 933,816 | 933,781 | 933,779 | 970,449 |
| text | 19 | 704,190 | 704,190 | 704,190 | 692,480 |
| binary | 1 | 7,997,811 | 7,880,014 | 8,001,664 | 9,037,641 |
| binary | 3 | 7,371,581 | 7,369,211 | 7,372,748 | 7,570,180 |
| binary | 19 | 5,339,170 | 5,339,170 | 5,339,170 | 5,204,544 |

全19 level・両 corpus の38条件で基準比 +0.3%以内。最大は binary level 9の +0.222916%。
level 3の CLI サイズ +10%以内、level 19の +8%以内も保つ。
level 1の出力は round 1より大きいが、基準比は text −1.550126%、binary +0.048176%。
全サイズは全19 levelの各版とCLIのframe byte数から再生成する。サイズ確認用の1回実行の速度は性能値に使わない。

level 1 / 2は8 byte load から5 byteを hash し、二位置の head 読取・更新を先行させる。
fast / double hash の表を loop 全体で借り、一致内の挿入をまとめる。短い周期は最後の一周期と境界の挿入だけで同じ表を保つ。
repeat は8 byte XORから一致長を求め、重複した距離を調べない。入口で block・position・repeat の範囲を検証し、
有界な fast loop 内の重複する整数幅判定を省く。末尾は初期化済み範囲を読む従来の短い比較を使う。
sequence 配列、prepared command、literal 集約 buffer を block 間で再利用する。
sequence の code・extra・四レーンの頻度表を一度で作り、FSE選択で同じ histogram を走査し直さない。
Huffman も四レーンで頻度を数え、256 symbolの頻度差が2倍以内なら最適な8 bit固定木より raw が小さいため木の構築を省く。
code は2 byteに詰め、tree の leaf sortと再帰書込を軽くし、rawを選ぶ前の Data copy を省く。

sequence 予約は最大 offset codeを求め、releaseでも `precondition(maxOf <= 30)` を通してから `n * 11 + 16` を確保する。
56 bitを超える extraは二回に分割し、bit writerの既存assertを維持する。`windowLog <= 23` に依存する予約ではない。
sequence 数も `128 KiB / 3` 以下を検証する。固定 prepared領域は約0.667 MiB、literal領域は128 KiB、頻度領域は3 KiB。
保持する sequence配列を含め、fast / lazy の既存5 MiB scratch、optimal の16 MiB scratch予算内に収める。
window・pending input・worker予約・checksum・並列pipelineの契約は変えない。

6 byte hash、強い miss 間引き、短い一致の疎な挿入はサイズ上限を越えたため戻した。
repeatを一つだけにする案も binaryサイズを約2.6%悪化させた。lazy先読みはサイズを改善したが速度を落とした。
FSE表の再利用、sequence配列の一括初期化、repeatの不一致mask化も十分な改善がなく戻した。
binary level 1には引き続き match+parseが最大の時間を占め、XXH64は約1 ms / 20 MiBなので変更していない。
段階profileは `collectProfile: true` の別encodeで再生成し、計時callbackなしの速度計測と分ける。

最終 source の段階 profile（同じ非 XCTest build、各1回、binary 全体の経過 ms）。
計時用 callback を有効にした値で、7回測定の性能表とは区別する。

| level | stage | round 1 ms | round 2 ms |
| --- | --- | ---: | ---: |
| 1 | match+parse | 78.630 | 53.448 |
| 1 | literals（集約を含む） | 19.985 | 15.830 |
| 1 | sequences | 35.140 | 20.882 |
| 3 | match+parse | 86.324 | 70.641 |
| 3 | literals（集約を含む） | 18.933 | 13.405 |
| 3 | sequences | 33.063 | 22.058 |

round 2 の release は `ZstdEncoderTests` / `ZstdXXH64Tests` / `ZstdWriterConfigurationTests` /
`CompressedTarZstdTests` / `ZipZstdWriterTests` / `ZstdParallelBenchmarkTests` の28件成功・失敗0・53.823秒。
`--disable-sandbox -c release -Xswiftc -enable-testing -debug-info-format none` を使う。
この XCTest の速度値は上の非 XCTest 性能表に使わない。`.zst` / `tar.zst` の256 MiB入力で
1 / 4 / 8 / 12 thread間の出力がbyte一致し、CLI検査にも成功した。
debugの対象10件は成功・失敗0・14.145秒。新規試験は二位置loopの0...15 byte末尾・非圧縮性区間後の短い周期、
一様literalのraw選択、offset code 30と61 bit extraの予約済み出力を含む。
全19 level・両 corpus・基準 / round 1 / round 2の114 frameをCLIで全 byte復号照合し、
交互測定で保存した12 frameも同じ出力と照合した（CLIサイズ確認を含め7.712秒）。
同じclassとopt-inで試験・oracle出力を再生成できる。過去版の件数・秒数は当時の試験構成による。
fixtureは変更せず、全suiteは走らせていない。

#### Zstandard 高速化 round 3（2026-10-07）

基準 `f273d34`、round 2 `914f6c0`、round 3を同じ非 XCTest harness に組み込み、
型名・helper名だけを変えた過去 source を元commitと照合した。
全版とも `swiftc -O -wmo -module-cache-path .build/clang-module-cache`、`-enable-testing` なし。
入力は一度だけ読み、instance確保・checksum・frame組立を含む encode を測る。
基準→round 2→round 3→CLI と逆順を交互に各7回実行し、最良値同士を比較する。
CLI 1.5.7は `-b<level> -e<level> -i1 -T1` の内部計測、MB/sは1,000,000 byte/秒。
Apple M4 Max / macOS 27.2（26B5101f）/ Apple Swift 6.4。
この計測中の1分load averageは3.26〜6.82。サイズ確認・XCTestは速度計測と別に実行した。

| corpus | level | 基準 MB/s | round 2 MB/s | round 3 MB/s | CLI MB/s | round 3 / CLI |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| text | 1 | 154.427 | 340.820 | 355.215 | 575.900 | 61.7% |
| text | 2 | 154.446 | 340.105 | 355.804 | 561.700 | 63.3% |
| text | 3 | 162.913 | 287.981 | 289.526 | 534.000 | 54.2% |
| binary | 1 | 98.862 | 231.887 | 315.152 | 753.300 | 41.8% |
| binary | 2 | 97.123 | 214.951 | 312.138 | 593.300 | 52.6% |
| binary | 3 | 101.221 | 195.438 | 207.364 | 478.500 | 43.3% |
| mixed | 1 | 220.669 | 462.567 | 618.842 | 1192.700 | 51.9% |
| mixed | 2 | 222.458 | 462.134 | 613.266 | 1032.400 | 59.4% |
| mixed | 3 | 126.347 | 386.194 | 397.444 | 799.800 | 49.7% |

binary L1のCLI比はこの計測で41.8%、独立再計測では39.4%だった。約40%の目標境界にあり、達成判定は負荷に依存する。
binary L3の40%、text L1/L3の50%はこの計測で満たした。
binary L1の50% stretchは未達。値はこのMac・三つのcorpus・測定時の負荷に限る。
L1/L2の予算は各corpusで基準比 +2.0%以内かつ同levelのCLI以下、L3以上は基準比 +0.3%以内。
全19 level × 3 corpusの57条件で成立した。L1/L2の最大増はbinary L1の +1.740389%、
L3以上の最大増はbinary L9の +0.222916%。L3のCLI比 +10%、L19の +8%以内も保つ。
サイズは各一回のencodeと `zstd -<level> -T1 -c` のframe全体（checksumあり）のbyte数。
この確認の実行時間は上の速度値に使わない。

| corpus | level | 基準 bytes | round 2 bytes | round 3 bytes | CLI bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| text | 1 | 1,008,821 | 993,183 | 1,007,734 | 1,022,409 |
| text | 2 | 1,008,787 | 993,073 | 1,007,669 | 1,019,676 |
| text | 3 | 933,816 | 933,779 | 933,779 | 970,449 |
| text | 19 | 704,190 | 704,190 | 704,190 | 692,480 |
| binary | 1 | 7,997,811 | 8,001,664 | 8,137,004 | 9,037,641 |
| binary | 2 | 7,985,150 | 7,940,706 | 8,068,679 | 8,319,767 |
| binary | 3 | 7,371,581 | 7,372,748 | 7,372,748 | 7,570,180 |
| binary | 19 | 5,339,170 | 5,339,170 | 5,339,170 | 5,204,544 |

追加したmixed corpusは16,777,216 bytes。`ZstdEncoderCorpus.mixed` で64個の256 KiB区間を作り、
各区間の先頭512 byteは固定のustar風header、その後は乱数・text・Mach-O・乱数の順に配置する。
乱数はxorshift64（左13・右7・左17）、初期値 `0x726F756E64330001`、各更新の下位byteを使う。
圧縮済み風の高entropy部分は実際のJPEG/zstd/xzではなく乱数。text/binaryは上記の同じ入力で、
区間番号/4 × 261,632 byteを開始位置として末尾で循環する。日時・uid/gidは0、modeは0644。
SHA-256は `c173284311befae01e348b2d953d039d5a3493dd7f1e4de5ea79ee6631af7cf9`。
textは4,194,304 bytes、binaryはdyld 4,129,088 + CreateML 16,559,504 = 20,688,592 bytes。
再計測時は `ZstdEncoderCorpus.mixed` と同じ入力を保存し、text / binaryも含めてSHA-256を記録する。

| mixed level | 基準 bytes | round 2 bytes | round 3 bytes | CLI bytes | 基準比 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 10,751,883 | 10,753,769 | 10,796,603 | 10,929,529 | +0.415927% |
| 2 | 10,751,622 | 10,750,390 | 10,791,686 | 10,843,327 | +0.372632% |
| 3 | 10,658,740 | 10,648,507 | 10,648,507 | 10,723,527 | -0.096006% |
| 4 | 10,646,099 | 10,641,061 | 10,641,061 | 10,710,788 | -0.047322% |
| 5 | 10,646,099 | 10,641,061 | 10,641,061 | 10,698,145 | -0.047322% |
| 6 | 10,653,735 | 10,512,076 | 10,512,076 | 10,652,061 | -1.329665% |
| 7 | 10,637,429 | 10,493,379 | 10,493,379 | 10,639,591 | -1.354181% |
| 8 | 10,613,585 | 10,484,516 | 10,484,516 | 10,615,580 | -1.216074% |
| 9 | 10,568,202 | 10,470,978 | 10,470,978 | 10,608,354 | -0.919967% |
| 10 | 10,541,523 | 10,469,476 | 10,469,476 | 10,582,011 | -0.683459% |
| 11 | 10,507,653 | 10,459,454 | 10,459,454 | 10,538,263 | -0.458704% |
| 12 | 10,483,644 | 10,458,444 | 10,458,444 | 10,538,063 | -0.240374% |
| 13 | 10,076,329 | 10,076,329 | 10,076,329 | 10,462,598 | +0.000000% |
| 14 | 10,079,410 | 10,079,410 | 10,079,410 | 10,451,591 | +0.000000% |
| 15 | 10,079,084 | 10,079,084 | 10,079,084 | 10,444,466 | +0.000000% |
| 16 | 10,078,747 | 10,078,747 | 10,078,747 | 10,367,059 | +0.000000% |
| 17 | 10,076,688 | 10,076,688 | 10,076,688 | 10,019,107 | +0.000000% |
| 18 | 10,076,227 | 10,076,227 | 10,076,227 | 9,972,525 | +0.000000% |
| 19 | 10,077,623 | 10,077,623 | 10,077,623 | 9,958,324 | +0.000000% |

L1/L2は一つ先の位置でrep0を先に調べ、現在位置の5-byte hash候補をtagで絞る専用loopにした。
探索用のrepeatは直近距離だけを保持し、RFCの三つのrepeatの更新はsequence encoderで行う。
tagは4-byte prefixから作る1 byteで、採用時には実入力と履歴距離を検証する。
fastで使わない256 KiBの短いheadを省き、tag表はL1が128 KiB、L2が256 KiB。
見積り・window・pending input・worker予約の契約を変えず、頻度表10 KiBは従来の5 MiB scratch内に収める。
Huffmanの1024 laneと256 countはframe所有のworkspaceに移し、blockごとの確保を省いた。
literalの広いcopyを行うsequence loopには `assert(s.length >= 3)` を加えた。

予約済みbit writerは各appendで完了byteを吐き、残りを0...7 bitに保つ。
入力幅<=56 bit・残り<=7 bit・非負値・予約内storeのassertを維持/追加し、hot loopの幅分岐を省く。
全てのL3以上のframeはround 2とbyte一致し、bit出力の変更で圧縮率は変わらない。
L1/L2のFSEだけは最大log 7（128 state）で一候補を評価し、表の構築・参照量を減らす。
大きい表の二候補を評価する版よりbinaryのsequence table時間が減り、サイズの緩和分で収まった。
6-byte hash、強いmiss間引き、rep0だけを同位置で調べる案はサイズ超過、
一致内を常に4 byte間隔で挿入する案やhashの二位置更新は十分な速度増がなく採用していない。
段階ごとの比較は各案を同じ非XCTest条件で7回交互に測定し、profileは別encodeで再生成する。

最終sourceの段階profileは同じ非 XCTest buildで、計時callbackありの各level一回、binary全体の経過ms。
7回の最良値による速度表とは区別する。

| level | stage | round 2 ms | round 3 ms |
| --- | --- | ---: | ---: |
| 1 | match+parse | 51.829 | 38.535 |
| 1 | literals（集約を含む） | 15.033 | 11.931 |
| 1 | sequences | 19.448 | 13.139 |
| 1 | sequence tables | 4.734 | 1.927 |
| 1 | literal bits | 5.366 | 2.266 |
| 2 | match+parse | 60.674 | 40.185 |
| 2 | literals（集約を含む） | 14.898 | 11.735 |
| 2 | sequences | 19.819 | 13.468 |
| 2 | sequence tables | 4.770 | 1.924 |
| 2 | literal bits | 5.252 | 2.191 |
| 3 | match+parse | 69.952 | 69.362 |
| 3 | literals（集約を含む） | 13.280 | 10.958 |
| 3 | sequences | 22.032 | 20.233 |
| 3 | sequence tables | 4.626 | 5.671 |
| 3 | literal bits | 4.174 | 1.690 |

L3のsequence tablesの4.626 → 5.671 msは単回計測の揺れとして扱う。
L3のtable codeは変更しておらず、frameもround 2とbyte一致しているため、この値だけで処理の退行とはしない。

最終検証はreleaseの `ZstdEncoderTests` / `ZstdXXH64Tests` / `ZstdWriterConfigurationTests` /
`CompressedTarZstdTests` / `ZipZstdWriterTests` / `ZstdParallelBenchmarkTests` が30件成功・失敗0・54.703秒（build 86.35秒）。
`--disable-sandbox -c release -Xswiftc -enable-testing -debug-info-format none` と並列benchmarkのopt-inを使う。
このXCTestの速度値は性能表に使わない。debugは並列benchmarkを除く同じ5 classを
`--disable-sandbox -c debug -debug-info-format none` で実行し、29件成功・失敗0・123.103秒（build 9.41秒）。
頻度workspaceのraw/RLE/Huffman遷移、二位置loop末尾、bit境界と予約、L1/L2を含むrebaseを検証した。
L1/L2の64 MiB・16 frameとL3の256 MiB `.zst` / `tar.zst` で、1 / 4 / 8 / 12 thread間のbyte一致が成立する。
基準・round 2・round 3・CLIの全levelの228 frameをCLI `-t` / `-dc` で全byte照合し、
最終交互測定の27 frameも同じ出力と照合した（計255 frame、CLIサイズ生成込み36.572秒）。
fixtureは変更せず、全suiteは実行していない。

現行版の全levelのサイズ・速度・段階profile・必須oracle照合は、
`GYOSHUKU_ZSTD_BENCHMARK=1 GYOSHUKU_ZSTD_ALL_LEVELS=1` とreleaseの `ZstdEncoderBenchmarkTests` filterで再生成する。
XCTestには `-Xswiftc -enable-testing` を指定し、上の非XCTest表との数値を混ぜない。
表と同じ旧版比較には、`f273d34`・`914f6c0`・`4011086` の `Compression/Zstd/` のSwift sourceを取り出し、
型名・helper名だけを変えて上記commandで一つのprogramに組み込む。三つのcorpusを固定し、
全19 levelのframeを保存・CLI復号照合し、速度の7回交互測定とprofileの単回encodeを別々に行う。
全sample・負荷・source / corpusのSHA-256を記録し、最速値とframe byte数を集計する。

### Zstandard の writer 接続（2026-10-06）

公開 API は `ArchiveFormat.tarZstd`、`SingleStreamFormat.zstd`、`CompressionMethod.zstd = 93`。
`WriterOptions.zstdLevel` は1...19、既定3。参照 encoder の parameter と同一ではない自前 preset を使う。
範囲外は `invalidOption("zstdLevel")`。既定の書庫形式・ZIP Deflate・既存 codec の framing は変えない。

`ZstdWriterConfiguration` は片を `C = max(4 MiB, properties.windowSize)` にする。
現行 preset はレベル1...12で4 MiB、13...19で8 MiB。`ParallelZstdCompressor` は
`TarChunkCutter` と `OrderedChunkPipeline` を使い、片ごとに独立した `ZstdFrameEncoder` を作る。
frame は既知の content size と content checksum を必ず持ち、辞書 ID は使わない。
[RFC 8878 §3.1](https://www.rfc-editor.org/rfc/rfc8878.html#section-3.1) の frame 連結で
入力順を保つ。連結先に依存した履歴や entropy table は持たない。

tar.zst は小さい member 群を上限 C まで詰める。次の member 全体が入らなければその前で区切る。
C を越える member は header 群と本文を分け、それぞれを C 以下に分割する。
tar の終端二 block と blocking factor 20 の padding は、一つの独立した最後の frame にする。
単独 .zst は hint を使わず固定 C の片にし、空入力でも空 frame を一つ書く。
`compressionThreads` を上限とし、組立中の入力も未出力 frame の枠に含める。
`maximumPendingInputBytes(for: .tarZstd)` は解決した並列数 t × C。
finishAdditions は残りの片を出力し、入力 byte の進捗を通知する。終端は finish が書く。

`memoryLimit` は自前 LZMA に加えて Zstandard にも適用する。予算 B は
`min(memoryLimit（nil は物理メモリの50%）, 物理メモリの50%)`。
encoder の見積り E と入力・出力二片、framing の余白を数え、
一 worker の予約 M を `E + 2C + 3 × (C / 128 KiB + 1) + 1024` byte にする。
t は要求並列数と64、`B / M` の最小値。一つも入らなければ出力作成前に `invalidOption("memoryLimit")`。
window は縮めない。allocator の管理領域は見積りに含めない。

ZIP method 93はentryごとに一つのframeを符号化し、16 MiB以下のentryは独立workerで並列化する。
ZIP内のframe連結は使わず、entry内の並列化は行わない。
既知サイズのheader、128 KiB blockとchecksumを共通sinkに逐次渡す。
一codecのMは上のCを128 KiBに置き換えたもの。項目窓の追加予約とpending inputは下のwriter並列化節を参照。
[APPNOTE 6.3.10 §4.4.5](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) の
Zstandard の現行 ID は93（20は非推奨）。§4.4.3の要求 version 表には Zstandard の明記がないため、
writer は6.3を選び、local / central の両 header に63を記録する。
AES は外側の method 99と0x9901内の実 method 93、ZipCrypto は spool 後の CRC付き header を使う。
全 frame が暗号化対象。ZIP64 / updater の一括追加 / rewriter は共通の ZipWriter 経路で扱う。
予約長は `入力長 + 3 × (入力長 / 128 KiB + 1) + 18` byteとし、AES の28 byteを加える。
圧縮して縮まらない block の raw fallback と frame overhead を覆い、local header の patch 長を保つ。
macOS Archive Utility / ditto / unzip は method 93 を展開できない。

隣接 KaitoKit の `FormatReaderFactory` が圧縮地図を記録するのは gzip / bzip2 / XZ のみ。
Zstandard は `TarContainer.other(.zstd)` で、tar member の配置を持つ場合も splice 用 chunkMap はない。
`CompressedTarUpdater.assess` はnil、`open` は requiresRewriteで拒否し、出力を作らない。
tar.zst の削除・改名・追加・形式変換は `ArchiveRewriter` が全体を再符号化する。

実ツールは Zstandard CLI 1.5.7と7-Zip 26.03。`7zz i` と method 93の実書庫で対応を確認した。
`CompressedTarZstdTests` は level 1 / 3 / 19の `zstd -t`、`zstd -dc | bsdtar -xf -` と
KaitoKitの全 byte 往復、20 MiB入力の4 thread・frame境界・逐次とのbyte一致、rewriter編集を扱う。
`SingleStreamCompressorTests` の9形式に .zstを含め、既定は空・1 byte・128 KiB text・1 MiB + 17 byte乱数を両readerで復元する。
元の1 MiB text・9 MiB乱数は `…FullSize` に残し、`GYOSHUKU_LARGE_ENCODER_TESTS=1` で実行する。
`ZipZstdWriterTests` は上記3 levelの非暗号・AES・ZipCryptoを `7zz t / l -slt / x` とKaitoKitで照合し、
非暗号 entry の raw dataを `zstd -dc` でも独立に照合する。9 MiB超のentryが単一frameであること、
ZIP64予約・updater追加・rewriterの削除・改名・追加も検査する。
`ZstdWriterConfigurationTests` はメモリ拒否・並列数制限と実際のpending input上界、固定片のthread間byte一致を扱う。

検証は下のコマンドで成功。sandbox が user cache への書込を拒否するため、module cacheを作業ツリー内に置く。

```sh
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift build --disable-sandbox
swift test --disable-sandbox --filter 'Zstd|CompressedTar|SingleStream|Zip'
swift test --disable-sandbox --filter DefaultOutput
git diff --check
git diff --stat
```

指定 filter は352件、既定のopt-in / 環境条件によるskipが16件、失敗0件（約42分）。
frozen出力の `LHADefaultOutputTests` / `LZMAWriterDefaultOutputTests` は2件成功。
`SevenZipWriterByteIdentityTests` も指定filter内で成功。fixtureは再生成せず、KaitoKitの変更とcommitは行わない。

### writerの項目・folder並列化（2026-10-07）

codec内部は変更しない。`EntryCompressionConfiguration`、`OrderedChunkPipeline`とunlink済みspoolで
ZIP 12/14/95/93/98と非solid 7z LZMA/BZip2/PPMdの16 MiB以下の項目を並列圧縮する。
LHAは1 MiB超〜16 MiBのmemberに同じ項目窓を使い、既存writerで完成recordをspoolへ作る。
読み取りの容量待ちは入力確保より前。ZIP/LHAのCRC計算はworker、7zの元入力CRCは呼出側。
ZIP/7zのheader確定、ZIP暗号化、7z IVの生成とpackの順序は呼出側で保つ。
LHAはworkerでheaderを含むrecordを完成させ、呼出側で投入順に出力する。
ZIP/7zの圧縮結果は最初の1 MiBをメモリに保持し、超えたときだけunlink済みdisk spoolへ移す。
空項目・directory・symlink・1 MiB以下のstored項目は同じZIP窓へinlineで投入し、圧縮spoolを作らない。
これらの前で窓全体をdrainしない。1 MiB超のStoredとZipCryptoのStored・空の通常fileは従来のstream経路を使う。
圧縮するZipCryptoの通常fileはspool付きの項目窓を使い、CRC確定後の暗号化はcallerが行う。
directory・symlinkは暗号化しないため、ZipCrypto指定でもinlineの窓を使える。
ZIP Zstdの64 KiB未満は呼出側で符号化し、投入順に出力する。
項目別APIでは空のZIP窓の64 KiB以上の圧縮項目（ZipCrypto以外）を一つ保留する。後続が来ればworkerへ渡し、
単独でfinish/finishAdditions/drainを迎えればcallerが従来のstream encoderで直接書く。
保留入力も窓の一枠に数え、圧縮出力のdisk spoolと再読取を省く。
一括追加APIの単独圧縮項目にはこの保留を使わず、worker一つとspoolを通る。Mac miniのreviewer計測ではnew/base=1.038で1.05以内。
LHAのseekを使う中memberの完成recordはdiskへ保持し、小memberはheaderとpayloadをメモリspoolへ置く。中memberを窓の始点で一つ保留し、次のmemberが来れば投入する。
単独のままfinish/endMembers/finishAdditionsに至るか16 MiB超のmemberが来れば、既存のaddStreamedParallelを全threadsで使う。
項目窓が非空なら小memberも同じ窓へ投入し、小・中の切替でdrainしない。
LHAの内部並列数は、1 MiBの実際の片数とmax(1, 要求threads / 投入後の未出力数)の最小値。
未出力jobの合計を要求threadsで制限しない。round 3の合計上限はcorpus LH7/t=12をround 1比32.3%遅くしたため撤回する。
先頭の出力までの割当上界はt×H(枠数)で、t=12なら約3t。先頭を出力して再投入する場合も、
各jobは最大t、窓はGCD poolの1/4以下なので上界は枠数×t。各枠のcodec状態は元からt分予約し、入力窓も有界に保つ。
7z folderは実際の片数、未割当threads、max(1, 要求threads / 投入後の未出力数)の最小値。
こちらは未出力jobの合計を`min(要求threads, floor(予算 / codec状態))`以下に保つ。BZip2は既存spliceの解決した並列数を使う。
先頭の出力開始時に予約を返し、予算待ちは先頭だけをemitする。出力失敗は窓をabandonし、二重返却しない。
7z LZMA2/Deflateは既存chunk幅での片数まで、7zの単一stream codecは1とする。
内部writerには項目窓を作らず再帰を防ぐ。ZIP一括追加も同じ項目窓を使い、
source descriptorの最大4本、失敗の項目帰属、caller threadでの進捗・didFinish順を保持する。
Stored batchの先読み上限は従来の1 MiBへ戻し、大きいStored項目はstreamで出力する。
16 MiBを超えるZIP/非solid項目は従来のstream経路。ZIP XZと7z LZMA2/Deflateの内部blockは並列化を保つ。
worker内部のOrderedChunkPipelineが1 threadならworker自身で符号化し、待機するGCD threadを増やさない。
外側の1 thread窓は従来の非同期を保ち、入力読取と圧縮を重ねる。
solid/filter folderの窓は上のsolid節のとおり。取消しは共有latchでworkerのread/writeにも伝え、
abortは項目・片の着手済みworkerを待ってspool descriptorを解放する。
LHAの片窓と7z folder内の窓も成功・失敗・取消しのすべてで終了を待ち、補助spoolを閉じる。

一workerの予約は`S + 16 MiB + 1 MiB + 4 × IOChunk.size`（IOChunk=256 KiB）。
LHA項目窓はSを要求threads分予約する。7z solid/filter窓は一枠につき`I/O + 最大片数 × S`を予約する。
LZMA1/PPMd/Copyの最大片数は1、LZMA2/Deflateは`min(要求threads, ceil(folder上限 / 片サイズ))`。
folder上限はsolidのblockSize、filter付き非solidは16 MiB。既存の片サイズとfolder区切りは変えない。Sは以下。

| codec | S |
|---|---|
| 自前LZMA1 / XZ / 7z LZMA2 | 既存`LZMAWriterConfiguration.memoryPerThread` |
| Apple XZ / LZMA2 | 130 MiB |
| Zstandard | 既存streaming用`ZstdWriterConfiguration.memoryPerThread` |
| BZip2 | `ParallelBzip2StreamEncoder.memoryReservation(level:threads: 1)`（level 9は41,501,063 byte） |
| PPMd | 指定model memory + 2 MiB |
| Deflate / Copyのfilter folder | 4 MiB |
| LHA中member | 8 MiB（LH7の約3.7 MiB＋符号列の一時コピー・Huffman領域） |

LZMA/XZ/Zstandardの新規項目/folder窓は`min(memoryLimit（nilは物理メモリ50%）, 物理メモリ50%)`を予算にする。
Appleも窓の見積りに含めるが、既存のblock経路の内部並列数・予約は変更しない。
BZip2は単一stream spliceの導入後、項目/folder窓と内側codecの予約にも同じmemoryLimit予算を使う（上のBZip2節）。
PPMd/Deflate/Copy/LHAは従来どおりmemoryLimitの対象外で物理メモリ50%を予算にする。
tは要求threadsと`floor(GCD constrained pool / 4)`と`floor(予算/予約)`の最小値。2枠未満なら既存の逐次経路へ戻し、
従来受理できた単一codecのmemoryLimitを拒否しない。モデル・辞書・片境界を縮めない。
既定の要求threadsは下記の topology / powerPolicy で開始時に解決する。
7z並列窓の割当codec合計をa、folder枠数をf、最大片数をpとすると`a <= min(要求threads, floor(予算/S), f × p)`。
従ってpeak予約は`a × S + f × I/O <= f × (p × S + I/O) <= 予算`。要求threads分のcodec状態を各folderへ重複予約しない。
公開pending-inputの式`f × folder上限`は維持するが、fの増加により値が増える。
物理16 GiB・予算8 GiB・要求12・既定level・64 MiB solidでLZMA2は5→12枠（320→768 MiB）、LZMA1は6→12枠（384→768 MiB）。
PPMd level 9の明示64 MiB solidは3→12枠（192→768 MiB）、既定384 MiB solidは同期のまま。
filter付き非solidのLZMA2 / LZMA1は80→192 / 96→192 MiB。PPMd level 9は既定block上限384 MiBによる同期経路を維持し、filter付き非solidは16 MiBのまま。
BZip2の式・予約と明示並列数の他形式の上界は維持する。
自動並列数と項目窓の固定16上限を撤廃したため、既定入力上界は topology・電力状態・pool・codecメモリ制限に従って変わる。
入力上界は上の`maximumPendingInputBytes`表。spoolのfile cacheとallocator管理領域はcodecの予約に含めない。
round 3はtree/single/single16r/small/LHA混在をthreads=1/12、corpus4方式をthreads=12で三版各5回測定した。
810 sampleの出力size・SHA-256が一致し、54比較すべてnew/base <= 1.05、tree/smallの22比較もnew/round1 <= 1.05。
round 3のLHA corpus LH7は内部thread合計上限でround 1比+32.3%（0.7092→0.9385秒）となった。
baseの3.9569秒より速くてもround 1への回帰を残すため、round 3bでLHAの合計上限を撤回した。7zの上限は維持する。
ZIP treeのZstd/BZip2はround 1の0.1675/0.5689秒から0.1303/0.5466秒へ改善した。
round 2の最終release executable（enable-testing無し）で、単一10 MiB・5,000小file・LHA混在・同じ256 MiB corpusの47条件を
threads=1/12、f273d34と交互に各5回測定した。940 sampleの出力size・SHA-256が一致し、94比較すべてnew/base <= 1.05。
最大は単一ZIP Zstd/t=12の+4.35%。256 MiB/t=12の改善はZIP BZip2/LZMA/XZ/Zstd/PPMdが
2.87/3.23/5.65/3.97/3.05倍、7z LZMA2 solidが5.04倍、LHA LH5/6/7が3.96/4.83/5.41倍。
5,000小fileのZIP BZip2は6.80倍、7z LZMAは5.79倍。全sampleの1分loadは1.51〜8.48。
以下はround 1時点の記録。

round 1（f9d5178）の256 MiB混合corpus（96×2 MiB＋64 MiB）、既定level、threads=12でf273d34と交互に各5回測定した。
最短wallのthroughputはZIP XZが12.31→62.42 MB/s（5.07倍、CPU/wall=7.46）、
ZIP BZip2は9.95→25.08、LZMAは9.00→25.64、Zstdは168.55→526.55、PPMdは6.03→17.66 MB/s。
7z LZMA2 solid16 MiBは14.95→76.66 MB/s（5.13倍、8.13core）、非solid Delta4は12.63→65.07 MB/s（5.15倍、7.08core）。
LHA LH5/6/7は150.20→605.74 / 97.06→474.26 / 66.62→373.19 MB/s、CPU/wallは7.53 / 8.92 / 9.85。
全53経路で基準版と変更版、threads=1/12の出力size・SHA-256が一致した。
大きい単一LZMA1/PPMd/ZIP BZip2/Zstdは逐次区間が残り、並列化可能な全対象で6coreを使う目標は未達。
ZIP93の64 MiB memberを4 MiB frameへ分けるprobeは7zz26.04とKaitoKitが受理したが、
全ZIPのbody差し替えによる計算上のサイズ増加は3.583%（単一16,990,650→連結20,122,354 byte）で、
0.3%上限を超えるため採用しない。7zz26.03そのものと候補全ZIPの速度は未検証。
wall/CPU・参照tool・全sample・対象testの詳細は[実測記録](verification/2026-10-07-writer-multicore.md)を参照。


## 自動並列数と電力方針

`CPUTopology` は `hw.activecpu`（失敗時は `ProcessInfo.activeProcessorCount`）と、
`hw.nperflevels` / `hw.perflevelN.logicalcpu` / `physicalcpu` を読む。0が最高性能で、名称を参照しない。
levelの欠落・0は全 CPU を持つ単一levelに戻す。core classや製品別の固定数は持たない。
通常の要求数は全active logical CPU、削減時は `max(1, min(ceil(n/2), 最低levelのlogical CPU数))`。
levelが一つなら `ceil(n/2)`。その後 `max(1, 物理メモリGiB)` と既存codecメモリresolverで制限する。
`.reduceInLowPowerMode` はLow Power Mode、`.reduceInLowPowerModeOrThermalPressure` はそれに加えて
serious / criticalで削減、`.alwaysUseAllCores` は削減しない。明示並列数には作用しない。
`WriterOptions.automaticCompressionThreads(powerPolicy:)` は表示用の現在値、`compressionThreadsRange` は明示値の受理範囲1...1024。
writer / updater / rewriter / 単独圧縮の入口で内部optionsコピーに自動値を固定し、検証・add・commit・workerは同じ値を使う。
外部の `maximumPendingInputBytes(for:)` も呼出しごとに一度解決するため、ジョブ開始後の電力状態によっては内部の固定値と異なる。
片・chunk・block・folder境界は並列数に依存させない。

項目 / folder窓の安全上限は `floor(pool / 4)`（最低1）。poolは `kern.wq_max_constrained_threads` を読み、
poolの安全上限はprocess内で共有し、失敗時はxnuの既定規則 `max(64, 5 × activeCPUs)` を使う。64はkernel fallbackの下限で、要求並列数の上限ではない。
ZIP項目workerは内側を1にし、XZの逐次片はinline実行する。7z folderworkerはOrderedChunkPipeline / LZMA2ChunkPipeline / ParallelBzip2StreamEncoderの片を待つが、片workerはcodecを実行する葉であり、さらにGCD workerを待たない。
ParallelXZCompressorも同じ葉に到達し、filterはそのfolder内で逐次。LHA memberworkerは内側LHAWriterの項目並列を無効にし、1 MiB片workerだけを待つため、外側の再帰はない。
外側の待機は一段だけなのでpoolの1/4以下にし、残り3/4を内側の葉、先読み、呼出側の待機と他の仕事の余地に残す。
先読みは最大4 descriptorを扱い、取得したworker自身が読取を完了して解放するため、別の内側workerの開始を待つ循環は作らない。
内側の窓が大きくても未着手の葉はthreadを占有せず、既に動く葉の完了で窓が進む。このジョブの入れ子によるpoolの枯渇を防ぐための上限であり、他ライブラリが同じprocessのpool全体を塞ぐ状況までは保証しない。
メモリ制限と全folderの割当codec数制限は引き続き適用する。
