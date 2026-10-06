# GyoshukuKit 設計書(2026-09-10 初版)

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
GyoshukuKit 0.7.0 は KaitoKit 0.12.x に依存する。`@_spi` は SemVer の保証外で、
`public import KaitoKit` により公開 API にも KaitoKit の型を含むため、次の minor は再検証が必要。
隣接 checkout の自動選択と、SwiftPM / Xcode の `checkouts/` 内では tag を使う規則は維持する。

### 2.1 ソースの配置(2026-09-28)

`Sources/GyoshukuKit/` は役割ごとの階層にする。SwiftPM は階層を見ないので `Package.swift` は変えない。
file 名は中の主な型の名前に合わせ、`Records` / `Layout` / `EditPlan` / `Updater` / `Writer` / `SelfCheck` の
語を形式をまたいで同じ意味で使う。

| directory | 内容 |
| --- | --- |
| `API/` | 公開の形式・設定・error(`ArchiveEditing`、`ArchiveFormat`、`WriterOptions`、`WriterError`、`UpdaterError`、`UpdaterRouteError`) |
| `Writer/` | 新規作成の facade `ArchiveWriter`(形式ごとの writer への振り分け)と、ディスク側の先読み・署名 |
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
| 3 | 7z | ○(non-solid・AES-256 / header 暗号化を選択可能) | ○(SevenZipUpdater、末尾へ) | ○(header・移動 pack、solid の一部削除はその folder だけ再圧縮) |
| 4 | LHA / LZH | ○(`-lh5-`) | ○(LHAUpdater、末尾へ) | ○(header と位置の動く member だけ) |
| — | RAR | × license が禁じる | × | × |
| — | CAB / RPM / ISO / xar | × | × | × |

圧縮 tar は session reader の復号済み image と区切りの地図から編集する。
継げる区切りが無い入力は最初の変更で全体を G1 の配置に符号化する。
従来の追加位置・所有者設定と open 時に拒否される入力は ArchiveRewriter を使う。
UI 側は進捗と取り消しを必ず出す。

### ZIP の圧縮方式

`CompressionMethod` は stored（0）、Deflate（8）、BZip2（12）、XZ（95）を持ち、既定は Deflate。
writer と updater の新規追加、ZIP への ArchiveRewriter は同じ ZipWriter を使う。
updater の既存 local record・圧縮 byte・central directory は追加時にそのまま運ぶ。
空ファイル・directory・symlink と、heuristic が選ぶ圧縮済み拡張子は stored。

method 12 は `Bzip2StreamEncoder` を項目ごとに一つ作り、`bzip2Level` で同期圧縮する。
tar.bz2 の chunk stream の連結は使わない。最大の codec state は level 9 で約7.6 MBと I/O buffer。
method 95 は `ParallelXZCompressor` と `XZFraming` を使い、最大16 MiBの block を
`compressionThreads` で並列化する。hint の無い固定幅を使い、stream header・blocks・index・footer を
一組だけ書く。通常枠 t 個と組立中1個の入力は `(t + 1) × 16 MiB` 以下で、codec と出力は
thread ごとに約130 MiB。index は block 数に比例する。両方式とも add の終了時に出力を完了する。
一括 disk 追加では通常ファイルを項目別の streaming 経路へ戻し、Deflate 専用 worker に渡さない。
全ての並列数と AES / ZipCrypto を併用でき、追加の unsupportedOption はない。

[APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) §4.4.3・§4.4.5 は
BZip2 の展開要求 version を4.6とする。XZ の要求 version は明記されていないので、
[7-Zip 26.03 の公開定義](https://github.com/ip7z/7zip/blob/main/CPP/7zip/Archive/Zip/ZipHeader.h) と
生成した ZIP の2.0を使う。LZMA（method 14）の6.3は流用しない。
method 95 の file data が完全な .xz stream であることは、7zz が作った ZIP の stream 単独復号と
KaitoKit の往復で確認する。圧縮方式、ZIP64、暗号化の要求 version の最大値を両 header に書く。
CRC32・確定サイズ・ZIP64 の事前予約・seek による local header patch は既存の経路を使い、descriptor は書かない。
XZ の予約長は Apple encoder の block ごとの容量上限と framing の上界から算出する。

macOS Archive Utility / ditto と `/usr/bin/unzip` は method 12 / 95 を展開できない。
Deflate を互換性の既定とし、BZip2 / XZ は KaitoKit や 7-Zip を使う場合の opt-in とする。

### LHA の並列 LH5（P4-G-a）

`ArchiveWriter.create` は `options.resolvedCompressionThreads` を LHAWriter に渡す。
rewriter もこの経路を使う。1 は従来の同期処理、2 以上では 1 MiB 以下の member を
`OrderedChunkPipeline` に渡し、CRC と入力の読み切りは呼出側で行う。directory も投入順を保つ。
入力を確保する前に容量を待ち、同時に保持する入力を並列数までに抑える。

大きい member は従来と同じ 1 MiB と直前 8 KiB の履歴に分ける。各 worker が返す完全な byte と
端数 bit を投入順に padding なしで継ぐ。LH5 の辞書・Huffman block の区切りは従来どおりで、
どの並列数でも直列時の byte と一致する。raw を先に出力し、縮めば spool から置き換える。
完成 byte の累計が原本サイズ以上になった区切りで残りの符号化を破棄し、raw の保存を続ける。

`add` の後に符号化が残る場合、失敗・取消しは後続の add / finish / internal の endMembers で通知し、
従来の abort で出力を削除する。大きい member の前と終了時に member の pipeline を drain する。
internal の `endAppendedMembers()`（tar と共通）は終端・fsync・close なしで追加の終わりを返す。
init の `recordsMembers` を有効にしたとき（updater が使う `ArchiveWriter.lhaAppend` は常に有効）だけ、実際の出力時点の header 絶対位置・header/data 長・method と
canonical な名前の byte（directory の 0xFF を `/` に変換し filename を連結）を保存する。
LHAUpdater はこの追加 writer を既存の `SegmentedArchiveOutput` と組み合わせる。

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
xz の cache 上限は8 threadsで256 MiBのまま。事前符号化と書出しの両方に下記の軽い block の枠を使う。
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

writer と updater は同じ二つの上限で区切る。hint の無い入力は16 MiBの固定幅のまま、
組立の予約も16 MiBの片のままとする。hint の無い経路に packing を使うと固定幅へ届かず停止する。
`OrderedChunkPipeline` の `weight` は入力 byte 数。`lightWeightLimit > 0` かつ
`0 < weight <= lightWeightLimit` の item だけを軽いものとする。
未出力の重い item が threads 以上、または全 item が `2 × threads + 1` 以上の間、
先頭を順に書き出してから次を投入する。次の item の重みは待機条件に使わない。
既定の limit と weight は0で、従来の枠を保つ。取消し・失敗・abandon の扱いも共通。

tar.xz だけが threads > 1 のとき `lightChunkLimit`（64 KiB）を指定する。
writer は block の入力長、updater の事前符号化と書出しは part の image 長を weight にする。
運ぶ part と cache 済みの part は入力が無いので weight 0。threads == 1 は同時に一つだけを符号化する。
待機中の入力と組立中の入力の上界は `(threads + 1) × (piece + lightChunkLimit)`。
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
| ZIP stored / BZip2 | 0（BZip2 は同期処理） |
| ZIP Deflate | `t × DeflateBlock.size`（ZipCrypto は 0） |
| ZIP XZ | `(t + 1) × 16 MiB`（ZipCrypto も同じ。項目の終了時には全て出力） |
| tar | 0 |
| tar.gz | `(t + 1) × DeflateBlock.size` |
| tar.bz2 | `(t + 1) × (5 × bzip2Level × 100,000)` |
| tar.xz | `t × 16 MiB + 4 MiB + (t > 1 ? (t + 1) × 64 KiB : 0)` |
| 7z | `t × 16 MiB` |
| LHA | `t > 1 ? t × 1 MiB : 0` |

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
KaitoKit 0.11.0 以降が SPI を提供するため、GyoshukuKit 0.7.0 の URL 依存は
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
圧縮方式は既存の拡張子 heuristic と stored / deflate / bzip2 / xz 設定を使い、両 header の method を 99、
version needed を 51、flag を bit 0 + bit 11 にする。0x9901 の 7 byte 本体は、vendor version、
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

### 7z AES-256 と header

非空 stream ごとに non-solid folder を作る。実測した `7zz a -p... -mhe=off -mhc=off` と
同じ decoder 順で AES（06 F1 07 01）を coder 0、LZMA2（21）を coder 1 に置く。
bind pair は input 1 ← output 0、packed input は暗黙の 0。unpack sizes は AES 出力である
圧縮結果の真の長さ、LZMA2 出力であるファイル長の順で、substream CRC は元ファイルの CRC。

AES property は `53 0F` + 16 byte IV（NumCyclesPower 19、salt なし）。UTF-16LE パスワードと
8 byte little-endian counter を 0 から 2^19 - 1 まで連結して SHA-256 へ入力し、鍵を得る。
同じ鍵は書庫内で再利用できるが IV は毎回乱数で生成する。AES-256-CBC は PKCS#7 を使わず、
最後の block の不足だけを zero pad する。真の圧縮長を AES の unpack size に記録する。
空ファイル・directory は従来の EmptyStream / EmptyFile 表現を使う。

`SevenZipWriter.lzmaChunkSize` は **16 MiB**、I/O 用の `chunkSize` は **256 KiB** と分離する。
短い read が返っても最大 16 MiB まで入力を集めてから Apple の LZMA buffer API を一度呼ぶ。
各片の LZMA2 辞書 reset を残して終端 byte だけを取り除き、最後に一度だけ終端を書く。
圧縮出力も 256 KiB ごとに分割して暗号化・書込を行う。一つの folder 内で decoder が reset する
正当な stream であり、平文・暗号出力とも spool は不要。

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
> Password output supports ZIP WinZip AES-256 or ZipCrypto, plus non-solid 7z
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
`.upToNextMinor(from: "0.12.0")` とし、KaitoKit 0.12.0 → GyoshukuKit 0.7.0 → KaitoFinder 0.5.0 の順にリリースする。

生存 file は元の順、追加は呼出し順で末尾へ置く。運ぶ folder の圧縮 byte、coder と props、bind、
packed input、unpack size、CRC、AES の IV を保ち、file の UTF-16LE の生の名前、FILETIME、属性、
empty / anti / StartPos も保つ。改名だけは NFC と directory の末尾 `/` を適用し、同じ正規化名への
改名は元の byte のままにする。予約と衝突判定は既存の共通部品を使う。

全部を削除した folder は落とし、solid の一部だけを削除した場合は、その folder 全体を順に復号して
CRC を照合し、生存 file を元の順の一つの LZMA2 folder に作り直す。他の folder は復号しない。
AES の folder は暗号化の予約が無ければ AES のまま。作り直しの出力は `makeScratch` に先に書いて長さを
確定し、S24-c1 の `.scratch` で写す。後続 pack は新しい位置へ写す。生存 stream が 0 byte だけの場合も
LZMA2 の `00` と各 substream の CRC を持つ folder を書く。
folder ごとの作り直し・AES 変換・password 検証の状態と encryptor は `SevenZipFolderWorkset` が持ち、`SevenZipUpdater` は
追加・commit・自己照合のライフサイクルと出力だけを担う（2026-09-29）。
`SevenZipFolderEncoder` は既存 writer の連結規則を共用し、本文 16 MiB / header 1 MiB の片を
`resolvedCompressionThreads` で並列化する。通常の writer の出力 byte は変えない。

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
